"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { PR_TERM_ZH } from "@/lib/prStatus";
import {
  CAMPAIGN_STATUS_LABEL,
  CAMPAIGN_STATUS_BADGE,
  type CampaignStatus,
} from "@/lib/campaignStatus";
import { Modal } from "@/components/Modal";
import { CampaignForm, type CampaignFormValues } from "@/components/CampaignForm";
import { CampaignOrdersPanel } from "@/components/CampaignOrdersPanel";
import { CampaignItemsTable } from "@/components/CampaignItemsTable";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { CampaignThumb } from "@/components/CampaignThumb";
import { campaignCoverUrl, type CampaignCoverItem } from "@/lib/campaignCover";
import FbPublishModal from "@/components/FbPublishModal";
import FbBulkPublishModal from "@/components/FbBulkPublishModal";
import { useRole, isAdmin } from "@/lib/role";

// 共用: chunked fetch — bypass PostgREST max-rows 1000 cap
// builder: 回 fresh query builder 的 factory (因為 .range() 後不能 reuse)
async function fetchAll<T>(builder: () => any, pageSize = 1000, maxPages = 50): Promise<T[]> {
  const all: T[] = [];
  for (let p = 0; p < maxPages; p++) {
    const { data, error } = await builder().range(p * pageSize, (p + 1) * pageSize - 1);
    if (error) throw error;
    const rows = (data ?? []) as T[];
    all.push(...rows);
    if (rows.length < pageSize) break;
  }
  return all;
}

type Status = CampaignStatus;

type CloseType = "regular" | "fast" | "limited";
type Category = "food_train" | null;

type Row = {
  id: number;
  campaign_no: string;
  name: string;
  status: Status;
  close_type: CloseType;
  category: Category;
  start_at: string | null;
  end_at: string | null;
  pickup_deadline: string | null;
  updated_at: string;
  cover_image_url: string | null;
  campaign_items: CampaignCoverItem[] | null;
};

const STATUS_LABEL = CAMPAIGN_STATUS_LABEL;

const CLOSE_TYPE_LABEL: Record<CloseType, string> = {
  regular: "常規",
  fast: "快團",
  limited: "限量",
};

const CLOSE_TYPE_BADGE: Record<CloseType, string> = {
  regular: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  fast: "bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300",
  limited: "bg-pink-100 text-pink-800 dark:bg-pink-950 dark:text-pink-300",
};

const CATEGORY_LABEL: Record<"food_train", string> = {
  food_train: "美食列車",
};

const CATEGORY_BADGE: Record<"food_train", string> = {
  food_train: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
};

const PAGE_SIZE = 20;

type View = "list" | "week" | "month";

type CalRow = {
  id: number;
  campaign_no: string;
  name: string;
  status: Status;
  close_type: CloseType;
  start_at: string | null;
};

function localDateKey(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function startOfDay(d: Date): Date {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

function fmtDateTime(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `${yyyy}/${mm}/${dd} ${hh}:${mi}`;
}

export default function CampaignsListPage() {
  const role = useRole();
  const showAdminActions = isAdmin(role);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<string>("");
  const [categoryFilter, setCategoryFilter] = useState<string>(""); // ""=全部 / "food_train" / "none"
  const [page, setPage] = useState(1);

  const [itemCounts, setItemCounts] = useState<Map<number, number>>(new Map());
  const [listOrderCounts, setListOrderCounts] = useState<Map<number, { normalQty: number; offsetQty: number }>>(new Map());
  const [modal, setModal] = useState<{ mode: "edit"; values: CampaignFormValues } | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [resyncTick, setResyncTick] = useState(0);
  const [fbPublishId, setFbPublishId] = useState<number | null>(null);
  const [bulkFbOpen, setBulkFbOpen] = useState(false);
  const [closingId, setClosingId] = useState<number | null>(null);
  const [finalizingId, setFinalizingId] = useState<number | null>(null);

  // 多選 + 批次操作
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());
  const [bulkBusy, setBulkBusy] = useState<"open" | "closed" | "cancelled" | null>(null);
  const [endAtOpen, setEndAtOpen] = useState(false);
  const [bulkEndAt, setBulkEndAt] = useState("");
  const [endAtErr, setEndAtErr] = useState<string | null>(null);

  const [view, setView] = useState<View>(() => {
    if (typeof window === "undefined") return "list";
    const saved = window.localStorage.getItem("campaigns:view");
    return saved === "week" || saved === "month" || saved === "list" ? saved : "list";
  });

  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem("campaigns:view", view);
  }, [view]);

  const [showRecurring, setShowRecurring] = useState(false);

  const [calRows, setCalRows] = useState<CalRow[] | null>(null);
  const [calItemCounts, setCalItemCounts] = useState<Map<number, number>>(new Map());
  const [calOrderCounts, setCalOrderCounts] = useState<Map<number, number>>(new Map());
  const [calOffsetCounts, setCalOffsetCounts] = useState<Map<number, number>>(new Map());
  const [monthAnchor, setMonthAnchor] = useState<Date>(() => startOfDay(new Date()));

  async function bulkSetStatus(target: "open" | "closed" | "cancelled", label: string) {
    const ids = Array.from(selectedIds);
    if (ids.length === 0) return;
    if (!confirm(`確定將已選的 ${ids.length} 個開團設為「${label}」？\n（系統會自動跳過狀態不合法、無商品或已是此狀態的）`)) return;
    setBulkBusy(target);
    setError(null);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_bulk_set_campaign_status", {
        p_ids: ids,
        p_status: target,
      });
      if (err) throw err;
      const changed = typeof data === "number" ? data : 0;
      const skipped = ids.length - changed;
      setSelectedIds(new Set());
      setReloadTick((t) => t + 1);
      if (skipped > 0) {
        console.info(`bulk_set_campaign_status: ${changed} updated, ${skipped} skipped`);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBulkBusy(null);
    }
  }

  async function bulkSetEndAt() {
    const ids = Array.from(selectedIds);
    if (ids.length === 0) return;
    setEndAtErr(null);
    if (!bulkEndAt) { setEndAtErr("請選擇收單時間"); return; }
    const iso = new Date(bulkEndAt).toISOString();
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_bulk_set_campaign_end_at", {
        p_ids: ids,
        p_end_at: iso,
      });
      if (err) throw err;
      const changed = typeof data === "number" ? data : 0;
      const skipped = ids.length - changed;
      setSelectedIds(new Set());
      setEndAtOpen(false);
      setBulkEndAt("");
      setReloadTick((t) => t + 1);
      if (skipped > 0) {
        console.info(`bulk_set_campaign_end_at: ${changed} updated, ${skipped} skipped`);
      }
    } catch (e) {
      setEndAtErr(e instanceof Error ? e.message : String(e));
    }
  }

  function toggleSelect(id: number) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function toggleAllOnPage() {
    if (!rows) return;
    const idsOnPage = rows.map((r) => r.id);
    const allSelected = idsOnPage.every((id) => selectedIds.has(id));
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (allSelected) idsOnPage.forEach((id) => next.delete(id));
      else idsOnPage.forEach((id) => next.add(id));
      return next;
    });
  }

  async function closeCampaign(id: number, name: string) {
    if (!confirm(`確定結單「${name}」？結單後可從${PR_TERM_ZH}頁面「帶入該日商品」產生 PR。`)) return;
    setClosingId(id);
    try {
      const { error: rpcErr } = await getSupabase().rpc("rpc_close_campaign", {
        p_campaign_id: id,
        p_operator: (await getSupabase().auth.getUser()).data.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setClosingId(null);
    }
  }

  async function finalizeCampaign(id: number, name: string) {
    if (!confirm(`整單結算「${name}」？結算後無法復原，請確認所有顧客訂單皆已完成 / 逾期 / 取消。`)) return;
    setFinalizingId(id);
    try {
      const { error: rpcErr } = await getSupabase().rpc("rpc_finalize_campaign", {
        p_campaign_id: id,
        p_operator: (await getSupabase().auth.getUser()).data.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setFinalizingId(null);
    }
  }

  // 刪除開團（僅草稿；實體刪除，連帶 campaign_items/channels/audit）
  async function deleteCampaign(id: number, name: string) {
    if (
      !confirm(
        `確定刪除草稿開團「${name}」？\n\n` +
          `將一併刪除其商品明細與頻道設定，此操作無法復原。\n` +
          `（只有「草稿」可刪除；已開團 / 已收單請改用「批次取消」）`
      )
    )
      return;
    setError(null);
    try {
      const { error: rpcErr } = await getSupabase().rpc("rpc_delete_campaign", {
        p_campaign_id: id,
        p_operator: (await getSupabase().auth.getUser()).data.user?.id,
      });
      if (rpcErr) throw rpcErr;
      setSelectedIds((prev) => {
        const next = new Set(prev);
        next.delete(id);
        return next;
      });
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    }
  }

  async function openEdit(id: number) {
    const { data, error: err } = await getSupabase()
      .from("group_buy_campaigns")
      .select("id, campaign_no, name, description, status, close_type, category, start_at, end_at, pickup_deadline, pickup_days, total_cap_qty, notes")
      .eq("id", id).maybeSingle();
    if (err || !data) { setError(err?.message ?? "找不到開團"); return; }
    setModal({
      mode: "edit",
      values: {
        id: data.id,
        campaign_no: data.campaign_no,
        name: data.name,
        description: data.description,
        status: data.status as CampaignFormValues["status"],
        close_type: data.close_type as CampaignFormValues["close_type"],
        category: (data.category ?? null) as CampaignFormValues["category"],
        start_at: data.start_at,
        end_at: data.end_at,
        pickup_deadline: data.pickup_deadline,
        pickup_days: data.pickup_days,
        total_cap_qty: data.total_cap_qty != null ? Number(data.total_cap_qty) : null,
        notes: data.notes,
      },
    });
  }

  useEffect(() => {
    const t = setTimeout(() => { setQuery(queryDraft); setPage(1); }, 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  useEffect(() => { setPage(1); }, [status]);
  useEffect(() => { setPage(1); }, [categoryFilter]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("group_buy_campaigns")
          .select("id, campaign_no, name, status, close_type, category, start_at, end_at, pickup_deadline, updated_at, cover_image_url, campaign_items(sort_order, sku:skus(product:products(images)))", { count: "exact" })
          .neq("campaign_no", "__INTERNAL_RESTOCK__")
          .order("start_at", { ascending: false, nullsFirst: false })
          .order("id", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
        if (query.trim()) {
          const safe = query.replace(/[%,()]/g, " ").trim();
          q = q.or(`name.ilike.%${safe}%,campaign_no.ilike.%${safe}%`);
        }
        if (status) q = q.eq("status", status);
        if (categoryFilter === "food_train") q = q.eq("category", "food_train");
        else if (categoryFilter === "none") q = q.is("category", null);

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        // supabase-js select 字串解析器把 to-one 嵌入(sku/product)推成陣列；
        // PostgREST 實際回傳單一物件，故經 unknown 斷言成執行期真實型別 Row。
        setRows((data ?? []) as unknown as Row[]);
        setTotal(count ?? 0);

        // 補商品數 + 下單總數量（normal / offset 分開、SUM(qty)）
        // chunked fetch: 跨萬筆訂單仍 work (bypass PostgREST 1000 row cap)
        const ids = (data ?? []).map((r) => r.id);
        if (ids.length) {
          const sb = getSupabase();
          const [itemRows, ordersList] = await Promise.all([
            fetchAll<{ campaign_id: number }>(() =>
              sb.from("campaign_items").select("campaign_id").in("campaign_id", ids).order("id", { ascending: true })),
            fetchAll<{ id: number; campaign_id: number; order_kind: string }>(() =>
              sb.from("customer_orders").select("id, campaign_id, order_kind").in("campaign_id", ids).order("id", { ascending: true })),
          ]);
          const m = new Map<number, number>();
          for (const id of ids) m.set(id, 0);
          for (const it of itemRows) m.set(it.campaign_id, (m.get(it.campaign_id) ?? 0) + 1);
          if (!cancelled) setItemCounts(m);

          // 抓 items qty 並依 order_kind 聚合到 campaign — chunked by orderId in batches + range
          const orderIds = ordersList.map((o) => o.id);
          const oqRows: { order_id: number; qty: number }[] = [];
          for (let i = 0; i < orderIds.length; i += 500) {
            const chunk = orderIds.slice(i, i + 500);
            const rows = await fetchAll<{ order_id: number; qty: number }>(() =>
              sb.from("customer_order_items").select("order_id, qty").in("order_id", chunk).order("id", { ascending: true }));
            oqRows.push(...rows);
          }
          const orderMeta = new Map(ordersList.map((o) => [o.id, o]));
          const om = new Map<number, { normalQty: number; offsetQty: number }>();
          for (const id of ids) om.set(id, { normalQty: 0, offsetQty: 0 });
          for (const it of oqRows) {
            const meta = orderMeta.get(it.order_id);
            if (!meta) continue;
            const cur = om.get(meta.campaign_id) ?? { normalQty: 0, offsetQty: 0 };
            if (meta.order_kind === "offset") cur.offsetQty += Number(it.qty);
            else cur.normalQty += Number(it.qty);
            om.set(meta.campaign_id, cur);
          }
          if (!cancelled) setListOrderCounts(om);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [query, status, categoryFilter, page, reloadTick]);

  // Calendar (week / month) 取資料：依視圖決定範圍
  useEffect(() => {
    if (view === "list") return;
    let cancelled = false;
    (async () => {
      const today = startOfDay(new Date());
      let from: Date;
      let to: Date;
      if (view === "week") {
        from = today;
        to = addDays(today, 7);
      } else {
        from = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth(), 1);
        to = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() + 1, 1);
      }
      const { data, error } = await getSupabase()
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, status, close_type, start_at, display_order")
        .neq("campaign_no", "__INTERNAL_RESTOCK__")
        .gte("start_at", from.toISOString())
        .lt("start_at", to.toISOString())
        .order("start_at", { ascending: true })
        .order("display_order", { ascending: true });
      if (cancelled) return;
      if (error) { setError(error.message); return; }
      setError(null);
      const list = (data ?? []) as CalRow[];
      setCalRows(list);

      // 補商品數 + 下單總數量 — chunked fetch (bypass PostgREST 1000 cap)
      const ids = list.map((r) => r.id);
      if (ids.length > 0) {
        const sb = getSupabase();
        const [itemRows, ordersList] = await Promise.all([
          fetchAll<{ campaign_id: number }>(() =>
            sb.from("campaign_items").select("campaign_id").in("campaign_id", ids).order("id", { ascending: true })),
          fetchAll<{ id: number; campaign_id: number; order_kind: string }>(() =>
            sb.from("customer_orders").select("id, campaign_id, order_kind").in("campaign_id", ids).order("id", { ascending: true })),
        ]);
        if (cancelled) return;
        const im = new Map<number, number>();
        const om = new Map<number, number>();
        const offm = new Map<number, number>();
        for (const id of ids) { im.set(id, 0); om.set(id, 0); offm.set(id, 0); }
        for (const it of itemRows) im.set(it.campaign_id, (im.get(it.campaign_id) ?? 0) + 1);

        const orderIds = ordersList.map((o) => o.id);
        const oqRows: { order_id: number; qty: number }[] = [];
        for (let i = 0; i < orderIds.length; i += 500) {
          const chunk = orderIds.slice(i, i + 500);
          const rows = await fetchAll<{ order_id: number; qty: number }>(() =>
            sb.from("customer_order_items").select("order_id, qty").in("order_id", chunk).order("id", { ascending: true }));
          oqRows.push(...rows);
        }
        if (cancelled) return;
        const orderMeta = new Map(ordersList.map((o) => [o.id, o]));
        for (const it of oqRows) {
          const meta = orderMeta.get(it.order_id);
          if (!meta) continue;
          if (meta.order_kind === "offset") {
            offm.set(meta.campaign_id, (offm.get(meta.campaign_id) ?? 0) + Number(it.qty));
          } else {
            om.set(meta.campaign_id, (om.get(meta.campaign_id) ?? 0) + Number(it.qty));
          }
        }
        setCalItemCounts(im);
        setCalOrderCounts(om);
        setCalOffsetCounts(offm);
      } else {
        setCalItemCounts(new Map());
        setCalOrderCounts(new Map());
        setCalOffsetCounts(new Map());
      }
    })();
    return () => { cancelled = true; };
  }, [view, monthAnchor, reloadTick]);

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  // 操作鈕（編輯 / 加單 / 結單 / 結算）— 桌機表格與手機卡片共用，單一維護點
  const campaignActions = (r: Row) => (
    <>
      {showAdminActions && (
        <SpinButton
          onClick={() => openEdit(r.id)}
          className="text-xs text-blue-600 hover:underline dark:text-blue-400"
        >
          編輯
        </SpinButton>
      )}
      {r.status === "open" && (
        <Link
          href={`/campaigns/order-entry?id=${r.id}`}
          className="text-xs text-green-600 hover:underline dark:text-green-400"
        >
          加單
        </Link>
      )}
      {showAdminActions && r.status === "open" && (
        <SpinButton
          onClick={() => closeCampaign(r.id, r.name)}
          disabled={closingId === r.id}
          className="text-xs text-amber-600 hover:underline disabled:opacity-50 dark:text-amber-400"
        >
          {closingId === r.id ? "結單中…" : "結單"}
        </SpinButton>
      )}
      {showAdminActions && (["open", "closed", "locked", "ordered", "receiving", "ready"] as Status[]).includes(r.status) && (
        <SpinButton
          onClick={() => setFbPublishId(r.id)}
          className="text-xs text-sky-600 hover:underline dark:text-sky-400"
        >
          發 FB
        </SpinButton>
      )}
      {(["closed", "locked", "ordered", "receiving", "ready"] as Status[]).includes(r.status) && (
        <SpinButton
          onClick={() => finalizeCampaign(r.id, r.name)}
          disabled={finalizingId === r.id}
          className="text-xs text-purple-600 hover:underline disabled:opacity-50 dark:text-purple-400"
        >
          {finalizingId === r.id ? "結算中…" : "結算"}
        </SpinButton>
      )}
      {r.status === "draft" && (
        <SpinButton
          onClick={() => deleteCampaign(r.id, r.name)}
          className="text-xs text-red-600 hover:underline disabled:opacity-50 dark:text-red-400"
        >
          刪除
        </SpinButton>
      )}
    </>
  );

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">開團</h1>
          <p className="text-sm text-zinc-500">
            {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
          </p>
        </div>
        {showAdminActions && (
          <div className="flex gap-2">
            <SpinButton
              onClick={() => setShowRecurring(true)}
              className="rounded-md border border-zinc-300 px-3 py-2 text-sm font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              🔁 批次建立
            </SpinButton>
            <Link href="/products?mode=campaign" className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">
              + 從商品開團
            </Link>
          </div>
        )}
      </header>

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["list", "week", "month"] as View[]).map((v) => (
          <SpinButton
            key={v}
            onClick={() => setView(v)}
            className={
              view === v
                ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "list" ? "列表" : v === "week" ? "未來 7 天" : "月曆"}
          </SpinButton>
        ))}
      </div>

      {view === "list" && (
        <div className="grid gap-3 sm:grid-cols-3">
          <input
            type="search" placeholder="搜尋 團號 / 名稱" value={queryDraft} onChange={(e) => setQueryDraft(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
          />
          <select value={status} onChange={(e) => setStatus(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
            <option value="">全部狀態</option>
            {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
          <select value={categoryFilter} onChange={(e) => setCategoryFilter(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            aria-label="類別篩選">
            <option value="">全部類別</option>
            <option value="food_train">美食列車</option>
            <option value="none">一般（無類別）</option>
          </select>
        </div>
      )}

      {view === "month" && (
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <SpinButton
              onClick={() => setMonthAnchor(new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() - 1, 1))}
              className="rounded-md border border-zinc-300 px-2 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >‹ 上月</SpinButton>
            <span className="font-medium">
              {monthAnchor.getFullYear()} 年 {monthAnchor.getMonth() + 1} 月
            </span>
            <SpinButton
              onClick={() => setMonthAnchor(new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() + 1, 1))}
              className="rounded-md border border-zinc-300 px-2 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >下月 ›</SpinButton>
            <SpinButton
              onClick={() => setMonthAnchor(startOfDay(new Date()))}
              className="rounded-md border border-zinc-300 px-2 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >今天</SpinButton>
          </div>
          <span className="text-sm text-zinc-500">
            {calRows === null ? "載入中…" : `${calRows.length} 場`}
          </span>
        </div>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      {view !== "list" && (
        <CalendarView
          view={view}
          rows={calRows}
          monthAnchor={monthAnchor}
          itemCounts={calItemCounts}
          orderCounts={calOrderCounts}
          offsetCounts={calOffsetCounts}
          onPick={(id) => openEdit(id)}
          showEdit={showAdminActions}
        />
      )}

      {view === "list" && selectedIds.size > 0 && (
        <div className="flex flex-wrap items-center gap-3 rounded-md border border-zinc-300 bg-white px-4 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900">
          <span className="text-zinc-600 dark:text-zinc-400">已選 <span className="font-semibold">{selectedIds.size}</span> 個開團</span>
          <SpinButton
            onClick={() => bulkSetStatus("open", "開團中")}
            disabled={bulkBusy !== null}
            className="rounded-md bg-green-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-green-600 disabled:opacity-50"
          >
            {bulkBusy === "open" ? "啟動中…" : "批次開團"}
          </SpinButton>
          <SpinButton
            onClick={() => bulkSetStatus("closed", "已收單")}
            disabled={bulkBusy !== null}
            className="rounded-md bg-amber-100 px-3 py-1.5 text-sm font-medium text-amber-800 hover:bg-amber-200 disabled:opacity-50 dark:bg-amber-950 dark:text-amber-300 dark:hover:bg-amber-900"
          >
            {bulkBusy === "closed" ? "結單中…" : "批次結單"}
          </SpinButton>
          <SpinButton
            onClick={() => bulkSetStatus("cancelled", "已取消")}
            disabled={bulkBusy !== null}
            className="rounded-md bg-red-100 px-3 py-1.5 text-sm font-medium text-red-800 hover:bg-red-200 disabled:opacity-50 dark:bg-red-950 dark:text-red-300 dark:hover:bg-red-900"
          >
            {bulkBusy === "cancelled" ? "取消中…" : "批次取消"}
          </SpinButton>
          <SpinButton
            onClick={() => { setEndAtErr(null); setBulkEndAt(""); setEndAtOpen(true); }}
            disabled={bulkBusy !== null}
            className="rounded-md bg-blue-100 px-3 py-1.5 text-sm font-medium text-blue-800 hover:bg-blue-200 disabled:opacity-50 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
          >
            批次設定收單時間
          </SpinButton>
          {showAdminActions && (
            <SpinButton
              onClick={() => setBulkFbOpen(true)}
              disabled={bulkBusy !== null}
              className="rounded-md bg-sky-100 px-3 py-1.5 text-sm font-medium text-sky-800 hover:bg-sky-200 disabled:opacity-50 dark:bg-sky-950 dark:text-sky-300 dark:hover:bg-sky-900"
            >
              批次發 FB
            </SpinButton>
          )}
          <SpinButton
            onClick={() => setSelectedIds(new Set())}
            className="ml-auto text-xs text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
          >
            清除選取
          </SpinButton>
        </div>
      )}

      {view === "list" && (
      <>
      {/* 手機：每筆開團一張卡片（桌機改用下方表格） */}
      <div className="space-y-2 sm:hidden">
        {rows === null ? (
          <div className="rounded-md border border-zinc-200 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800">載入中…</div>
        ) : rows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800">
            {total === 0 && !query && !status ? "還沒有開團，按「新增開團」開始。" : "沒有符合條件的開團。"}
          </div>
        ) : rows.map((r) => (
          <div
            key={r.id}
            onClick={() => openEdit(r.id)}
            className={`cursor-pointer rounded-lg border p-3 ${selectedIds.has(r.id) ? "border-blue-300 bg-blue-50 dark:border-blue-800 dark:bg-blue-950/30" : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950"}`}
          >
            <div className="flex items-start gap-2">
              <input
                type="checkbox"
                checked={selectedIds.has(r.id)}
                onChange={() => toggleSelect(r.id)}
                onClick={(e) => e.stopPropagation()}
                className="mt-1 cursor-pointer"
              />
              <CampaignThumb url={campaignCoverUrl(r.cover_image_url, r.campaign_items)} name={r.name} />
              <div className="min-w-0 flex-1">
                <div className="break-words text-base font-bold text-zinc-900 dark:text-zinc-100">{r.name}</div>
                <div className="mt-1 flex flex-wrap items-center gap-1.5">
                  <StatusBadge s={r.status} />
                  <span className={`inline-block rounded px-1.5 py-0.5 text-[11px] font-medium ${CLOSE_TYPE_BADGE[r.close_type]}`}>
                    {CLOSE_TYPE_LABEL[r.close_type]}
                  </span>
                  {r.category && (
                    <span className={`inline-block rounded px-1.5 py-0.5 text-[11px] font-medium ${CATEGORY_BADGE[r.category]}`}>
                      {CATEGORY_LABEL[r.category]}
                    </span>
                  )}
                </div>
              </div>
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500">
              <span>
                {fmtDateTime(r.start_at)}
                {" → "}
                {fmtDateTime(r.end_at)}
              </span>
              <span>取貨截止 {r.pickup_deadline ?? "—"}</span>
              <span>商品 {itemCounts.get(r.id) ?? 0}</span>
              {(() => {
                const oc = listOrderCounts.get(r.id) ?? { normalQty: 0, offsetQty: 0 };
                if (oc.normalQty === 0 && oc.offsetQty === 0) return <span>下單 0</span>;
                return (
                  <Link
                    href={`/orders?campaignId=${r.id}`}
                    onClick={(e) => e.stopPropagation()}
                    className="inline-flex items-center gap-1 font-mono text-blue-700 hover:underline dark:text-blue-400"
                  >
                    下單 {oc.normalQty}
                    {oc.offsetQty !== 0 && (
                      <span className="rounded bg-red-100 px-1 text-[11px] text-red-800 dark:bg-red-950 dark:text-red-300">
                        {oc.offsetQty}
                      </span>
                    )}
                  </Link>
                );
              })()}
              <span className="ml-auto">更新 {new Date(r.updated_at).toLocaleDateString("zh-TW")}</span>
            </div>
            <div
              className="mt-2 flex flex-wrap items-center gap-2 border-t border-zinc-200/70 pt-2 dark:border-zinc-800"
              onClick={(e) => e.stopPropagation()}
            >
              {campaignActions(r)}
            </div>
          </div>
        ))}
      </div>

      <div className="hidden sm:block">
      <Table>
        <THead>
          <Th className="w-10">
            <input
              type="checkbox"
              checked={!!rows && rows.length > 0 && rows.every((r) => selectedIds.has(r.id))}
              ref={(el) => {
                if (el && rows) {
                  const allSel = rows.length > 0 && rows.every((r) => selectedIds.has(r.id));
                  const someSel = rows.some((r) => selectedIds.has(r.id));
                  el.indeterminate = !allSel && someSel;
                }
              }}
              onChange={toggleAllOnPage}
              className="cursor-pointer"
            />
          </Th>
          <Th className="w-20">{""}</Th><Th className="min-w-[14rem]">名稱</Th><Th className="whitespace-nowrap">狀態</Th><Th className="whitespace-nowrap">收單</Th><Th className="whitespace-nowrap">開團/收單</Th><Th className="whitespace-nowrap">取貨截止</Th><Th align="right" className="whitespace-nowrap">商品數</Th><Th align="right" className="whitespace-nowrap">下單總數</Th><Th align="right" className="whitespace-nowrap">更新</Th><Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={11} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={11}>{total === 0 && !query && !status ? "還沒有開團，按「新增開團」開始。" : "沒有符合條件的開團。"}</EmptyRow>
          ) : rows.map((r) => (
            <Tr key={r.id} onClick={() => openEdit(r.id)} className={selectedIds.has(r.id) ? "bg-blue-50 dark:bg-blue-950/30" : ""}>
                <Td className="w-10">
                  <input
                    type="checkbox"
                    checked={selectedIds.has(r.id)}
                    onChange={() => toggleSelect(r.id)}
                    onClick={(e) => e.stopPropagation()}
                    className="cursor-pointer"
                  />
                </Td>
                <Td className="w-20">
                  <CampaignThumb url={campaignCoverUrl(r.cover_image_url, r.campaign_items)} name={r.name} />
                </Td>
                <Td className="min-w-[14rem]">{r.name}</Td>
                <Td className="whitespace-nowrap"><StatusBadge s={r.status} /></Td>
                <Td>
                  <div className="flex flex-wrap items-center gap-1">
                    <span className={`inline-block rounded px-1.5 py-0.5 text-[11px] font-medium ${CLOSE_TYPE_BADGE[r.close_type]}`}>
                      {CLOSE_TYPE_LABEL[r.close_type]}
                    </span>
                    {r.category && (
                      <span className={`inline-block rounded px-1.5 py-0.5 text-[11px] font-medium ${CATEGORY_BADGE[r.category]}`}>
                        {CATEGORY_LABEL[r.category]}
                      </span>
                    )}
                  </div>
                </Td>
                <Td className="whitespace-nowrap text-xs text-zinc-500">
                  {fmtDateTime(r.start_at)}
                  {" → "}
                  {fmtDateTime(r.end_at)}
                </Td>
                <Td className="whitespace-nowrap text-xs">{r.pickup_deadline ?? "—"}</Td>
                <Td align="right" className="font-mono">{itemCounts.get(r.id) ?? 0}</Td>
                <Td align="right">
                  {(() => {
                    const oc = listOrderCounts.get(r.id) ?? { normalQty: 0, offsetQty: 0 };
                    const totalQty = oc.normalQty + oc.offsetQty;
                    if (oc.normalQty === 0 && oc.offsetQty === 0) {
                      return <span className="font-mono text-zinc-400">0</span>;
                    }
                    return (
                      <Link
                        href={`/orders?campaignId=${r.id}`}
                        onClick={(e) => e.stopPropagation()}
                        className="inline-flex items-center gap-1 rounded font-mono hover:bg-zinc-100 px-1 dark:hover:bg-zinc-800"
                        title={`點擊查看此開團的訂單\n正常下單總量：${oc.normalQty} 件${oc.offsetQty !== 0 ? `\n抵減量：${oc.offsetQty} 件\n淨需求：${totalQty} 件` : ""}`}
                      >
                        <span className="text-blue-700 hover:underline dark:text-blue-400">
                          {oc.normalQty}
                        </span>
                        {oc.offsetQty !== 0 && (
                          <span className="rounded bg-red-100 px-1 text-[11px] text-red-800 dark:bg-red-950 dark:text-red-300">
                            {oc.offsetQty}
                          </span>
                        )}
                      </Link>
                    );
                  })()}
                </Td>
                <Td align="right" className="whitespace-nowrap text-xs text-zinc-500">{new Date(r.updated_at).toLocaleString("zh-TW")}</Td>
                <Td className="whitespace-nowrap">
                  <div className="flex gap-2" onClick={(e) => e.stopPropagation()}>
                    {campaignActions(r)}
                  </div>
                </Td>
            </Tr>
          ))}
        </TBody>
      </Table>
      </div>
      </>
      )}

      <Modal
        open={showRecurring}
        onClose={() => setShowRecurring(false)}
        title="批次建立草稿開團"
        maxWidth="max-w-2xl"
      >
        {showRecurring && (
          <RecurringCampaignsForm
            onClose={() => setShowRecurring(false)}
            onCreated={() => { setShowRecurring(false); setReloadTick((t) => t + 1); }}
          />
        )}
      </Modal>

      <Modal
        open={endAtOpen}
        onClose={() => setEndAtOpen(false)}
        title="批次設定收單時間"
        maxWidth="max-w-md"
      >
        {endAtOpen && (
          <div className="space-y-4">
            <p className="text-sm text-zinc-600 dark:text-zinc-400">
              將套用到已選的 <span className="font-semibold">{selectedIds.size}</span> 個開團。
              僅「草稿 / 開團中」會被更新；已收單（含之後）會自動略過。
            </p>
            <label className="block text-sm">
              <span className="text-zinc-600 dark:text-zinc-400">新收單時間</span>
              <input
                type="datetime-local"
                value={bulkEndAt}
                onChange={(e) => setBulkEndAt(e.target.value)}
                className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                aria-label="新收單時間"
              />
            </label>
            {endAtErr && <p className="text-xs text-rose-600">{endAtErr}</p>}
            <div className="flex justify-end gap-2 pt-2">
              <SpinButton
                onClick={() => setEndAtOpen(false)}
                className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                取消
              </SpinButton>
              <SpinButton
                onClick={bulkSetEndAt}
                className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
              >
                確定套用
              </SpinButton>
            </div>
          </div>
        )}
      </Modal>

      <Modal
        open={!!modal}
        onClose={() => setModal(null)}
        title={modal ? `編輯開團 #${modal.values.campaign_no}｜${modal.values.name}` : ""}
        maxWidth="max-w-4xl"
      >
        {modal && (
          <div className="space-y-6">
            <CampaignItemsTable
              campaignId={modal.values.id!}
              status={modal.values.status}
              onResynced={() => { setResyncTick((t) => t + 1); setReloadTick((t) => t + 1); }}
            />
            <div className="border-t border-zinc-200 pt-4 dark:border-zinc-800">
              <CampaignForm
                initial={modal.values}
                onSaved={() => { setModal(null); setReloadTick((t) => t + 1); }}
                onCancel={() => setModal(null)}
              />
            </div>
            <div className="border-t border-zinc-200 pt-4 dark:border-zinc-800">
              <CampaignOrdersPanel key={resyncTick} campaignId={modal.values.id!} />
            </div>
          </div>
        )}
      </Modal>

      {view === "list" && totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}

      <FbPublishModal
        open={fbPublishId !== null}
        campaignId={fbPublishId}
        onClose={() => setFbPublishId(null)}
      />

      <FbBulkPublishModal
        open={bulkFbOpen}
        campaignIds={Array.from(selectedIds)}
        onClose={() => setBulkFbOpen(false)}
        onCompleted={() => setReloadTick((t) => t + 1)}
      />
    </div>
  );
}

function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return <SpinButton onClick={onClick} disabled={disabled} className="rounded-md border border-zinc-300 px-2 py-1 hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800 dark:disabled:hover:bg-transparent">{children}</SpinButton>;
}
function StatusBadge({ s }: { s: Status }) {
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${CAMPAIGN_STATUS_BADGE[s]}`}>{STATUS_LABEL[s]}</span>;
}

// ============================================================
// Calendar (week / month) view — 點卡片 → 開編輯 modal（共用 openEdit）
// ============================================================
function CalendarView({
  view,
  rows,
  monthAnchor,
  itemCounts,
  orderCounts,
  offsetCounts,
  onPick,
  showEdit,
}: {
  view: View;
  rows: CalRow[] | null;
  monthAnchor: Date;
  itemCounts: Map<number, number>;
  orderCounts: Map<number, number>;
  offsetCounts: Map<number, number>;
  onPick: (id: number) => void;
  showEdit: boolean;
}) {
  if (rows === null) {
    return <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>;
  }
  // 按日期分桶（key = YYYY-MM-DD）
  const buckets = new Map<string, CalRow[]>();
  for (const r of rows) {
    if (!r.start_at) continue;
    const key = localDateKey(new Date(r.start_at));
    const arr = buckets.get(key) ?? [];
    arr.push(r);
    buckets.set(key, arr);
  }

  if (view === "week") {
    const today = startOfDay(new Date());
    const days = Array.from({ length: 7 }, (_, i) => addDays(today, i));
    const weekdayCh = "日一二三四五六";
    return (
      <div className="grid gap-2 md:grid-cols-7">
        {days.map((d) => {
          const key = localDateKey(d);
          const list = buckets.get(key) ?? [];
          const isToday = key === localDateKey(new Date());
          return (
            <div
              key={key}
              className={`flex min-h-[280px] flex-col rounded-md border ${
                isToday
                  ? "border-zinc-900 dark:border-zinc-100"
                  : "border-zinc-200 dark:border-zinc-800"
              }`}
            >
              <div
                className={`flex items-baseline justify-between border-b px-3 py-2 ${
                  isToday
                    ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                    : "border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900"
                }`}
              >
                <div>
                  <div className={`text-[11px] ${isToday ? "opacity-90" : "text-zinc-500"}`}>
                    {d.getMonth() + 1} 月
                  </div>
                  <div className="flex items-baseline gap-1.5">
                    <span className="text-xl font-semibold leading-none">{d.getDate()}</span>
                    <span className={`text-xs ${isToday ? "opacity-90" : "text-zinc-500"}`}>
                      週{weekdayCh[d.getDay()]}
                    </span>
                  </div>
                </div>
                {isToday && (
                  <span className="rounded bg-white px-1.5 py-0.5 text-[10px] font-medium text-zinc-900 dark:bg-zinc-900 dark:text-zinc-100">
                    今天
                  </span>
                )}
              </div>
              <div className="flex-1 space-y-2 p-2">
                {list.length === 0 && (
                  <div className="py-4 text-center text-[11px] text-zinc-400">—</div>
                )}
                {list.map((r) => (
                  <CampaignCard
                    key={r.id}
                    r={r}
                    itemCount={itemCounts.get(r.id) ?? 0}
                    orderCount={orderCounts.get(r.id) ?? 0}
                    offsetCount={offsetCounts.get(r.id) ?? 0}
                    onPick={onPick}
                    showEdit={showEdit}
                  />
                ))}
              </div>
            </div>
          );
        })}
      </div>
    );
  }

  // month
  const year = monthAnchor.getFullYear();
  const month = monthAnchor.getMonth();
  const firstOfMonth = new Date(year, month, 1);
  const startWeekday = firstOfMonth.getDay(); // 0=Sun ... 6=Sat
  // 從這週日開始，一直渲到 6 週（42 格）
  const gridStart = addDays(firstOfMonth, -startWeekday);
  const cells = Array.from({ length: 42 }, (_, i) => addDays(gridStart, i));
  const todayKey = localDateKey(new Date());

  return (
    <div>
      <div className="grid grid-cols-7 border-l border-t border-zinc-200 dark:border-zinc-800">
        {"日一二三四五六".split("").map((d) => (
          <div
            key={d}
            className="border-b border-r border-zinc-200 bg-zinc-50 px-2 py-1.5 text-center text-xs font-medium text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400"
          >
            {d}
          </div>
        ))}
        {cells.map((d) => {
          const key = localDateKey(d);
          const inMonth = d.getMonth() === month;
          const isToday = key === todayKey;
          const list = buckets.get(key) ?? [];
          return (
            <div
              key={key}
              className={`min-h-[110px] border-b border-r border-zinc-200 p-1.5 dark:border-zinc-800 ${
                inMonth ? "bg-white dark:bg-zinc-950" : "bg-zinc-50 dark:bg-zinc-900/40"
              }`}
            >
              <div
                className={`mb-1 text-right text-xs ${
                  isToday
                    ? "font-bold text-zinc-900 dark:text-zinc-100"
                    : inMonth
                    ? "text-zinc-600 dark:text-zinc-400"
                    : "text-zinc-400 dark:text-zinc-600"
                }`}
              >
                {d.getDate()}
              </div>
              <div className="space-y-1">
                {list.slice(0, 3).map((r) => (
                  <CampaignCard
                    key={r.id}
                    r={r}
                    compact
                    itemCount={itemCounts.get(r.id) ?? 0}
                    orderCount={orderCounts.get(r.id) ?? 0}
                    offsetCount={offsetCounts.get(r.id) ?? 0}
                    onPick={onPick}
                    showEdit={showEdit}
                  />
                ))}
                {list.length > 3 && (
                  <div className="text-[10px] text-zinc-500">+{list.length - 3} 場</div>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ============================================================
// RecurringCampaignsForm — 批次建立草稿開團（每月 N 號 / 每週 N / 每隔 N 天）
// ============================================================

type RecMode = "monthly" | "weekly" | "daily";

type ActiveProductRow = {
  id: number;
  product_code: string;
  name: string;
  skus: { id: number; sku_code: string; variant_name: string | null; status: string }[];
};

function RecurringCampaignsForm({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: () => void;
}) {
  const [products, setProducts] = useState<ActiveProductRow[] | null>(null);
  const [productId, setProductId] = useState<number | null>(null);
  const [skuId, setSkuId] = useState<number | null>(null);
  const [mode, setMode] = useState<RecMode>("monthly");
  const [anchorDate, setAnchorDate] = useState<string>(() => localDateKey(addDays(startOfDay(new Date()), 1)));
  const [time, setTime] = useState<string>("08:00");
  const [count, setCount] = useState<number>(3);
  const [intervalDays, setIntervalDays] = useState<number>(7);
  const [dayOfMonth, setDayOfMonth] = useState<number>(() => new Date().getDate());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: prods, error } = await sb
        .from("products")
        .select("id, product_code, name, status")
        .eq("status", "active")
        .order("product_code");
      if (cancelled) return;
      if (error) { setError(error.message); return; }
      const ids = (prods ?? []).map((p) => p.id);
      let skusByProd = new Map<number, ActiveProductRow["skus"]>();
      if (ids.length > 0) {
        const { data: skus } = await sb
          .from("skus")
          .select("id, product_id, sku_code, variant_name, status")
          .in("product_id", ids)
          .eq("status", "active")
          .order("id");
        for (const s of (skus ?? []) as { id: number; product_id: number; sku_code: string; variant_name: string | null; status: string }[]) {
          const arr = skusByProd.get(s.product_id) ?? [];
          arr.push({ id: s.id, sku_code: s.sku_code, variant_name: s.variant_name, status: s.status });
          skusByProd.set(s.product_id, arr);
        }
      }
      const list: ActiveProductRow[] = (prods ?? [])
        .map((p) => ({ ...p, skus: skusByProd.get(p.id) ?? [] }))
        .filter((p) => p.skus.length > 0);
      setProducts(list);
    })();
    return () => { cancelled = true; };
  }, []);

  const selectedProduct = products?.find((p) => p.id === productId) ?? null;

  // 切換 product 時、自動選第一個 sku
  useEffect(() => {
    if (selectedProduct && selectedProduct.skus.length > 0) {
      if (!selectedProduct.skus.some((s) => s.id === skuId)) {
        setSkuId(selectedProduct.skus[0].id);
      }
    } else {
      setSkuId(null);
    }
  }, [selectedProduct, skuId]);

  // 計算預覽日期
  // monthly: 使用 anchorDate 的年月當起點 + dayOfMonth 為固定日；遇 30/31 不存在月份用該月最後一天
  const previewDates = (() => {
    if (!anchorDate) return [];
    const [y, m, d] = anchorDate.split("-").map(Number);
    const result: Date[] = [];
    const n = Math.max(1, Math.min(count, 24));
    for (let i = 0; i < n; i++) {
      if (mode === "monthly") {
        const targetMonth = m - 1 + i;
        const lastDay = new Date(y, targetMonth + 1, 0).getDate();
        const day = Math.min(dayOfMonth, lastDay);
        result.push(new Date(y, targetMonth, day));
      } else if (mode === "weekly") {
        const base = new Date(y, m - 1, d);
        result.push(new Date(base.getFullYear(), base.getMonth(), base.getDate() + i * 7));
      } else {
        const base = new Date(y, m - 1, d);
        result.push(new Date(base.getFullYear(), base.getMonth(), base.getDate() + i * intervalDays));
      }
    }
    return result;
  })();

  async function handleSubmit() {
    setError(null);
    if (!productId || !skuId || !selectedProduct) {
      setError("請先選擇商品 / 規格");
      return;
    }
    if (previewDates.length === 0) {
      setError("無預覽日期");
      return;
    }
    setBusy(true);
    setProgress({ done: 0, total: previewDates.length });
    const sb = getSupabase();

    const errors: string[] = [];
    for (let i = 0; i < previewDates.length; i++) {
      const d = previewDates[i];
      const [hh, mm] = time.split(":").map(Number);
      const startAt = new Date(d.getFullYear(), d.getMonth(), d.getDate(), hh ?? 8, mm ?? 0);
      const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
      const campaignNo = `GB${ymd}-S${String(skuId).padStart(6, "0")}`;

      try {
        const { data: campId, error: cErr } = await sb.rpc("rpc_upsert_campaign", {
          p_id: null,
          p_campaign_no: campaignNo,
          p_name: selectedProduct.name,
          p_description: null,
          p_status: "draft",
          p_close_type: "regular",
          p_start_at: startAt.toISOString(),
          p_end_at: null,
          p_pickup_deadline: null,
          p_pickup_days: null,
          p_total_cap_qty: null,
          p_notes: `recurring batch (${mode}) for product ${selectedProduct.product_code}`,
        });
        if (cErr) throw cErr;
        const { error: iErr } = await sb.rpc("rpc_upsert_campaign_item", {
          p_id: null,
          p_campaign_id: Number(campId),
          p_sku_id: skuId,
          p_unit_price: 0,
          p_cap_qty: null,
          p_sort_order: 0,
          p_notes: null,
        });
        if (iErr) throw iErr;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        errors.push(`${campaignNo}: ${msg}`);
      }
      setProgress({ done: i + 1, total: previewDates.length });
    }

    setBusy(false);
    if (errors.length > 0) {
      setError(`完成 ${previewDates.length - errors.length} / ${previewDates.length}\n失敗：\n${errors.join("\n")}`);
    } else {
      onCreated();
    }
  }

  if (products === null) {
    return <div className="p-4 text-center text-sm text-zinc-500">載入上架商品…</div>;
  }
  if (products.length === 0) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-zinc-700 dark:text-zinc-300">目前沒有上架商品。請先到商品頁把商品設為「上架」（需有規格 + 三種價格）。</p>
        <SpinButton onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">關閉</SpinButton>
      </div>
    );
  }

  const inputCls = "w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="space-y-4">
      {/* 商品 / 規格 */}
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">商品（上架中）</span>
          <select value={productId ?? ""} onChange={(e) => setProductId(Number(e.target.value) || null)} className={inputCls}>
            <option value="">— 請選 —</option>
            {products.map((p) => (
              <option key={p.id} value={p.id}>{p.product_code} {p.name}</option>
            ))}
          </select>
        </label>

        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">規格</span>
          <select value={skuId ?? ""} onChange={(e) => setSkuId(Number(e.target.value) || null)} disabled={!selectedProduct} className={inputCls}>
            <option value="">— 請選商品先 —</option>
            {selectedProduct?.skus.map((s) => (
              <option key={s.id} value={s.id}>{s.sku_code}{s.variant_name ? ` / ${s.variant_name}` : ""}</option>
            ))}
          </select>
        </label>
      </div>

      {/* 重複頻率 */}
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">重複頻率</span>
          <select value={mode} onChange={(e) => setMode(e.target.value as RecMode)} className={inputCls}>
            <option value="monthly">每月</option>
            <option value="weekly">每週</option>
            <option value="daily">每隔 N 天</option>
          </select>
        </label>

        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">第一場日期</span>
          <DatePicker value={anchorDate} onChange={setAnchorDate} className={inputCls} />
        </label>

        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">開團時間</span>
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} className={inputCls} />
        </label>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        {mode === "monthly" && (
          <label className="block space-y-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">每月 N 號（1-31，超過該月天數會用該月最後一天）</span>
            <input type="number" min={1} max={31} value={dayOfMonth} onChange={(e) => setDayOfMonth(Math.max(1, Math.min(31, Number(e.target.value) || 1)))} className={inputCls} />
          </label>
        )}
        {mode === "daily" && (
          <label className="block space-y-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">每隔幾天</span>
            <input type="number" min={1} max={60} value={intervalDays} onChange={(e) => setIntervalDays(Math.max(1, Math.min(60, Number(e.target.value) || 1)))} className={inputCls} />
          </label>
        )}
        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">建立場次（最多 24）</span>
          <input type="number" min={1} max={24} value={count} onChange={(e) => setCount(Math.max(1, Math.min(24, Number(e.target.value) || 1)))} className={inputCls} />
        </label>
      </div>

      {/* 預覽 */}
      <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
        <div className="mb-2 text-xs font-medium text-zinc-700 dark:text-zinc-300">
          將建立 {previewDates.length} 場開團（draft）：
        </div>
        <div className="flex flex-wrap gap-1.5">
          {previewDates.map((d, i) => (
            <span key={i} className="rounded bg-zinc-100 px-2 py-0.5 text-xs text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
              {d.getFullYear()}/{d.getMonth() + 1}/{d.getDate()}（週{"日一二三四五六"[d.getDay()]}）
            </span>
          ))}
        </div>
      </div>

      {error && (
        <div className="whitespace-pre-wrap rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {progress && (
        <div className="text-xs text-zinc-500">
          建立中 {progress.done} / {progress.total}
        </div>
      )}

      <div className="flex items-center gap-2">
        <SpinButton
          onClick={handleSubmit}
          disabled={busy || !productId || !skuId}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
        >
          {busy ? `建立中… ${progress?.done ?? 0}/${progress?.total ?? 0}` : `建立 ${previewDates.length} 場`}
        </SpinButton>
        <SpinButton onClick={onClose} disabled={busy} className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700">取消</SpinButton>
      </div>
    </div>
  );
}

function CampaignCard({
  r,
  compact,
  itemCount,
  orderCount,
  offsetCount,
  onPick,
  showEdit,
}: {
  r: CalRow;
  compact?: boolean;
  itemCount: number;
  orderCount: number;
  offsetCount: number;
  onPick: (id: number) => void;
  showEdit: boolean;
}) {
  const statusBadgeColor: Record<Status, string> = {
    draft: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-200",
    open: "bg-green-200 text-green-800 dark:bg-green-900 dark:text-green-200",
    closed: "bg-amber-200 text-amber-800 dark:bg-amber-900 dark:text-amber-200",
    locked: "bg-rose-200 text-rose-800 dark:bg-rose-900 dark:text-rose-200",
    ordered: "bg-blue-200 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
    receiving: "bg-indigo-200 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200",
    ready: "bg-emerald-200 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200",
    completed: "bg-zinc-300 text-zinc-700 dark:bg-zinc-600 dark:text-zinc-200",
    cancelled: "bg-red-200 text-red-800 dark:bg-red-900 dark:text-red-200",
  };
  const compactBg = CAMPAIGN_STATUS_BADGE;

  if (compact) {
    return (
      <SpinButton
        onClick={() => onPick(r.id)}
        className={`block w-full truncate rounded px-1.5 py-0.5 text-left text-[10px] ${compactBg[r.status]} hover:opacity-80`}
        title={`${r.campaign_no}｜${r.name}｜${STATUS_LABEL[r.status]}｜${itemCount} 商品｜下單 ${orderCount} 件${offsetCount !== 0 ? `｜抵減 ${offsetCount} 件` : ""}`}
      >
        <span className="font-medium">{r.name || r.campaign_no}</span>
      </SpinButton>
    );
  }

  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3.5 shadow-sm transition hover:border-zinc-400 hover:shadow dark:border-zinc-700 dark:bg-zinc-900 dark:hover:border-zinc-500">
      {/* 標題：商品名稱 + 狀態 */}
      <div className="mb-2 flex items-start justify-between gap-1.5">
        <SpinButton
          onClick={() => onPick(r.id)}
          className="flex-1 truncate text-left text-[15px] font-semibold leading-tight text-zinc-900 hover:underline dark:text-zinc-100"
          title={`${r.campaign_no}｜${r.name}`}
        >
          {r.name || r.campaign_no}
        </SpinButton>
        <span className={`shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${statusBadgeColor[r.status]}`}>
          {STATUS_LABEL[r.status]}
        </span>
      </div>

      {/* 收單類型 + 團號 */}
      <div className="mb-2 flex items-center gap-1.5">
        <span className={`shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${CLOSE_TYPE_BADGE[r.close_type]}`}>
          {CLOSE_TYPE_LABEL[r.close_type]}
        </span>
        <SpinButton
          onClick={() => onPick(r.id)}
          className="min-w-0 flex-1 truncate text-left font-mono text-[11px] text-zinc-500 hover:underline"
        >
          {r.campaign_no}
        </SpinButton>
      </div>

      {/* 數據：商品數 / 下單總量 / 抵減總量 */}
      <div className="mb-2 flex flex-wrap gap-2 text-[12px]">
        <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
          📦 {itemCount} 商品
        </span>
        {orderCount !== 0 || offsetCount !== 0 ? (
          <Link
            href={`/orders?campaignId=${r.id}`}
            className={`rounded px-1.5 py-0.5 transition ${orderCount > 0 ? "bg-blue-100 font-medium text-blue-800 hover:bg-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900" : "bg-zinc-100 text-zinc-500 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-400"}`}
            title={`點擊查看訂單｜下單總量：${orderCount} 件${offsetCount !== 0 ? `｜抵減量：${offsetCount} 件｜淨需求：${orderCount + offsetCount} 件` : ""}`}
          >
            🛒 {orderCount} 件
          </Link>
        ) : (
          <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
            🛒 0 件
          </span>
        )}
        {offsetCount !== 0 && (
          <Link
            href={`/orders?campaignId=${r.id}`}
            className="rounded bg-red-100 px-1.5 py-0.5 font-medium text-red-800 hover:bg-red-200 dark:bg-red-950 dark:text-red-300 dark:hover:bg-red-900"
            title={`庫存抵減 ${offsetCount} 件（採購聚合會扣掉這部分）`}
          >
            {offsetCount} 抵
          </Link>
        )}
      </div>

      {/* 動作 */}
      <div className="flex flex-wrap gap-1">
        {r.status === "open" && (
          <Link
            href={`/campaigns/order-entry?id=${r.id}`}
            className="rounded border border-green-400 bg-green-50 px-2 py-0.5 text-[11px] font-medium text-green-700 hover:bg-green-100 dark:border-green-700 dark:bg-green-950 dark:text-green-300 dark:hover:bg-green-900"
          >
            + 加單
          </Link>
        )}
        {showEdit && (
          <SpinButton
            onClick={() => onPick(r.id)}
            className="rounded border border-zinc-300 px-2 py-0.5 text-[11px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400 dark:hover:bg-zinc-800"
          >
            編輯
          </SpinButton>
        )}
      </div>
    </div>
  );
}
