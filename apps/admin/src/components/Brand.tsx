// Groupo 購寶 品牌元件 — 草寫 G 標誌（G2）+ 草寫字標 + 中文副標。
// 標誌為自繪 SVG（G2 變體）、字標用 script 字型（--font-script，layout 注入）。
// 主色 orange-600。推廣頁、註冊頁共用，favicon 見 public/groupo-mark.svg。

// G2：起筆入鋒、橫桿收小鉤的草寫 G（viewBox 0 0 64 64，stroke-based）
const G2_PATH =
  "M50 24 c -2 -4 -9 -6 -15 -5 C 21 21, 14 33, 19 43 c 4 8 14 11 22 6 c 5 -3 7 -8 5 -13 c -1 -2 -3 -3 -5 -2 l -6 1";

export function GroupoMark({ className = "h-7 w-7" }: { className?: string }) {
  return (
    <span className={`inline-flex shrink-0 items-center justify-center rounded-[28%] bg-orange-600 ${className}`}>
      <svg viewBox="0 0 64 64" fill="none" className="h-[70%] w-[70%]" aria-hidden>
        <path d={G2_PATH} stroke="#fff" strokeWidth={6.5} strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </span>
  );
}

const SIZES = {
  sm: { mark: "h-6 w-6", en: "text-[22px]", zh: "text-xs" },
  md: { mark: "h-8 w-8", en: "text-[30px]", zh: "text-sm" },
  lg: { mark: "h-10 w-10", en: "text-[40px]", zh: "text-base" },
} as const;

export function GroupoWordmark({
  size = "md",
  className = "",
}: {
  size?: keyof typeof SIZES;
  className?: string;
}) {
  const s = SIZES[size];
  return (
    <span className={`inline-flex items-center gap-2 ${className}`}>
      <GroupoMark className={s.mark} />
      <span
        style={{ fontFamily: "var(--font-script)" }}
        className={`${s.en} font-bold leading-none tracking-tight text-zinc-900 dark:text-zinc-50`}
      >
        Groupo
      </span>
      <span className={`${s.zh} self-end pb-1 font-medium text-zinc-400 dark:text-zinc-500`}>
        購寶
      </span>
    </span>
  );
}
