/**
 * 「已訂購 N 件」徽章：火焰 icon + 品牌色 pill，讓訂單量一眼看得到（社群證明）。
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
  const sizeCls =
    size === "lg"
      ? "gap-1.5 px-3 py-1 text-[15px]"
      : size === "md"
        ? "gap-1 px-2.5 py-0.5 text-[14px]"
        : "gap-1 px-2 py-0.5 text-[12px]";
  const iconCls =
    size === "lg" ? "h-4 w-4" : size === "md" ? "h-3.5 w-3.5" : "h-3 w-3";
  return (
    <span
      className={`inline-flex items-center whitespace-nowrap rounded-full bg-[var(--brand-soft)] font-semibold text-[var(--brand-strong)] ${sizeCls} ${className}`}
      title={`已訂購 ${n.toLocaleString()} 件`}
    >
      <FlameIcon className={iconCls} />
      <span>
        已訂購 <span className="font-extrabold tabular-nums">{n.toLocaleString()}</span> 件
      </span>
    </span>
  );
}

export function FlameIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      aria-hidden
      className={`shrink-0 ${className}`}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5Z"
      />
    </svg>
  );
}
