/**
 * 後台統一的 inline spinner（取代裸文字「載入中…」）。
 * 用 currentColor —— 放在哪就繼承該處文字色（多半 text-zinc-400/500），
 * 與 SearchSpinner 視覺一致。需要區塊置中時用 <LoadingBlock />。
 */
export default function Spinner({
  size = 16,
  className = "",
}: {
  size?: number;
  className?: string;
}) {
  return (
    <svg
      className={`animate-spin ${className}`}
      style={{ width: size, height: size }}
      viewBox="0 0 24 24"
      fill="none"
      role="status"
      aria-label="載入中"
    >
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
  );
}

/** 區塊置中的載入態（表格 body / 卡片區），純轉圈不帶文字。 */
export function LoadingBlock({
  size = 24,
  className = "",
}: {
  size?: number;
  className?: string;
}) {
  return (
    <div
      className={`flex items-center justify-center p-6 text-zinc-400 ${className}`}
    >
      <Spinner size={size} />
    </div>
  );
}
