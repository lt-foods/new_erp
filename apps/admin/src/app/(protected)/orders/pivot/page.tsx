"use client";

import Link from "next/link";
import { Fragment, Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import { useDefaultStoreFromUser, useUserBranchStoreId } from "@/lib/useDefaultStoreFromUser";
import { ORDER_STATUSES, ORDER_STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";
import SpinButton from "@/components/SpinButton";

type CampaignStatus =
  | "draft" | "open" | "closed" | "ordered" | "receiving" | "ready" | "completed" | "cancelled";

type Campaign = {
  id: number;
  campaign_no: string;
  name: string;
  status: CampaignStatus;
  start_at: string | null;
  end_at: string | null;
};

// 已過收單階段的狀態（在 pivot 視覺上標「已結單」tag + 底色）
const CLOSED_STATUSES: ReadonlySet<CampaignStatus> = new Set([
  "closed", "ordered", "receiving", "ready", "completed",
]);
type Store = { id: number; code: string; name: string };

type OrderRow = {
  id: number;
  order_no: string;
  campaign_id: number;
  member_id: number | null;
  nickname_snapshot: string | null;
  pickup_store_id: number;
  pickup_deadline: string | null;
  status: OrderStatus;
  created_at: string;
};

type Member = { id: number; name: string | null; phone: string | null };

// server-side aggregate row (rpc_orders_pivot)
type PivotRow = {
  group_key: string;
  group_id: number | null;        // campaign mode = campaign_id；date mode = null
  sku_id: number;
  sku_product_name: string | null;
  sku_variant_name: string | null;
  pickup_store_id: number;
  qty_sum: number | string;       // numeric → string via postgrest
  amount: number | string;
  pos_order_ids: number[];
  neg_order_ids: number[];
};

type ViewBy = "order_date" | "campaign";
type Metric = "item_qty" | "order_count" | "amount";

// 把舊 LS 的 "count" 視為 "item_qty" (用戶真正想要的、之前命名誤導)
function normalizeMetric(v: string | undefined | null): Metric | null {
  if (v === "item_qty" || v === "order_count" || v === "amount") return v;
  if (v === "count") return "item_qty"; // legacy migration
  return null;
}

// 「取貨日」分組已下架（2026-05-21）— 舊 LS / URL 殘留 fallback 到 campaign
function normalizeViewBy(v: string | undefined | null): ViewBy | null {
  if (v === "order_date" || v === "campaign") return v;
  if (v === "pickup_date") return "campaign";
  return null;
}

const DEFAULT_EXCLUDED: OrderStatus[] = ["cancelled", "expired", "transferred_out"];
const DEFAULT_INCLUDED: OrderStatus[] = ORDER_STATUSES.filter(
  (s) => !DEFAULT_EXCLUDED.includes(s as OrderStatus),
);
const LS_KEY = "new_erp-orders-pivot-filters";

function fmtMonthInput(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

// 預設: 當月 ~ 當月 (1 個月範圍, 想看更多月使用者自己拉)
function defaultMonthRange(): { from: string; to: string } {
  const today = new Date();
  const cur = fmtMonthInput(today);
  return { from: cur, to: cur };
}

// 把 LS 舊版的 YYYY-MM-DD 截成 YYYY-MM
function normalizeMonth(v: string | undefined | null): string | null {
  if (!v) return null;
  if (/^\d{4}-\d{2}$/.test(v)) return v;
  if (/^\d{4}-\d{2}-\d{2}/.test(v)) return v.slice(0, 7);
  return null;
}

// "2026-05" → "2026-05-01" (含當月 1 日 00:00)
function monthStartDate(ym: string): string {
  return `${ym}-01`;
}

// "2026-05" → "2026-06-01" (下個月 1 日 00:00, 用 < 比較)
function nextMonthStartDate(ym: string): string {
  const [y, m] = ym.split("-").map(Number);
  const next = new Date(Date.UTC(y, m, 1)); // m: 1-based 過了一個月 → 0-based 即下個月
  const ny = next.getUTCFullYear();
  const nm = String(next.getUTCMonth() + 1).padStart(2, "0");
  return `${ny}-${nm}-01`;
}

function fmtMD(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

function fmtAmount(n: number): string {
  const r = Math.round(n);
  return r < 0
    ? `-$${Math.abs(r).toLocaleString("zh-TW")}`
    : `$${r.toLocaleString("zh-TW")}`;
}

export default function OrdersPivotPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PivotContent />
    </Suspense>
  );
}

function PivotContent() {
  const searchParams = useSearchParams();
  const def = useMemo(defaultMonthRange, []);

  const initialCampaignIds = ((): string[] => {
    const multi = searchParams.get("campaignIds");
    if (multi) return multi.split(",").map((s) => s.trim()).filter(Boolean);
    return [];
  })();

  const [campaignIds, setCampaignIds] = useState<string[]>(initialCampaignIds);
  const [viewBy, setViewBy] = useState<ViewBy>(
    normalizeViewBy(searchParams.get("viewBy")) ?? "campaign",
  );
  const [dateFrom, setDateFrom] = useState(
    normalizeMonth(searchParams.get("from")) ?? def.from,
  );
  const [dateTo, setDateTo] = useState(normalizeMonth(searchParams.get("to")) ?? def.to);
  const [statusSet, setStatusSet] = useState<Set<OrderStatus>>(new Set(DEFAULT_INCLUDED));
  const [storeId, setStoreId] = useState(searchParams.get("storeId") ?? "");
  const [metric, setMetric] = useState<Metric>(
    normalizeMetric(searchParams.get("metric")) ?? "item_qty",
  );
  const [closedOnly, setClosedOnly] = useState<boolean>(
    searchParams.get("closedOnly") === "1",
  );

  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [pivotRows, setPivotRows] = useState<PivotRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaignPickerOpen, setCampaignPickerOpen] = useState(false);
  const [statusPickerOpen, setStatusPickerOpen] = useState(false);

  // hydrate flag — 等 LS 載入完才跑 filter 抓資料
  const [hydrated, setHydrated] = useState(false);

  // Cell drill-down modal
  const [cellModal, setCellModal] = useState<{
    title: string;
    orderIds: number[];
    skuId: number;
  } | null>(null);
  const [detailId, setDetailId] = useState<number | null>(null);
  const [detailNo, setDetailNo] = useState<string>("");

  // 水平導覽：用 header 旁的箭頭鈕捲動（捲軸已隱藏）
  const scrollRef = useRef<HTMLDivElement>(null);
  const [canScrollL, setCanScrollL] = useState(false);
  const [canScrollR, setCanScrollR] = useState(false);
  function scrollX(dir: 1 | -1) {
    const el = scrollRef.current;
    if (!el) return;
    el.scrollBy({ left: dir * Math.max(240, el.clientWidth * 0.8), behavior: "smooth" });
  }

  // 從 localStorage 載入 filter (URL params 優先級高於 LS)
  useEffect(() => {
    try {
      const raw = localStorage.getItem(LS_KEY);
      if (raw) {
        const saved = JSON.parse(raw) as Partial<{
          campaignIds: string[];
          viewBy: ViewBy;
          dateFrom: string;
          dateTo: string;
          status: OrderStatus[];
          storeId: string;
          metric: Metric;
          closedOnly: boolean;
        }>;
        if (!searchParams.get("campaignIds") && Array.isArray(saved.campaignIds)) {
          setCampaignIds(saved.campaignIds);
        }
        if (!searchParams.get("viewBy")) {
          const v = normalizeViewBy(saved.viewBy);
          if (v) setViewBy(v);
        }
        if (!searchParams.get("from")) {
          const m = normalizeMonth(saved.dateFrom);
          if (m) setDateFrom(m);
        }
        if (!searchParams.get("to")) {
          const m = normalizeMonth(saved.dateTo);
          if (m) setDateTo(m);
        }
        if (Array.isArray(saved.status) && saved.status.length > 0) {
          setStatusSet(new Set(saved.status));
        }
        if (!searchParams.get("storeId") && typeof saved.storeId === "string") {
          setStoreId(saved.storeId);
        }
        if (!searchParams.get("metric")) {
          const m = normalizeMetric(saved.metric);
          if (m) setMetric(m);
        }
        if (!searchParams.get("closedOnly") && typeof saved.closedOnly === "boolean") {
          setClosedOnly(saved.closedOnly);
        }
      }
    } catch {
      /* noop */
    }
    setHydrated(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 寫回 localStorage
  useEffect(() => {
    if (!hydrated) return;
    try {
      localStorage.setItem(
        LS_KEY,
        JSON.stringify({
          campaignIds,
          viewBy,
          dateFrom,
          dateTo,
          status: Array.from(statusSet),
          storeId,
          metric,
          closedOnly,
        }),
      );
    } catch {
      /* noop */
    }
  }, [hydrated, campaignIds, viewBy, dateFrom, dateTo, statusSet, storeId, metric, closedOnly]);

  // 分店帳號鎖
  const branchStoreId = useUserBranchStoreId(stores);
  useEffect(() => {
    if (branchStoreId != null && storeId !== String(branchStoreId)) {
      setStoreId(String(branchStoreId));
    }
  }, [branchStoreId, storeId]);
  useDefaultStoreFromUser(stores, storeId, setStoreId);

  // Load campaigns + stores
  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [c, s] = await Promise.all([
        sb
          .from("group_buy_campaigns")
          .select("id, campaign_no, name, status, start_at, end_at")
          .order("updated_at", { ascending: false })
          .limit(500),
        sb.from("stores").select("id, code, name").order("name"),
      ]);
      setCampaigns((c.data as Campaign[]) ?? []);
      setStores((s.data as Store[]) ?? []);
    })();
  }, []);

  // 透過 server-side RPC 拉 aggregate（rpc_orders_pivot）
  // 取代之前 client 撈 raw orders+items 再 group by 的做法 — 那做法 items
  // 一次 .in('order_id', ...) 沒分頁，會被 PostgREST max_rows=1000 截斷，
  // 導致跨多店時數字偏低（甚至出現「單店 > 全部」的反直覺結果）
  useEffect(() => {
    if (!hydrated) return;
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        const statusArr = Array.from(statusSet);
        if (statusArr.length === 0) {
          setPivotRows([]);
          setError(null);
          setLoading(false);
          return;
        }
        const fromBoundary = dateFrom ? monthStartDate(dateFrom) : null;
        const toBoundary = dateTo ? nextMonthStartDate(dateTo) : null;
        const { data, error: rpcErr } = await sb.rpc("rpc_orders_pivot", {
          p_view_by: viewBy,
          p_date_from: fromBoundary,
          p_date_to: toBoundary,
          p_campaign_ids: campaignIds.length ? campaignIds.map((x) => Number(x)) : null,
          p_store_id: storeId ? Number(storeId) : null,
          p_statuses: statusArr,
          p_closed_only: closedOnly ? true : null,
        });
        if (cancelled) return;
        if (rpcErr) {
          setError(rpcErr.message);
          setPivotRows([]);
          setLoading(false);
          return;
        }
        setPivotRows((data ?? []) as PivotRow[]);
        setError(null);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [hydrated, campaignIds, viewBy, dateFrom, dateTo, statusSet, storeId, closedOnly]);

  const storeMap = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);
  const campaignMap = useMemo(() => new Map(campaigns.map((c) => [c.id, c])), [campaigns]);

  // 樞紐 aggregate — 從 server-side RPC 結果（pivotRows）構造
  // 每一列 = 一個 (group × sku × store) cell
  type CellAgg = {
    posOrders: Set<number>; // 有效訂單
    negOrders: Set<number>; // 取消/逾期/轉出（扣抵）
    qtySum: number;
    amount: number;
  };
  type SkuEntry = { name: string; perStore: Map<number, CellAgg> };
  type Group = {
    key: string;
    label: string;
    subLabel: string | null;
    sortKey: number; // bigger = newer for campaign desc, date as YYYYMMDD num
    closed: boolean; // campaign 視角時為 true 代表已過收單階段
    skus: Map<number, SkuEntry>;
  };

  const pivot = useMemo(() => {
    const groups = new Map<string, Group>();
    const storeIdsUsed = new Set<number>();

    for (const r of pivotRows) {
      let label = "";
      let subLabel: string | null = null;
      let sortKey = 0;
      let closed = false;

      if (viewBy === "campaign") {
        const cid = r.group_id;
        const c = cid != null ? campaignMap.get(cid) : undefined;
        label = c?.name ?? `團 ${cid ?? "?"}`;
        if (c?.start_at || c?.end_at) {
          subLabel = `${fmtMD(c?.start_at ?? null)} ~ ${fmtMD(c?.end_at ?? null)} 收單`;
        } else {
          subLabel = "未設收單時間";
        }
        sortKey = c?.end_at ? new Date(c.end_at).getTime() : 0;
        closed = c ? CLOSED_STATUSES.has(c.status) : false;
      } else {
        // date mode: group_key = "d2026-05-01"
        const dk = r.group_key.startsWith("d") ? r.group_key.slice(1) : r.group_key;
        label = dk;
        sortKey = Number(dk.replace(/-/g, ""));
      }

      let group = groups.get(r.group_key);
      if (!group) {
        group = { key: r.group_key, label, subLabel, sortKey, closed, skus: new Map() };
        groups.set(r.group_key, group);
      }

      const skuName =
        r.sku_variant_name?.trim() || r.sku_product_name?.trim() || `SKU#${r.sku_id}`;
      let entry = group.skus.get(r.sku_id);
      if (!entry) {
        entry = { name: skuName, perStore: new Map() };
        group.skus.set(r.sku_id, entry);
      }
      const sid = r.pickup_store_id;
      storeIdsUsed.add(sid);
      // 同一 cell 在 RPC 結果應只出現一次（GROUP BY 後唯一），直接覆寫
      entry.perStore.set(sid, {
        posOrders: new Set(r.pos_order_ids ?? []),
        negOrders: new Set(r.neg_order_ids ?? []),
        qtySum: Number(r.qty_sum),
        amount: Number(r.amount),
      });
    }

    const groupArr = Array.from(groups.values()).sort((a, b) =>
      // campaign mode: 新到舊 (desc); date mode: 早到晚 (asc)
      viewBy === "campaign" ? b.sortKey - a.sortKey : a.sortKey - b.sortKey,
    );
    const storeIds = Array.from(storeIdsUsed).sort((a, b) => {
      const an = storeMap.get(a)?.name ?? "";
      const bn = storeMap.get(b)?.name ?? "";
      return an.localeCompare(bn, "zh-TW");
    });
    return { groups: groupArr, storeIds };
  }, [pivotRows, campaignMap, storeMap, viewBy]);

  // 追蹤可否再往左/右捲（決定箭頭鈕 disabled）
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const update = () => {
      setCanScrollL(el.scrollLeft > 1);
      setCanScrollR(el.scrollLeft + el.clientWidth < el.scrollWidth - 1);
    };
    update();
    el.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    return () => {
      el.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
    };
  }, [pivot]);

  // metric 取值 helper
  // 訂單數淨值＝有效訂單數 − 取消/逾期/轉出 訂單數
  const cellOrderCount = (c: CellAgg): number => c.posOrders.size - c.negOrders.size;
  const cellTouched = (c: CellAgg): number => c.posOrders.size + c.negOrders.size;
  const cellAllOrderIds = (c: CellAgg): number[] => [...c.posOrders, ...c.negOrders];
  const cellValue = (cell: CellAgg | undefined): number => {
    if (!cell) return 0;
    if (metric === "item_qty") return cell.qtySum;
    if (metric === "order_count") return cellOrderCount(cell);
    return cell.amount;
  };
  const fmtCellValue = (v: number): string => {
    if (metric === "amount") return fmtAmount(v);
    // item_qty / order_count 都顯示數字 (qty 可能小數、round 2 位後去 trailing 0)
    if (metric === "item_qty") {
      const r = Math.round(v * 100) / 100;
      return String(r);
    }
    return String(v);
  };

  // Grand totals — 依 metric 取值
  const grandTotals = useMemo(() => {
    const perStore = new Map<number, number>();
    let grand = 0;
    for (const g of pivot.groups) {
      for (const [, entry] of g.skus) {
        for (const [sid, cell] of entry.perStore) {
          const v =
            metric === "item_qty"
              ? cell.qtySum
              : metric === "order_count"
              ? cell.posOrders.size - cell.negOrders.size
              : cell.amount;
          perStore.set(sid, (perStore.get(sid) ?? 0) + v);
          grand += v;
        }
      }
    }
    return { perStore, grand };
  }, [pivot, metric]);

  const visibleOrders = useMemo(() => {
    const ids = new Set<number>();
    for (const r of pivotRows) {
      for (const id of r.pos_order_ids ?? []) ids.add(id);
      for (const id of r.neg_order_ids ?? []) ids.add(id);
    }
    return ids.size;
  }, [pivotRows]);

  function onCellClick(group: Group, skuId: number, sid: number, cell: CellAgg) {
    if (cellTouched(cell) === 0) return;
    const sku = group.skus.get(skuId);
    const skuName = sku?.name ?? `SKU#${skuId}`;
    const storeName = storeMap.get(sid)?.name ?? `店#${sid}`;
    const title = `${group.label}${group.subLabel ? "（" + group.subLabel + "）" : ""} / ${skuName} / ${storeName}`;
    setCellModal({ title, orderIds: cellAllOrderIds(cell), skuId });
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">訂單 — 樞紐表</h1>
          <p className="text-sm text-zinc-500">
            {loading
              ? "載入中…"
              : `共 ${visibleOrders} 筆訂單 / ${pivot.groups.length} ${viewBy === "campaign" ? "個開團" : "個日期"} / ${pivot.storeIds.length} 家店`}
          </p>
        </div>
        <Link
          href="/orders"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          ← 列表
        </Link>
      </header>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        {/* Campaign multi-select */}
        <div className="relative">
          <SpinButton
            type="button"
            onClick={() => setCampaignPickerOpen((v) => !v)}
            className="flex w-full items-center justify-between rounded-md border border-zinc-300 bg-white px-3 py-2 text-left text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <span className="truncate">
              {campaignIds.length === 0
                ? "全部開團"
                : campaignIds.length === 1
                ? campaigns.find((c) => String(c.id) === campaignIds[0])?.name ?? `團 ${campaignIds[0]}`
                : `已選 ${campaignIds.length} 個開團`}
            </span>
            <span className="ml-2 text-zinc-400">▾</span>
          </SpinButton>
          {campaignPickerOpen && (
            <div className="absolute z-20 mt-1 max-h-80 w-full overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
              <div className="sticky top-0 flex justify-between border-b border-zinc-200 bg-white px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900">
                <SpinButton
                  onClick={() => setCampaignIds([])}
                  className="text-blue-600 hover:underline dark:text-blue-400"
                >
                  全部清除
                </SpinButton>
                <SpinButton
                  onClick={() => setCampaignPickerOpen(false)}
                  className="text-zinc-500 hover:text-zinc-700 dark:text-zinc-400"
                >
                  關閉
                </SpinButton>
              </div>
              {campaigns.map((c) => {
                const checked = campaignIds.includes(String(c.id));
                return (
                  <label
                    key={c.id}
                    className="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-950"
                  >
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(e) => {
                        const id = String(c.id);
                        setCampaignIds((cur) =>
                          e.target.checked ? [...cur, id] : cur.filter((x) => x !== id),
                        );
                      }}
                    />
                    <span className="font-mono text-xs text-zinc-500">{c.campaign_no}</span>
                    <span className="truncate">{c.name}</span>
                  </label>
                );
              })}
            </div>
          )}
        </div>

        {/* viewBy: 訂單日 / 開團 */}
        <select
          value={viewBy}
          onChange={(e) => setViewBy(e.target.value as ViewBy)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          title="樞紐表 row 的分組維度"
        >
          <option value="order_date">分組：訂單日</option>
          <option value="campaign">分組：開團（收單期間）</option>
        </select>

        {/* Month range — 以月為單位、可跨多月 */}
        <div
          className="flex items-center gap-1 rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          title={
            viewBy === "campaign"
              ? "依開團模式：套用至 campaign 收單月份 (end_at)"
              : "依訂單日：套用至訂單 created_at 月份"
          }
        >
          <input
            type="month"
            value={dateFrom}
            max={dateTo || undefined}
            onChange={(e) => setDateFrom(e.target.value)}
            className="w-full bg-transparent px-1 py-1 outline-none"
          />
          <span className="text-zinc-400">~</span>
          <input
            type="month"
            value={dateTo}
            min={dateFrom || undefined}
            onChange={(e) => setDateTo(e.target.value)}
            className="w-full bg-transparent px-1 py-1 outline-none"
          />
        </div>

        {/* Status multi-select */}
        <div className="relative">
          <SpinButton
            type="button"
            onClick={() => setStatusPickerOpen((v) => !v)}
            className="flex w-full items-center justify-between rounded-md border border-zinc-300 bg-white px-3 py-2 text-left text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <span className="truncate">
              {statusSet.size === ORDER_STATUSES.length
                ? "全部狀態"
                : statusSet.size === 0
                ? "未選狀態"
                : `已選 ${statusSet.size} / ${ORDER_STATUSES.length} 狀態`}
            </span>
            <span className="ml-2 text-zinc-400">▾</span>
          </SpinButton>
          {statusPickerOpen && (
            <div className="absolute z-20 mt-1 w-full rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
              <div className="sticky top-0 flex justify-between border-b border-zinc-200 bg-white px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900">
                <SpinButton
                  onClick={() => setStatusSet(new Set(DEFAULT_INCLUDED))}
                  className="text-blue-600 hover:underline dark:text-blue-400"
                >
                  預設
                </SpinButton>
                <SpinButton
                  onClick={() => setStatusSet(new Set(ORDER_STATUSES))}
                  className="text-blue-600 hover:underline dark:text-blue-400"
                >
                  全選
                </SpinButton>
                <SpinButton
                  onClick={() => setStatusPickerOpen(false)}
                  className="text-zinc-500 hover:text-zinc-700 dark:text-zinc-400"
                >
                  關閉
                </SpinButton>
              </div>
              {ORDER_STATUSES.map((s) => {
                const checked = statusSet.has(s);
                return (
                  <label
                    key={s}
                    className="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-950"
                  >
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(e) => {
                        setStatusSet((cur) => {
                          const next = new Set(cur);
                          if (e.target.checked) next.add(s);
                          else next.delete(s);
                          return next;
                        });
                      }}
                    />
                    <span>{ORDER_STATUS_LABEL[s]}</span>
                    <span className="ml-auto font-mono text-xs text-zinc-400">{s}</span>
                  </label>
                );
              })}
            </div>
          )}
        </div>

        {/* Store filter */}
        {branchStoreId != null ? (
          <div className="flex items-center rounded-md border border-zinc-300 bg-zinc-50 px-3 py-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
            🏬 {stores.find((s) => Number(s.id) === branchStoreId)?.name ?? "—"}
            <span className="ml-2 text-xs text-zinc-500">(僅本店)</span>
          </div>
        ) : (
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部取貨店</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
        )}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      {/* Metric toggle: 品項數 / 訂單數 / 訂單金額 */}
      <div className="flex items-center gap-2 text-sm">
        <span className="text-zinc-500">數值：</span>
        <div className="inline-flex rounded-md border border-zinc-300 dark:border-zinc-700">
          <SpinButton
            onClick={() => setMetric("item_qty")}
            className={`rounded-l-md px-3 py-1.5 text-sm transition-colors ${
              metric === "item_qty"
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "bg-white text-zinc-700 hover:bg-zinc-50 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-900"
            }`}
            title="該品項數量加總 (Σ qty)"
          >
            品項數
          </SpinButton>
          <SpinButton
            onClick={() => setMetric("order_count")}
            className={`border-l border-zinc-300 px-3 py-1.5 text-sm transition-colors dark:border-zinc-700 ${
              metric === "order_count"
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "bg-white text-zinc-700 hover:bg-zinc-50 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-900"
            }`}
            title="不重複訂單數 (COUNT DISTINCT order_id)"
          >
            訂單數
          </SpinButton>
          <SpinButton
            onClick={() => setMetric("amount")}
            className={`rounded-r-md border-l border-zinc-300 px-3 py-1.5 text-sm transition-colors dark:border-zinc-700 ${
              metric === "amount"
                ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "bg-white text-zinc-700 hover:bg-zinc-50 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-900"
            }`}
            title="金額加總 (Σ qty × unit_price)"
          >
            訂單金額
          </SpinButton>
        </div>

        {/* 只看已收單 toggle — campaign.status ∈ closed/ordered/receiving/ready/completed */}
        <SpinButton
          onClick={() => setClosedOnly((v) => !v)}
          className={`rounded-md border px-3 py-1.5 text-sm transition-colors ${
            closedOnly
              ? "border-amber-300 bg-amber-100 text-amber-800 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300"
              : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-900"
          }`}
          title="只看已過收單階段（closed / ordered / receiving / ready / completed）的開團"
        >
          只看已收單
        </SpinButton>

        <div className="ml-auto flex items-center gap-1">
          <span className="hidden text-xs text-zinc-400 sm:inline">店別欄</span>
          <SpinButton
            onClick={() => scrollX(-1)}
            disabled={!canScrollL}
            aria-label="往左捲動店別欄"
            title="往左"
            className="rounded-md border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-30 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ◀
          </SpinButton>
          <SpinButton
            onClick={() => scrollX(1)}
            disabled={!canScrollR}
            aria-label="往右捲動店別欄"
            title="往右"
            className="rounded-md border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-30 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ▶
          </SpinButton>
        </div>
      </div>

      <div
        ref={scrollRef}
        className="no-scrollbar max-h-[calc(100vh-280px)] overflow-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950"
      >
        {loading && pivot.groups.length === 0 ? (
          <p className="p-6 text-center text-sm text-zinc-500">載入中…</p>
        ) : pivot.groups.length === 0 ? (
          <p className="p-6 text-center text-sm text-zinc-500">沒有符合條件的訂單。</p>
        ) : (
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="sticky top-0 z-10 bg-zinc-50 shadow-[0_1px_0_0_rgb(228_228_231)] dark:bg-zinc-900 dark:shadow-[0_1px_0_0_rgb(39_39_42)]">
              <tr>
                <th className="w-64 bg-zinc-50 px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 dark:bg-zinc-900">
                  {viewBy === "campaign" ? "開團" : "日期"}
                </th>
                <th className="min-w-[180px] bg-zinc-50 px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 dark:bg-zinc-900">
                  商品品項
                </th>
                {pivot.storeIds.map((sid) => (
                  <th
                    key={sid}
                    className="min-w-[80px] bg-zinc-50 px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500 dark:bg-zinc-900"
                    title={storeMap.get(sid)?.code ?? ""}
                  >
                    {storeMap.get(sid)?.name ?? `店#${sid}`}
                  </th>
                ))}
                <th className="bg-zinc-50 px-3 py-2 text-right text-xs font-bold uppercase tracking-wide text-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
                  合計
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {pivot.groups.map((group) => {
                const skuArr = Array.from(group.skus.entries()).sort((a, b) =>
                  a[1].name.localeCompare(b[1].name, "zh-TW"),
                );
                const groupTotalsPerStore = new Map<number, number>();
                let groupGrand = 0;
                for (const [, entry] of skuArr) {
                  for (const sid of pivot.storeIds) {
                    const v = cellValue(entry.perStore.get(sid));
                    groupTotalsPerStore.set(sid, (groupTotalsPerStore.get(sid) ?? 0) + v);
                    groupGrand += v;
                  }
                }
                return (
                  <Fragment key={group.key}>
                    {skuArr.map(([skuId, entry], i) => {
                      let rowTotal = 0;
                      const rowCls = [
                        i === 0 ? "border-t-2 border-zinc-300 dark:border-zinc-700" : "",
                        group.closed ? "bg-amber-50/60 dark:bg-amber-950/30" : "",
                      ]
                        .filter(Boolean)
                        .join(" ");
                      return (
                        <tr
                          key={`${group.key}-${skuId}`}
                          className={rowCls}
                        >
                          <td className="w-64 px-3 py-1.5 align-top text-xs text-zinc-700 dark:text-zinc-300">
                            {i === 0 ? (
                              <div>
                                <div className="flex flex-wrap items-center gap-1.5">
                                  {group.closed && (
                                    <span className="inline-block rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                                      已結單
                                    </span>
                                  )}
                                  <span className="font-medium">{group.label}</span>
                                </div>
                                {group.subLabel && (
                                  <div className="mt-0.5 text-[10px] text-zinc-500">
                                    {group.subLabel}
                                  </div>
                                )}
                              </div>
                            ) : (
                              ""
                            )}
                          </td>
                          <td className="min-w-[180px] px-3 py-1.5">{entry.name}</td>
                          {pivot.storeIds.map((sid) => {
                            const cell = entry.perStore.get(sid);
                            const v = cellValue(cell);
                            rowTotal += v;
                            if (!cell || cellTouched(cell) === 0) {
                              return (
                                <td
                                  key={sid}
                                  className="px-3 py-1.5 text-right font-mono text-zinc-300 dark:text-zinc-700"
                                >
                                  ·
                                </td>
                              );
                            }
                            return (
                              <td key={sid} className="px-3 py-1.5 text-right">
                                <SpinButton
                                  type="button"
                                  onClick={() => onCellClick(group, skuId, sid, cell)}
                                  className="rounded px-1.5 py-0.5 font-mono font-semibold text-blue-700 hover:bg-blue-50 hover:underline dark:text-blue-300 dark:hover:bg-blue-950"
                                  title={`點看 ${cellTouched(cell)} 筆訂單`}
                                >
                                  {fmtCellValue(v)}
                                </SpinButton>
                              </td>
                            );
                          })}
                          <td className="px-3 py-1.5 text-right font-mono font-semibold">
                            {rowTotal ? fmtCellValue(rowTotal) : ""}
                          </td>
                        </tr>
                      );
                    })}
                    {viewBy !== "campaign" && (
                      <tr className="bg-zinc-50 font-semibold dark:bg-zinc-900">
                        <td className="w-64 px-3 py-1.5 text-xs text-zinc-500">小計</td>
                        <td className="px-3 py-1.5 text-xs text-zinc-500">{group.label}</td>
                        {pivot.storeIds.map((sid) => {
                          const v = groupTotalsPerStore.get(sid) ?? 0;
                          return (
                            <td
                              key={sid}
                              className="px-3 py-1.5 text-right font-mono text-zinc-700 dark:text-zinc-300"
                            >
                              {v ? fmtCellValue(v) : ""}
                            </td>
                          );
                        })}
                        <td className="px-3 py-1.5 text-right font-mono">{fmtCellValue(groupGrand)}</td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
              <tr className="border-t-4 border-zinc-900 bg-zinc-100 font-bold dark:border-zinc-100 dark:bg-zinc-800">
                <td className="px-3 py-2" colSpan={2}>
                  總計
                </td>
                {pivot.storeIds.map((sid) => (
                  <td key={sid} className="px-3 py-2 text-right font-mono">
                    {fmtCellValue(grandTotals.perStore.get(sid) ?? 0)}
                  </td>
                ))}
                <td className="px-3 py-2 text-right font-mono">{fmtCellValue(grandTotals.grand)}</td>
              </tr>
            </tbody>
          </table>
        )}
      </div>

      <p className="text-xs text-zinc-500">
        說明：Cell 為「該 group × 該品項 × 該店」的
        {metric === "item_qty"
          ? "品項數量加總（Σ qty）"
          : metric === "order_count"
          ? "不重複訂單數（COUNT DISTINCT order_id）"
          : "金額合計（Σ qty × unit_price）"}
        ，點數字看訂單清單。
      </p>

      {/* Cell drill-down modal */}
      <Modal
        open={cellModal !== null}
        onClose={() => setCellModal(null)}
        title={cellModal?.title ?? ""}
        maxWidth="max-w-3xl"
      >
        {cellModal && (
          <CellOrdersList
            orderIds={cellModal.orderIds}
            skuId={cellModal.skuId}
            campaignMap={campaignMap}
            onOpenOrder={(id, no) => {
              setDetailId(id);
              setDetailNo(no);
            }}
          />
        )}
      </Modal>

      {/* OrderDetail modal */}
      <Modal
        open={detailId !== null}
        onClose={() => setDetailId(null)}
        title={`訂單明細 ${detailNo}`}
        maxWidth="max-w-4xl"
      >
        {detailId !== null && (
          <OrderDetail
            orderId={detailId}
            onNavigate={(id, no) => {
              setDetailId(id);
              setDetailNo(no);
            }}
          />
        )}
      </Modal>
    </div>
  );
}

function CellOrdersList({
  orderIds,
  skuId,
  campaignMap,
  onOpenOrder,
}: {
  orderIds: number[];
  skuId: number;
  campaignMap: Map<number, Campaign>;
  onOpenOrder: (id: number, no: string) => void;
}) {
  // 點 cell 開 modal 後才拉那 cell 對應的訂單／會員／對該 sku 的 qty。
  // 單一 cell 的 orderIds 數量通常 < 200，不會撞 PostgREST max_rows=1000。
  const [rows, setRows] = useState<OrderRow[] | null>(null);
  const [memberMap, setMemberMap] = useState<Map<number, Member>>(new Map());
  const [qtyBySku, setQtyBySku] = useState<Map<number, number>>(new Map());
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setRows(null);
    setErr(null);
    setMemberMap(new Map());
    setQtyBySku(new Map());
    if (orderIds.length === 0) {
      setRows([]);
      return;
    }
    (async () => {
      try {
        const sb = getSupabase();
        const [oRes, iRes] = await Promise.all([
          sb
            .from("customer_orders")
            .select(
              "id, order_no, campaign_id, member_id, nickname_snapshot, pickup_store_id, pickup_deadline, status, created_at",
            )
            .in("id", orderIds),
          sb
            .from("customer_order_items")
            .select("order_id, qty")
            .in("order_id", orderIds)
            .eq("sku_id", skuId),
        ]);
        if (cancelled) return;
        if (oRes.error) {
          setErr(oRes.error.message);
          return;
        }
        if (iRes.error) {
          setErr(iRes.error.message);
          return;
        }
        const oRows = (oRes.data ?? []) as OrderRow[];
        setRows(oRows);
        const memIds = Array.from(
          new Set(oRows.map((o) => o.member_id).filter((x): x is number => x != null)),
        );
        if (memIds.length) {
          const mRes = await sb.from("members").select("id, name, phone").in("id", memIds);
          if (cancelled) return;
          const mm = new Map<number, Member>();
          for (const m of ((mRes.data ?? []) as Member[])) mm.set(m.id, m);
          setMemberMap(mm);
        }
        const qm = new Map<number, number>();
        for (const it of ((iRes.data ?? []) as { order_id: number; qty: number }[])) {
          qm.set(it.order_id, (qm.get(it.order_id) ?? 0) + Number(it.qty));
        }
        setQtyBySku(qm);
      } catch (e) {
        if (!cancelled) setErr(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [orderIds, skuId]);

  if (err) {
    return <p className="p-4 text-sm text-red-600 dark:text-red-400">讀取失敗：{err}</p>;
  }
  if (rows === null) {
    return <p className="p-4 text-sm text-zinc-500">載入中…</p>;
  }
  if (rows.length === 0) {
    return <p className="p-4 text-sm text-zinc-500">沒有訂單。</p>;
  }

  const sorted = [...rows].sort((a, b) => a.order_no.localeCompare(b.order_no));

  return (
    <div className="max-h-[60vh] overflow-y-auto">
      <p className="mb-2 text-xs text-zinc-500">{sorted.length} 筆訂單</p>
      <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
        <thead className="bg-zinc-50 dark:bg-zinc-900">
          <tr>
            <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
              訂單編號
            </th>
            <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
              會員
            </th>
            <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
              開團
            </th>
            <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">
              數量
            </th>
            <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">
              狀態
            </th>
            <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">
              訂購日
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
          {sorted.map((o) => {
            const m = o.member_id ? memberMap.get(o.member_id) : null;
            const c = campaignMap.get(o.campaign_id);
            const qty = qtyBySku.get(o.id) ?? 0;
            return (
              <tr
                key={o.id}
                className="cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-900"
                onClick={() => onOpenOrder(o.id, o.order_no)}
              >
                <td className="px-3 py-2 font-mono text-xs">
                  <span className="text-blue-700 hover:underline dark:text-blue-300">
                    {o.order_no}
                  </span>
                </td>
                <td className="px-3 py-2">
                  {m?.name ?? o.nickname_snapshot ?? "—"}
                  {m?.phone && <span className="ml-1 font-mono text-xs text-zinc-500">{m.phone}</span>}
                </td>
                <td className="px-3 py-2 text-xs text-zinc-500">{c?.name ?? "—"}</td>
                <td className="px-3 py-2 text-right font-mono">{qty || "—"}</td>
                <td className="px-3 py-2 text-xs">
                  {ORDER_STATUS_LABEL[o.status] ?? o.status}
                </td>
                <td className="px-3 py-2 text-right text-xs text-zinc-500">
                  {new Date(o.created_at).toLocaleDateString("zh-TW", {
                    month: "numeric",
                    day: "numeric",
                  })}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
