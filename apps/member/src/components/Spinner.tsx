/**
 * 全站統一的 iOS 風 spinner：淡灰底環 + 品牌色弧線旋轉。
 * - 一般淺底用 default（品牌玫瑰弧）
 * - 彩色 CTA 鈕內用 onColor（白弧），避免品牌色壓在品牌漸層上看不清
 */
export default function Spinner({
  size = 20,
  onColor = false,
  className = "",
}: {
  size?: number;
  onColor?: boolean;
  className?: string;
}) {
  const track = onColor ? "rgba(255,255,255,0.4)" : "#7676801f";
  const arc = onColor ? "#ffffff" : "var(--brand-strong)";
  return (
    <svg
      className={`animate-spin ${className}`}
      style={{ width: size, height: size }}
      viewBox="0 0 24 24"
      fill="none"
      role="status"
      aria-label="載入中"
    >
      <circle cx="12" cy="12" r="9" stroke={track} strokeWidth="2.5" />
      <path
        d="M12 3a9 9 0 0 1 9 9"
        stroke={arc}
        strokeWidth="2.5"
        strokeLinecap="round"
      />
    </svg>
  );
}

/**
 * 整頁 / 區塊置中的載入畫面（取代裸文字「載入中…」），讓首屏更像原生 App。
 * 預設不帶文字 —— 原生 App 多半只轉圈不寫字；需要語境時才傳 label。
 */
export function LoadingScreen({
  label,
  className = "min-h-[55vh]",
}: {
  label?: string;
  className?: string;
}) {
  return (
    <div
      className={`flex flex-col items-center justify-center gap-3 ${className}`}
    >
      <Spinner size={30} />
      {label ? (
        <p className="text-[14px] text-[var(--secondary-label)]">{label}</p>
      ) : null}
    </div>
  );
}
