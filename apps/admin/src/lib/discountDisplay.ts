// ============================================================
// 折後金額 —— 只給畫面「多顯示一行」用，不參與任何收款／扣款計算
//
// 取貨頁卡片、會員訂單列表原本的金額只算「數量 × 單價」（或只套整單折扣），
// 品項折扣沒算進去：例 20 × $259、品項打 5% → 收據應收 $4921，畫面卻是 $5180。
// 這支照取貨收據（/pickup/print 的 batchPayOf）同一式算出折後金額，讓畫面在
// 原本的數字旁邊多標一行「折扣 −$X → 折後 $Y」；原本顯示的數字一個都不改。
//
//   net      = max(0, round(Σ 品項小計 × (1 − 整單% / 100) − 整單$))
//   品項小計 = lineSubtotal（先套品項%，再減品項$；只計價部分數量時品項$ 按比例）
//   gross    = Σ 計價數量 × 單價
//   discount = gross − net
// gross / discount 只去掉浮點雜訊到小數 4 位（與 unit_price NUMERIC(18,4) 同精度），
// 不是四捨五入到整數。
// ============================================================
import { lineSubtotal } from "./walletCredit";

export type DiscountDisplayLine = {
  qty: number;
  unit_price: number;
  discount_percent?: number | null;
  discount_amount?: number | null;
  /** 這次計價的數量（例：扣掉未取退貨後的量）；不給就用 qty */
  billQty?: number;
};

export type DiscountDisplayOrder = {
  discount_percent?: number | null;
  discount_amount?: number | null;
};

const round4 = (n: number) => Math.round(n * 10000) / 10000;

export function discountedTotal(
  order: DiscountDisplayOrder,
  items: DiscountDisplayLine[],
): { gross: number; net: number; discount: number } {
  let gross = 0;
  let sub = 0;
  for (const it of items) {
    const q = it.billQty != null ? Number(it.billQty) : Number(it.qty);
    gross += q * Number(it.unit_price);
    sub += lineSubtotal(it, q);
  }
  const pct = Number(order?.discount_percent ?? 0);
  const net = Math.max(0, Math.round(sub * (1 - pct / 100) - Number(order?.discount_amount ?? 0)));
  return { gross: round4(gross), net, discount: round4(gross - net) };
}

/**
 * 整單或任一品項有設折扣（% 或 $）。畫面只在這個成立時才畫「折扣 → 折後」那一行：
 * 單價、數量可以有小數，沒設折扣的單 net（四捨五入到整數）也可能跟原本的金額差幾毛，
 * 不能因此冒出一行「折扣」。
 */
export function hasAnyDiscount(order: DiscountDisplayOrder, items: DiscountDisplayLine[]): boolean {
  const pos = (v: number | null | undefined) => Number(v ?? 0) > 0;
  return (
    pos(order?.discount_percent) ||
    pos(order?.discount_amount) ||
    items.some((it) => pos(it.discount_percent) || pos(it.discount_amount))
  );
}
