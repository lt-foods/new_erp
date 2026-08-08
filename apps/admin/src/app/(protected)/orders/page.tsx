"use client";

import Link from "next/link";
import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import Spinner, { LoadingBlock } from "@/components/Spinner";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";
import { translateRpcError } from "@/lib/rpcError";
import { withBasePath } from "@/lib/basePath";
import { printViaIframe } from "@/lib/printIframe";
import { fetchReprintableEvents } from "@/lib/pickupReceipt";
import { useDefaultStoreFromUser, useUserBranchStoreId } from "@/lib/useDefaultStoreFromUser";
import { useRole } from "@/lib/role";
import { ORDER_STATUS_LABEL as STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";
import { summarizeOrderSource, SOURCE_TREND_SERIES, type OrderItemSource } from "@/lib/orderSource";
import { OrderSourceBadge } from "@/components/OrderSourceBadge";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";

type Row = {
  id: number;
  order_no: string;
  campaign_id: number;
  member_id: number | null;
  nickname_snapshot: string | null;
  pickup_store_id: number;
  pickup_deadline: string | null;
  status: OrderStatus;
  transferred_from_order_id: number | null;
  created_at: string;
  updated_at: string;
};

type Campaign = { id: number; campaign_no: string; name: string; cover_image_url: string | null; start_at: string | null };
type Store = { id: number; code: string; name: string };
type Member = { id: number; name: string | null; phone: string | null; member_no: string; avatar_url: string | null };

type DayTrend = {
  ymd: string; // "YYYY-MM-DD"
  orders: number;
  amount: number;
  members: number;
  aov: number; // amount / orders
  qty: number; // 件數；只有取貨趨勢 (pickupTrend) 會填，下單趨勢一律 0
};

// 本月累計 (member 是跨日 distinct, 不是日 sum)
type MonthAgg = {
  orders: number;
  amount: number;
  members: number;
  aov: number;
  qty: number;
};

type TrendData = {
  days: DayTrend[];
  total: MonthAgg;
};

// 下單來源趨勢 — rpc_order_overview v8 的 source_days / source_total
// （migration 20260808000030）。與 trend 同一個時間軸（當月 1 號 ~ 今天、依
// 下單日 created_at），差別只在多按 customer_order_items.source 分組。
// ⚠ 一張單混合來源（小幫手代 key + 會員自助）時每個來源各算一張 —— 各線
//   加起來會比「本月訂單數」多，這是刻意的：問的是「每個通路各有幾張單在動」。
type SourceDayAgg = { ymd: string; source: string; orders?: number; amount?: number; qty?: number };
type SourceSeries = {
  source: OrderItemSource;
  label: string;
  color: string;
  /** 對齊 SourceTrendData.days 的每日訂單數 / 金額（沒資料補 0） */
  daily: number[];
  dailyAmount: number[];
  totalOrders: number;
  totalAmount: number;
};
type SourceTrendData = {
  /** "YYYY-MM-DD" 連續序列，與 TrendData.days 同一組日期 */
  days: string[];
  series: SourceSeries[];
};

// 「可取貨」= status 'ready'（ORDER_STATUS_LABEL.ready），貨已到店、會員還沒來取。
// 它是「未取貨」(pending/confirmed/shipping/ready) 的子集 — 兩個 tab 刻意重疊：
// 未取貨是全部未取的總覽，可取貨是其中今天真的能交貨的那批。
type Tab = "pending" | "ready" | "partially" | "completed" | "cancelled" | "transferred";
const TABS: { value: Tab; label: string }[] = [
  { value: "pending", label: "未取貨" },
  { value: "ready", label: "可取貨" },
  { value: "partially", label: "部分取貨" },
  { value: "completed", label: "已完成" },
  { value: "transferred", label: "轉出" },
  { value: "cancelled", label: "取消" },
];
const TAB_VALUES = TABS.map((t) => t.value);
// 日期區間欄位在各 tab 的名稱與說明 —— 對應 v_admin_orders.event_at 的來源
// （只有「未取貨」看訂單日 created_at，其餘看該狀態自己的事件時間）。
const DATE_FIELD_LABEL: Record<Tab, { label: string; hint: string }> = {
  pending:     { label: "訂單日", hint: "依訂單日 (created_at) 篩選" },
  ready:       { label: "可取日", hint: "依「到貨變成可取貨」的日期篩選" },
  partially:   { label: "取貨日", hint: "依最後一次取貨的日期篩選" },
  completed:   { label: "取貨日", hint: "依取貨完成的日期篩選" },
  cancelled:   { label: "取消日", hint: "依取消／過期的日期篩選" },
  transferred: { label: "轉出日", hint: "依轉出（開出接手單）的日期篩選" },
};
// 表格排序 — 全部欄位都可排序。排序鍵對應 v_admin_orders_list 的欄位
// （view 疊在 v_admin_orders 上、多出 join/彙總欄，見 migration 20260807000000），
// 由 PostgREST 伺服端排序，跨分頁有效（client 端只排得到當頁 50 筆，沒有意義）。
// "date" 不在 SORT_COL：它跟著 tab 的日期語意走（未取貨=updated_at、其餘=event_at）。
type SortKey = "campaign" | "member" | "source" | "store" | "lines" | "qty" | "amount" | "date";
const SORT_COL: Record<Exclude<SortKey, "date">, string> = {
  campaign: "campaign_name",
  member: "member_name",
  source: "source_summary",
  store: "store_name",
  lines: "line_count",
  qty: "total_qty",
  amount: "total_amount",
};
// 第一下點擊的方向：文字欄升冪（A→Z 分組好找），數字/日期欄降冪（大→小、新→舊）
const SORT_DEFAULT_ASC: Record<SortKey, boolean> = {
  campaign: true,
  member: true,
  source: true,
  store: true,
  lines: false,
  qty: false,
  amount: false,
  date: false,
};
// 手機沒有表頭可點 → 下拉選排序鍵（桌機用表頭）
const SORT_OPTIONS: { value: SortKey; label: string }[] = [
  { value: "date", label: "日期" },
  { value: "campaign", label: "開團" },
  { value: "member", label: "會員 / 暱稱" },
  { value: "source", label: "來源" },
  { value: "store", label: "取貨店" },
  { value: "lines", label: "項數" },
  { value: "qty", label: "總數量" },
  { value: "amount", label: "總金額" },
];
type SortState = { key: SortKey; asc: boolean } | null;

const PENDING_STATUSES: OrderStatus[] = ["pending", "confirmed", "shipping", "ready"];
const CANCELLED_STATUSES: OrderStatus[] = ["cancelled", "expired"];
// 可印小白單（取貨清單）的狀態 — 小白單只列還沒取的品項，取完的單印出來會是空單
const SLIP_STATUSES: OrderStatus[] = [...PENDING_STATUSES, "partially_completed"];

const PAGE_SIZE = 50;
// 「選取全部符合篩選」一次最多抓幾筆 id（列印是 client 端逐張跑，太多會卡瀏覽器）
const SELECT_ALL_MAX = 500;
// 依會員分組後超過這個張數，先跟使用者確認再印
const BULK_PRINT_CONFIRM = 20;

// 日期區間 filter — <input type="date"> 給的是 "YYYY-MM-DD" 當地日期，
// created_at 是 timestamptz，因此在瀏覽器時區換算成半開區間 [from, to)：
//   from = 起日 00:00、to = 迄日的「隔天」00:00（迄日當天整天算進來）。
// 同一組字串同時餵給 PostgREST 列表查詢與 rpc_order_overview，確保列表與 tab 數量一致。
function dayStartIso(ymd: string, addDays = 0): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return null;
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(y, m - 1, d + addDays, 0, 0, 0, 0).toISOString();
}

// Date → "YYYY-MM-DD"（當地時區；不能用 toISOString().slice(0,10)，UTC 會差一天）
function fmtYmd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// 日期區間快捷：回傳 [起, 迄]（皆含當日）
const DATE_PRESETS: { label: string; range: () => [string, string] }[] = [
  { label: "今天", range: () => { const t = new Date(); return [fmtYmd(t), fmtYmd(t)]; } },
  {
    label: "近 7 天",
    range: () => {
      const t = new Date();
      const from = new Date(t.getFullYear(), t.getMonth(), t.getDate() - 6);
      return [fmtYmd(from), fmtYmd(t)];
    },
  },
  {
    label: "本月",
    range: () => {
      const t = new Date();
      return [fmtYmd(new Date(t.getFullYear(), t.getMonth(), 1)), fmtYmd(t)];
    },
  },
];

// 關鍵字 → PostgREST or-filter：先用 members 解出符合的會員 id，
// 再讓 customer_orders 以 (order_no ∨ nickname_snapshot ∨ member_id ∈ ids) 過濾。
// 回傳的字串再與既有 campaign/store/tab 條件 AND 起來。
async function buildKeywordOr(keyword: string): Promise<string | null> {
  const t = keyword.trim();
  if (!t) return null;
  const safe = t.replace(/[%,()]/g, " ");
  // Google 式：以空白 / + 拆 token，每個 token 都要在 name / phone / member_no 至少一欄命中
  const tokens = safe.split(/[\s+]+/).filter(Boolean);
  let memberQ = getSupabase().from("members").select("id").neq("status", "deleted").limit(300);
  for (const tok of tokens) {
    memberQ = memberQ.or(`name.ilike.%${tok}%,phone.ilike.%${tok}%,member_no.ilike.%${tok}%`);
  }
  const { data } = await memberQ;
  const ids = ((data ?? []) as { id: number }[]).map((m) => m.id);
  // 整串 keyword 也允許出現在 order_no / nickname_snapshot（不拆 token，避免誤判）
  const ors = [`order_no.ilike.%${safe}%`, `nickname_snapshot.ilike.%${safe}%`];
  if (ids.length > 0) ors.push(`member_id.in.(${ids.join(",")})`);
  return ors.join(",");
}

type OrderFilters = {
  campaignIds: string[];
  tab: Tab;
  storeId: string;
  skuIds: string[];
  fromTs: string | null;
  toTs: string | null;
  keywordOr: string | null;
  // 日期區間看事件日（event_at）還是訂單日（created_at）— 語意跟著 tab 走，見 dateOnEvent
  dateOnEvent: boolean;
};

// 品項（SKU）篩選用的內嵌 join：applyOrderFilters 的 items.sku_id 過濾要靠 select
// 帶這段內嵌才會生效（!inner 把父列收斂到「至少一列品項命中」的訂單）。
// 沒篩品項時不要帶，免得多一個無謂的 join。
const ITEM_EMBED = ", items:customer_order_items!inner(sku_id)";

// 套用目前的篩選條件（開團 / tab 狀態 / 取貨店 / 日期區間 / 關鍵字）。
// 列表分頁查詢與「選取全部符合篩選」共用同一支，確保「勾到的」＝「看到的」。
function applyOrderFilters<
  Q extends {
    eq(column: string, value: never): Q;
    in(column: string, values: never[]): Q;
    gte(column: string, value: never): Q;
    lt(column: string, value: never): Q;
    or(filters: string): Q;
  },
>(q: Q, f: OrderFilters): Q {
  let out = q;
  const eq = (col: string, val: unknown) => { out = out.eq(col, val as never); };
  const inList = (col: string, vals: unknown[]) => { out = out.in(col, vals as never[]); };

  if (f.campaignIds.length === 1) eq("campaign_id", Number(f.campaignIds[0]));
  else if (f.campaignIds.length > 1) inList("campaign_id", f.campaignIds.map((x) => Number(x)));
  // 依 tab 套狀態過濾;一律隱藏 transferred_out (視同關閉、金額/數量不入統計)
  if (f.tab === "ready") eq("status", "ready");
  else if (f.tab === "partially") eq("status", "partially_completed");
  else if (f.tab === "completed") eq("status", "completed");
  else if (f.tab === "cancelled") inList("status", CANCELLED_STATUSES);
  else if (f.tab === "transferred") eq("status", "transferred_out");
  else inList("status", PENDING_STATUSES);
  if (f.storeId) eq("pickup_store_id", Number(f.storeId));
  // 品項篩選 — select 需帶 ITEM_EMBED 內嵌（見上），tab 數量端則由
  // rpc_order_overview 的 p_sku_ids 套同一條件，兩邊數字才對得起來
  if (f.skuIds.length > 0) inList("items.sku_id", f.skuIds.map((x) => Number(x)));
  const dateCol = f.dateOnEvent ? "event_at" : "created_at";
  if (f.fromTs) out = out.gte(dateCol, f.fromTs as never);
  if (f.toTs) out = out.lt(dateCol, f.toTs as never);
  if (f.keywordOr) out = out.or(f.keywordOr);
  return out;
}

// 手機卡片底色（依訂單狀態）— 對應桌機表格列底色
// 一般開團「一團一品」：開團名＝商品名（顯示在粗體行上方），粗體行只放規格即可；
// 補貨 sentinel 團（【內部】補貨申請）等開團名非商品名時，補上商品名，避免只剩「一盒」看不出是什麼。
function itemLabel(
  it: { product_name: string | null; variant_name: string | null },
  campaignName: string,
): string {
  if (it.product_name && it.product_name !== campaignName) {
    return it.variant_name ? `${it.product_name} / ${it.variant_name}` : it.product_name;
  }
  return it.variant_name || it.product_name || "—";
}

function cardTint(status: OrderStatus): string {
  if (status === "cancelled") return "border-red-200 bg-red-50 dark:border-red-900 dark:bg-red-950/30";
  if (status === "expired") return "border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950/30";
  if (status === "transferred_out") return "border-zinc-200 bg-zinc-100 text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900";
  return "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950";
}

export default function OrdersListPage() {
  return (
    <Suspense fallback={<LoadingBlock />}>
      <OrdersListContent />
    </Suspense>
  );
}

function OrdersListContent() {
  const searchParams = useSearchParams();
  // 支援單個 campaignId（舊）+ campaignIds 多個逗號分隔（新）
  const initialCampaignIds = ((): string[] => {
    const multi = searchParams.get("campaignIds");
    if (multi) return multi.split(",").map((s) => s.trim()).filter(Boolean);
    const single = searchParams.get("campaignId");
    return single ? [single] : [];
  })();
  const initialTab: Tab = (() => {
    const t = searchParams.get("tab");
    return TAB_VALUES.includes(t as Tab) ? (t as Tab) : "pending";
  })();
  const initialStoreId = searchParams.get("storeId") ?? "";
  const initialSkuId = searchParams.get("skuId") ?? "";
  const initialKeyword = searchParams.get("q") ?? "";
  const initialDate = (key: string) => {
    const v = searchParams.get(key) ?? "";
    return /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : "";
  };

  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaignIds, setCampaignIds] = useState<string[]>(initialCampaignIds);
  const [tab, setTab] = useState<Tab>(initialTab);
  const [storeId, setStoreId] = useState(initialStoreId);
  // 品項（SKU）二層篩選 — 只在選了開團後出現；"" = 全部品項
  const [skuId, setSkuId] = useState(initialSkuId);
  // 所選開團的品項清單（campaign_items）；label 於 render 時再組（要等 campaignMap）
  const [skuOptionRows, setSkuOptionRows] = useState<
    { skuId: number; campaignId: number; productName: string | null; variantName: string | null }[]
  >([]);
  // 訂單日 (created_at) 區間；"" = 不限
  const [dateFrom, setDateFrom] = useState(initialDate("from"));
  const [dateTo, setDateTo] = useState(initialDate("to"));
  const [tabCounts, setTabCounts] = useState<Record<Tab, number> | null>(null);
  const [page, setPage] = useState(1);
  const [kwInput, setKwInput] = useState(initialKeyword);
  const [keyword, setKeyword] = useState(initialKeyword);
  const [campaignPickerOpen, setCampaignPickerOpen] = useState(false);
  const [campaignSearch, setCampaignSearch] = useState("");
  const [searchingCampaign, setSearchingCampaign] = useState(false);

  // dropdownIds: 目前下拉清單顯示的開團 id 序（最新 20 / 搜尋結果），由 effect 寫入
  const [dropdownIds, setDropdownIds] = useState<number[]>([]);
  // campaigns: 已知開團的 cache（包含下拉、訂單列、目前勾選），由 effect 累加
  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [members, setMembers] = useState<Map<number, Member>>(new Map());
  const [itemSummary, setItemSummary] = useState<
    Map<
      number,
      {
        lineCount: number;
        totalQty: number;
        totalAmount: number;
        items: { product_name: string | null; variant_name: string | null; qty: number }[];
        sources: string[];
      }
    >
  >(new Map());
  // shipping 單是否有品項已到貨可先取（v_order_item_pickup_ready；部分到貨單開放「去取貨」）
  const [hasArrivedItem, setHasArrivedItem] = useState<Map<number, boolean>>(new Map());
  const [detailId, setDetailId] = useState<number | null>(null);
  const [detailNo, setDetailNo] = useState<string>("");
  const [returnTarget, setReturnTarget] = useState<{ orderId: number; storeId: number } | null>(null);
  const [reloadOrders, setReloadOrders] = useState(0);
  // 排序；null = 預設（日期新→舊）。換 tab / 篩選不重置 — 排序是「怎麼看」不是「看什麼」
  const [sort, setSort] = useState<SortState>(null);
  // 批量列印用的勾選（跨分頁累加；換 tab / 改篩選會清空，避免印到看不見的單）
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [bulkPrintErr, setBulkPrintErr] = useState<string | null>(null);

  // KPI trend (當月 1 號 ~ 今天 每日 + 本月累計、套 filter 開團+店家、排除 transferred_out)
  const [trend, setTrend] = useState<TrendData | null>(null);
  // 取貨 KPI — 同一支 RPC 回的 pickup_days/pickup_total（已取貨品項的金額，
  // 依取貨當天切；「今日取貨金額」卡用最後一天＝今天）
  const [pickupTrend, setPickupTrend] = useState<TrendData | null>(null);
  // 下單來源 KPI — 同一支 RPC 回的 source_days/source_total（App / 商城 / 小幫手）
  const [sourceTrend, setSourceTrend] = useState<SourceTrendData | null>(null);

  const fromTs = useMemo(() => (dateFrom ? dayStartIso(dateFrom) : null), [dateFrom]);
  const toTs = useMemo(() => (dateTo ? dayStartIso(dateTo, 1) : null), [dateTo]);
  // 日期區間的語意跟著 tab 走（不另做切換 UI）：只有「未取貨」看訂單日，其餘每個 tab
  // 都看該狀態自己的事件日 v_admin_orders.event_at（可取=ready_at、取貨=completed_at /
  // 最後一次取貨、取消=cancelled_at、轉出=接手單 created_at）。
  // 團購下單到取貨隔好幾天甚至幾週，終態 tab 用訂單日篩最近幾天永遠是 0 筆 ——
  // 使用者要問的是「這幾天*發生*了什麼」。定義與覆蓋率見 migration
  // 20260805000120_v_admin_orders_event_at.sql；tab 數量同步改法見 20260805000130。
  // ⚠ 不要改用 updated_at：它會被之後任何寫入 touch 掉（線上 26% 的已完成單偏差 >1h）。
  const dateOnEvent = tab !== "pending";
  // 伺服端排序欄位。預設（sort=null）＝原本行為：事件日 tab 照 event_at、未取貨照
  // updated_at，皆新→舊（照 updated_at 排會讓被批次寫入 touch 過的舊單浮上來，
  // 所以事件日 tab 不用它）。nullsFirst:false = 空值一律沉底；再以 id 當 tiebreak，
  // 同值時分頁順序才穩定（不然翻頁會看到重複/漏單）。
  const sortSpec = useMemo(() => {
    const dateCol = dateOnEvent ? "event_at" : "updated_at";
    return {
      col: !sort || sort.key === "date" ? dateCol : SORT_COL[sort.key],
      asc: sort?.asc ?? false,
    };
  }, [sort, dateOnEvent]);
  // 換排序回第一頁（在事件端做，不開 effect）；勾選保留 — 符合條件的集合沒變，
  // 只是換個順序看
  function applySort(next: { key: SortKey; asc: boolean }) {
    setSort(next);
    setPage(1);
  }
  function toggleSort(k: SortKey) {
    const eff = sort ?? { key: "date" as SortKey, asc: false };
    applySort(eff.key === k ? { key: k, asc: !eff.asc } : { key: k, asc: SORT_DEFAULT_ASC[k] });
  }
  // 品項篩選只在有選開團時生效（下拉也只在那時渲染）。開團清空不硬清 skuId，
  // 改由這裡歸零 — 篩選不能在 UI 看不到的情況下默默生效。
  const activeSkuId = campaignIds.length > 0 ? skuId : "";
  const hasFilter = campaignIds.length > 0 || !!storeId || !!activeSkuId || !!keyword || !!dateFrom || !!dateTo;

  useEffect(() => {
    setPage(1);
    // 篩選一變，勾選就作廢 — 不然會印到已經看不見的單
    setSelected(new Set());
    setBulkPrintErr(null);
  }, [campaignIds, tab, storeId, activeSkuId, keyword, fromTs, toTs]);

  // 品項下拉的選項 = 所選開團的 campaign_items。沒選開團就不提供品項篩選
  // （全庫 SKU 太多、也沒有情境）。products.name 是 source of truth
  // （skus.product_name 是 denorm 可能過期，見 CampaignItemsTable 同註解）。
  useEffect(() => {
    // 沒選開團：下拉未渲染，舊選項留著無妨 — 下次選團會整批重抓
    if (campaignIds.length === 0) return;
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase()
        .from("campaign_items")
        .select("campaign_id, sku_id, sort_order, skus!inner(id, variant_name, products!inner(name))")
        .in("campaign_id", campaignIds.map((x) => Number(x)))
        .order("campaign_id")
        .order("sort_order");
      if (cancelled) return;
      type ItemRow = {
        campaign_id: number;
        sku_id: number;
        skus:
          | { id: number; variant_name: string | null; products: { name: string } | { name: string }[] | null }
          | { id: number; variant_name: string | null; products: { name: string } | { name: string }[] | null }[]
          | null;
      };
      const rows = ((data ?? []) as unknown as ItemRow[]).map((r) => {
        const sku = Array.isArray(r.skus) ? r.skus[0] : r.skus;
        const prod = sku && (Array.isArray(sku.products) ? sku.products[0] : sku.products);
        return {
          skuId: r.sku_id,
          campaignId: r.campaign_id,
          productName: prod?.name ?? null,
          variantName: sku?.variant_name ?? null,
        };
      });
      setSkuOptionRows(rows);
      // 換了開團組合後，原本選的品項若不在新清單裡就歸回「全部品項」
      setSkuId((cur) => (cur && !rows.some((r) => String(r.skuId) === cur) ? "" : cur));
    })();
    return () => { cancelled = true; };
  }, [campaignIds]);

  // 取貨店篩選不鎖分店：所有帳號都可自由選任一店 / 全部
  // （僅保留軟性預設選中自家店，使用者可自行切換到別店或「全部」）
  useDefaultStoreFromUser(stores, storeId, setStoreId);

  // 店端快速鈕：一鍵搜尋自己店的【內部】會員訂單（補貨現貨單掛在該會員名下，
  // 從這裡找到 ready 的內部單即可「轉手」拆給客人）
  const role = useRole();
  const branchStoreId = useUserBranchStoreId(stores);
  const internalKeyword = (() => {
    if (role !== "store_manager" && role !== "store_staff") return null;
    const name = stores.find((s) => s.id === branchStoreId)?.name;
    return name ? `【內部】${name}` : null;
  })();

  // 載入 stores 一次
  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data } = await sb.from("stores").select("id, code, name").order("name");
      setStores((data as Store[]) ?? []);
    })();
  }, []);

  // 累加開團到 cache（dedupe by id）
  const mergeCampaigns = (list: Campaign[]) => {
    if (list.length === 0) return;
    setCampaigns((cur) => {
      const map = new Map(cur.map((c) => [c.id, c]));
      for (const c of list) map.set(c.id, c);
      return Array.from(map.values());
    });
  };

  // 下拉清單：預設 start_at desc 前 20 筆；有搜尋字串時 ilike + 50 筆
  // 用 setTimeout 250ms debounce 避免每個字打進去都打一次 server
  useEffect(() => {
    setSearchingCampaign(true);
    const t = setTimeout(async () => {
      try {
        const sb = getSupabase();
        const kw = campaignSearch.trim();
        let q = sb
          .from("group_buy_campaigns")
          .select("id, campaign_no, name, cover_image_url, start_at")
          .order("start_at", { ascending: false, nullsFirst: false });
        if (kw) {
          const safe = kw.replace(/[%,()]/g, " ");
          q = q.or(`name.ilike.%${safe}%,campaign_no.ilike.%${safe}%`).limit(50);
        } else {
          q = q.limit(20);
        }
        const { data } = await q;
        const list = (data as Campaign[]) ?? [];
        setDropdownIds(list.map((c) => c.id));
        mergeCampaigns(list);
      } finally {
        setSearchingCampaign(false);
      }
    }, 250);
    return () => clearTimeout(t);
  }, [campaignSearch]);

  // 把目前用到的開團（已勾選 + 訂單列引用）全部撈進 cache，
  // 確保按鈕的開團名、訂單列封面/名稱在「不在前 20 名」也能正確顯示。
  // mergeCampaigns dedupe，重複 id 不會重撈。
  useEffect(() => {
    const ids = new Set<number>();
    for (const x of campaignIds) ids.add(Number(x));
    for (const r of rows ?? []) ids.add(r.campaign_id);
    if (ids.size === 0) return;
    (async () => {
      const sb = getSupabase();
      const { data } = await sb
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, cover_image_url, start_at")
        .in("id", Array.from(ids));
      mergeCampaigns((data as Campaign[]) ?? []);
    })();
  }, [campaignIds, rows]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        // 查 v_admin_orders_list（= v_admin_orders + 開團名/會員名/店名/品項彙總，
        // 見 migration 20260807000000）：日期區間有單一欄位（event_at）可篩，
        // 且每個表格欄位都有對應 view 欄位可給伺服端排序（sortSpec）。
        const base = getSupabase()
          .from("v_admin_orders_list")
          .select(
            "id, order_no, campaign_id, member_id, nickname_snapshot, pickup_store_id, pickup_deadline, status, transferred_from_order_id, created_at, updated_at"
              + (activeSkuId ? ITEM_EMBED : ""),
            { count: "exact" },
          )
          .order(sortSpec.col, { ascending: sortSpec.asc, nullsFirst: false })
          .order("id", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        const kwOr = await buildKeywordOr(keyword);
        if (cancelled) return;
        const q = applyOrderFilters(base, { campaignIds, tab, storeId, skuIds: activeSkuId ? [activeSkuId] : [], fromTs, toTs, keywordOr: kwOr, dateOnEvent });

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        const list = (data ?? []) as unknown as Row[];
        setRows(list);
        setTotal(count ?? 0);

        const ids = list.map((r) => r.id);
        const memIds = Array.from(new Set(list.map((r) => r.member_id).filter((x): x is number => x != null)));
        // shipping 單查品項到貨狀態（pickup_ready=true 隱含該品項 active 且已到貨）
        const shippingIds = list.filter((r) => r.status === "shipping").map((r) => r.id);
        const [ic, ms, rdy] = await Promise.all([
          ids.length
            // 已取消 / 斷貨 / 過期的品項不算進項數 · 件數 · 金額，與伺服端
            // v_admin_orders_list 的彙總（可排序欄位）同一套過濾，見 migration
            // 20260808000010；不然「排序看到的數字」跟「格子裡的數字」會對不起來。
            ? getSupabase().from("customer_order_items").select("order_id, qty, unit_price, source, sku:skus(product_name, variant_name)").in("order_id", ids).not("status", "in", "(cancelled,expired)")
            : Promise.resolve({ data: [] as { order_id: number; qty: number; unit_price: number; source: string; sku: { product_name: string | null; variant_name: string | null } | null }[] }),
          memIds.length
            ? getSupabase().from("members").select("id, name, phone, member_no, avatar_url").in("id", memIds)
            : Promise.resolve({ data: [] as Member[] }),
          shippingIds.length
            ? getSupabase().from("v_order_item_pickup_ready").select("order_id, pickup_ready").in("order_id", shippingIds).eq("pickup_ready", true)
            : Promise.resolve({ data: [] as { order_id: number; pickup_ready: boolean }[] }),
        ]);
        const im = new Map<number, { lineCount: number; totalQty: number; totalAmount: number; items: { product_name: string | null; variant_name: string | null; qty: number }[]; sources: string[] }>();
        for (const id of ids) im.set(id, { lineCount: 0, totalQty: 0, totalAmount: 0, items: [], sources: [] });
        for (const it of (ic.data as { order_id: number; qty: number; unit_price: number; source: string; sku: { product_name: string | null; variant_name: string | null } | null }[]) ?? []) {
          const cur = im.get(it.order_id) ?? { lineCount: 0, totalQty: 0, totalAmount: 0, items: [], sources: [] };
          cur.lineCount += 1;
          cur.totalQty += Number(it.qty);
          cur.totalAmount += Number(it.qty) * Number(it.unit_price);
          cur.items.push({
            product_name: it.sku?.product_name ?? null,
            variant_name: it.sku?.variant_name ?? null,
            qty: Number(it.qty),
          });
          if (it.source) cur.sources.push(it.source);
          im.set(it.order_id, cur);
        }
        const mm = new Map<number, Member>();
        for (const m of (ms.data as Member[]) ?? []) mm.set(m.id, m);
        const arrived = new Map<number, boolean>();
        for (const r of ((rdy.data ?? []) as { order_id: number; pickup_ready: boolean }[])) {
          if (r.pickup_ready) arrived.set(r.order_id, true);
        }
        if (!cancelled) { setItemSummary(im); setMembers(mm); setHasArrivedItem(arrived); }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [campaignIds, tab, dateOnEvent, storeId, activeSkuId, page, reloadOrders, keyword, fromTs, toTs, sortSpec]);

  // 頁首聚合（tab 數量 + 月趨勢）— 單一伺服端 RPC rpc_order_overview
  // 取代之前 client 端「5 個 count:exact 全表掃描」+「搬整月訂單+全部明細
  // 回瀏覽器做聚合」的做法（後者一個月幾萬筆訂單時是主要的慢點）。
  // 切 tab 不重抓,只在 campaign / 店家 / keyword / reload 變動時更新。
  useEffect(() => {
    let cancelled = false;
    setTrend(null);
    setPickupTrend(null);
    setSourceTrend(null);
    (async () => {
      const sb = getSupabase();
      const today = new Date();
      const startDate = new Date(today.getFullYear(), today.getMonth(), 1);

      // p_date_from/p_date_to 只收斂 tab 數量（趨勢卡維持「本月」語意，見 migration 20260803000000）
      const { data, error: rpcErr } = await sb.rpc("rpc_order_overview", {
        p_campaign_ids: campaignIds.length ? campaignIds.map((x) => Number(x)) : null,
        p_store_id: storeId ? Number(storeId) : null,
        p_keyword: keyword || null,
        p_month_start: startDate.toISOString(),
        p_date_from: fromTs,
        p_date_to: toTs,
        // p_sku_ids 是 v6（20260806000020）才有的參數：沒篩品項就不帶這個 key，
        // 萬一線上還是舊版函式，其餘功能不受影響
        ...(activeSkuId ? { p_sku_ids: [Number(activeSkuId)] } : {}),
      });
      if (cancelled) return;

      type AggRow = { ymd?: string; orders?: number; members?: number; amount?: number; qty?: number };
      type Overview = {
        tab_counts: { pending: number; ready: number; partially: number; completed: number; cancelled: number; transferred: number };
        trend_days: (AggRow & { ymd: string })[];
        trend_total: AggRow;
        // v3 (migration 20260803000010) 起：已取貨品項金額，依取貨當天切
        pickup_days?: (AggRow & { ymd: string })[];
        pickup_total?: AggRow;
        // v8 (migration 20260808000030) 起：依 customer_order_items.source 分組。
        // 線上還是舊版函式時這兩個 key 不存在 → buildSourceTrend 拿空陣列，
        // 卡片畫出三條 0 的線，其餘 KPI 不受影響。
        source_days?: SourceDayAgg[];
        source_total?: Omit<SourceDayAgg, "ymd">[];
      };
      if (rpcErr || !data) {
        setTabCounts(null);
        setTrend(buildTrend(startDate, today, [], null));
        setPickupTrend(buildTrend(startDate, today, [], null));
        setSourceTrend(buildSourceTrend(startDate, today, [], []));
        return;
      }
      const ov = data as Overview;
      setTabCounts({
        pending: ov.tab_counts.pending ?? 0,
        ready: ov.tab_counts.ready ?? 0,
        partially: ov.tab_counts.partially ?? 0,
        completed: ov.tab_counts.completed ?? 0,
        cancelled: ov.tab_counts.cancelled ?? 0,
        transferred: ov.tab_counts.transferred ?? 0,
      });

      setTrend(buildTrend(startDate, today, ov.trend_days ?? [], ov.trend_total));
      setPickupTrend(buildTrend(startDate, today, ov.pickup_days ?? [], ov.pickup_total));
      setSourceTrend(buildSourceTrend(startDate, today, ov.source_days ?? [], ov.source_total ?? []));
    })();
    return () => {
      cancelled = true;
    };
  }, [campaignIds, storeId, activeSkuId, reloadOrders, keyword, fromTs, toTs]);

  const campaignMap = useMemo(() => new Map(campaigns.map((c) => [c.id, c])), [campaigns]);
  const storeMap = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);
  // 品項下拉顯示用：跨團 dedupe by sku_id；label 沿用 itemLabel 慣例
  // （一團一品時商品名＝開團名 → 只顯示規格，否則顯示「商品 / 規格」）
  const skuFilterOptions = useMemo(() => {
    const seen = new Set<number>();
    const out: { id: number; label: string }[] = [];
    for (const r of skuOptionRows) {
      if (seen.has(r.skuId)) continue;
      seen.add(r.skuId);
      out.push({
        id: r.skuId,
        label: itemLabel(
          { product_name: r.productName, variant_name: r.variantName },
          campaignMap.get(r.campaignId)?.name ?? "",
        ),
      });
    }
    return out;
  }, [skuOptionRows, campaignMap]);

  // 批次取貨 — 抓所有勾選訂單的 pickable items, 連續呼 rpc_record_pickup,
  async function cancelOrder(orderId: number, orderNo: string, status: string) {
    const reason = prompt(
      status === "shipping"
        ? `撤回派貨：${orderNo}\n互助單會撤回派貨單並反向回收已出庫存；波次出貨的訂單不動庫存。請輸入原因：`
        : `取消訂單：${orderNo}\n請輸入取消原因：`
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { error: rpcErr } = await sb.rpc("rpc_cancel_aid_order", {
      p_order_id: orderId,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`取消失敗：${translateRpcError(rpcErr)}`); return; }
    alert("已取消");
    setReloadOrders((n) => n + 1);
  }

  // 互助單已收貨(ready)退回原店：反向退回原調出店並還原來源單（rpc_return_aid_order）
  async function returnAidToSource(orderId: number, orderNo: string) {
    const reason = prompt(
      `退回原店：${orderNo}\n會把已收貨品反向退回原調出店，並把來源單還原。請輸入原因：`,
    );
    if (reason === null) return;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id ?? null;
    if (!operator) { alert("尚未登入"); return; }
    const { data, error: rpcErr } = await sb.rpc("rpc_return_aid_order", {
      p_order_id: orderId,
      p_reason: reason,
      p_operator: operator,
    });
    if (rpcErr) { alert(`退回失敗：${translateRpcError(rpcErr)}`); return; }
    const refunded = Number((data as { wallet_refunded?: number } | null)?.wallet_refunded ?? 0);
    alert(refunded > 0
      ? `已退回原店，已退回 $${refunded} 儲值金到會員餘額`
      : "已退回原店，貨已退回原調出店");
    setReloadOrders((n) => n + 1);
  }

  // 操作按鈕（去取貨 / 取消 / ↩退貨 / 狀態鈕）— 桌機表格與手機卡片共用，單一維護點
  const orderActions = (r: Row, m: Member | null | undefined) => (
    <>
      {(PENDING_STATUSES.includes(r.status) || r.status === "partially_completed") && (
        <SpinButton
          onClick={() =>
            printViaIframe(withBasePath(`/pickup/print-list?order_ids=${r.id}`))
          }
          title="列印小白單（取貨清單，貨還沒到也可印）"
          className="rounded-md border border-zinc-300 px-2 py-1 text-[11px] font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          列印
        </SpinButton>
      )}
      {!["completed","expired","cancelled","transferred_out"].includes(r.status) && (() => {
        // shipping 單部分到貨（≥1 品項已實收）也開放去取貨 — 已到品項可先取
        const canPickup = r.status === "ready" || r.status === "partially_completed"
          || (r.status === "shipping" && hasArrivedItem.get(r.id) === true);
        // 訂單頁本身不執行取貨,只導向 /pickup (帶會員編號自動搜尋)
        if (canPickup && m?.member_no) {
          return (
            <Link
              href={`/pickup?q=${encodeURIComponent(m.member_no)}`}
              className="rounded-md bg-emerald-600 px-2 py-1 text-[11px] font-medium text-white hover:bg-emerald-700"
            >
              ✅ 去取貨
            </Link>
          );
        }
        return (
          <SpinButton
            type="button"
            disabled
            title={canPickup ? "找不到會員資料,無法導向" : "分店尚未收貨,無法取貨"}
            className="cursor-not-allowed rounded-md bg-emerald-200 px-2 py-1 text-[11px] font-medium text-emerald-700 dark:bg-emerald-950 dark:text-emerald-400"
          >
            ✅ 去取貨
          </SpinButton>
        );
      })()}
      {["pending", "confirmed", "shipping"].includes(r.status) && (
        <SpinButton
          onClick={() => cancelOrder(r.id, r.order_no, r.status)}
          title={r.status === "shipping" ? "撤回派貨並反向回收已出庫存" : "取消訂單"}
          className="rounded-md bg-red-600 px-2 py-1 text-[11px] font-medium text-white hover:bg-red-700"
        >
          取消
        </SpinButton>
      )}
      {/* 互助單已收貨（ready）：退回原調出店，而非退回總倉（貨源是分店不是總倉） */}
      {r.status === "ready" && r.transferred_from_order_id != null && (
        <SpinButton
          onClick={() => returnAidToSource(r.id, r.order_no)}
          title="互助單已收貨：反向退回原調出店並還原來源單"
          className="rounded-md border border-orange-300 px-2 py-1 text-[11px] font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
        >
          ↩ 退回原店
        </SpinButton>
      )}
      {r.status === "cancelled" && (
        <SpinButton
          disabled
          title="此訂單已取消"
          className="rounded-md bg-red-200 px-2 py-1 text-[11px] font-medium text-red-700 cursor-not-allowed dark:bg-red-950 dark:text-red-300"
        >
          已取消
        </SpinButton>
      )}
      {r.status === "expired" && (
        <SpinButton
          disabled
          title="此訂單已逾期"
          className="rounded-md bg-amber-200 px-2 py-1 text-[11px] font-medium text-amber-800 cursor-not-allowed dark:bg-amber-950 dark:text-amber-300"
        >
          已逾期
        </SpinButton>
      )}
      {r.status === "completed" && (
        <SpinButton
          disabled
          title="此訂單已完成"
          className="rounded-md bg-emerald-200 px-2 py-1 text-[11px] font-medium text-emerald-800 cursor-not-allowed dark:bg-emerald-950 dark:text-emerald-300"
        >
          已完成
        </SpinButton>
      )}
      {r.status === "transferred_out" && (
        <SpinButton
          disabled
          title="此訂單已轉出"
          className="rounded-md bg-zinc-300 px-2 py-1 text-[11px] font-medium text-zinc-700 cursor-not-allowed dark:bg-zinc-700 dark:text-zinc-300"
        >
          已轉出
        </SpinButton>
      )}
      {["ready", "partially_completed", "completed", "expired"].includes(r.status)
        && !(r.status === "ready" && r.transferred_from_order_id != null) && (
        <SpinButton
          onClick={() => setReturnTarget({ orderId: r.id, storeId: r.pickup_store_id })}
          title="已收貨/已取貨，無法取消；點此退貨回總倉（反向回收已派庫存）"
          className="rounded-md border border-orange-300 px-2 py-1 text-[11px] font-medium text-orange-700 hover:bg-orange-50 dark:border-orange-800 dark:text-orange-300 dark:hover:bg-orange-950"
        >
          ↩ 退貨
        </SpinButton>
      )}
    </>
  );
  // ---------- 批量列印（勾選 → 依會員分組 → 逐張送印） ----------
  const pageIds = (rows ?? []).map((r) => r.id);
  const pageAllSelected = pageIds.length > 0 && pageIds.every((id) => selected.has(id));

  function toggleOne(id: number) {
    setSelected((cur) => {
      const next = new Set(cur);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }
  function togglePage() {
    setSelected((cur) => {
      const next = new Set(cur);
      if (pageAllSelected) for (const id of pageIds) next.delete(id);
      else for (const id of pageIds) next.add(id);
      return next;
    });
  }

  // 「選取全部符合篩選」— 用跟列表同一組條件再撈一次 id（不受目前分頁 50 筆限制）
  async function selectAllMatching() {
    setBulkPrintErr(null);
    const kwOr = await buildKeywordOr(keyword);
    const base = getSupabase()
      .from("v_admin_orders_list")
      .select("id" + (activeSkuId ? ITEM_EMBED : ""))
      .order(sortSpec.col, { ascending: sortSpec.asc, nullsFirst: false })
      .order("id", { ascending: false })
      .limit(SELECT_ALL_MAX);
    const { data, error } = await applyOrderFilters(base, {
      campaignIds, tab, storeId, skuIds: activeSkuId ? [activeSkuId] : [], fromTs, toTs, keywordOr: kwOr, dateOnEvent,
    });
    if (error) { setBulkPrintErr(error.message); return; }
    const ids = ((data ?? []) as unknown as { id: number }[]).map((r) => r.id);
    setSelected(new Set(ids));
    if (total > ids.length) {
      setBulkPrintErr(`符合條件共 ${total} 筆，一次最多選 ${SELECT_ALL_MAX} 筆（已選目前排序最前的 ${ids.length} 筆）`);
    }
  }

  async function bulkPrint(kind: "receipt" | "slip") {
    setBulkPrintErr(null);
    const ids = Array.from(selected);
    if (ids.length === 0) return;
    const { data, error } = await getSupabase()
      .from("customer_orders")
      .select("id, member_id, status")
      .in("id", ids);
    if (error) { setBulkPrintErr(error.message); return; }
    const orders = (data ?? []) as { id: number; member_id: number | null; status: OrderStatus }[];

    // 列印頁（收據 /pickup/print、小白單 /pickup/print-list）都假設「一次進來的是同一個會員」
    // — 表頭與合計都取第一張單的會員。所以這裡依會員分組，一個會員印一張，不能全部倒進同一個 URL。
    const groups = new Map<string, number[]>();
    const push = (memberId: number | null, orderId: number, payload: number[]) => {
      const key = memberId != null ? `m${memberId}` : `o${orderId}`;
      groups.set(key, [...(groups.get(key) ?? []), ...payload]);
    };
    let skipped = 0;

    if (kind === "slip") {
      for (const o of orders) {
        if (!SLIP_STATUSES.includes(o.status)) { skipped++; continue; }
        push(o.member_id, o.id, [o.id]);
      }
    } else {
      const evMap = await fetchReprintableEvents(ids);
      for (const o of orders) {
        const evs = evMap.get(o.id) ?? [];
        if (evs.length === 0) { skipped++; continue; }
        push(o.member_id, o.id, evs.map((e) => e.id));
      }
    }

    if (groups.size === 0) {
      setBulkPrintErr(
        kind === "slip"
          ? `選取的 ${ids.length} 張都不能印小白單（已取貨 / 已取消的單印出來會是空單）`
          : `選取的 ${ids.length} 張都沒有可補印的收據（還沒取貨，或取貨已被撤銷）`,
      );
      return;
    }
    if (
      groups.size > BULK_PRINT_CONFIRM
      && !window.confirm(`會依會員分成 ${groups.size} 張單依序列印（每張都會跳一次列印對話框），確定？`)
    ) return;

    const path = kind === "slip" ? "/pickup/print-list?order_ids=" : "/pickup/print?event_ids=";
    for (const payload of groups.values()) {
      printViaIframe(withBasePath(`${path}${payload.join(",")}`));
    }
    if (skipped > 0) {
      setBulkPrintErr(
        `已送印 ${groups.size} 張（依會員分組）；另有 ${skipped} 張略過（`
        + (kind === "slip" ? "已取貨 / 已取消，印出來會是空單）" : "還沒取貨或取貨已撤銷）"),
      );
    }
  }

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">訂單</h1>
          <p className="text-sm text-zinc-500">
            {loading ? (
              <Spinner size={14} className="inline-block align-[-2px]" />
            ) : total === 0 ? (
              "共 0 筆"
            ) : (
              `共 ${total} 筆（${fromIdx}-${toIdx}）`
            )}
          </p>
        </div>
        <Link
          href="/orders/pivot"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          title="日期 × 商品 × 店家 樞紐表"
        >
          樞紐表 ↗
        </Link>
      </header>

      {/* KPI Trend — 大字 = 本月累計 / sparkline = 每日 / 副字 = 日均 (套 filter, 排除 transferred_out)
          最後一張「今日取貨金額」是取貨視角（依取貨當天切），大字 = 今天、副字 = 本月累計 */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <TrendCard
          label="本月營業額"
          trend={trend}
          getTotal={(t) => t.amount}
          getDaily={(d) => d.amount}
          fmt={(v) => `$${Math.round(v).toLocaleString("zh-TW")}`}
          subLabel="日均"
        />
        <TrendCard
          label="本月訂單數"
          trend={trend}
          getTotal={(t) => t.orders}
          getDaily={(d) => d.orders}
          fmt={(v) => v.toLocaleString("zh-TW")}
          subLabel="日均"
        />
        <PickupTodayCard trend={pickupTrend} />
      </div>

      {/* 下單來源 KPI — App(PWA) / 商城(LIFF) / 小幫手 三條折線，看通路消長 */}
      <SourceTrendCard trend={sourceTrend} />

      {/* Tab bar — 未取貨 / 可取貨 / 部分取貨 / 已完成 / 轉出 / 取消;含各 tab 數量 */}
      {/* 6 個 tab 在手機寬度放不下 → 橫向捲動,不要擠壓/換行 */}
      <div className="flex items-center gap-1 overflow-x-auto border-b border-zinc-200 dark:border-zinc-800">
        {TABS.map((t) => {
          const active = tab === t.value;
          const count = tabCounts?.[t.value];
          return (
            <SpinButton
              key={t.value}
              onClick={() => setTab(t.value)}
              className={`relative shrink-0 whitespace-nowrap px-3 py-2 text-sm font-medium transition-colors sm:px-4 ${
                active
                  ? "text-zinc-900 dark:text-zinc-100"
                  : "text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
              }`}
            >
              {t.label}
              {count !== undefined && (
                <span className={`ml-1.5 ${active ? "" : "text-zinc-400 dark:text-zinc-500"}`}>
                  ({count})
                </span>
              )}
              {active && (
                <span className="absolute -bottom-px left-0 right-0 h-0.5 bg-zinc-900 dark:bg-zinc-100" />
              )}
            </SpinButton>
          );
        })}
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
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
                ? campaignMap.get(Number(campaignIds[0]))?.name ?? `團 ${campaignIds[0]}`
                : `已選 ${campaignIds.length} 個開團`}
            </span>
            <span className="ml-2 text-zinc-400">▾</span>
          </SpinButton>
          {campaignPickerOpen && (
            <div className="absolute z-20 mt-1 max-h-96 w-full overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
              <div className="sticky top-0 z-10 border-b border-zinc-200 bg-white px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900">
                <div className="flex justify-between text-xs">
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
                <div className="relative mt-2">
                  <input
                    type="search"
                    value={campaignSearch}
                    onChange={(e) => setCampaignSearch(e.target.value)}
                    placeholder="搜尋開團編號 / 名稱"
                    className="w-full rounded border border-zinc-300 bg-white px-2 py-1 pr-8 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                  />
                  <SearchSpinner active={searchingCampaign} />
                </div>
              </div>
              {(() => {
                // 顯示順序：已勾選的開團釘在最上面（避免搜尋字串改變後不見），再放下拉結果
                const seen = new Set<number>();
                const ordered: Campaign[] = [];
                for (const id of campaignIds) {
                  const c = campaignMap.get(Number(id));
                  if (c && !seen.has(c.id)) {
                    ordered.push(c);
                    seen.add(c.id);
                  }
                }
                for (const id of dropdownIds) {
                  const c = campaignMap.get(id);
                  if (c && !seen.has(c.id)) {
                    ordered.push(c);
                    seen.add(c.id);
                  }
                }
                if (ordered.length === 0) {
                  return (
                    <div className="px-3 py-6 text-center text-xs text-zinc-500">
                      {campaignSearch ? "找不到符合的開團" : "無開團"}
                    </div>
                  );
                }
                return ordered.map((c) => {
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
                });
              })()}
            </div>
          )}
        </div>
        {/* 品項二層篩選 — 選了開團才出現（選項 = 所選開團的品項），只看含此品項的訂單 */}
        {campaignIds.length > 0 && (
          <select
            value={skuId}
            onChange={(e) => setSkuId(e.target.value)}
            title="再依品項（規格）篩選：只看含此品項的訂單"
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部品項</option>
            {skuFilterOptions.map((o) => (
              <option key={o.id} value={o.id}>{o.label}</option>
            ))}
          </select>
        )}
        <select value={storeId} onChange={(e) => setStoreId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部取貨店</option>
          {stores.map((s) => <option key={s.id} value={s.id}>{s.name} ({s.code})</option>)}
        </select>

        <form
          onSubmit={(e) => { e.preventDefault(); setKeyword(kwInput.trim()); }}
          className="flex gap-2"
        >
          <input
            type="search"
            value={kwInput}
            onChange={(e) => setKwInput(e.target.value)}
            placeholder="搜尋 訂單編號 / 姓名 / 電話 / 會員編號"
            className="min-w-0 flex-1 rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
          <SpinButton
            type="submit"
            className="shrink-0 rounded-md bg-zinc-900 px-3 py-2 text-sm text-white transition hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            🔍
          </SpinButton>
          {keyword && (
            <SpinButton
              type="button"
              onClick={() => { setKwInput(""); setKeyword(""); }}
              title="清空搜尋"
              className="shrink-0 rounded-md border border-zinc-300 px-2 py-2 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              ✕
            </SpinButton>
          )}
          {internalKeyword && (
            <SpinButton
              type="button"
              onClick={() => { setTab("pending"); setKwInput(internalKeyword); setKeyword(internalKeyword); }}
              title="搜尋本店【內部】會員名下的訂單（補貨現貨單），可從中轉手給客人"
              className={keyword === internalKeyword
                ? "shrink-0 rounded-md border border-amber-400 bg-amber-100 px-3 py-2 text-sm font-medium text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300"
                : "shrink-0 rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              }
            >
              內部店庫存單
            </SpinButton>
          )}
        </form>
      </div>

      {/* 日期區間 — 含起訖當日；留空 = 不限。語意跟著 tab 走（見 dateOnEvent 與
          DATE_FIELD_LABEL）：未取貨 = 訂單日，其餘 = 該狀態的事件日。
          自成一列：兩個 date input + 快捷鈕塞進上面的 3 欄 grid 會被壓到看不到年份。 */}
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <div
          className="flex items-center gap-1 rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          title={`${DATE_FIELD_LABEL[tab].hint}，含起訖當日；留空 = 不限`}
        >
          <span className={`shrink-0 pl-1 text-xs ${dateOnEvent ? "font-medium text-emerald-700 dark:text-emerald-400" : "text-zinc-500"}`}>
            {DATE_FIELD_LABEL[tab].label}
          </span>
          <input
            type="date"
            value={dateFrom}
            max={dateTo || undefined}
            onChange={(e) => setDateFrom(e.target.value)}
            className="bg-transparent px-1 py-1 outline-none"
          />
          <span className="text-zinc-400">~</span>
          <input
            type="date"
            value={dateTo}
            min={dateFrom || undefined}
            onChange={(e) => setDateTo(e.target.value)}
            className="bg-transparent px-1 py-1 outline-none"
          />
        </div>
        {DATE_PRESETS.map((p) => {
          const [f, t] = p.range();
          const active = dateFrom === f && dateTo === t;
          return (
            <SpinButton
              key={p.label}
              type="button"
              onClick={() => { setDateFrom(f); setDateTo(t); }}
              className={active
                ? "rounded-md border border-zinc-900 bg-zinc-900 px-2.5 py-1.5 text-xs font-medium text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "rounded-md border border-zinc-300 px-2.5 py-1.5 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              }
            >
              {p.label}
            </SpinButton>
          );
        })}
        {(dateFrom || dateTo) && (
          <SpinButton
            type="button"
            onClick={() => { setDateFrom(""); setDateTo(""); }}
            title="清除日期區間"
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-500 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ✕ 清除
          </SpinButton>
        )}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p><p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      {/* 批量列印工具列 — 勾選（可跨分頁累加）後依會員分組送印 */}
      {rows !== null && rows.length > 0 && (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900">
          <label className="flex cursor-pointer items-center gap-1.5">
            <input
              type="checkbox"
              checked={pageAllSelected}
              onChange={togglePage}
              className="h-4 w-4 cursor-pointer accent-emerald-600"
            />
            <span>選本頁（{pageIds.length}）</span>
          </label>
          {total > pageIds.length && (
            <SpinButton
              onClick={selectAllMatching}
              title={`選取全部符合目前篩選的訂單（最多 ${SELECT_ALL_MAX} 筆）`}
              className="rounded-md border border-zinc-300 px-2 py-1 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              選全部 {total} 筆
            </SpinButton>
          )}
          <span className={selected.size > 0 ? "font-semibold text-emerald-700 dark:text-emerald-400" : "text-zinc-500"}>
            已選 {selected.size} 筆
          </span>
          {selected.size > 0 && (
            <SpinButton
              onClick={() => { setSelected(new Set()); setBulkPrintErr(null); }}
              className="text-zinc-500 underline-offset-2 hover:underline"
            >
              清除
            </SpinButton>
          )}
          <div className="ml-auto flex flex-wrap items-center gap-2">
            <SpinButton
              onClick={() => bulkPrint("receipt")}
              disabled={selected.size === 0}
              title="補印已取貨那次的收據（80mm 熱感）— 同一會員的多張單合印一張，沒取貨的自動略過"
              className="rounded-md border border-zinc-300 px-2 py-1 font-medium hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              🖨️ 補印收據
            </SpinButton>
            <SpinButton
              onClick={() => bulkPrint("slip")}
              disabled={selected.size === 0}
              title="列印小白單（取貨清單，只列還沒取的品項）— 同一會員的多張單合印一張"
              className="rounded-md border border-zinc-300 px-2 py-1 font-medium hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              🖨️ 列印小白單
            </SpinButton>
          </div>
          {bulkPrintErr && (
            <div className="w-full text-amber-700 dark:text-amber-400">{bulkPrintErr}</div>
          )}
        </div>
      )}

      {/* 手機排序控制 — 卡片版沒有表頭可點，改用下拉 + 方向鈕（桌機點表頭） */}
      <div className="flex items-center gap-2 text-sm sm:hidden">
        <span className="shrink-0 text-xs text-zinc-500">排序</span>
        <select
          value={(sort ?? { key: "date" }).key}
          onChange={(e) => {
            const k = e.target.value as SortKey;
            applySort({ key: k, asc: SORT_DEFAULT_ASC[k] });
          }}
          className="min-w-0 flex-1 rounded-md border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
        >
          {SORT_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
        <SpinButton
          type="button"
          onClick={() => toggleSort((sort ?? { key: "date" as SortKey }).key)}
          title="切換升冪 / 降冪"
          className="shrink-0 rounded-md border border-zinc-300 px-2.5 py-1.5 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          {(sort?.asc ?? false) ? "▲ 升冪" : "▼ 降冪"}
        </SpinButton>
      </div>

      {/* 手機：每筆訂單一張卡片（桌機改用下方表格） */}
      <div className="space-y-2 sm:hidden">
        {rows === null ? (
          <div className="rounded-md border border-zinc-200 p-6 dark:border-zinc-800">
            <div className="flex justify-center text-zinc-400">
              <Spinner size={20} />
            </div>
          </div>
        ) : rows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800">
            {total === 0 && !hasFilter ? "此 tab 下尚無訂單。" : "沒有符合條件的訂單。"}
          </div>
        ) : rows.map((r) => {
          const m = r.member_id ? members.get(r.member_id) : null;
          const c = campaignMap.get(r.campaign_id);
          const s = storeMap.get(r.pickup_store_id);
          const sum = itemSummary.get(r.id);
          return (
            <div key={r.id} className={`rounded-lg border p-3 ${cardTint(r.status)}`}>
              <button
                type="button"
                onClick={() => { setDetailId(r.id); setDetailNo(r.order_no); }}
                className="block w-full text-left"
                title={r.order_no}
              >
                {c ? (
                  <div className="flex items-start gap-2">
                    <CoverThumb src={c.cover_image_url} alt={c.name} />
                    <div className="min-w-0 flex-1 space-y-0.5">
                      <div className="break-words text-xs text-zinc-500">{c.name}</div>
                      {(sum?.items ?? []).map((it, idx) => (
                        <div key={idx} className="break-words text-base font-bold text-zinc-900 dark:text-zinc-100">
                          {itemLabel(it, c.name)}
                          <span className="ml-1.5 text-xs font-normal text-zinc-500">× {it.qty}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                ) : "—"}
              </button>

              <div className="mt-2 flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={selected.has(r.id)}
                  onChange={() => toggleOne(r.id)}
                  title={`勾選 ${r.order_no} 供批量列印`}
                  className="h-4 w-4 shrink-0 cursor-pointer accent-emerald-600"
                />
                {m ? (
                  <>
                    <Avatar src={m.avatar_url} name={m.name ?? r.nickname_snapshot ?? "?"} />
                    <span className="min-w-0 truncate">
                      <Link href={`/members?id=${m.id}`} className="hover:underline">{m.name ?? "—"}</Link>
                      <span className="ml-1 font-mono text-xs text-zinc-500">{m.phone}</span>
                    </span>
                  </>
                ) : r.nickname_snapshot ? (
                  <>
                    <Avatar src={null} name={r.nickname_snapshot} />
                    <span className="text-zinc-500">({r.nickname_snapshot})</span>
                  </>
                ) : (
                  <span className="text-zinc-400">—</span>
                )}
              </div>

              <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500">
                <span>🏬 {s?.name ?? "—"}</span>
                {sum && sum.sources.length > 0 && (
                  <OrderSourceBadge summary={summarizeOrderSource(sum.sources)} />
                )}
                <span>{sum?.lineCount ?? 0} 項</span>
                <span>共 {sum?.totalQty ?? 0} 件</span>
                <span className="font-mono text-sm font-semibold text-zinc-900 dark:text-zinc-100">${sum?.totalAmount ?? 0}</span>
                <span
                  className="ml-auto"
                  title={`訂單日：${new Date(r.created_at).toLocaleString("zh-TW", { hour12: false })}\n更新日：${new Date(r.updated_at).toLocaleString("zh-TW", { hour12: false })}`}
                >
                  訂 {new Date(r.created_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })} · 更 {new Date(r.updated_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })}
                </span>
              </div>

              <div className="mt-2 flex flex-wrap items-center gap-1.5 border-t border-zinc-200/70 pt-2 dark:border-zinc-800">
                {orderActions(r, m)}
              </div>
            </div>
          );
        })}
      </div>

      <div className="hidden overflow-x-auto rounded-md border border-zinc-200 sm:block dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th className="w-8">
                <input
                  type="checkbox"
                  checked={pageAllSelected}
                  onChange={togglePage}
                  title="選取本頁全部"
                  className="h-4 w-4 cursor-pointer accent-emerald-600"
                />
              </Th>
              <SortTh label="開團" k="campaign" sort={sort} onSort={toggleSort} className="min-w-[14rem]" />
              <SortTh label="會員 / 暱稱" k="member" sort={sort} onSort={toggleSort} className="whitespace-nowrap" />
              <SortTh label="來源" k="source" sort={sort} onSort={toggleSort} className="whitespace-nowrap" title="依來源排序（同來源的單排在一起，混合來源自成一組）" />
              <SortTh label="取貨店" k="store" sort={sort} onSort={toggleSort} className="whitespace-nowrap" />
              <SortTh label="項數" k="lines" sort={sort} onSort={toggleSort} right className="whitespace-nowrap" />
              <SortTh label="總數量" k="qty" sort={sort} onSort={toggleSort} right className="whitespace-nowrap" />
              <SortTh label="總金額" k="amount" sort={sort} onSort={toggleSort} right className="whitespace-nowrap" />
              <SortTh label="日期" k="date" sort={sort} onSort={toggleSort} right className="whitespace-nowrap" title={`依「${dateOnEvent ? DATE_FIELD_LABEL[tab].label : "更新時間"}」排序`} />
              <Th className="whitespace-nowrap text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={10}><LoadingBlock /></td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={10} className="p-6 text-center text-zinc-500">{total === 0 && !hasFilter ? "此 tab 下尚無訂單。" : "沒有符合條件的訂單。"}</td></tr>
            ) : rows.map((r) => {
              const m = r.member_id ? members.get(r.member_id) : null;
              const c = campaignMap.get(r.campaign_id);
              const s = storeMap.get(r.pickup_store_id);
              return (
                <tr
                  key={r.id}
                  className={
                    r.status === "cancelled"
                      ? "bg-red-50 hover:bg-red-100 dark:bg-red-950/30 dark:hover:bg-red-950/50"
                      : r.status === "expired"
                      ? "bg-amber-50 hover:bg-amber-100 dark:bg-amber-950/30 dark:hover:bg-amber-950/50"
                      : r.status === "transferred_out"
                      ? "bg-zinc-100 text-zinc-500 hover:bg-zinc-200 dark:bg-zinc-900 dark:text-zinc-500 dark:hover:bg-zinc-800"
                      : "odd:bg-white even:bg-zinc-50 hover:bg-zinc-100 dark:odd:bg-zinc-950 dark:even:bg-zinc-900 dark:hover:bg-zinc-800"
                  }
                >
                  <Td className="w-8 align-top">
                    <input
                      type="checkbox"
                      checked={selected.has(r.id)}
                      onChange={() => toggleOne(r.id)}
                      title={`勾選 ${r.order_no} 供批量列印`}
                      className="h-4 w-4 cursor-pointer accent-emerald-600"
                    />
                  </Td>
                  <Td className="min-w-[14rem]">
                    <SpinButton
                      onClick={() => { setDetailId(r.id); setDetailNo(r.order_no); }}
                      className="block w-full text-left hover:underline"
                      title={r.order_no}
                    >
                      {c ? (
                        <div className="flex items-start gap-2">
                          <CoverThumb src={c.cover_image_url} alt={c.name} />
                          <div className="min-w-0 flex-1 space-y-0.5">
                            <div className="text-xs text-zinc-500 break-words">{c.name}</div>
                            {(itemSummary.get(r.id)?.items ?? []).map((it, idx) => (
                              <div
                                key={idx}
                                className="break-words text-base font-bold text-zinc-900 dark:text-zinc-100"
                              >
                                {itemLabel(it, c.name)}
                                <span className="ml-1.5 text-xs font-normal text-zinc-500">
                                  × {it.qty}
                                </span>
                              </div>
                            ))}
                          </div>
                        </div>
                      ) : "—"}
                    </SpinButton>
                  </Td>
                  <Td className="whitespace-nowrap">
                    {m ? (
                      <span className="flex items-center gap-2">
                        <Avatar src={m.avatar_url} name={m.name ?? r.nickname_snapshot ?? "?"} />
                        <span className="min-w-0">
                          <Link href={`/members?id=${m.id}`} className="hover:underline">{m.name ?? "—"}</Link>
                          <span className="ml-1 font-mono text-xs text-zinc-500">{m.phone}</span>
                        </span>
                      </span>
                    ) : r.nickname_snapshot ? (
                      <span className="flex items-center gap-2">
                        <Avatar src={null} name={r.nickname_snapshot} />
                        <span className="text-zinc-500">({r.nickname_snapshot})</span>
                      </span>
                    ) : "—"}
                  </Td>
                  <Td className="whitespace-nowrap">
                    {(() => {
                      const sum = itemSummary.get(r.id);
                      return sum && sum.sources.length > 0 ? (
                        <OrderSourceBadge summary={summarizeOrderSource(sum.sources)} />
                      ) : (
                        <span className="text-zinc-400">—</span>
                      );
                    })()}
                  </Td>
                  <Td className="whitespace-nowrap text-xs">{s?.name ?? "—"}</Td>
                  <Td className="whitespace-nowrap text-right font-mono">{itemSummary.get(r.id)?.lineCount ?? 0}</Td>
                  <Td className="whitespace-nowrap text-right font-mono">{itemSummary.get(r.id)?.totalQty ?? 0}</Td>
                  <Td className="whitespace-nowrap text-right font-mono">${itemSummary.get(r.id)?.totalAmount ?? 0}</Td>
                  <Td
                    className="whitespace-nowrap text-right text-xs text-zinc-500"
                    title={`訂單日：${new Date(r.created_at).toLocaleString("zh-TW", { hour12: false })}\n更新日：${new Date(r.updated_at).toLocaleString("zh-TW", { hour12: false })}`}
                  >
                    <div>訂 {new Date(r.created_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })}</div>
                    <div>更 {new Date(r.updated_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })}</div>
                  </Td>
                  <Td className="whitespace-nowrap text-right">
                    <div className="flex items-center justify-end gap-1">
                      {orderActions(r, m)}
                    </div>
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

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

      <OrderReturnCreateModal
        open={returnTarget !== null}
        onClose={() => setReturnTarget(null)}
        onCreated={() => { setReturnTarget(null); setReloadOrders((n) => n + 1); }}
        prefillOrderId={returnTarget?.orderId ?? null}
        prefillStoreId={returnTarget?.storeId ?? null}
      />

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

// 把 RPC 回的每日聚合補齊成「當月 1 號 ~ 今天」連續序列（沒資料補 0）。
// 下單趨勢 (trend_days/trend_total) 與取貨趨勢 (pickup_days/pickup_total)
// 形狀相同、只有各自用得到的欄位有值，共用同一支避免兩份補值邏輯漂移。
type AggLike = { ymd?: string; orders?: number; members?: number; amount?: number; qty?: number };
function buildTrend(
  startDate: Date,
  today: Date,
  rows: (AggLike & { ymd: string })[],
  totalRow: AggLike | null | undefined,
): TrendData {
  const dayMap = new Map(rows.map((d) => [d.ymd, d]));
  const days: DayTrend[] = [];
  const cur = new Date(startDate);
  while (cur <= today) {
    const ymd = fmtYmd(cur);
    const b = dayMap.get(ymd);
    const orders = Number(b?.orders ?? 0);
    const amount = Number(b?.amount ?? 0);
    days.push({
      ymd,
      orders,
      amount,
      members: Number(b?.members ?? 0),
      qty: Number(b?.qty ?? 0),
      aov: orders > 0 ? amount / orders : 0,
    });
    cur.setDate(cur.getDate() + 1);
  }
  const tOrders = Number(totalRow?.orders ?? 0);
  const tAmount = Number(totalRow?.amount ?? 0);
  return {
    days,
    total: {
      orders: tOrders,
      amount: tAmount,
      members: Number(totalRow?.members ?? 0),
      qty: Number(totalRow?.qty ?? 0),
      aov: tOrders > 0 ? tAmount / tOrders : 0,
    },
  };
}

// 把 RPC 回的 (日期 × source) 聚合攤平成「每條線一組對齊日期的陣列」。
// 只留 SOURCE_TREND_SERIES 定義的三個人工通路 —— 系統流程（遞轉/互助/匯入…）
// 不畫線；它們不是「客人怎麼下單」的一部分，畫進去只會多兩條貼著 0 的雜訊。
function buildSourceTrend(
  startDate: Date,
  today: Date,
  rows: SourceDayAgg[],
  totals: Omit<SourceDayAgg, "ymd">[],
): SourceTrendData {
  const days: string[] = [];
  const cur = new Date(startDate);
  while (cur <= today) {
    days.push(fmtYmd(cur));
    cur.setDate(cur.getDate() + 1);
  }
  const dayIdx = new Map(days.map((d, i) => [d, i]));
  const totalBySource = new Map(totals.map((t) => [t.source, t]));

  const series = SOURCE_TREND_SERIES.map((def) => {
    const daily = new Array<number>(days.length).fill(0);
    const dailyAmount = new Array<number>(days.length).fill(0);
    for (const r of rows) {
      if (r.source !== def.source) continue;
      const i = dayIdx.get(r.ymd);
      if (i === undefined) continue;
      daily[i] = Number(r.orders ?? 0);
      dailyAmount[i] = Number(r.amount ?? 0);
    }
    const t = totalBySource.get(def.source);
    return {
      ...def,
      daily,
      dailyAmount,
      totalOrders: Number(t?.orders ?? 0),
      totalAmount: Number(t?.amount ?? 0),
    };
  });
  return { days, series };
}

// 容器實際寬度（px）—— 折線圖要滿版又要維持字級/線寬不被 viewBox 縮放，
// 只能量出來再照 px 畫（preserveAspectRatio 會把 10px 的軸標在手機上縮成 4px）。
function useMeasuredWidth<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [width, setWidth] = useState(0);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    setWidth(Math.round(el.clientWidth));
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver((entries) => {
      setWidth(Math.round(entries[0]?.contentRect.width ?? 0));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, width] as const;
}

function Sparkline({
  values,
  labels,
  fmt,
  color = "currentColor",
}: {
  values: number[];
  labels?: string[];
  fmt?: (v: number) => string;
  color?: string;
}) {
  const [hovered, setHovered] = useState<number | null>(null);
  const w = 140;
  const h = 32;
  const pad = 2;
  const n = values.length;
  if (n === 0) return <svg width={w} height={h} />;
  const max = Math.max(...values, 1);
  const min = Math.min(...values, 0);
  const range = max - min || 1;
  const stepX = n > 1 ? (w - 2 * pad) / (n - 1) : 0;
  const points = values.map((v, i) => {
    const x = pad + i * stepX;
    const y = h - pad - ((v - min) / range) * (h - 2 * pad);
    return [x, y] as [number, number];
  });
  const path = points.map(([x, y], i) => `${i === 0 ? "M" : "L"} ${x.toFixed(1)} ${y.toFixed(1)}`).join(" ");
  const lastX = points[points.length - 1][0];
  const lastY = points[points.length - 1][1];
  const hoveredPt = hovered != null ? points[hovered] : null;

  return (
    <div className="relative inline-block" style={{ width: w, height: h }}>
      <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} className="overflow-visible">
        <path d={path} fill="none" stroke={color} strokeWidth="1.5" strokeLinejoin="round" strokeLinecap="round" />
        <circle cx={lastX} cy={lastY} r={2.5} fill={color} />
        {hoveredPt && (
          <>
            <line
              x1={hoveredPt[0]}
              y1={0}
              x2={hoveredPt[0]}
              y2={h}
              stroke="rgb(161 161 170)"
              strokeWidth="0.5"
              strokeDasharray="2 2"
            />
            <circle cx={hoveredPt[0]} cy={hoveredPt[1]} r={3} fill={color} stroke="white" strokeWidth="1" />
          </>
        )}
        {/* invisible hover bands */}
        {n > 1 &&
          values.map((_, i) => {
            const bandX = Math.max(0, points[i][0] - stepX / 2);
            const bandW = i === 0 || i === n - 1 ? stepX / 2 + pad : stepX;
            return (
              <rect
                key={i}
                x={bandX}
                y={0}
                width={bandW}
                height={h}
                fill="transparent"
                onMouseEnter={() => setHovered(i)}
                onMouseLeave={() => setHovered((cur) => (cur === i ? null : cur))}
              />
            );
          })}
      </svg>
      {hoveredPt && labels && (
        <div
          className="pointer-events-none absolute z-20 -translate-x-1/2 whitespace-nowrap rounded bg-zinc-900 px-1.5 py-1 text-[10px] leading-tight text-white shadow dark:bg-zinc-100 dark:text-zinc-900"
          style={{ left: hoveredPt[0], bottom: h + 4 }}
        >
          <div className="font-semibold">{labels[hovered!]}</div>
          <div className="tabular-nums">{fmt ? fmt(values[hovered!]) : values[hovered!]}</div>
        </div>
      )}
    </div>
  );
}

// 今日取貨金額 — 只看今天：已取貨品項 (status='picked_up') 的 qty×unit_price，
// 依「取貨當天」切。與另外兩張「本月」卡時間基準不同（那兩張依下單日 created_at），
// 所以綠底標示、也不放 sparkline / 本月累計 — 這張卡就只回答「今天交出去多少」。
function PickupTodayCard({ trend }: { trend: TrendData | null }) {
  const today = trend ? trend.days[trend.days.length - 1] : null;
  const num = (v: number) => v.toLocaleString("zh-TW");
  return (
    <div className="rounded-md border border-emerald-200 bg-emerald-50 px-4 py-3 dark:border-emerald-900 dark:bg-emerald-950/30">
      <div className="flex items-center justify-between">
        <div className="text-xs font-medium text-emerald-700 dark:text-emerald-400">今日取貨金額</div>
        {today && (
          <div className="text-[10px] text-zinc-400">
            {Number(today.ymd.split("-")[1])}/{Number(today.ymd.split("-")[2])}
          </div>
        )}
      </div>
      {!trend ? (
        <div className="mt-1 text-xl font-semibold tabular-nums text-zinc-400">—</div>
      ) : (
        <>
          <div className="mt-1 truncate text-xl font-semibold tabular-nums">
            ${num(Math.round(today?.amount ?? 0))}
          </div>
          <div className="mt-0.5 text-[11px] text-zinc-500">
            {num(today?.orders ?? 0)} 單 · {num(today?.qty ?? 0)} 件
          </div>
        </>
      )}
    </div>
  );
}

function TrendCard({
  label,
  trend,
  getTotal,
  getDaily,
  fmt,
  subLabel,
  subMode = "avg",
  hint,
}: {
  label: string;
  trend: TrendData | null;
  getTotal: (t: MonthAgg) => number;
  getDaily: (d: DayTrend) => number;
  fmt: (v: number) => string;
  subLabel: string;
  subMode?: "avg" | "last_day"; // 副字: 日均 or 最後一天
  hint?: string;
}) {
  if (!trend) {
    return (
      <div className="rounded-md border border-zinc-200 bg-white px-4 py-3 dark:border-zinc-800 dark:bg-zinc-950">
        <div className="text-xs text-zinc-500">{label}</div>
        <div className="mt-1 text-xl font-semibold tabular-nums text-zinc-400">—</div>
      </div>
    );
  }
  const total = getTotal(trend.total);
  const dailyValues = trend.days.map(getDaily);
  const lastDayValue = dailyValues[dailyValues.length - 1] ?? 0;
  // 副字算法
  const daysPassed = trend.days.length;
  const subValue =
    subMode === "last_day" ? lastDayValue : daysPassed > 0 ? total / daysPassed : 0;
  // sparkline 顏色 — 用最後一天 vs 上一天的差判斷
  const curr = lastDayValue;
  const prev = dailyValues[dailyValues.length - 2] ?? 0;
  const trendUp = curr > prev;
  const trendFlat = curr === prev;
  const sparkColor = trendFlat
    ? "rgb(161 161 170)"
    : trendUp
    ? "rgb(5 150 105)"
    : "rgb(220 38 38)";
  const firstDay = trend.days[0]?.ymd ?? "";
  const lastDay = trend.days[trend.days.length - 1]?.ymd ?? "";
  const fmtMD = (ymd: string) => {
    const [, m, d] = ymd.split("-");
    return `${Number(m)}/${Number(d)}`;
  };
  return (
    <div className="rounded-md border border-zinc-200 bg-white px-4 py-3 dark:border-zinc-800 dark:bg-zinc-950">
      <div className="flex items-center justify-between">
        <div className="text-xs text-zinc-500">{label}</div>
        <div className="text-[10px] text-zinc-400" title={`本月每日 (共 ${daysPassed} 天)`}>
          {fmtMD(firstDay)} ~ {fmtMD(lastDay)}
        </div>
      </div>
      <div className="mt-1 flex items-end justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate text-xl font-semibold tabular-nums" title={fmt(total)}>
            {fmt(total)}
          </div>
          <div className="mt-0.5 text-[11px] text-zinc-500">
            {subLabel} {fmt(subValue)}
          </div>
        </div>
        {/* sparkline 佔掉的寬度會把大字擠成 "$1,4…"（7 位數金額 ~109px）。
            xl 以上一張卡才夠放 140px sparkline + 完整大字，以下整個收起讓大字吃滿。 */}
        <div className="hidden xl:block">
          <Sparkline
            values={dailyValues}
            labels={trend.days.map((d) => fmtMD(d.ymd))}
            fmt={fmt}
            color={sparkColor}
          />
        </div>
      </div>
      {hint && <div className="mt-1 text-[10px] text-amber-600 dark:text-amber-400">{hint}</div>}
    </div>
  );
}

// 下單來源趨勢卡 — App(PWA) / 商城(LIFF) / 小幫手 三條折線疊在同一張圖上。
// 大字放在圖例：本月各通路累計（切「金額」時同一組線改畫金額）。
// 時間基準跟另外兩張「本月」卡一致（依下單日 created_at），所以可以直接對照。
function SourceTrendCard({ trend }: { trend: SourceTrendData | null }) {
  const [metric, setMetric] = useState<"orders" | "amount">("orders");
  const fmtOrders = (v: number) => `${Math.round(v).toLocaleString("zh-TW")} 單`;
  const fmtAmount = (v: number) => `$${Math.round(v).toLocaleString("zh-TW")}`;
  const fmt = metric === "orders" ? fmtOrders : fmtAmount;

  const lines = (trend?.series ?? []).map((s) => ({
    label: s.label,
    color: s.color,
    values: metric === "orders" ? s.daily : s.dailyAmount,
    total: metric === "orders" ? s.totalOrders : s.totalAmount,
  }));
  const grandTotal = lines.reduce((sum, l) => sum + l.total, 0);

  return (
    <div className="rounded-md border border-zinc-200 bg-white px-4 py-3 dark:border-zinc-800 dark:bg-zinc-950">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <div className="text-xs text-zinc-500">本月下單來源</div>
          <span
            className="cursor-help text-[10px] text-zinc-400"
            title={
              "依訂單日 (created_at) 每日統計，套用上方的開團／店家／品項／關鍵字篩選。\n" +
              "App = 會員在 App（PWA / 瀏覽器）自助下單；商城 = 會員在 LINE 內下單；小幫手 = 後台代客 key 單。\n" +
              "一張單同時有多種來源時，每個來源各算一張，所以三條線加起來會多於「本月訂單數」。\n" +
              "2026-08-08 以前的自助訂單沒有記執行環境，一律算「商城」。"
            }
          >
            ⓘ
          </span>
        </div>
        {/* 同一組線換指標：看單量還是看金額 */}
        <div className="flex items-center gap-0.5 rounded-md border border-zinc-200 p-0.5 text-[11px] dark:border-zinc-800">
          {([["orders", "訂單數"], ["amount", "金額"]] as const).map(([v, l]) => (
            <button
              key={v}
              type="button"
              onClick={() => setMetric(v)}
              className={`rounded px-2 py-0.5 transition-colors ${
                metric === v
                  ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
                  : "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              }`}
            >
              {l}
            </button>
          ))}
        </div>
      </div>

      {!trend ? (
        <div className="mt-3 h-[168px] animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
      ) : (
        <>
          {/* 圖例＝各通路本月累計 + 佔比（佔比分母是三條線的和，不是本月訂單數） */}
          <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1">
            {lines.map((l) => (
              <div key={l.label} className="min-w-0">
                <div className="flex items-center gap-1.5 text-[11px] text-zinc-500">
                  <span aria-hidden className="h-2 w-2 rounded-full" style={{ background: l.color }} />
                  {l.label}
                </div>
                <div className="text-lg font-semibold tabular-nums leading-tight">{fmt(l.total)}</div>
                <div className="text-[10px] text-zinc-400 tabular-nums">
                  {grandTotal > 0 ? `${Math.round((l.total / grandTotal) * 100)}%` : "—"}
                </div>
              </div>
            ))}
          </div>
          <MultiLineChart days={trend.days} lines={lines} fmt={fmt} />
        </>
      )}
    </div>
  );
}

// 多條折線 + 共用 y 軸的小圖表（不引第三方 chart 套件 — 這裡只需要折線）。
// 寬度量容器實際 px 再畫，字級/線寬才不會被 viewBox 縮放（見 useMeasuredWidth）。
function MultiLineChart({
  days,
  lines,
  fmt,
  height = 168,
}: {
  days: string[];
  lines: { label: string; color: string; values: number[] }[];
  fmt: (v: number) => string;
  height?: number;
}) {
  const [ref, measured] = useMeasuredWidth<HTMLDivElement>();
  const [hovered, setHovered] = useState<number | null>(null);
  const n = days.length;
  const w = Math.max(measured, 240);
  const padL = 44;
  const padR = 10;
  const padT = 10;
  const padB = 18;
  const plotW = Math.max(w - padL - padR, 10);
  const plotH = height - padT - padB;

  // y 軸上界取「好看的整數」：step ∈ {1,2,3,5}×10^k，畫 4 格 → 格線都落在整數上
  // 下限 1：訂單數/金額都是整數，step<1 會畫出 0.3 這種刻度
  const maxV = Math.max(1, ...lines.flatMap((l) => l.values));
  const step = Math.max(1, niceStep(maxV / 4));
  const top = step * 4;
  const tickFmt = makeTickFmt(top);

  const xAt = (i: number) => (n > 1 ? padL + (plotW * i) / (n - 1) : padL + plotW / 2);
  const yAt = (v: number) => padT + plotH - (v / top) * plotH;
  const fmtMD = (ymd: string) => {
    const [, m, d] = ymd.split("-");
    return `${Number(m)}/${Number(d)}`;
  };
  // x 軸標籤最多 ~6 個，太密會疊在一起
  const labelEvery = Math.max(1, Math.ceil(n / 6));
  const hoveredX = hovered != null ? xAt(hovered) : 0;

  return (
    <div
      ref={ref}
      className="relative mt-2"
      style={{ height }}
      onMouseLeave={() => setHovered(null)}
    >
      {measured > 0 && (
        <svg width={w} height={height} className="select-none">
          {/* 格線 + y 軸刻度（只標 0 / 中 / 上界，三個就夠讀） */}
          {[0, 1, 2, 3, 4].map((k) => {
            const v = step * k;
            const y = yAt(v);
            return (
              <g key={k}>
                <line
                  x1={padL}
                  y1={y}
                  x2={w - padR}
                  y2={y}
                  stroke="currentColor"
                  strokeWidth="1"
                  className="text-zinc-200 dark:text-zinc-800"
                />
                {k % 2 === 0 && (
                  <text
                    x={padL - 6}
                    y={y + 3}
                    textAnchor="end"
                    className="fill-zinc-400 text-[9px] tabular-nums"
                  >
                    {tickFmt(v)}
                  </text>
                )}
              </g>
            );
          })}

          {/* x 軸日期 */}
          {days.map((ymd, i) =>
            i % labelEvery === 0 || i === n - 1 ? (
              <text
                key={ymd}
                x={xAt(i)}
                y={height - 5}
                textAnchor={i === 0 ? "start" : i === n - 1 ? "end" : "middle"}
                className="fill-zinc-400 text-[9px] tabular-nums"
              >
                {fmtMD(ymd)}
              </text>
            ) : null,
          )}

          {/* hover 垂直線畫在折線底下，不擋線 */}
          {hovered != null && (
            <line
              x1={hoveredX}
              y1={padT}
              x2={hoveredX}
              y2={padT + plotH}
              stroke="rgb(161 161 170)"
              strokeWidth="1"
              strokeDasharray="2 2"
            />
          )}

          {lines.map((l) => {
            const pts = l.values.map((v, i) => `${xAt(i).toFixed(1)},${yAt(v).toFixed(1)}`);
            return (
              <g key={l.label}>
                <polyline
                  points={pts.join(" ")}
                  fill="none"
                  stroke={l.color}
                  strokeWidth="1.75"
                  strokeLinejoin="round"
                  strokeLinecap="round"
                />
                {/* 只有一天（每月 1 號）時 polyline 畫不出東西 → 補一個點 */}
                {n === 1 && <circle cx={xAt(0)} cy={yAt(l.values[0] ?? 0)} r={2.5} fill={l.color} />}
                {hovered != null && (
                  <circle
                    cx={hoveredX}
                    cy={yAt(l.values[hovered] ?? 0)}
                    r={3}
                    fill={l.color}
                    stroke="white"
                    strokeWidth="1"
                  />
                )}
              </g>
            );
          })}

          {/* 透明感應區：一天一條，滑到哪就顯示那天的三個值 */}
          {days.map((ymd, i) => {
            const bandW = n > 1 ? plotW / (n - 1) : plotW;
            return (
              <rect
                key={ymd}
                x={Math.max(0, xAt(i) - bandW / 2)}
                y={0}
                width={bandW}
                height={height}
                fill="transparent"
                onMouseEnter={() => setHovered(i)}
                onTouchStart={() => setHovered(i)}
              />
            );
          })}
        </svg>
      )}
      {hovered != null && (
        <div
          className="pointer-events-none absolute z-20 -translate-x-1/2 whitespace-nowrap rounded bg-zinc-900 px-2 py-1 text-[10px] leading-snug text-white shadow dark:bg-zinc-100 dark:text-zinc-900"
          // 靠邊時夾住，tooltip 才不會被卡片裁掉
          style={{ left: Math.min(Math.max(hoveredX, 56), w - 56), top: 0 }}
        >
          <div className="font-semibold">{fmtMD(days[hovered])}</div>
          {lines.map((l) => (
            <div key={l.label} className="flex items-center gap-1.5">
              <span aria-hidden className="h-1.5 w-1.5 rounded-full" style={{ background: l.color }} />
              <span className="opacity-70">{l.label}</span>
              <span className="ml-auto tabular-nums">{fmt(l.values[hovered] ?? 0)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

/** ≥ v 的「好看的刻度間距」：1/2/3/5 × 10^k。 */
function niceStep(v: number): number {
  if (!(v > 0)) return 1;
  const mag = Math.pow(10, Math.floor(Math.log10(v)));
  const norm = v / mag;
  const mult = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 3 ? 3 : norm <= 5 ? 5 : 10;
  return mult * mag;
}

/** y 軸刻度標的格式化器：軸很窄，上萬用 k / 上百萬用 M 省位置。
 *  單位看「上界」決定、不逐格判斷 —— 不然會出現 0 / 6,000 / 12k 混在同一軸上。 */
function makeTickFmt(top: number): (v: number) => string {
  const trim = (x: number) => Number(x.toFixed(1)).toString();
  if (top >= 1_000_000) return (v) => (v === 0 ? "0" : `${trim(v / 1_000_000)}M`);
  if (top >= 10_000) return (v) => (v === 0 ? "0" : `${trim(v / 1_000)}k`);
  return (v) => Math.round(v).toLocaleString("zh-TW");
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
// 可排序表頭：點一下依此欄排序、再點切換方向。sort=null 時實際上就是照日期
// 新→舊在排，所以把「日期」標成作用中，讓現況看得見。
function SortTh({
  label, k, sort, onSort, className = "", right = false, title,
}: {
  label: string;
  k: SortKey;
  sort: SortState;
  onSort: (k: SortKey) => void;
  className?: string;
  right?: boolean;
  title?: string;
}) {
  const eff = sort ?? { key: "date" as SortKey, asc: false };
  const active = eff.key === k;
  return (
    <th className={`px-4 py-2 text-xs font-medium ${right ? "text-right" : "text-left"} ${className}`}>
      <button
        type="button"
        onClick={() => onSort(k)}
        title={title ?? `依「${label}」排序`}
        className={`inline-flex select-none items-center gap-0.5 uppercase tracking-wide ${
          active
            ? "font-semibold text-zinc-800 dark:text-zinc-200"
            : "text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
        }`}
      >
        {label}
        <span aria-hidden className={active ? "" : "text-zinc-300 dark:text-zinc-600"}>
          {active ? (eff.asc ? "▲" : "▼") : "↕"}
        </span>
      </button>
    </th>
  );
}
function Td({ children, className = "", title }: { children: React.ReactNode; className?: string; title?: string }) {
  return <td className={`px-4 py-3 ${className}`} title={title}>{children}</td>;
}
function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return <SpinButton onClick={onClick} disabled={disabled} className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800">{children}</SpinButton>;
}
function CoverThumb({ src, alt }: { src: string | null; alt: string }) {
  if (!src) {
    return (
      <span
        aria-hidden
        className="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded bg-zinc-100 text-xs text-zinc-400 dark:bg-zinc-800 dark:text-zinc-500"
      >
        ▦
      </span>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt={alt}
      className="h-10 w-10 flex-shrink-0 rounded object-cover"
      onError={(e) => {
        (e.currentTarget as HTMLImageElement).style.display = "none";
      }}
    />
  );
}
function Avatar({ src, name }: { src: string | null; name: string }) {
  const initial = name.trim().charAt(0) || "?";
  if (!src) {
    return (
      <span
        aria-hidden
        className="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full bg-zinc-200 text-xs font-medium text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
      >
        {initial}
      </span>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt=""
      referrerPolicy="no-referrer"
      className="h-8 w-8 flex-shrink-0 rounded-full object-cover"
      onError={(e) => {
        const el = e.currentTarget as HTMLImageElement;
        el.style.display = "none";
      }}
    />
  );
}
function StatusBadge({ s }: { s: OrderStatus }) {
  const st: Record<OrderStatus, string> = {
    pending: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
    shipping: "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300",
    ready: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    partially_completed: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300",
    completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
    expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
    transferred_out: "bg-zinc-300 text-zinc-700 line-through dark:bg-zinc-700 dark:text-zinc-400",
  };
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${st[s]}`}>{STATUS_LABEL[s]}</span>;
}
