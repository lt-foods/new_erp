/** 對齊 v_customer_order_summary.settlement_no：S-<訂單id補零8位>-<店short_code>。
 *  會員端「結單」頁顯示的就是這一組，改格式要兩邊一起動。 */
export function settlementNo(orderId: number, storeShortCode?: string | null): string {
  return `S-${String(orderId).padStart(8, "0")}-${storeShortCode ?? "XX"}`;
}
