// 取貨畫面 / 小白單的品項顯示名
//
// 一般團購單的活動名稱 ≈ 商品名（線上 83,351 筆品項有 82,176 筆的 campaign.name
// 就含著 skus.product_name），所以品項只印規格（「一包」「(A)高麗菜」）剛剛好，
// 80mm 單也塞得下。
//
// 但轉貨補單 / 補貨申請的單全部掛在共用活動「【內部】補貨申請」
// (campaign_no = __INTERNAL_RESTOCK__) 底下，活動名稱一個商品字都沒有 ——
// 只印規格的話整張取貨單就變成「【內部】補貨申請 / 一包 × 2」，
// 店員看不出要拿什麼貨（2026-08-11 回報：RR / TF 補單列印看不到品項）。
//
// 規則：活動名稱已經帶到商品名 → 維持只顯示規格；沒帶到 → 補上商品名。

export type SkuNameLike = {
  product_name?: string | null;
  variant_name?: string | null;
} | null | undefined;

// 比對用正規化：去掉半形/全形空白再比，避免 " Chuli 初梨…" 這種前後空白的資料
// 被當成跟活動名稱不同（線上真的有）。
function norm(s: string): string {
  return s.replace(/[\s　]+/g, "").toLowerCase();
}

export function itemDisplayName(sku: SkuNameLike, campaignName?: string | null): string {
  const product = (sku?.product_name ?? "").trim();
  const variant = (sku?.variant_name ?? "").trim();
  if (!product) return variant || "—";
  if (!variant || norm(variant) === norm(product)) return product;
  const campaign = (campaignName ?? "").trim();
  if (campaign && norm(campaign).includes(norm(product))) return variant;
  return `${product} / ${variant}`;
}
