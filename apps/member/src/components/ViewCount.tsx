/**
 * 商品瀏覽次數：眼睛 icon + 數字。
 *
 * 商城列表卡片與商品詳情頁共用同一個樣式 —— 兩邊各畫一份的話，之後調字級 /
 * 顏色只會改到其中一邊。
 */
export default function ViewCount({
  count,
  size = "sm",
  className = "",
}: {
  count: number | null | undefined;
  /** sm = 列表卡片、md = 商品詳情頁 */
  size?: "sm" | "md";
  className?: string;
}) {
  // 0 也照顯示。新功能上線時每個商品都還是 0，藏起來的話整個列表看起來
  // 就像功能沒做（2026-08-05 就是這樣被回報「App 上面沒有看到」）。
  const raw = Number(count ?? 0);
  const n = Number.isFinite(raw) && raw > 0 ? raw : 0;
  const isMd = size === "md";
  return (
    <span
      className={`inline-flex items-center gap-1 text-[var(--secondary-label)] ${
        isMd ? "text-[13px]" : "text-[12px]"
      } ${className}`}
      title={`${n.toLocaleString()} 次瀏覽`}
    >
      <EyeIcon className={isMd ? "h-4 w-4" : "h-3.5 w-3.5"} />
      <span className="tabular-nums">{n.toLocaleString()}</span>
      {isMd && <span>次瀏覽</span>}
    </span>
  );
}

export function EyeIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      aria-hidden
      className={`shrink-0 ${className}`}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"
      />
      <circle cx="12" cy="12" r="3" />
    </svg>
  );
}
