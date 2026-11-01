// 預估把握度的小圖示（推薦系統，取代「信心高 / 中 / 低」文字；Alex 2026-11-01）：
// 往上的角括號疊起來 —— 三個紅色 = 最有把握（賣過同款）、兩個橘色 = 有很像的、一個灰色 = 只能參考同類。

type Level = "high" | "mid" | "low";

const COUNT: Record<Level, number> = { high: 3, mid: 2, low: 1 };
const COLOR: Record<Level, string> = {
  high: "text-red-500 dark:text-red-400",
  mid: "text-orange-400 dark:text-orange-300",
  low: "text-zinc-400 dark:text-zinc-500",
};
const TITLE: Record<Level, string> = {
  high: "把握度高：賣過同款",
  mid: "把握度中：有很像的商品賣過",
  low: "把握度低：只能參考同類商品",
};

export default function ConfidenceChevrons({ level, className = "" }: { level: Level | null | undefined; className?: string }) {
  if (!level) return null;
  const n = COUNT[level];
  return (
    <span className={`inline-flex shrink-0 items-center ${COLOR[level]} ${className}`} title={TITLE[level]} aria-label={TITLE[level]}>
      <svg viewBox="0 0 12 14" width="13" height="16" fill="none" stroke="currentColor" strokeWidth="2"
           strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {Array.from({ length: n }, (_, i) => {
          // 由下往上疊：一個在最下面，三個時佔滿
          const y = 12 - i * 4;
          return <path key={i} d={`M2 ${y} L6 ${y - 3} L10 ${y}`} />;
        })}
      </svg>
    </span>
  );
}
