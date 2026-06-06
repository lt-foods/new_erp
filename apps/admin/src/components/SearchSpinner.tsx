"use client";

/**
 * 搜尋進行中的轉圈圈 indicator。
 * 放在 `relative` 的搜尋輸入框容器內，預設貼齊右側垂直置中。
 * active=false 時不渲染任何東西。
 */
export default function SearchSpinner({
  active,
  className = "",
}: {
  active: boolean;
  className?: string;
}) {
  if (!active) return null;
  return (
    <span
      className={`pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-zinc-400 ${className}`}
      aria-label="搜尋中"
      role="status"
    >
      <svg className="h-4 w-4 animate-spin" viewBox="0 0 24 24" fill="none" aria-hidden>
        <circle
          cx="12"
          cy="12"
          r="10"
          stroke="currentColor"
          strokeWidth="3"
          className="opacity-25"
        />
        <path
          d="M4 12a8 8 0 0 1 8-8"
          stroke="currentColor"
          strokeWidth="3"
          strokeLinecap="round"
        />
      </svg>
    </span>
  );
}
