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

/** 預估人數的數字顏色，跟圖示同一個顏色（沒有把握度時維持一般字色） */
export function confidenceTextColor(level: Level | null | undefined): string {
  return level ? COLOR[level] : "text-zinc-800 dark:text-zinc-100";
}

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

const DOT: Record<Level, string> = {
  high: "bg-red-500 dark:bg-red-400",
  mid: "bg-orange-400 dark:bg-orange-300",
  low: "bg-zinc-400 dark:bg-zinc-500",
};

/**
 * 預估範圍條：左邊最少、右邊最多，中間的點是預估落在範圍裡的位置（點的顏色同把握度）。
 * 範圍是回測裡八成實際結果會落在的區間。
 */
export function PredictRange({ low, high, value, level }: {
  low: number | null | undefined; high: number | null | undefined; value: number | null | undefined; level: Level | null | undefined;
}) {
  if (low == null || high == null) return null;
  const pos = value == null || high <= low ? 50 : Math.min(100, Math.max(0, ((value - low) / (high - low)) * 100));
  return (
    <span className="inline-flex items-center gap-1 whitespace-nowrap text-[10px] tabular-nums text-zinc-400 dark:text-zinc-500"
          title={`八成會落在 ${low}～${high} 位之間`}>
      <span>{low}</span>
      <span className="relative inline-block h-1 w-10 rounded-full bg-zinc-200 dark:bg-zinc-700">
        <span className={`absolute top-1/2 h-2 w-2 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-white dark:ring-zinc-900 ${level ? DOT[level] : "bg-zinc-500"}`}
              style={{ left: `${pos}%` }} />
      </span>
      <span>{high}</span>
    </span>
  );
}
