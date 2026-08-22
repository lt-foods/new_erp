// ============================================================
// 補貨申請 (restock_requests.status) 的 approved_transfer 有「兩種」意思
//
// 2026-06-12（20260612000040）之前：按下去會當場建一張 status='shipped' 的 transfer、
//   rpc_outbound 直接扣總倉庫存 → 貨真的出去了，linked_transfer_id 有值。
// 2026-06-12 之後（最新版 rpc_approve_restock_to_transfer，20260714000040:260-270）：
//   只 UPDATE status，並把 linked_transfer_id 明確設成 NULL → 貨完全沒動，
//   改成排進「派貨工作台」挑貨、建撿貨單，最後按「派貨出倉」才真的出庫。
//
// ⇒ 同一個 status，對這兩批單要講的話不一樣。判準就是 linked_transfer_id 有沒有值
//   （派貨工作台的 v_picking_demand_no_po 也是用同一個判準挑單，20260612000040:70-71）。
// ⛔ 不要把兩者併成同一句話 —— 任何一句對另一批都是假的。
// ============================================================

/** 舊流程（2026-06-12 以前）真的直接出過貨的那批單專用字 */
export const RESTOCK_LEGACY_SHIPPED_LABEL = "已派庫存（舊流程）";

/**
 * 取補貨申請狀態的中文字。
 *
 * 各頁對其他狀態的用字刻意不同（例：approved_pr 有「已轉採購」「已下單」「已下訂」三種寫法），
 * 所以 label 表由呼叫端自己帶進來，這支只負責 approved_transfer 的新舊分流。
 *
 * @param linkedTransferId 有值＝舊流程直派過的單；null＝新流程（貨還在總倉、等派貨工作台挑）
 */
export function restockStatusLabel(
  status: string,
  linkedTransferId: number | null | undefined,
  labels: Record<string, string>,
): string {
  if (status === "approved_transfer" && linkedTransferId != null) {
    return RESTOCK_LEGACY_SHIPPED_LABEL;
  }
  return labels[status] ?? status;
}
