"use client";

import Link from "next/link";
import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import Spinner, { LoadingBlock } from "@/components/Spinner";
import OrderReturnCreateModal from "@/components/OrderReturnCreateModal";
import { translateRpcError } from "@/lib/rpcError";
import { withBasePath } from "@/lib/basePath";
import { printViaIframe } from "@/lib/printIframe";
import { useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import { ORDER_STATUS_LABEL as STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";
import { summarizeOrderSource } from "@/lib/orderSource";
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
};

// 本月累計 (member 是跨日 distinct, 不是日 sum)
type MonthAgg = {
  orders: number;
  amount: number;
  members: number;
  aov: number;
};

type TrendData = {
  days: DayTrend[];
  total: MonthAgg;
};

type Tab = "pending" | "partially" | "completed" | "cancelled" | "transferred";
const TABS: { value: Tab; label: string }[] = [
  { value: "pending", label: "未取貨" },
  { value: "partially", label: "部分取貨" },
  { value: "completed", label: "已完成" },
  { value: "transferred", label: "轉出" },
  { value: "cancelled", label: "取消" },
];
const PENDING_STATUSES: OrderStatus[] = ["pending", "confirmed", "shipping", "ready"];
const CANCELLED_STATUSES: OrderStatus[] = ["cancelled", "expired"];

const PAGE_SIZE = 50;

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

// 手機卡片底色（依訂單狀態）— 對應桌機表格列底色
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
    if (t === "pending" || t === "partially" || t === "completed" || t === "cancelled" || t === "transferred") return t;
    return "pending";
  })();
  const initialStoreId = searchParams.get("storeId") ?? "";
  const initialKeyword = searchParams.get("q") ?? "";

  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaignIds, setCampaignIds] = useState<string[]>(initialCampaignIds);
  const [tab, setTab] = useState<Tab>(initialTab);
  const [storeId, setStoreId] = useState(initialStoreId);
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

  // KPI trend (當月 1 號 ~ 今天 每日 + 本月累計、套 filter 開團+店家、排除 transferred_out)
  const [trend, setTrend] = useState<TrendData | null>(null);

  useEffect(() => { setPage(1); }, [campaignIds, tab, storeId, keyword]);

  // 取貨店篩選不鎖分店：所有帳號都可自由選任一店 / 全部
  // （僅保留軟性預設選中自家店，使用者可自行切換到別店或「全部」）
  useDefaultStoreFromUser(stores, storeId, setStoreId);

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
        let q = getSupabase()
          .from("customer_orders")
          .select("id, order_no, campaign_id, member_id, nickname_snapshot, pickup_store_id, pickup_deadline, status, transferred_from_order_id, created_at, updated_at", { count: "exact" })
          .order("updated_at", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (campaignIds.length === 1) q = q.eq("campaign_id", Number(campaignIds[0]));
        else if (campaignIds.length > 1) q = q.in("campaign_id", campaignIds.map((x) => Number(x)));
        // 依 tab 套狀態過濾;一律隱藏 transferred_out (視同關閉、金額/數量不入統計)
        if (tab === "partially") q = q.eq("status", "partially_completed");
        else if (tab === "completed") q = q.eq("status", "completed");
        else if (tab === "cancelled") q = q.in("status", CANCELLED_STATUSES);
        else if (tab === "transferred") q = q.eq("status", "transferred_out");
        else q = q.in("status", PENDING_STATUSES);
        if (storeId) q = q.eq("pickup_store_id", Number(storeId));
        const kwOr = await buildKeywordOr(keyword);
        if (cancelled) return;
        if (kwOr) q = q.or(kwOr);

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        setRows((data ?? []) as Row[]);
        setTotal(count ?? 0);

        const ids = (data ?? []).map((r) => r.id);
        const memIds = Array.from(new Set((data ?? []).map((r) => r.member_id).filter((x): x is number => x != null)));
        // shipping 單查品項到貨狀態（pickup_ready=true 隱含該品項 active 且已到貨）
        const shippingIds = (data ?? []).filter((r) => r.status === "shipping").map((r) => r.id);
        const [ic, ms, rdy] = await Promise.all([
          ids.length
            ? getSupabase().from("customer_order_items").select("order_id, qty, unit_price, source, sku:skus(product_name, variant_name)").in("order_id", ids)
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
  }, [campaignIds, tab, storeId, page, reloadOrders, keyword]);

  // 頁首聚合（tab 數量 + 月趨勢）— 單一伺服端 RPC rpc_order_overview
  // 取代之前 client 端「5 個 count:exact 全表掃描」+「搬整月訂單+全部明細
  // 回瀏覽器做聚合」的做法（後者一個月幾萬筆訂單時是主要的慢點）。
  // 切 tab 不重抓,只在 campaign / 店家 / keyword / reload 變動時更新。
  useEffect(() => {
    let cancelled = false;
    setTrend(null);
    (async () => {
      const sb = getSupabase();
      const today = new Date();
      const startDate = new Date(today.getFullYear(), today.getMonth(), 1);

      const { data, error: rpcErr } = await sb.rpc("rpc_order_overview", {
        p_campaign_ids: campaignIds.length ? campaignIds.map((x) => Number(x)) : null,
        p_store_id: storeId ? Number(storeId) : null,
        p_keyword: keyword || null,
        p_month_start: startDate.toISOString(),
      });
      if (cancelled) return;

      type Overview = {
        tab_counts: { pending: number; partially: number; completed: number; cancelled: number; transferred: number };
        trend_days: { ymd: string; orders: number; members: number; amount: number }[];
        trend_total: { orders: number; members: number; amount: number };
      };
      if (rpcErr || !data) {
        setTabCounts(null);
        setTrend({ days: buildEmptyTrend(today), total: { orders: 0, amount: 0, members: 0, aov: 0 } });
        return;
      }
      const ov = data as Overview;
      setTabCounts({
        pending: ov.tab_counts.pending ?? 0,
        partially: ov.tab_counts.partially ?? 0,
        completed: ov.tab_counts.completed ?? 0,
        cancelled: ov.tab_counts.cancelled ?? 0,
        transferred: ov.tab_counts.transferred ?? 0,
      });

      // 把 RPC 回的每日聚合補齊成「當月 1 號 ~ 今天」連續序列（沒資料補 0）
      const dayMap = new Map<string, { orders: number; members: number; amount: number }>();
      for (const d of ov.trend_days ?? []) {
        dayMap.set(d.ymd, { orders: Number(d.orders), members: Number(d.members), amount: Number(d.amount) });
      }
      const days: DayTrend[] = [];
      const cur = new Date(startDate);
      while (cur <= today) {
        const ymd = `${cur.getFullYear()}-${String(cur.getMonth() + 1).padStart(2, "0")}-${String(cur.getDate()).padStart(2, "0")}`;
        const b = dayMap.get(ymd);
        const orderCnt = b?.orders ?? 0;
        const amt = b?.amount ?? 0;
        days.push({
          ymd,
          orders: orderCnt,
          amount: amt,
          members: b?.members ?? 0,
          aov: orderCnt > 0 ? amt / orderCnt : 0,
        });
        cur.setDate(cur.getDate() + 1);
      }
      const monthOrders = Number(ov.trend_total?.orders ?? 0);
      const monthAmount = Number(ov.trend_total?.amount ?? 0);
      const total: MonthAgg = {
        orders: monthOrders,
        amount: monthAmount,
        members: Number(ov.trend_total?.members ?? 0),
        aov: monthOrders > 0 ? monthAmount / monthOrders : 0,
      };
      setTrend({ days, total });
    })();
    return () => {
      cancelled = true;
    };
  }, [campaignIds, storeId, reloadOrders, keyword]);

  const campaignMap = useMemo(() => new Map(campaigns.map((c) => [c.id, c])), [campaigns]);
  const storeMap = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);

  // 批次取貨 — 抓所有勾選訂單的 pickable items, 連續呼 rpc_record_pickup,
  async function cancelOrder(orderId: number, orderNo: string, status: string) {
    const reason = prompt(
      status === "shipping"
        ? `撤回派貨：${orderNo}\n會反向回收已出庫存，請輸入原因：`
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

      {/* KPI Trend — 大字 = 本月累計 / sparkline = 每日 / 副字 = 日均 (套 filter, 排除 transferred_out) */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
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
        <TrendCard
          label="客單價"
          trend={trend}
          getTotal={(t) => t.aov}
          getDaily={(d) => d.aov}
          fmt={(v) => `$${Math.round(v).toLocaleString("zh-TW")}`}
          subLabel="今日"
          subMode="last_day"
        />
        <TrendCard
          label="本月會員數"
          trend={trend}
          getTotal={(t) => t.members}
          getDaily={(d) => d.members}
          fmt={(v) => v.toLocaleString("zh-TW")}
          subLabel="今日"
          subMode="last_day"
        />
      </div>

      {/* Tab bar — 未取貨 / 部分取貨 / 已完成 / 轉出 / 取消;含各 tab 數量 */}
      <div className="flex items-center gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {TABS.map((t) => {
          const active = tab === t.value;
          const count = tabCounts?.[t.value];
          return (
            <SpinButton
              key={t.value}
              onClick={() => setTab(t.value)}
              className={`relative px-4 py-2 text-sm font-medium transition-colors ${
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
        </form>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p><p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

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
            {total === 0 && campaignIds.length === 0 && !storeId && !keyword ? "此 tab 下尚無訂單。" : "沒有符合條件的訂單。"}
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
                          {it.variant_name || it.product_name || "—"}
                          <span className="ml-1.5 text-xs font-normal text-zinc-500">× {it.qty}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                ) : "—"}
              </button>

              <div className="mt-2 flex items-center gap-2 text-sm">
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
              <Th className="min-w-[14rem]">開團</Th><Th className="whitespace-nowrap">會員 / 暱稱</Th><Th className="whitespace-nowrap">來源</Th><Th className="whitespace-nowrap">取貨店</Th><Th className="whitespace-nowrap text-right">項數</Th><Th className="whitespace-nowrap text-right">總數量</Th><Th className="whitespace-nowrap text-right">總金額</Th><Th className="whitespace-nowrap text-right">日期</Th><Th className="whitespace-nowrap text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9}><LoadingBlock /></td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">{total === 0 && campaignIds.length === 0 && !storeId && !keyword ? `此 tab 下尚無訂單。` : "沒有符合條件的訂單。"}</td></tr>
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
                                {it.variant_name || it.product_name || "—"}
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

function buildEmptyTrend(today: Date): DayTrend[] {
  const days: DayTrend[] = [];
  const cur = new Date(today.getFullYear(), today.getMonth(), 1);
  while (cur <= today) {
    const ymd = `${cur.getFullYear()}-${String(cur.getMonth() + 1).padStart(2, "0")}-${String(cur.getDate()).padStart(2, "0")}`;
    days.push({ ymd, orders: 0, amount: 0, members: 0, aov: 0 });
    cur.setDate(cur.getDate() + 1);
  }
  return days;
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
  // 副字算法
  const daysPassed = trend.days.length;
  const subValue =
    subMode === "last_day"
      ? dailyValues[dailyValues.length - 1] ?? 0
      : daysPassed > 0
      ? total / daysPassed
      : 0;
  // sparkline 顏色 — 用最後一天 vs 上一天的差判斷
  const curr = dailyValues[dailyValues.length - 1] ?? 0;
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
        <div className="hidden sm:block">
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

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
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
