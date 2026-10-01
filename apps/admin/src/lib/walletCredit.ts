// ============================================================
// 儲值金「尚可抵用」的算法 —— 分批取貨時每一批都要用這一支
//
// customer_orders.wallet_paid_amount 是**整張單累計**扣過的儲值金，不是「這一批」
// 的。第一批取貨扣了 $79 之後，第二批如果再把整個 $79 拿去抵本批金額，就會把
// 已經被第一批用掉的錢又抵一次（2026-10-01 古華 黃淑惠：第 3 批扣 $79、第 4 批
// $456 的貨被印成「應付 $377」）。
//
// 正確口徑：已扣儲值金先扣掉「已取走品項已付的部分」，剩下的才是還能抵給
// 未取品項的額度。
//   creditLeft = max(0, wallet_paid_amount − 已取品項應收)
// 整張單一次取完、或還沒取過任何品項時，creditLeft = wallet_paid_amount，行為不變；
// 整張單先用儲值金付清（訂單頁「儲值金結帳」）再分批取時，前面幾批把額度用掉，
// 後面的批才開始收現。
//
// DB 側同一條規則：v_customer_order_summary.outstanding_amount
//   = LEAST(未取品項應收, balance_due)（20261002010000）。
// ============================================================

type PricedLine = {
  qty: number;
  unit_price: number;
  discount_amount?: number | null;
  discount_percent?: number | null;
};

/** 單行小計（含行折扣），與 PickupDialog.lineSubQty / print 頁 lineSub 同一套 */
export function lineSubtotal(it: PricedLine, qty: number = Number(it.qty)): number {
  const fullQty = Number(it.qty) || 0;
  const ratio = fullQty > 0 ? qty / fullQty : 0;
  const gross = qty * Number(it.unit_price);
  const afterPct = gross * (1 - Number(it.discount_percent ?? 0) / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - Number(it.discount_amount ?? 0) * ratio);
}

/**
 * 已取走品項的應收（套整單折扣%，**不**減整單折扣金額）。
 * 整單折扣金額只在整張單上減一次，而取貨結帳算每一批應收時本來就會各自減掉它，
 * 所以這裡不再減，否則同一筆折扣會被算兩次。
 */
export function pickedPayable(items: (PricedLine & { status: string })[], discountPercent: number): number {
  const sub = items
    .filter((it) => it.status === "picked_up")
    .reduce((s, it) => s + lineSubtotal(it), 0);
  return Math.max(0, Math.round(sub * (1 - Number(discountPercent ?? 0) / 100)));
}

/** 已扣儲值金裡還沒被已取品項用掉的部分 */
export function walletCreditLeft(walletPaid: number, pickedPayableAmount: number): number {
  return Math.max(0, Number(walletPaid ?? 0) - pickedPayableAmount);
}
