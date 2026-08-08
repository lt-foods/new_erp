// ============================================================
// 顧客訂單 (customer_orders.status) 中央定義
//
// Single source of truth — 所有 admin 端 / LIFF 端 status 中文 label
// 都從這裡 import。新增 status 時：
//   1. 加到 ORDER_STATUSES tuple
//   2. 加到 ORDER_STATUS_LABEL
//   3. 同步 supabase migration 的 CHECK constraint
//   4. 視語意調整 isTerminalStatus / canPayWithWallet
//
// 已砍掉但保留歷史翻譯（檔案最下方）：
//   - reserved (已備貨)         — 未啟用，DB 0 筆，無 RPC SET
//   - partially_ready (部分可取) — 未啟用，無 RPC SET
//   - picked_up (已取貨)        — 是 customer_order_items.status，不是 orders.status
// ============================================================

export const ORDER_STATUSES = [
  "pending",
  "confirmed",
  "ready",
  "shipping",
  "partially_completed",
  "completed",
  "cancelled",
  "transferred_out",
  "expired",
] as const;

export type OrderStatus = (typeof ORDER_STATUSES)[number];

export const ORDER_STATUS_LABEL: Record<OrderStatus, string> = {
  pending:             "待確認",
  confirmed:           "已確認",
  ready:               "可取貨",
  shipping:            "派貨中",
  partially_completed: "部分取貨",
  completed:           "已完成",
  cancelled:           "已取消",
  transferred_out:     "已轉出",
  expired:             "已過期",
};

/** 取中文 label；未知 status 直接 fallback 原字串。 */
export function orderStatusLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return ORDER_STATUS_LABEL[s as OrderStatus] ?? s;
}

// customer_order_items.status 的中文 label（與 orders.status 是不同集合）。
// pending/reserved/ready 都是「尚未取貨」的細分；picked_up=已取貨。
export const ORDER_ITEM_STATUS_LABEL: Record<string, string> = {
  pending:   "待取貨",
  reserved:  "已備貨",
  ready:     "可取貨",
  picked_up: "已取貨",
  cancelled: "已取消",
  expired:   "已過期",
};

/** customer_order_items.status 取中文 label；未知直接 fallback 原字串。 */
export function orderItemStatusLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return ORDER_ITEM_STATUS_LABEL[s] ?? s;
}

const TERMINAL_STATUSES = new Set<string>([
  "completed",
  "cancelled",
  "transferred_out",
  "expired",
]);

/** 終態 = 訂單流程已結束、不會再轉換。 */
export function isTerminalStatus(s: string | null | undefined): boolean {
  return s != null && TERMINAL_STATUSES.has(s);
}

// ============================================================
// 數量 / 金額統計的納入規則（訂單層級 + 品項層級，兩層都要套）
//
// 轉單不是「搬移」而是「複製 + 標記」，所以任何加總都必須兩層都濾掉，
// 否則同一批貨會被算兩次（同店互轉最明顯：一進一出總量卻變多）：
//
//   1. 整單轉出 (rpc_transfer_order_to_store)
//      來源單 status → 'transferred_out'，但**品項原封不動留著**
//      （轉入單是 INSERT..SELECT 複製一份）。只濾 cancelled/expired
//      不濾 transferred_out ⇒ 來源單 + 轉入單各算一次。
//   2. 部分轉出 (rpc_transfer_order_partial)
//      整項轉走的來源品項 → status='cancelled' 但**仍掛在來源單上**
//      （來源單 status 不變，還是 confirmed/ready）。不濾品項 status
//      ⇒ 來源單照算原數量 + 轉入單再算一次。
//      實例：GRP-20260804-007 湖口店 -0058 轉 1 顆到 -TF0157，
//      本店小計顯示 21 顆（實際 20）、$1,325（實際 $1,250）。
//
// 新增任何「加總 customer_order_items」的畫面時，兩個 helper 一起用。
// ============================================================

const NON_COUNTING_ORDER_STATUSES = new Set<string>([
  "cancelled",
  "expired",
  "transferred_out",
]);

/** 這張訂單的數量/金額要不要計入統計（已取消/已過期/已轉出都不計）。 */
export function orderCountsInTotals(s: string | null | undefined): boolean {
  return !(s != null && NON_COUNTING_ORDER_STATUSES.has(s));
}

const NON_COUNTING_ITEM_STATUSES = new Set<string>(["cancelled", "expired"]);

/** 這個品項的數量/金額要不要計入統計（部分轉出會把來源品項標 cancelled 留在原單）。 */
export function orderItemCountsInTotals(s: string | null | undefined): boolean {
  return !(s != null && NON_COUNTING_ITEM_STATUSES.has(s));
}

/**
 * 此 status 的訂單能不能用儲值金結帳。
 * 規則：非終態 + 非已付清（payment_status 由呼叫端另判）。
 * 跟 supabase/migrations/20260606000013 rpc_wallet_pay_order 同步。
 */
export function canPayWithWallet(
  status: string | null | undefined,
  paymentStatus: string | null | undefined,
): boolean {
  if (paymentStatus === "paid") return false;
  if (isTerminalStatus(status)) return false;
  return true;
}

// ============================================================
// 歷史翻譯（已砍、僅留紀錄；未來重啟用時引用此處避免重新討論）
//   reserved              → 已備貨   （之前部分檔案誤翻「已保留」）
//   partially_ready       → 部分可取
//   picked_up             → 已取貨   （只用於 customer_order_items.status）
// ============================================================

// ============================================================
// 訂單清單頁的深連結
//
// /orders 沒有「全部」分頁，預設落在「未取貨」(PENDING_STATUSES)。
// 直接用 ?q=<order_no> 連過去，已完成 / 已取消的單會找不到 —— 所以要依訂單
// 當下的 status 一併帶上對的 tab。對應關係與 orders/page.tsx 的查詢一致：
//   pending  → status IN (pending, confirmed, shipping, ready)
//   ready    → status = ready            （已被 pending 涵蓋，不特別導過去）
//   partially/completed/cancelled/transferred → 各自對應
// ============================================================
export function orderListTabFor(status: string | null | undefined): string {
  switch (status) {
    case "partially_completed":
      return "partially";
    case "completed":
      return "completed";
    case "cancelled":
    case "expired":
      return "cancelled";
    case "transferred_out":
      return "transferred";
    default:
      return "pending";
  }
}

/** 訂單清單頁的深連結；帶上 status 對應的 tab，確保連過去看得到那張單 */
export function orderListHref(orderNo: string, status?: string | null): string {
  const qs = new URLSearchParams({ q: orderNo, tab: orderListTabFor(status) });
  return `/orders?${qs.toString()}`;
}
