/**
 * 「已訂購 N 件」統計：純排版層次 —— 數字大而粗（深色）、「已訂購 / 件」小號淡灰。
 * 不用色塊 pill / icon（試過火焰＋粉底 pill，太像促銷貼紙、沒質感），
 * 靠字重與字級對比讓訂單量安靜但醒目，社群證明的呈現比照精品電商的統計數字。
 *
 * 商城列表卡片（grid / hero）、限時專區橫列、商品詳情頁共用同一個樣式 ——
 * 各頁各畫一份的話，之後調字級 / 顏色只會改到其中一邊（同 ViewCount 的理由）。
 * 顯示條件維持既有行為：count > 0 才渲染，0 / null 一律不顯示。
 */
export default function OrderedCount({
  count,
  size = "sm",
  className = "",
}: {
  count: number | null | undefined;
  /** sm = 列表卡片、md = hero 卡片 / 橫列、lg = 商品詳情頁 */
  size?: "sm" | "md" | "lg";
  className?: string;
}) {
  const n = Number(count ?? 0);
  if (!Number.isFinite(n) || n <= 0) return null;
  const numCls =
    size === "lg" ? "text-[20px]" : size === "md" ? "text-[17px]" : "text-[15px]";
  const labelCls = size === "lg" ? "text-[13px]" : "text-[12px]";
  return (
    <span
      className={`inline-flex items-baseline gap-1 whitespace-nowrap ${className}`}
      title={`已訂購 ${n.toLocaleString()} 件`}
    >
      <span className={`${labelCls} font-medium text-[var(--secondary-label)]`}>
        已訂購
      </span>
      <span
        className={`${numCls} font-bold tabular-nums leading-none text-[var(--foreground)]`}
      >
        {n.toLocaleString()}
      </span>
      <span className={`${labelCls} font-medium text-[var(--secondary-label)]`}>
        件
      </span>
    </span>
  );
}
