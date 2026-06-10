"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { SendPOModal } from "@/components/SendPOModal";
import SpinButton from "@/components/SpinButton";
import Spinner, { LoadingBlock } from "@/components/Spinner";
import { RowAction } from "@/components/RowAction";
import { PO_STATUS_LABEL, PO_TERM_ZH, type POStatus } from "@/lib/poStatus";
import { PR_TERM_ZH } from "@/lib/prStatus";

type Supplier = {
  id: number;
  name: string;
  code: string | null;
  preferred_po_channel: string | null;
  line_contact: string | null;
  email: string | null;
  phone: string | null;
};

type SendCtx = {
  poId: number;
  poNo: string;
  supplier: Supplier | null;
  items: {
    sku_code: string;
    product_name: string;
    qty_ordered: number;
    unit_cost: number;
    unit_uom: string | null;
  }[];
  total: number;
};

type PO = {
  id: number;
  po_no: string;
  supplier_id: number;
  supplier_name: string | null;
  status: POStatus;
  total: number;
  expected_date: string | null;
  sent_at: string | null;
  sent_channel: string | null;
  stockout_at: string | null;
  created_at: string;
  updated_at: string;
  pr_id: number | null;
  pr_no: string | null;
  product_names: string[];
  item_count: number;
};

type StatusTab = "all" | POStatus;

const STATUS_LABEL = PO_STATUS_LABEL;

const STATUS_BADGE: Record<POStatus, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  sent: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  partially_received:
    "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  fully_received:
    "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  closed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

const STATUS_TAB_ORDER: StatusTab[] = [
  "all",
  "draft",
  "sent",
  "partially_received",
  "fully_received",
  "closed",
  "cancelled",
];

const PAGE_SIZE = 30;

type SortCol = "updated_at" | "expected_date" | "total" | "po_no" | "supplier";

export default function PurchaseOrdersListPage() {
  const [pos, setPos] = useState<PO[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<StatusTab>("all");
  const [search, setSearch] = useState("");
  const [supplierFilter, setSupplierFilter] = useState<number | "all">("all");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [groupBy, setGroupBy] = useState<"none" | "pr" | "supplier">("none");
  const [sortBy, setSortBy] = useState<SortCol>("updated_at");
  const [sortDir, setSortDir] = useState<"asc" | "desc">("desc");
  const [page, setPage] = useState(1);
  const [reloadKey, setReloadKey] = useState(0);
  const [sendBusyId, setSendBusyId] = useState<number | null>(null);
  const [sendCtx, setSendCtx] = useState<SendCtx | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();

        // 1. 撈 POs(拉多一點以利 KPI 計算與分頁)
        const { data: poData, error: poErr } = await supabase
          .from("purchase_orders")
          .select(
            "id, po_no, supplier_id, status, total, expected_date, sent_at, sent_channel, stockout_at, created_at, updated_at, suppliers(name)",
          )
          .order("updated_at", { ascending: false })
          .limit(500);
        if (poErr) throw new Error(poErr.message);
        if (cancelled) return;

        type RawPO = {
          id: number;
          po_no: string;
          supplier_id: number;
          status: POStatus;
          total: number;
          expected_date: string | null;
          sent_at: string | null;
          sent_channel: string | null;
          stockout_at: string | null;
          created_at: string;
          updated_at: string;
          suppliers: { name: string } | { name: string }[] | null;
        };
        const baseList: PO[] = ((poData as RawPO[] | null) ?? []).map((r) => {
          const sup = Array.isArray(r.suppliers) ? r.suppliers[0] : r.suppliers;
          return {
            id: r.id,
            po_no: r.po_no,
            supplier_id: r.supplier_id,
            supplier_name: sup?.name ?? null,
            status: r.status,
            total: Number(r.total),
            expected_date: r.expected_date,
            sent_at: r.sent_at,
            sent_channel: r.sent_channel,
            stockout_at: r.stockout_at,
            created_at: r.created_at,
            updated_at: r.updated_at,
            pr_id: null,
            pr_no: null,
            product_names: [],
            item_count: 0,
          };
        });

        // 2. 透過 purchase_order_items + purchase_request_items 找來源 PR + 商品/品項
        const poIds = baseList.map((p) => p.id);
        const poToPR = new Map<number, number>();
        const poItemMap = new Map<number, number[]>(); // po_id -> sku_ids[]
        if (poIds.length) {
          const { data: poiRows } = await supabase
            .from("purchase_order_items")
            .select("id, po_id, sku_id")
            .in("po_id", poIds);
          const poiToPo = new Map<number, number>();
          for (const r of poiRows ?? []) {
            poiToPo.set(r.id, r.po_id);
            if (!poItemMap.has(r.po_id)) poItemMap.set(r.po_id, []);
            poItemMap.get(r.po_id)!.push(r.sku_id);
          }
          const poiIds = (poiRows ?? []).map((r) => r.id);
          if (poiIds.length) {
            const { data: priRows } = await supabase
              .from("purchase_request_items")
              .select("po_item_id, pr_id")
              .in("po_item_id", poiIds);
            for (const r of priRows ?? []) {
              const po = r.po_item_id ? poiToPo.get(r.po_item_id) : null;
              if (po && r.pr_id) poToPR.set(po, r.pr_id);
            }
          }
        }

        // 3. 撈 SKU -> product name(批次)
        const allSkuIds = Array.from(
          new Set(Array.from(poItemMap.values()).flat()),
        );
        const skuToProduct = new Map<number, string>();
        if (allSkuIds.length) {
          const { data: skuRows } = await supabase
            .from("skus")
            .select("id, products!inner(name)")
            .in("id", allSkuIds);
          type SkuLite = {
            id: number;
            products: { name: string } | { name: string }[] | null;
          };
          for (const s of (skuRows as SkuLite[] | null) ?? []) {
            const prod = Array.isArray(s.products) ? s.products[0] : s.products;
            if (prod?.name) skuToProduct.set(s.id, prod.name);
          }
        }
        for (const p of baseList) {
          const skuIds = poItemMap.get(p.id) ?? [];
          p.item_count = skuIds.length;
          const nameSet = new Set<string>();
          for (const sid of skuIds) {
            const name = skuToProduct.get(sid);
            if (name) nameSet.add(name);
          }
          p.product_names = Array.from(nameSet);
        }
        const prIds = Array.from(new Set(Array.from(poToPR.values())));
        const prMap = new Map<number, string>();
        if (prIds.length) {
          const { data: prRows } = await supabase
            .from("purchase_requests")
            .select("id, pr_no")
            .in("id", prIds);
          for (const r of prRows ?? []) prMap.set(r.id, r.pr_no);
        }
        for (const p of baseList) {
          const prId = poToPR.get(p.id);
          if (prId) {
            p.pr_id = prId;
            p.pr_no = prMap.get(prId) ?? null;
          }
        }

        if (!cancelled) {
          setPos(baseList);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadKey]);

  // === KPI 統計 ===
  const today = new Date().toISOString().slice(0, 10);

  const stats = useMemo(() => {
    const acc = {
      draft: 0,
      sent: 0,
      partially_received: 0,
      fully_received: 0,
      closed: 0,
      cancelled: 0,
      overdue: 0,
      pendingAmount: 0,
    };
    for (const p of pos ?? []) {
      acc[p.status] += 1;
      const inFlight =
        p.status === "sent" || p.status === "partially_received";
      if (inFlight) acc.pendingAmount += p.total;
      if (inFlight && p.expected_date && p.expected_date < today) {
        acc.overdue += 1;
      }
    }
    return acc;
  }, [pos, today]);

  // 供應商下拉選項
  const supplierOptions = useMemo(() => {
    const set = new Map<number, string>();
    for (const p of pos ?? []) {
      if (p.supplier_id && p.supplier_name) {
        set.set(p.supplier_id, p.supplier_name);
      }
    }
    return Array.from(set.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [pos]);

  // tab counts
  const tabCounts = useMemo(
    () => ({
      all: pos?.length ?? 0,
      draft: stats.draft,
      sent: stats.sent,
      partially_received: stats.partially_received,
      fully_received: stats.fully_received,
      closed: stats.closed,
      cancelled: stats.cancelled,
    }),
    [pos, stats],
  );

  // filter
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (pos ?? []).filter((p) => {
      if (tab !== "all" && p.status !== tab) return false;
      if (supplierFilter !== "all" && p.supplier_id !== supplierFilter)
        return false;
      if (dateFrom && (p.created_at ?? "") < `${dateFrom}T00:00:00`)
        return false;
      if (dateTo && (p.created_at ?? "") > `${dateTo}T23:59:59.999`)
        return false;
      if (q) {
        const hits = [p.po_no, p.supplier_name, p.pr_no]
          .filter((x): x is string => !!x)
          .some((x) => x.toLowerCase().includes(q));
        if (!hits) return false;
      }
      return true;
    });
  }, [pos, tab, supplierFilter, dateFrom, dateTo, search]);

  // sort
  const sorted = useMemo(() => {
    const arr = [...filtered];
    arr.sort((a, b) => {
      let av: string | number;
      let bv: string | number;
      if (sortBy === "total") {
        av = a.total;
        bv = b.total;
      } else if (sortBy === "po_no") {
        av = a.po_no;
        bv = b.po_no;
      } else if (sortBy === "expected_date") {
        av = a.expected_date ?? "";
        bv = b.expected_date ?? "";
      } else if (sortBy === "supplier") {
        av = a.supplier_name ?? "";
        bv = b.supplier_name ?? "";
      } else {
        av = a.updated_at;
        bv = b.updated_at;
      }
      if (av < bv) return sortDir === "asc" ? -1 : 1;
      if (av > bv) return sortDir === "asc" ? 1 : -1;
      return 0;
    });
    return arr;
  }, [filtered, sortBy, sortDir]);

  // 篩選變動 → 重置到第 1 頁
  useEffect(() => {
    setPage(1);
  }, [tab, search, supplierFilter, dateFrom, dateTo, sortBy, sortDir, groupBy]);

  const total = sorted.length;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const pageRows = sorted.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  // group
  const grouped = useMemo(() => {
    if (groupBy === "none") return null;
    const map = new Map<string, { label: string; rows: PO[] }>();
    for (const p of pageRows) {
      let key = "—";
      let label = "—";
      if (groupBy === "pr") {
        if (p.pr_id) {
          key = `pr-${p.pr_id}`;
          label = `${PR_TERM_ZH} ${p.pr_no ?? `#${p.pr_id}`}`;
        } else {
          key = "manual";
          label = "手動建立 / 無來源 PR";
        }
      } else {
        key = p.supplier_id ? `sup-${p.supplier_id}` : "no-sup";
        label = p.supplier_name ?? "(未指定供應商)";
      }
      let slot = map.get(key);
      if (!slot) {
        slot = { label, rows: [] };
        map.set(key, slot);
      }
      slot.rows.push(p);
    }
    return Array.from(map.entries())
      .sort((a, b) => a[1].label.localeCompare(b[1].label))
      .map(([k, v]) => ({ key: k, ...v }));
  }, [pageRows, groupBy]);

  async function openSendModal(po: PO) {
    setSendBusyId(po.id);
    try {
      const supabase = getSupabase();
      const [{ data: supRow }, { data: itemRows }] = await Promise.all([
        supabase
          .from("suppliers")
          .select(
            "id, name, code, preferred_po_channel, line_contact, email, phone",
          )
          .eq("id", po.supplier_id)
          .maybeSingle(),
        supabase
          .from("purchase_order_items")
          .select("sku_id, qty_ordered, unit_cost")
          .eq("po_id", po.id)
          .order("id"),
      ]);
      const skuIds = (itemRows ?? []).map((r) => r.sku_id);
      const { data: skuRows } = skuIds.length
        ? await supabase
            .from("skus")
            .select("id, sku_code, variant_name, base_unit, products!inner(name)")
            .in("id", skuIds)
        : { data: [] as unknown[] };
      type SkuLite = {
        id: number;
        sku_code: string;
        variant_name: string | null;
        base_unit: string | null;
        products: { name: string } | { name: string }[];
      };
      const skuMap = new Map<
        number,
        { sku_code: string; product_name: string; unit_uom: string | null }
      >();
      for (const s of (skuRows as SkuLite[] | null) ?? []) {
        const prod = Array.isArray(s.products) ? s.products[0] : s.products;
        skuMap.set(s.id, {
          sku_code: s.sku_code,
          product_name:
            (prod?.name ?? "?") +
            (s.variant_name ? `-${s.variant_name}` : ""),
          unit_uom: s.base_unit ?? null,
        });
      }
      const items = (itemRows ?? []).map((r) => {
        const m = skuMap.get(r.sku_id);
        return {
          sku_code: m?.sku_code ?? "?",
          product_name: m?.product_name ?? "?",
          qty_ordered: Number(r.qty_ordered),
          unit_cost: Number(r.unit_cost),
          unit_uom: m?.unit_uom ?? null,
        };
      });
      const subtotal = items.reduce(
        (s, it) => s + it.qty_ordered * it.unit_cost,
        0,
      );
      setSendCtx({
        poId: po.id,
        poNo: po.po_no,
        supplier: (supRow as Supplier | null) ?? null,
        items,
        total: subtotal,
      });
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    } finally {
      setSendBusyId(null);
    }
  }

  async function markStockout(po: PO) {
    const reason = window.prompt(
      `將 ${po.po_no} 標記為「斷貨」？\n供應商無法供貨時使用：未到貨的數量不再等待，單據直接結掉。\n\n可填寫斷貨原因（可留空）：`,
    );
    if (reason === null) return;
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc(
        "rpc_stockout_purchase_order",
        {
          p_po_id: po.id,
          p_operator: userData.user?.id,
          p_reason: reason || null,
        },
      );
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadKey((k) => k + 1);
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }

  async function deletePO(po: PO) {
    if (
      !window.confirm(
        `確定要刪除 ${po.po_no}？\n刪除後無法復原；來源${PR_TERM_ZH}的品項會解除連結、可重新拆單。`,
      )
    )
      return;
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc(
        "rpc_delete_purchase_order",
        {
          p_po_id: po.id,
          p_operator: userData.user?.id,
        },
      );
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadKey((k) => k + 1);
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }

  function setSort(col: SortCol) {
    if (sortBy === col) {
      setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    } else {
      setSortBy(col);
      setSortDir("desc");
    }
  }

  const filtersActive =
    tab !== "all" ||
    !!search ||
    supplierFilter !== "all" ||
    !!dateFrom ||
    !!dateTo;

  function clearFilters() {
    setTab("all");
    setSearch("");
    setSupplierFilter("all");
    setDateFrom("");
    setDateTo("");
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">{PO_TERM_ZH}（PO）</h1>
          <p className="text-sm text-zinc-500">
            {pos === null ? (
              <Spinner size={14} className="inline-block align-[-2px]" />
            ) : (
              `共 ${pos.length} 張 PO`
            )}
          </p>
        </div>
        <Link
          href="/purchase/requests"
          className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:hover:bg-zinc-800"
        >
          ← {PR_TERM_ZH}
        </Link>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* === 總覽 KPI cards === */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          label="待發送"
          hint="草稿 PO,等發給供應商"
          value={stats.draft}
          accent="text-zinc-700 dark:text-zinc-200"
          active={tab === "draft"}
          onClick={() => setTab(tab === "draft" ? "all" : "draft")}
        />
        <KpiCard
          label="待到貨"
          hint="已發送 + 部分到貨"
          value={stats.sent + stats.partially_received}
          accent="text-blue-700 dark:text-blue-400"
          active={tab === "sent" || tab === "partially_received"}
          onClick={() =>
            setTab(tab === "sent" ? "partially_received" : "sent")
          }
        />
        <KpiCard
          label="⚠ 已逾期"
          hint="預計到貨日已過、尚未全收"
          value={stats.overdue}
          accent="text-red-700 dark:text-red-400"
        />
        <KpiCard
          label="待到貨金額"
          hint="已發送 + 部分到貨 的金額合計"
          value={`$${stats.pendingAmount.toLocaleString()}`}
          accent="text-emerald-700 dark:text-emerald-400"
        />
      </div>

      {/* === 狀態 tabs === */}
      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {STATUS_TAB_ORDER.map((s) => {
          const label = s === "all" ? "全部" : STATUS_LABEL[s];
          const count = tabCounts[s];
          const active = tab === s;
          return (
            <SpinButton
              key={s}
              onClick={() => setTab(s)}
              className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                active
                  ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300"
                  : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
              }`}
            >
              {label}
              <span className="ml-1 text-xs text-zinc-400">{count}</span>
            </SpinButton>
          );
        })}
      </div>

      {/* === 篩選 / 搜尋工具列 === */}
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="🔍 搜尋 單號 / 供應商 / PR"
          className="flex-1 min-w-[180px] rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        />
        <select
          value={String(supplierFilter)}
          onChange={(e) =>
            setSupplierFilter(
              e.target.value === "all" ? "all" : Number(e.target.value),
            )
          }
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        >
          <option value="all">全部供應商</option>
          {supplierOptions.map(([id, name]) => (
            <option key={id} value={id}>
              {name}
            </option>
          ))}
        </select>
        <input
          type="date"
          value={dateFrom}
          onChange={(e) => setDateFrom(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          title="建立起日"
        />
        <span className="text-xs text-zinc-400">~</span>
        <input
          type="date"
          value={dateTo}
          onChange={(e) => setDateTo(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          title="建立迄日"
        />
        <label className="flex items-center gap-1 text-xs text-zinc-500">
          <span>分組</span>
          <select
            value={groupBy}
            onChange={(e) => setGroupBy(e.target.value as typeof groupBy)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
          >
            <option value="none">不分組</option>
            <option value="pr">依{PR_TERM_ZH}</option>
            <option value="supplier">依供應商</option>
          </select>
        </label>
        {filtersActive && (
          <SpinButton
            onClick={clearFilters}
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            清除篩選
          </SpinButton>
        )}
        <span className="ml-auto text-xs text-zinc-500">
          {pos === null ? (
            <Spinner size={14} className="inline-block align-[-2px]" />
          ) : (
            `符合 ${total} 筆${total > PAGE_SIZE ? ` · 第 ${page}/${totalPages} 頁` : ""}`
          )}
        </span>
      </div>

      {/* === 主表格 === */}
      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <SortTh
                col="po_no"
                label="單號"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
              />
              <SortTh
                col="supplier"
                label="供應商"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
              />
              <Th>來源 PR</Th>
              <Th>狀態</Th>
              <Th>商品</Th>
              <Th align="right">品項</Th>
              <SortTh
                col="total"
                label="金額"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
                align="right"
              />
              <SortTh
                col="expected_date"
                label="預計到貨"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
              />
              <Th>發送</Th>
              <SortTh
                col="updated_at"
                label="更新"
                sortBy={sortBy}
                sortDir={sortDir}
                onClick={setSort}
                align="right"
              />
              <Th align="right">動作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {pos === null ? (
              <tr>
                <td colSpan={11}>
                  <LoadingBlock />
                </td>
              </tr>
            ) : pageRows.length === 0 ? (
              <tr>
                <td colSpan={11} className="p-6 text-center text-zinc-500">
                  {filtersActive ? "沒有符合條件的 PO" : `尚無${PO_TERM_ZH}`}
                </td>
              </tr>
            ) : grouped ? (
              grouped.flatMap((g) => [
                <tr
                  key={`g-${g.key}`}
                  className="bg-zinc-50 dark:bg-zinc-950"
                >
                  <td
                    colSpan={11}
                    className="px-4 py-2 text-xs font-semibold text-zinc-700 dark:text-zinc-200"
                  >
                    📂 {g.label}
                    <span className="ml-2 font-normal text-zinc-500">
                      ({g.rows.length})
                    </span>
                  </td>
                </tr>,
                ...g.rows.map((p) => (
                  <PORow
                    key={p.id}
                    po={p}
                    onSend={openSendModal}
                    onStockout={markStockout}
                    onDelete={deletePO}
                    sendBusyId={sendBusyId}
                  />
                )),
              ])
            ) : (
              pageRows.map((p) => (
                <PORow
                  key={p.id}
                  po={p}
                  onSend={openSendModal}
                  onStockout={markStockout}
                  onDelete={deletePO}
                  sendBusyId={sendBusyId}
                />
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* === 分頁 === */}
      {total > PAGE_SIZE && (
        <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
          <span className="text-xs text-zinc-500">
            共 {total} 筆 · 顯示 {(page - 1) * PAGE_SIZE + 1} -{" "}
            {Math.min(page * PAGE_SIZE, total)}
          </span>
          <SpinButton
            onClick={() => setPage(1)}
            disabled={page === 1}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            « 第一頁
          </SpinButton>
          <SpinButton
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            disabled={page === 1}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ‹ 上頁
          </SpinButton>
          <span className="text-xs text-zinc-500">
            {page} / {totalPages}
          </span>
          <SpinButton
            onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            disabled={page === totalPages}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            下頁 ›
          </SpinButton>
          <SpinButton
            onClick={() => setPage(totalPages)}
            disabled={page === totalPages}
            className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            最末頁 »
          </SpinButton>
        </div>
      )}

      {sendCtx && (
        <SendPOModal
          open
          onClose={() => setSendCtx(null)}
          poId={sendCtx.poId}
          poNo={sendCtx.poNo}
          supplier={sendCtx.supplier}
          items={sendCtx.items}
          total={sendCtx.total}
          onSent={() => {
            setSendCtx(null);
            setReloadKey((k) => k + 1);
          }}
        />
      )}
    </div>
  );
}

function KpiCard({
  label,
  hint,
  value,
  accent,
  active,
  onClick,
}: {
  label: string;
  hint?: string;
  value: number | string;
  accent: string;
  active?: boolean;
  onClick?: () => void;
}) {
  const Wrapper = onClick ? "button" : "div";
  return (
    <Wrapper
      type={onClick ? "button" : undefined}
      onClick={onClick}
      title={hint}
      className={`rounded-md border p-3 text-left transition ${
        active
          ? "border-blue-500 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/40"
          : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
      } ${onClick ? "hover:border-blue-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/60" : ""}`}
    >
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-0.5 text-2xl font-semibold ${accent}`}>{value}</div>
      {hint && (
        <div className="mt-0.5 text-[10px] text-zinc-400">{hint}</div>
      )}
    </Wrapper>
  );
}

function PORow({
  po,
  onSend,
  onStockout,
  onDelete,
  sendBusyId,
}: {
  po: PO;
  onSend: (p: PO) => void;
  onStockout: (p: PO) => Promise<void>;
  onDelete: (p: PO) => Promise<void>;
  sendBusyId: number | null;
}) {
  const overdue =
    (po.status === "sent" || po.status === "partially_received") &&
    !!po.expected_date &&
    po.expected_date < new Date().toISOString().slice(0, 10);
  return (
    <tr className="hover:bg-zinc-50 dark:hover:bg-zinc-900/60">
      <Td className="font-mono">
        <Link
          href={`/purchase/orders/edit?id=${po.id}`}
          className="text-blue-600 hover:underline dark:text-blue-400"
        >
          {po.po_no}
        </Link>
      </Td>
      <Td>{po.supplier_name ?? "—"}</Td>
      <Td>
        {po.pr_id ? (
          <Link
            href={`/purchase/requests/edit?id=${po.pr_id}`}
            className="font-mono text-xs text-blue-600 hover:underline dark:text-blue-400"
          >
            {po.pr_no ?? `PR#${po.pr_id}`}
          </Link>
        ) : (
          <span className="text-xs text-zinc-400">手動</span>
        )}
      </Td>
      <Td>
        <span
          className={`inline-flex rounded px-2 py-0.5 text-xs ${STATUS_BADGE[po.status]}`}
        >
          {STATUS_LABEL[po.status]}
        </span>
        {po.stockout_at && (
          <span
            className="ml-1 inline-flex rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300"
            title={`斷貨於 ${new Date(po.stockout_at).toLocaleString("zh-TW")}`}
          >
            ⛔ 斷貨
          </span>
        )}
      </Td>
      <Td className="max-w-[220px]">
        {po.product_names.length === 0 ? (
          <span className="text-xs text-zinc-400">—</span>
        ) : (
          <div
            className="truncate text-xs"
            title={po.product_names.join("、")}
          >
            {po.product_names.slice(0, 2).join("、")}
            {po.product_names.length > 2 && (
              <span className="ml-1 rounded bg-zinc-100 px-1 text-[10px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400">
                +{po.product_names.length - 2}
              </span>
            )}
          </div>
        )}
      </Td>
      <Td className="text-right text-xs">
        {po.item_count > 0 ? (
          <span className="font-mono">{po.item_count}</span>
        ) : (
          <span className="text-zinc-400">—</span>
        )}
      </Td>
      <Td className="text-right font-mono">${po.total.toLocaleString()}</Td>
      <Td className="text-xs">
        {po.expected_date ? (
          <span
            className={
              overdue ? "font-semibold text-red-600 dark:text-red-400" : ""
            }
          >
            {po.expected_date}
            {overdue && <span className="ml-1">⚠</span>}
          </span>
        ) : (
          "—"
        )}
      </Td>
      <Td className="text-xs text-zinc-500">
        {po.sent_at ? (
          <>
            <div>
              {new Date(po.sent_at).toLocaleDateString("zh-TW", {
                month: "numeric",
                day: "numeric",
              })}
            </div>
            {po.sent_channel && (
              <div className="text-zinc-400">via {po.sent_channel}</div>
            )}
          </>
        ) : (
          "—"
        )}
      </Td>
      <Td className="text-right text-xs text-zinc-500">
        {new Date(po.updated_at).toLocaleDateString("zh-TW", {
          month: "numeric",
          day: "numeric",
        })}
      </Td>
      <Td className="text-right">
        <div className="flex justify-end gap-1">
          {po.status === "draft" && (
            <RowAction
              variant="success"
              disabled={sendBusyId === po.id}
              onClick={() => onSend(po)}
            >
              {sendBusyId === po.id ? "載入…" : "📤 發送"}
            </RowAction>
          )}
          {(po.status === "sent" || po.status === "partially_received") && (
            <Link
              href={`/purchase/orders/receive?po=${po.id}`}
              className="rounded border border-emerald-400 bg-emerald-50 px-2.5 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-100 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300 dark:hover:bg-emerald-900"
            >
              進貨
            </Link>
          )}
          {(po.status === "sent" || po.status === "partially_received") && (
            <RowAction variant="warning" onClick={() => onStockout(po)}>
              斷貨
            </RowAction>
          )}
          {(po.status === "draft" ||
            po.status === "sent" ||
            po.status === "cancelled") && (
            <RowAction variant="danger" onClick={() => onDelete(po)}>
              刪除
            </RowAction>
          )}
        </div>
      </Td>
    </tr>
  );
}

function Th({
  children,
  align = "left",
}: {
  children?: React.ReactNode;
  align?: "left" | "right" | "center";
}) {
  const cls =
    align === "right"
      ? "text-right"
      : align === "center"
        ? "text-center"
        : "text-left";
  return (
    <th
      className={`px-4 py-2 text-xs font-medium uppercase tracking-wide text-zinc-500 ${cls}`}
    >
      {children}
    </th>
  );
}

function SortTh({
  col,
  label,
  sortBy,
  sortDir,
  onClick,
  align = "left",
}: {
  col: SortCol;
  label: string;
  sortBy: SortCol;
  sortDir: "asc" | "desc";
  onClick: (col: SortCol) => void;
  align?: "left" | "right";
}) {
  const active = sortBy === col;
  const arrow = active ? (sortDir === "asc" ? "▲" : "▼") : "";
  const cls = align === "right" ? "text-right" : "text-left";
  return (
    <th
      className={`px-4 py-2 text-xs font-medium uppercase tracking-wide text-zinc-500 ${cls}`}
    >
      <button
        type="button"
        onClick={() => onClick(col)}
        className={`inline-flex items-center gap-1 hover:text-zinc-900 dark:hover:text-zinc-100 ${
          active ? "text-zinc-900 dark:text-zinc-100" : ""
        }`}
      >
        {label}
        {arrow && <span className="text-[10px]">{arrow}</span>}
      </button>
    </th>
  );
}

function Td({
  children,
  className = "",
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
