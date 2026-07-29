"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
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

// 樞紐（依廠商彙整品項）用的扁平品項列
type PivotItem = {
  po_id: number;
  po_no: string;
  supplier_id: number;
  supplier_name: string | null;
  status: POStatus;
  sku_id: number;
  sku_label: string;
  ordered: number;
  received: number;
};

// pos: po_id -> po_no（保留 id 讓來源 PO 可連到詳細頁）
type PivotSkuAgg = { sku_id: number; label: string; ordered: number; received: number; pos: Map<number, string> };
type PivotGroup = {
  supplier_id: number;
  supplier_name: string;
  skus: PivotSkuAgg[];
  ordered: number;
  received: number;
  poCount: number;
};

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
  // 檢視模式：清單（原本）/ 樞紐（依廠商彙整已下單＋部分到貨的品項）
  const [viewMode, setViewMode] = useState<"list" | "pivot">("list");
  // 樞紐狀態子篩選：兩者 / 僅已下單 / 僅部分到貨
  const [pivotStatus, setPivotStatus] = useState<"both" | "sent" | "partially_received">("both");
  const [pivotItems, setPivotItems] = useState<PivotItem[] | null>(null);
  const [pivotLoading, setPivotLoading] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();

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
        // 1. 撈 POs — 全部撈回來，篩選 / 搜尋 / KPI 都是前端算的。
        //    原本是 .limit(500) 取最近更新的 500 張：超出的 PO 不只翻不到，
        //    連搜單號都找不到（實測 778 張時，第 501 張之後全部搜不到），
        //    而且狀態頁籤數字與 KPI 也會少算。改用 fetchAllRows 分頁拿完整清單。
        //    updated_at 會有同值，補 id 當 tiebreaker 給分頁一個穩定的 total order。
        const poData = await fetchAllRows<RawPO>(() =>
          supabase
            .from("purchase_orders")
            .select(
              "id, po_no, supplier_id, status, total, expected_date, sent_at, sent_channel, stockout_at, created_at, updated_at, suppliers(name)",
            )
            .order("updated_at", { ascending: false })
            .order("id", { ascending: false }),
        );
        if (cancelled) return;

        const baseList: PO[] = poData.map((r) => {
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
        // 500 張 PO 的品項列數很容易破 PostgREST 1000 列上限，且一次 .in() 塞幾百個
        // id 會撐爆 URL — 一律 chunk + fetchAllRows 分頁（同下方樞紐檢視的作法）。
        const chunk = <T,>(arr: T[], n: number): T[][] => {
          const out: T[][] = [];
          for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
          return out;
        };
        const poIds = baseList.map((p) => p.id);
        const poToPR = new Map<number, number>();
        const poItemMap = new Map<number, number[]>(); // po_id -> sku_ids[]
        {
          const poiRows: { id: number; po_id: number; sku_id: number }[] = [];
          for (const c of chunk(poIds, 200)) {
            const rows = await fetchAllRows<{ id: number; po_id: number; sku_id: number }>(
              () =>
                supabase
                  .from("purchase_order_items")
                  .select("id, po_id, sku_id")
                  .in("po_id", c)
                  .order("id", { ascending: true }),
            );
            poiRows.push(...rows);
          }
          const poiToPo = new Map<number, number>();
          for (const r of poiRows) {
            poiToPo.set(r.id, r.po_id);
            if (!poItemMap.has(r.po_id)) poItemMap.set(r.po_id, []);
            poItemMap.get(r.po_id)!.push(r.sku_id);
          }
          const poiIds = poiRows.map((r) => r.id);
          for (const c of chunk(poiIds, 200)) {
            const priRows = await fetchAllRows<{ po_item_id: number | null; pr_id: number | null }>(
              () =>
                supabase
                  .from("purchase_request_items")
                  .select("po_item_id, pr_id")
                  .in("po_item_id", c)
                  .order("po_item_id", { ascending: true }),
            );
            for (const r of priRows) {
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
        for (const c of chunk(allSkuIds, 300)) {
          const { data: skuRows, error: skuErr } = await supabase
            .from("skus")
            .select("id, products!inner(name)")
            .in("id", c);
          if (skuErr) throw new Error(skuErr.message);
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
        for (const c of chunk(prIds, 200)) {
          const { data: prRows, error: prErr } = await supabase
            .from("purchase_requests")
            .select("id, pr_no")
            .in("id", c);
          if (prErr) throw new Error(prErr.message);
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

  // 資料重載（reloadKey 變動）→ 讓樞紐下次進去重撈
  useEffect(() => {
    setPivotItems(null);
  }, [reloadKey]);

  // 樞紐資料：lazy 撈「已下單 + 部分到貨」PO 的品項（訂購量 / 已到量），切到樞紐才撈一次。
  // 注意：pivotLoading 不可放進本 effect 的依賴陣列，也不可拿來當守衛條件。
  // 否則 setPivotLoading(true) 會立刻改動依賴 → React 先跑 cleanup 把 cancelled 設 true
  // → 進行中的查詢回來時所有 setState（含 finally 的 setPivotLoading(false)）都被 !cancelled 擋掉
  // → 樞紐永遠停在「載入中」。重入保護改由 pivotItems !== null 負責（載入完成/失敗都會離開 null）。
  useEffect(() => {
    if (viewMode !== "pivot" || pivotItems !== null || !pos) return;
    let cancelled = false;
    setPivotLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        const chunk = <T,>(arr: T[], n: number): T[][] => {
          const out: T[][] = [];
          for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
          return out;
        };
        const targetPos = pos.filter(
          (p) => p.status === "sent" || p.status === "partially_received",
        );
        const poMeta = new Map(targetPos.map((p) => [p.id, p]));
        const poIds = targetPos.map((p) => p.id);
        if (poIds.length === 0) {
          if (!cancelled) setPivotItems([]);
          return;
        }
        // 1. PO 品項（訂購量）— fetchAllRows 分頁，避免 PostgREST 1000 列上限截斷。
        const poiRows: { id: number; po_id: number; sku_id: number; qty_ordered: number }[] = [];
        for (const c of chunk(poIds, 200)) {
          const rows = await fetchAllRows<{ id: number; po_id: number; sku_id: number; qty_ordered: number }>(
            () =>
              sb
                .from("purchase_order_items")
                .select("id, po_id, sku_id, qty_ordered")
                .in("po_id", c)
                .order("id", { ascending: true }),
          );
          poiRows.push(...rows);
        }
        // 2. 已到量：先抓這些 PO 的 confirmed 收貨單，再依 gr_id 撈明細加總。
        //    （不走 goods_receipts!inner 內嵌過濾 — 內嵌 join 在部分 RLS 下行為不穩，
        //     直接兩段查詢較可靠，且收貨單數量遠少於品項數。）
        const grIds: number[] = [];
        for (const c of chunk(poIds, 200)) {
          const rows = await fetchAllRows<{ id: number }>(
            () =>
              sb
                .from("goods_receipts")
                .select("id")
                .eq("status", "confirmed")
                .in("po_id", c)
                .order("id", { ascending: true }),
          );
          grIds.push(...rows.map((r) => r.id));
        }
        const recvByItem = new Map<number, number>();
        for (const c of chunk(grIds, 200)) {
          const rows = await fetchAllRows<{ po_item_id: number; qty_received: number }>(
            () =>
              sb
                .from("goods_receipt_items")
                .select("po_item_id, qty_received")
                .in("gr_id", c)
                .order("po_item_id", { ascending: true }),
          );
          for (const r of rows) {
            recvByItem.set(r.po_item_id, (recvByItem.get(r.po_item_id) ?? 0) + Number(r.qty_received));
          }
        }
        // 3. SKU 標籤
        const skuIds = Array.from(new Set(poiRows.map((r) => r.sku_id)));
        const skuLabel = new Map<number, string>();
        for (const c of chunk(skuIds, 300)) {
          const { data } = await sb
            .from("skus")
            .select("id, sku_code, variant_name, products!inner(name)")
            .in("id", c);
          type SkuLite = { id: number; sku_code: string | null; variant_name: string | null; products: { name: string } | { name: string }[] | null };
          for (const s of (data as SkuLite[] | null) ?? []) {
            const prod = Array.isArray(s.products) ? s.products[0] : s.products;
            const base = prod?.name ?? s.sku_code ?? `#${s.id}`;
            skuLabel.set(s.id, s.variant_name ? `${base} / ${s.variant_name}` : base);
          }
        }
        const items: PivotItem[] = poiRows.map((r) => {
          const p = poMeta.get(r.po_id)!;
          return {
            po_id: r.po_id,
            po_no: p.po_no,
            supplier_id: p.supplier_id,
            supplier_name: p.supplier_name,
            status: p.status,
            sku_id: r.sku_id,
            sku_label: skuLabel.get(r.sku_id) ?? `#${r.sku_id}`,
            ordered: Number(r.qty_ordered),
            received: recvByItem.get(r.id) ?? 0,
          };
        });
        if (!cancelled) setPivotItems(items);
      } catch (e) {
        // 設成空陣列避免「載入中」卡死；錯誤原因由上方 error banner 呈現。
        if (!cancelled) {
          setError(e instanceof Error ? e.message : String(e));
          setPivotItems([]);
        }
      } finally {
        if (!cancelled) setPivotLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [viewMode, pivotItems, pos]);

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
        const hits = [p.po_no, p.supplier_name, p.pr_no, ...p.product_names]
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

  // 樞紐分組：依廠商 → SKU 彙整（訂購 / 已到 / 未到），套用 pivotStatus + 供應商 + 搜尋。
  const pivotGroups: PivotGroup[] = useMemo(() => {
    if (!pivotItems) return [];
    const q = search.trim().toLowerCase();
    const bySup = new Map<
      number,
      { supplier_id: number; supplier_name: string; skus: Map<number, PivotSkuAgg>; poIds: Set<number> }
    >();
    for (const it of pivotItems) {
      if (pivotStatus !== "both" && it.status !== pivotStatus) continue;
      if (supplierFilter !== "all" && it.supplier_id !== supplierFilter) continue;
      if (q) {
        const hit = [it.po_no, it.supplier_name, it.sku_label]
          .filter((x): x is string => !!x)
          .some((x) => x.toLowerCase().includes(q));
        if (!hit) continue;
      }
      let sup = bySup.get(it.supplier_id);
      if (!sup) {
        sup = {
          supplier_id: it.supplier_id,
          supplier_name: it.supplier_name ?? `#${it.supplier_id}`,
          skus: new Map(),
          poIds: new Set(),
        };
        bySup.set(it.supplier_id, sup);
      }
      sup.poIds.add(it.po_id);
      let sk = sup.skus.get(it.sku_id);
      if (!sk) {
        sk = { sku_id: it.sku_id, label: it.sku_label, ordered: 0, received: 0, pos: new Map() };
        sup.skus.set(it.sku_id, sk);
      }
      sk.ordered += it.ordered;
      sk.received += it.received;
      sk.pos.set(it.po_id, it.po_no);
    }
    return Array.from(bySup.values())
      .map((sup) => {
        const skus = Array.from(sup.skus.values()).sort((a, b) => a.label.localeCompare(b.label));
        return {
          supplier_id: sup.supplier_id,
          supplier_name: sup.supplier_name,
          skus,
          ordered: skus.reduce((s, r) => s + r.ordered, 0),
          received: skus.reduce((s, r) => s + r.received, 0),
          poCount: sup.poIds.size,
        };
      })
      .sort((a, b) => a.supplier_name.localeCompare(b.supplier_name));
  }, [pivotItems, pivotStatus, supplierFilter, search]);

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
    <div className="flex flex-1 flex-col gap-4 p-4 sm:p-6">
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

      {/* === 檢視切換：清單 / 樞紐 === */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-md border border-zinc-300 p-0.5 dark:border-zinc-700">
          <SpinButton
            onClick={() => setViewMode("list")}
            className={`rounded px-3 py-1 text-sm ${viewMode === "list" ? "bg-blue-600 font-semibold text-white" : "text-zinc-600 dark:text-zinc-300"}`}
          >
            清單
          </SpinButton>
          <SpinButton
            onClick={() => setViewMode("pivot")}
            className={`rounded px-3 py-1 text-sm ${viewMode === "pivot" ? "bg-blue-600 font-semibold text-white" : "text-zinc-600 dark:text-zinc-300"}`}
          >
            樞紐（依廠商）
          </SpinButton>
        </div>
        {viewMode === "pivot" && (
          <div className="inline-flex rounded-md border border-zinc-300 p-0.5 text-sm dark:border-zinc-700">
            {(
              [
                ["both", "已下單＋部分到貨"],
                ["sent", "已下單廠商"],
                ["partially_received", "部分到貨"],
              ] as const
            ).map(([v, lbl]) => (
              <SpinButton
                key={v}
                onClick={() => setPivotStatus(v)}
                className={`rounded px-2.5 py-1 ${pivotStatus === v ? "bg-amber-500 font-semibold text-white" : "text-zinc-600 dark:text-zinc-300"}`}
              >
                {lbl}
              </SpinButton>
            ))}
          </div>
        )}
      </div>

      {/* === 狀態 tabs（清單模式）=== */}
      {viewMode === "list" && (
      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {STATUS_TAB_ORDER.map((s) => {
          const label = s === "all" ? "全部" : s === "sent" ? "已下單廠商" : STATUS_LABEL[s];
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
      )}

      {/* === 篩選 / 搜尋工具列 === */}
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="🔍 搜尋 單號 / 供應商 / PR / 產品"
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

      {viewMode === "list" && (
        <>
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
                <td colSpan={10}>
                  <LoadingBlock />
                </td>
              </tr>
            ) : pageRows.length === 0 ? (
              <tr>
                <td colSpan={10} className="p-6 text-center text-zinc-500">
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
                    colSpan={10}
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
        </>
      )}

      {viewMode === "pivot" && (
        <PoPivot groups={pivotGroups} loading={pivotLoading || pivotItems === null} />
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

function PoPivot({ groups, loading }: { groups: PivotGroup[]; loading: boolean }) {
  if (loading) {
    return (
      <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
        載入樞紐資料中…
      </div>
    );
  }
  if (groups.length === 0) {
    return (
      <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
        目前沒有「已下單 / 部分到貨」的品項。
      </div>
    );
  }
  const totOrdered = groups.reduce((s, g) => s + g.ordered, 0);
  const totReceived = groups.reduce((s, g) => s + g.received, 0);
  return (
    <div className="flex flex-col gap-4">
      <div className="text-xs text-zinc-500">
        {groups.length} 家廠商 · 訂購合計 {totOrdered} · 已到 {totReceived} · 未到 {totOrdered - totReceived}
      </div>
      {groups.map((g) => (
        <div
          key={g.supplier_id}
          className="overflow-hidden rounded-md border border-zinc-200 dark:border-zinc-800"
        >
          <div className="flex flex-wrap items-baseline justify-between gap-2 bg-zinc-50 px-3 py-2 dark:bg-zinc-900">
            <div className="font-semibold">
              {g.supplier_name}
              <span className="ml-2 text-xs font-normal text-zinc-500">
                {g.poCount} 張 PO · {g.skus.length} 品項
              </span>
            </div>
            <div className="text-xs text-zinc-500">
              訂購 {g.ordered} · 已到 {g.received} ·{" "}
              <span className={g.ordered - g.received > 0 ? "text-amber-600 dark:text-amber-400" : ""}>
                未到 {g.ordered - g.received}
              </span>
            </div>
          </div>
          {/* 桌機：表格 */}
          <div className="hidden overflow-x-auto sm:block">
            <table className="min-w-full text-sm">
              <thead className="text-xs text-zinc-500">
                <tr className="border-b border-zinc-200 dark:border-zinc-800">
                  <th className="px-3 py-1.5 text-left font-medium">品項</th>
                  <th className="px-3 py-1.5 text-right font-medium">訂購</th>
                  <th className="px-3 py-1.5 text-right font-medium">已到</th>
                  <th className="px-3 py-1.5 text-right font-medium">未到</th>
                  <th className="px-3 py-1.5 text-left font-medium">來源 PO</th>
                </tr>
              </thead>
              <tbody>
                {g.skus.map((s) => {
                  const outstanding = s.ordered - s.received;
                  return (
                    <tr key={s.sku_id} className="border-b border-zinc-100 dark:border-zinc-800/60">
                      <td className="px-3 py-1.5">{s.label}</td>
                      <td className="px-3 py-1.5 text-right font-mono">{s.ordered}</td>
                      <td className="px-3 py-1.5 text-right font-mono">{s.received}</td>
                      <td
                        className={`px-3 py-1.5 text-right font-mono ${
                          outstanding > 0 ? "text-amber-600 dark:text-amber-400" : "text-zinc-400"
                        }`}
                      >
                        {outstanding}
                      </td>
                      <td className="px-3 py-1.5 font-mono text-xs">
                        <PoLinks pos={s.pos} />
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* 手機：每個品項一張堆疊卡片 */}
          <ul className="divide-y divide-zinc-100 sm:hidden dark:divide-zinc-800/60">
            {g.skus.map((s) => {
              const outstanding = s.ordered - s.received;
              return (
                <li key={s.sku_id} className="px-3 py-2">
                  <div className="text-sm">{s.label}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-x-4 gap-y-0.5 text-xs text-zinc-500">
                    <span>
                      訂購{" "}
                      <span className="font-mono text-zinc-800 dark:text-zinc-200">{s.ordered}</span>
                    </span>
                    <span>
                      已到{" "}
                      <span className="font-mono text-zinc-800 dark:text-zinc-200">{s.received}</span>
                    </span>
                    <span>
                      未到{" "}
                      <span
                        className={`font-mono ${
                          outstanding > 0 ? "text-amber-600 dark:text-amber-400" : "text-zinc-400"
                        }`}
                      >
                        {outstanding}
                      </span>
                    </span>
                  </div>
                  <div className="mt-0.5 font-mono text-[11px] text-zinc-400">
                    PO <PoLinks pos={s.pos} />
                  </div>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </div>
  );
}

// 樞紐裡的來源 PO 單號清單：每個單號連到 PO 詳細頁
function PoLinks({ pos }: { pos: Map<number, string> }) {
  const entries = Array.from(pos.entries()).sort((a, b) =>
    a[1].localeCompare(b[1]),
  );
  return (
    <>
      {entries.map(([id, no], i) => (
        <span key={id}>
          {i > 0 && <span className="text-zinc-400">、</span>}
          <Link
            href={`/purchase/orders/edit?id=${id}`}
            className="text-blue-600 hover:underline dark:text-blue-400"
          >
            {no}
          </Link>
        </span>
      ))}
    </>
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
      <Td className="text-right text-xs">
        {po.item_count > 0 ? (
          <span
            className="cursor-help font-mono underline decoration-dotted decoration-zinc-400 underline-offset-2"
            title={po.product_names.join("、")}
          >
            {po.item_count}
          </span>
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
