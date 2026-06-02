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

/**
 * 此 status 的訂單能不能列印取貨小白單。
 * 取消 / 逾期 / 轉出 = 不會發生取貨，不印；其餘（含已完成）皆可印。
 * 已完成單印的是「已取貨品項」(收據/紀錄)，待取單印「待取品項」，
 * 由 /pickup/print-list 頁依訂單狀態決定要列出哪些品項。
 */
export function canPrintPickupSlip(status: string | null | undefined): boolean {
  if (!status) return false;
  return !["cancelled", "expired", "transferred_out"].includes(status);
}

// ============================================================
// 歷史翻譯（已砍、僅留紀錄；未來重啟用時引用此處避免重新討論）
//   reserved              → 已備貨   （之前部分檔案誤翻「已保留」）
//   partially_ready       → 部分可取
//   picked_up             → 已取貨   （只用於 customer_order_items.status）
// ============================================================
