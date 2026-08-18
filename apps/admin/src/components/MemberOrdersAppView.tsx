"use client";

/**
 * 會員明細 →「會員畫面」：把會員 app「我的訂單」那一頁原樣搬進後台。
 *
 * 為什麼要有這個：金額客訴（例：2026-08-11 會員 109814 的「應付總金額」）
 * 都是團友傳截圖進來、客服對著後台表格逐張猜是哪幾筆 —— 兩邊口徑不同，
 * 對不上就得來回一整個下午。這個視圖跟 app 用同一個 view、同一套分桶與加總，
 * 客服看到的數字 = 團友手機上的數字，一眼就能對。
 *
 * 「一樣」是硬需求，四個地方要跟會員端同步（改那邊記得改這邊）：
 *   - 資料管線 = liff-api listMyOrders：v_customer_order_summary、半年內、
 *     active / history 各最多 100 筆、一般取消不顯示但斷貨取消要顯示、已轉讓隱藏
 *   - orderPhase 分桶 = apps/member/src/components/OrderCard.tsx
 *   - 應付總金額只在「待到貨」「待取貨」顯示、用 outstanding_amount
 *     = apps/member/src/app/orders/page.tsx（2026-08-11 起「全部」不顯示金額）
 *   - 卡片標題 orderCardTitle（內部 sentinel 團改印品項名）
 *     = apps/member/src/lib/orderTitle.ts 的副本 lib/orderTitle.ts
 *   - 「已完成」依「那一次到店結單」分組（order_pickup_events）
 *     = apps/member/src/lib/pickups.ts 的副本 lib/pickupVisits.ts
 *
 * 後台加值：點卡片可直接開訂單明細（會員 app 沒有這個）。
 */

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { orderCardTitle } from "@/lib/orderTitle";
import { fetchReprintableEvents } from "@/lib/pickupReceipt";
import {
  buildDoneNodes,
  formatVisitWhen,
  visibleTotals,
  type PickupVisit,
} from "@/lib/pickupVisits";

type AppOrderItem = {
  id: number;
  product_name: string | null;
  variant_name: string | null;
  qty: number;
  unit_price: number;
  subtotal: number;
  status: string;
  stockout?: boolean;
};

export type AppOrderRow = {
  id: number;
  order_no: string;
  status: string | null;
  stockout_at: string | null;
  payable_amount: number;
  outstanding_amount: number | null;
  items_total: number;
  shipping_fee: number;
  discount_amount: number;
  arrived: boolean;
  items: AppOrderItem[];
  created_at: string;
  /** 內部 sentinel 團判斷用（'__' 開頭）；v_customer_order_summary @20260811000050 */
  campaign_no: string | null;
  campaign_name: string | null;
  campaign_cutoff_date: string | null;
  store_name: string | null;
  /** 這張單的取貨紀錄（order_pickup_events；撤銷掉的那幾次已濾除）—— 「已完成」分組用 */
  pickups?: { id: number; picked_at: string; item_ids: number[] }[];
};

type Phase = "waiting" | "pickup" | "done" | "void" | "transferred";
type Tab = "all" | "waiting" | "pickup" | "done" | "void";

// 「全部」放最後、預設落在「待到貨」＝會員 app（2026-08-13：預設「全部」會讓
// 待取貨跟未到貨混排，客人以為全到貨跑來撲空）
const TAB_LABEL: Record<Tab, string> = {
  waiting: "待到貨",
  pickup: "待取貨",
  done: "已完成",
  void: "不成立",
  all: "全部",
};

// = apps/member/src/components/OrderCard.tsx 的 orderPhase（分桶 + 右上角狀態字）
function orderPhase(o: Pick<AppOrderRow, "status" | "arrived">): {
  phase: Phase;
  label: string;
  className: string;
} {
  switch (o.status) {
    case "cancelled":
      return { phase: "void", label: "訂單不成立", className: "text-red-700 dark:text-red-400" };
    case "expired":
      return { phase: "void", label: "逾期未取", className: "text-red-700 dark:text-red-400" };
    case "transferred_out":
      return { phase: "transferred", label: "已轉讓", className: "text-zinc-400" };
    case "completed":
      return { phase: "done", label: "已完成", className: "text-rose-700 dark:text-rose-400" };
    case "partially_completed":
      return { phase: "pickup", label: "部分已取", className: "text-amber-700 dark:text-amber-400" };
  }
  if (o.arrived) return { phase: "pickup", label: "待取貨", className: "text-amber-700 dark:text-amber-400" };
  if (o.status === "shipping")
    return { phase: "waiting", label: "運送中", className: "text-amber-700 dark:text-amber-400" };
  return { phase: "waiting", label: "待到貨", className: "text-amber-700 dark:text-amber-400" };
}

function fmtAmount(n: number | string | null | undefined): string {
  return Number(n ?? 0).toLocaleString();
}

function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "-";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`;
}

/**
 * 抓「會員 app 看得到的訂單」＋分桶。抽成 hook 是因為兩個地方要用同一份數字：
 * 「會員畫面」整個視圖、以及「列表」表尾的應付總金額（同 app 口徑）——
 * 各抓各的遲早會分家，客服又要對不上。
 */
export function useMemberAppOrders(memberId: number, reloadTick = 0) {
  const [orders, setOrders] = useState<AppOrderRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      setErr(null);
      const sb = getSupabase();
      const cutoff = new Date();
      cutoff.setMonth(cutoff.getMonth() - 6);
      const base = () =>
        sb
          .from("v_customer_order_summary")
          .select("*")
          .eq("member_id", memberId)
          .gte("created_at", cutoff.toISOString())
          .order("created_at", { ascending: false })
          .limit(100);
      // = liff-api listMyOrders 的兩個 tab（active / history），各自 limit 100
      const [activeQ, historyQ] = await Promise.all([
        base().not("status", "in", "(completed,expired)"),
        base().eq("status", "completed"),
      ]);
      if (cancelled) return;
      const qErr = activeQ.error ?? historyQ.error;
      if (qErr) {
        setErr(qErr.message);
        setLoading(false);
        return;
      }
      // 一般取消不顯示、斷貨取消要顯示；已轉讓整個隱藏 —— 都跟 app 一致
      const rows = [
        ...((activeQ.data ?? []) as AppOrderRow[]).filter(
          (o) => o.status !== "cancelled" || o.stockout_at,
        ),
        ...((historyQ.data ?? []) as AppOrderRow[]),
      ]
        .filter((o) => orderPhase(o).phase !== "transferred")
        .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());

      // 取貨紀錄 —— 「已完成」要依「客人那一次到店結單」分組（= 會員 app）。
      // 拿不到就只是少了分組（卡片照列），不要讓整個視圖掛掉。
      const eventsByOrder = await fetchReprintableEvents(rows.map((o) => o.id));
      if (cancelled) return;
      for (const o of rows) {
        o.pickups = (eventsByOrder.get(o.id) ?? []).map((ev) => ({
          id: ev.id,
          picked_at: ev.created_at,
          item_ids: ev.item_ids,
        }));
      }

      setOrders(rows);
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [memberId, reloadTick]);

  const buckets = useMemo(() => {
    const b: Record<Tab, AppOrderRow[]> = { all: orders, waiting: [], pickup: [], done: [], void: [] };
    for (const o of orders) {
      const { phase } = orderPhase(o);
      if (phase !== "transferred") b[phase].push(o);
    }
    return b;
  }, [orders]);

  return { orders, buckets, loading, err };
}

export type MemberAppOrders = ReturnType<typeof useMemberAppOrders>;

/**
 * 一個分桶的應付加總 = 會員 app orders/page.tsx 的 sumOrders：
 * outstanding_amount（還沒領走的貨），排除 cancelled / expired。
 */
export function outstandingTotals(list: AppOrderRow[]) {
  const active = list.filter((o) => !["cancelled", "expired"].includes(String(o.status ?? "")));
  return {
    count: active.length,
    amount: active.reduce(
      (s, o) => s + Number(o.outstanding_amount ?? o.payable_amount ?? 0),
      0,
    ),
    hasPicked: active.some(
      (o) => Number(o.outstanding_amount ?? o.payable_amount ?? 0) < Number(o.payable_amount ?? 0),
    ),
  };
}

export function MemberOrdersAppView({
  data,
  onOpenOrder,
}: {
  /** useMemberAppOrders 的回傳 —— 由 MemberDetail 抓一次，列表表尾共用同一份 */
  data: MemberAppOrders;
  /** 點卡片開後台訂單明細（app 沒有；後台看細節 / 操作用） */
  onOpenOrder: (id: number, orderNo: string) => void;
}) {
  const { buckets, loading, err } = data;
  const [tab, setTab] = useState<Tab>("waiting");

  // 「已完成」依「那一次到店結單」分組（= 會員 app 的同一支演算法）：客人一趟
  // 拿走好幾個團的貨、當場付一次現金，平鋪的訂單列表拼不回那一次拿了什麼。
  // 一張單分兩次取完會拆成兩張卡，各自掛在自己那一次底下。
  const doneNodes = useMemo(() => buildDoneNodes(buckets.done), [buckets.done]);

  const bucket = buckets[tab];
  // = 會員 app orders/page.tsx：應付總金額只在待到貨 / 待取貨顯示
  const showTotals = tab === "waiting" || tab === "pickup";
  const { count: activeCount, amount: totalAmount, hasPicked } = outstandingTotals(bucket);

  if (err) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {err}
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-1.5">
        {(Object.keys(TAB_LABEL) as Tab[]).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={
              tab === t
                ? "rounded-full bg-rose-600 px-3 py-1 text-xs font-semibold text-white"
                : "rounded-full border border-zinc-300 px-3 py-1 text-xs text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }
          >
            {TAB_LABEL[t]}
            {/* app 同款：全部 / 已完成不掛數字 */}
            {t !== "all" && t !== "done" && buckets[t].length > 0 && (
              <span className="ml-1 opacity-70">{buckets[t].length}</span>
            )}
          </button>
        ))}
      </div>

      {loading && <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>}

      {!loading && showTotals && activeCount > 0 && (
        <div className="flex items-center justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50/60 px-4 py-3 dark:border-rose-900 dark:bg-rose-950/30">
          <div>
            <div className="text-sm text-zinc-800 dark:text-zinc-200">應付總金額</div>
            <div className="text-xs text-zinc-500">
              共 {activeCount} 筆訂單
              {hasPicked && <span className="ml-1.5">· 已取貨的不計（取貨時付現）</span>}
            </div>
          </div>
          <span className="text-xl font-semibold tabular-nums text-rose-700 dark:text-rose-400">
            ${fmtAmount(totalAmount)}
          </span>
        </div>
      )}

      {!loading && bucket.length === 0 && (
        <div className="p-8 text-center text-sm text-zinc-500">
          {tab === "all" ? "半年內沒有訂單" : `目前沒有「${TAB_LABEL[tab]}」的訂單`}
        </div>
      )}

      {!loading && (
        <div className="max-h-[560px] space-y-3 overflow-auto pr-1">
          {tab === "done"
            ? doneNodes.map((node) =>
                node.kind === "visit" ? (
                  <PickupVisitHeader key={node.key} visit={node.visit} />
                ) : (
                  <AppOrderCard
                    key={node.key}
                    order={node.order}
                    visitSlice
                    onClick={() => onOpenOrder(node.order.id, node.order.order_no)}
                  />
                ),
              )
            : bucket.map((o) => (
                <AppOrderCard key={o.id} order={o} onClick={() => onOpenOrder(o.id, o.order_no)} />
              ))}
        </div>
      )}

      <p className="text-[11px] text-zinc-400">
        與會員 app「我的訂單」同一套資料與口徑（半年內、每類最多 100 筆）；「已完成」依客人
        到店結單的那一次分組；點卡片可開後台訂單明細。
      </p>
    </div>
  );
}

// 一次到店結單的標題（= 會員 app 的 PickupVisitHeader）。
// 措辭避開「結單」兩個字：卡片上的「結單日」是開團收單日，兩種意思擺一起會誤讀。
function PickupVisitHeader({ visit }: { visit: PickupVisit }) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50/60 px-4 py-2.5 dark:border-rose-900 dark:bg-rose-950/30">
      <div className="min-w-0">
        <div className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
          🧾 {formatVisitWhen(visit.pickedAt)} 取貨
        </div>
        <div className="text-xs text-zinc-500">
          {visit.storeName && <>{visit.storeName} · </>}
          {visit.orderCount} 筆訂單 · {visit.qty} 件
        </div>
      </div>
      <div className="flex-shrink-0 text-right">
        <div className="text-[11px] text-zinc-500">本次取貨金額</div>
        <div className="text-lg font-semibold tabular-nums text-rose-700 dark:text-rose-400">
          ${fmtAmount(visit.amount)}
        </div>
      </div>
    </div>
  );
}

// 品項的「還沒取」集合 = rpc_record_pickup 的 v_active_remaining 同一套
const ACTIVE_ITEM_STATUSES = ["pending", "reserved", "ready"];

// = apps/member/src/components/OrderCard.tsx 的卡片內容（後台配色 + 可點擊）
function AppOrderCard({
  order,
  onClick,
  /**
   * 這張卡是「某一次結單的分片」（只帶那一次取走的品項）—— 金額要照卡片上真的
   * 列出來的行算，掛整張單的 items_total / payable_amount 會出現「1 件 $278」
   * 這種對不起來的畫面。= 會員 app OrderCard 的 viewPhase 分身卡同一套。
   */
  visitSlice = false,
}: {
  order: AppOrderRow;
  onClick: () => void;
  visitSlice?: boolean;
}) {
  const phase = orderPhase(order);
  const visible = visibleTotals(order.items ?? []);
  // 內部 sentinel 團（店內現貨轉手單）印品項名，其餘印開團名稱 —— 見 lib/orderTitle
  const title = orderCardTitle(order);
  const totalQty = (order.items ?? []).reduce(
    (s, i) => (["cancelled", "expired"].includes(i.status) ? s : s + Number(i.qty ?? 0)),
    0,
  );
  // = 會員端 OrderCard：部分取貨時逐行標「已取 / 未取」，客服看到的跟
  // 團友手機上的一致（2026-08-13 中和店客訴：分不出哪行取了）
  const showPickChips =
    (order.items ?? []).some((i) => i.status === "picked_up") &&
    (order.items ?? []).some((i) => ACTIVE_ITEM_STATUSES.includes(i.status));
  const pickChip = (status: string) =>
    !showPickChips ? null : status === "picked_up" ? (
      <span className="ml-1.5 inline-block rounded bg-green-100 px-1 py-0.5 text-[10px] font-medium text-green-800 dark:bg-green-950 dark:text-green-300">
        已取
      </span>
    ) : ACTIVE_ITEM_STATUSES.includes(status) ? (
      <span className="ml-1.5 inline-block rounded bg-amber-100 px-1 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
        未取
      </span>
    ) : null;
  const outstanding = Number(order.outstanding_amount ?? NaN);
  const partlyPaid =
    Number.isFinite(outstanding) && outstanding > 0 && outstanding < Number(order.payable_amount ?? 0);

  return (
    <article
      onClick={onClick}
      title={`點此查看訂單明細 ${order.order_no}`}
      className="cursor-pointer overflow-hidden rounded-xl border border-zinc-200 bg-white transition-shadow hover:shadow-md dark:border-zinc-800 dark:bg-zinc-900"
    >
      <header className="bg-rose-50/60 px-4 pb-2.5 pt-3 dark:bg-rose-950/20">
        <div className="flex items-center justify-between gap-2">
          <h4 className="min-w-0 truncate text-[15px] font-bold text-zinc-900 dark:text-zinc-100">
            {title}
          </h4>
          <span className={`flex-shrink-0 text-xs font-medium ${phase.className}`}>{phase.label}</span>
        </div>
        {order.stockout_at && (
          <p className="mt-0.5 text-xs text-red-700 dark:text-red-400">
            ⛔ 供應商斷貨，本筆訂單已取消，造成不便敬請見諒
          </p>
        )}
        <p className="mt-0.5 text-xs text-zinc-500">
          {fmtDate(order.created_at)}
          {order.store_name && <span className="ml-1.5">· 取貨：{order.store_name}</span>}
          {order.campaign_cutoff_date && <span className="ml-1.5">· 結單日 {order.campaign_cutoff_date}</span>}
        </p>
      </header>

      <ul className="divide-y divide-zinc-100 px-4 dark:divide-zinc-800">
        {(order.items ?? []).map((it) => (
          <li key={it.id} className="flex items-start gap-3 py-2">
            <div className="min-w-0 flex-1">
              <div
                className={`text-sm ${
                  it.stockout
                    ? "text-zinc-400 line-through"
                    : "text-zinc-900 dark:text-zinc-100"
                }`}
              >
                {it.variant_name ?? "—"}
                {it.stockout && (
                  <span className="ml-1.5 inline-block rounded bg-red-100 px-1 py-0.5 text-[10px] font-medium text-red-800 no-underline dark:bg-red-950 dark:text-red-300">
                    斷貨
                  </span>
                )}
                {pickChip(it.status)}
              </div>
              <div className="text-xs text-zinc-500">
                {fmtAmount(it.unit_price)} × {it.qty}
              </div>
            </div>
            <div
              className={`flex-shrink-0 text-right text-sm font-medium tabular-nums ${
                it.stockout ? "text-zinc-400 line-through" : "text-zinc-900 dark:text-zinc-100"
              }`}
            >
              {fmtAmount(it.subtotal)}
            </div>
          </li>
        ))}
      </ul>

      <div className="space-y-1 border-t border-zinc-100 px-4 py-2.5 text-sm dark:border-zinc-800">
        <div className="flex justify-between text-xs text-zinc-500">
          <span>商品（{totalQty} 件）</span>
          <span className="tabular-nums">
            {fmtAmount(visitSlice ? visible.amount : order.items_total)}
          </span>
        </div>
        {Number(order.shipping_fee) > 0 && (
          <div className="flex justify-between text-xs text-zinc-500">
            <span>運費</span>
            <span className="tabular-nums">{fmtAmount(order.shipping_fee)}</span>
          </div>
        )}
        {Number(order.discount_amount) > 0 && (
          <div className="flex justify-between text-xs text-zinc-500">
            <span>折扣</span>
            <span className="tabular-nums">−{fmtAmount(order.discount_amount)}</span>
          </div>
        )}
        <div className="flex items-baseline justify-between pt-1">
          <span className="text-zinc-800 dark:text-zinc-200">
            {partlyPaid ? "訂單金額" : "應付金額"}
          </span>
          <span
            className={
              partlyPaid
                ? "text-sm tabular-nums text-zinc-500"
                : "text-lg font-semibold tabular-nums text-rose-700 dark:text-rose-400"
            }
          >
            ${fmtAmount(visitSlice ? visible.amount : order.payable_amount)}
          </span>
        </div>
        {partlyPaid && (
          <div className="flex items-baseline justify-between">
            <span className="text-zinc-800 dark:text-zinc-200">還需付款</span>
            <span className="text-lg font-semibold tabular-nums text-rose-700 dark:text-rose-400">
              ${fmtAmount(order.outstanding_amount)}
            </span>
          </div>
        )}
      </div>
    </article>
  );
}
