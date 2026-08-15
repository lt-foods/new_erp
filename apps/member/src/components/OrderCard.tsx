import { orderCardTitle } from "@/lib/orderTitle";
import StatusChip from "@/components/StatusChip";
import SkuThumb from "@/components/SkuThumb";

export type OrderItem = {
  id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  campaign_item_id: number | null;
  qty: number;
  unit_price: number;
  subtotal: number;
  status: string;
  stockout?: boolean;
  notes: string | null;
  image_url: string | null;
  /**
   * 這一行到店了沒（v_customer_order_summary.items[].arrived @20260814070000）。
   * 只有 active 行（pending/reserved/ready）有值，其餘是 null —— 那些行的分桶
   * 看 status 就決定了，不必付閘門的計算成本。
   *
   * ⚠️ 不可以用單頭的 arrived 代替：那一欄有快路徑，單頭一到 ready /
   * partially_completed 就無條件 true（短收時會謊報到貨）。
   */
  arrived?: boolean | null;
};

export type OrderRow = {
  id: number;
  order_no: string;
  status?: string | null;
  stockout_at?: string | null;
  pickup_deadline: string | null;
  payable_amount: number;
  /** 應付 − 已用儲值金扣抵；v_customer_order_summary 有給 */
  balance_due?: number;
  /**
   * 這張單真正還沒收的錢＝尚未取貨的品項（20260810000000）。取貨當下收現金，
   * 所以「已取走」＝「已付清」。訂單列表的「應付總金額」用它加總，
   * 不可以用 payable_amount —— 那是「這張單本身多少錢」，會把取過的貨一直掛帳。
   */
  outstanding_amount?: number;
  items_total: number;
  shipping_fee: number;
  discount_amount: number;
  arrived: boolean;
  settled: boolean;
  paid: boolean;
  shipped: boolean;
  items: OrderItem[];
  notes: string | null;
  created_at: string;
  /** 內部 sentinel 團判斷用（'__' 開頭）；v_customer_order_summary @20260811000050 */
  campaign_no?: string | null;
  campaign_name: string | null;
  campaign_cover_url: string | null;
  campaign_cutoff_date: string | null;
  store_name: string | null;
  settlement_no: string;
};

/**
 * 蝦皮式訂單階段：分頁分桶 + 卡片右上角狀態字共用同一份判定，
 * 兩邊才不會出現「分在待取貨、標籤卻寫待到貨」。
 *
 * 對應（我們取貨付現，沒有「待付款」；「待收貨」＝到店「待取貨」）：
 *   waiting     待到貨（pending / confirmed；shipping 標「運送中」，貨還沒到店）
 *   pickup      待取貨（門市已收貨、取貨閘門放行；partially_completed 剩的也還能取）
 *   done        已完成
 *   void        不成立（斷貨取消 / 逾期）
 *   transferred 已轉讓（轉單給別人，只在「全部」出現）
 */
export type OrderPhase = "waiting" | "pickup" | "done" | "void" | "transferred";

/** 分身卡右上角的狀態字（依「行」拆頁後，整張單的狀態字會對不上該頁的內容） */
const PHASE_LABEL: Record<OrderPhase, { label: string; className: string }> = {
  waiting: { label: "待到貨", className: "text-[#b06c00]" },
  pickup: { label: "待取貨", className: "text-[#b06c00]" },
  done: { label: "已完成", className: "text-[var(--brand-strong)]" },
  void: { label: "訂單不成立", className: "text-[#c4271d]" },
  transferred: { label: "已轉讓", className: "text-[var(--ios-gray)]" },
};

export function orderPhase(o: Pick<OrderRow, "status" | "arrived">): {
  phase: OrderPhase;
  label: string;
  className: string;
} {
  switch (o.status) {
    case "cancelled":
      return { phase: "void", label: "訂單不成立", className: "text-[#c4271d]" };
    case "expired":
      return { phase: "void", label: "逾期未取", className: "text-[#c4271d]" };
    case "transferred_out":
      return { phase: "transferred", label: "已轉讓", className: "text-[var(--ios-gray)]" };
    case "completed":
      return { phase: "done", label: "已完成", className: "text-[var(--brand-strong)]" };
    case "partially_completed":
      return { phase: "pickup", label: "部分已取", className: "text-[#b06c00]" };
  }
  if (o.arrived) return { phase: "pickup", label: "待取貨", className: "text-[#b06c00]" };
  // 派貨中 = 總倉已出貨、門市**還沒收貨**，團友這時跑來店裡會領不到東西。
  // arrived 曾經無條件把 shipping 當「已到店」（2026-08-11 修掉，20260811000010：
  // 改問 is_order_pickup_ready）。標籤寫「運送中」比「待到貨」明確，
  // 但仍歸在 waiting 分頁 —— 兩者對團友的意思都是「先別跑來」。
  if (o.status === "shipping")
    return { phase: "waiting", label: "運送中", className: "text-[#b06c00]" };
  return { phase: "waiting", label: "待到貨", className: "text-[#b06c00]" };
}

/**
 * 單一品項行屬於哪個分頁。
 *
 * 分頁要依**行**分，不能整張單塞同一個分頁：一張單短收之後常常是
 * 「一件已經領走、一件根本還沒到」（GRP-20260805-006-0026 忠順），
 * 整張歸在「待取貨」等於告訴客人剩下那件在店裡等他 —— 跑一趟撲空。
 *
 * 單頭層級的終局狀態（取消 / 逾期 / 轉讓）優先，其餘看行自己的狀態：
 *   已取走            → 已完成
 *   斷貨 / 取消 / 逾期 → 不成立
 *   還沒取 + 到貨了    → 待取貨
 *   還沒取 + 沒到貨    → 待到貨
 */
export function itemPhase(order: Pick<OrderRow, "status">, item: OrderItem): OrderPhase {
  switch (order.status) {
    case "cancelled":
    case "expired":
      return "void";
    case "transferred_out":
      return "transferred";
  }
  if (item.status === "picked_up") return "done";
  if (["cancelled", "expired"].includes(item.status)) return "void";
  // arrived 只有 active 行有值；缺值（舊 payload / 尚未部署 view）一律當「沒到」，
  // 寧可少報到貨也不要叫客人白跑一趟。
  return item.arrived === true ? "pickup" : "waiting";
}

/**
 * 把一張單依品項分頁拆成數個「分身」，每個分身只帶屬於該分頁的品項行。
 * 回傳的 key 就是該分身要進的分頁。一張單可能同時出現在兩個分頁
 * （例：一件已領走 → 已完成、一件還沒到 → 待到貨），這是刻意的。
 */
export function splitOrderByPhase(order: OrderRow): Map<OrderPhase, OrderRow> {
  const out = new Map<OrderPhase, OrderRow>();
  for (const it of order.items) {
    const ph = itemPhase(order, it);
    const cur = out.get(ph);
    if (cur) cur.items.push(it);
    else out.set(ph, { ...order, items: [it] });
  }
  return out;
}

/** 這一組品項行還沒領走的貨值（用來把單頭的應付金額分攤到各分頁，避免重複計算） */
export function unpickedSubtotal(items: OrderItem[]): number {
  return items
    .filter((i) => !["cancelled", "expired", "picked_up"].includes(i.status))
    .reduce((s, i) => s + Number(i.subtotal ?? 0), 0);
}

function fmtAmount(n: number | string | null | undefined): string {
  return Number(n ?? 0).toLocaleString();
}

function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "-";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}/${m}/${day}`;
}

// 品項的「還沒取」集合 = rpc_record_pickup 的 v_active_remaining 同一套
const ACTIVE_ITEM_STATUSES = ["pending", "reserved", "ready"];

export default function OrderCard({
  order,
  /**
   * 這張卡是「某個分頁的分身」時傳入該分頁 —— 右上角狀態字改用分頁的語意，
   * 而不是整張單的。不傳（「全部」分頁）就照舊顯示整張單的狀態。
   */
  viewPhase,
}: {
  order: OrderRow;
  viewPhase?: OrderPhase;
}) {
  // 斷貨 / 已取消的品項照樣列出來（畫成刪除線 + 「斷貨」標），但不算件數 —
  // items_total / payable_amount 從 20260808000010 起就不含這些行了，
  // 件數要跟著排除，否則「商品（5 件）$218」對不起來。
  const totalQty = order.items.reduce(
    (s, i) => (["cancelled", "expired"].includes(i.status) ? s : s + Number(i.qty ?? 0)),
    0,
  );
  // 分身卡（依分頁拆出來的）用得到：這張卡實際列出來的品項貨值
  const visibleItemsTotal = order.items.reduce(
    (s, i) => (["cancelled", "expired"].includes(i.status) ? s : s + Number(i.subtotal ?? 0)),
    0,
  );
  // 部分取貨的單，客人看不出哪行取了、哪行沒取（2026-08-13 中和店客訴）——
  // 取過的行和還沒取的行混在同一張卡時，逐行標「已取 / 未取」。
  // 全取完（已完成）或全沒取的單不標，右上角狀態字已經講完了，行內再標是噪音。
  // 部分數量取貨會拆行（20260630000010），所以每一行必屬其中一邊，不用管數量。
  // 2026-08-14：改看「行的分頁」而不是只看已取/未取 —— 短收時同一張單會有
  // 「已領走」和「根本還沒到」兩種行，只標「未取」等於叫客人來拿沒到的貨。
  // 行的分頁超過一種才標；單一種時右上角狀態字已經講完了，行內再標是噪音。
  const phasesInCard = new Set(order.items.map((i) => itemPhase(order, i)));
  const showPickChips = phasesInCard.size > 1;
  const pickChip = (it: OrderItem) => {
    if (!showPickChips) return null;
    if (it.status === "picked_up") return <StatusChip tone="ok" label="已取" />;
    if (!ACTIVE_ITEM_STATUSES.includes(it.status)) return null;
    // 沒到貨的行講「未到貨」，不要講「未取」—— 後者會被讀成「貨在店裡等你」
    return it.arrived === true
      ? <StatusChip tone="warn" label="未取" />
      : <StatusChip tone="warn" label="未到貨" />;
  };
  // 內部 sentinel 團（店內現貨轉手單）印品項名，其餘印開團名稱 —— 見 lib/orderTitle
  const title = orderCardTitle(order);
  // 分身卡（依分頁拆出來的）右上角要講該分頁的語意，不是整張單的
  const phase = viewPhase
    ? { ...orderPhase(order), ...PHASE_LABEL[viewPhase] }
    : orderPhase(order);
  // 已經領走一部分（取貨當場收現金）→ 這張單真正還要付的是 outstanding_amount。
  // 只在「領了一部分、還剩一部分」時才多畫一行：全部領完 / 取消的單 outstanding=0，
  // 那些維持原本單一「應付金額」的樣子。沒有這欄的舊 payload 也走原本的樣子。
  // 分身卡的「應付金額」要用這張卡實際列出的品項貨值 —— 掛整張單的 payable_amount
  // 會讓「已完成」那張分身卡寫著 $278（含還沒到貨那件的錢）。
  // 折扣 / 運費沒有按行分攤，分身卡的這個數字是近似值（無折扣的單完全相等）。
  const cardPayable = viewPhase ? visibleItemsTotal : Number(order.payable_amount ?? 0);
  const outstanding = Number(order.outstanding_amount ?? NaN);
  const partlyPaid =
    Number.isFinite(outstanding) &&
    outstanding > 0 &&
    outstanding < cardPayable;

  return (
    <article className="card overflow-hidden">
      <header className="bg-[var(--brand-soft)]/35 px-4 pt-4 pb-3">
        <div className="flex items-center justify-between gap-2">
          <div className="flex min-w-0 items-center gap-2">
            <h3 className="min-w-0 truncate text-[18px] font-bold text-[var(--foreground)]">{title}</h3>
            {order.stockout_at && (
              <StatusChip tone="danger" label="斷貨" />
            )}
          </div>
          {/* 蝦皮式右上角狀態字 */}
          <span className={`flex-shrink-0 text-[14px] font-medium ${phase.className}`}>
            {phase.label}
          </span>
        </div>
        {order.stockout_at && (
          <p className="mt-1 text-[13px] text-[#c4271d]">
            ⛔ 供應商斷貨，本筆訂單已取消，造成不便敬請見諒
          </p>
        )}
        <p className="mt-0.5 text-[14px] text-[var(--secondary-label)]">
          {fmtDate(order.created_at)}
          {order.store_name && (
            <>
              <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
              取貨：{order.store_name}
            </>
          )}
        </p>
        {order.campaign_cutoff_date && (
          <p className="text-[14px] text-[var(--secondary-label)]">
            結單日 {order.campaign_cutoff_date}
          </p>
        )}
      </header>

      <ul className="border-t border-[var(--separator)] px-4">
        {order.items.map((it, idx) => (
          <li
            key={it.id}
            className={`flex items-start gap-3 py-3 ${
              idx > 0 ? "border-t border-[var(--separator)]" : ""
            }`}
          >
            {/* 商品沒自己的圖時退到開團封面 —— 團購品項多半只有封面，
                不退一層的話整張單會是一排購物袋 placeholder。 */}
            <SkuThumb
              url={it.image_url ?? order.campaign_cover_url}
              muted={["cancelled", "expired"].includes(it.status)}
            />
            <div className="min-w-0 flex-1">
              {it.variant_name && (
                <div className={`text-[16px] ${it.stockout ? "text-[var(--secondary-label)] line-through" : "text-[var(--foreground)]"}`}>
                  {it.variant_name}
                  {it.stockout && (
                    <span className="ml-1.5 inline-block no-underline">
                      <StatusChip tone="danger" label="斷貨" />
                    </span>
                  )}
                  {pickChip(it) && (
                    <span className="ml-1.5 inline-block">{pickChip(it)}</span>
                  )}
                </div>
              )}
              {!it.variant_name && (it.stockout || pickChip(it)) && (
                <div className="flex items-center gap-1.5">
                  {it.stockout && <StatusChip tone="danger" label="斷貨" />}
                  {pickChip(it)}
                </div>
              )}
              <div className="text-[14px] text-[var(--secondary-label)]">
                {fmtAmount(it.unit_price)} × {it.qty}
              </div>
              {/* it.notes 是內部備註（補貨申請 / 轉單軌跡等），顧客端不顯示 */}
            </div>
            <div className={`flex-shrink-0 text-right text-[16px] font-medium tabular-nums ${it.stockout ? "text-[var(--secondary-label)] line-through" : "text-[var(--foreground)]"}`}>
              {fmtAmount(it.subtotal)}
            </div>
          </li>
        ))}
      </ul>

      {/* order.notes 同為內部備註，顧客端不顯示 */}

      <div className="space-y-1 border-t border-[var(--separator)] px-4 py-3 text-[14px]">
        <div className="flex justify-between text-[var(--secondary-label)]">
          <span>商品（{totalQty} 件）</span>
          {/* 分身卡只列該分頁的品項行，金額要跟著只算這些行 ——
              否則會出現「商品（1 件）278」這種件數與金額對不起來的畫面。 */}
          <span className="tabular-nums">{fmtAmount(viewPhase ? visibleItemsTotal : order.items_total)}</span>
        </div>
        {Number(order.shipping_fee) > 0 && (
          <div className="flex justify-between text-[var(--secondary-label)]">
            <span>運費</span>
            <span className="tabular-nums">{fmtAmount(order.shipping_fee)}</span>
          </div>
        )}
        {Number(order.discount_amount) > 0 && (
          <div className="flex justify-between text-[var(--secondary-label)]">
            <span>折扣</span>
            <span className="tabular-nums">−{fmtAmount(order.discount_amount)}</span>
          </div>
        )}
        <div className="flex items-baseline justify-between pt-2">
          <span className="text-[16px] text-[var(--foreground)]">
            {partlyPaid ? "訂單金額" : "應付金額"}
          </span>
          <span
            className={
              partlyPaid
                ? "text-[16px] tabular-nums text-[var(--secondary-label)]"
                : "text-[24px] font-semibold tabular-nums text-[var(--brand-strong)]"
            }
          >
            ${fmtAmount(cardPayable)}
          </span>
        </div>
        {/* 部分取貨：取走的那幾項當場付現了，卡片只留「應付金額」會跟列表上方的
            總金額對不上（2026-08-11 團友 528204 手動加總差 $49 就是這張單）。 */}
        {partlyPaid && (
          <div className="flex items-baseline justify-between">
            <span className="text-[16px] text-[var(--foreground)]">還需付款</span>
            <span className="text-[24px] font-semibold tabular-nums text-[var(--brand-strong)]">
              ${fmtAmount(order.outstanding_amount)}
            </span>
          </div>
        )}
      </div>
    </article>
  );
}
