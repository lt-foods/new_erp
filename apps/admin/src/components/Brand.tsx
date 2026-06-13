// Groupo 購寶 品牌元件 — 標誌與字標同一個手寫 G（Caveat）+ 中文副標。
// 標誌：橘底白色「G」，用 Caveat 字型（--font-script，layout 注入）渲染，
//       和字標的 Groupo 字首完全一致；SVG <text> 隨容器尺寸自動縮放。
// favicon 見 public/groupo-mark.svg（Caveat G 已轉成 path、不依賴字型）。
// 主色 brand-600。固定淺暖色（不隨系統深色模式變化，對外行銷一致）。

export function GroupoMark({ className = "h-7 w-7" }: { className?: string }) {
  return (
    <span className={`inline-flex shrink-0 items-center justify-center rounded-[28%] bg-brand-600 ${className}`}>
      <svg viewBox="0 0 64 64" className="h-full w-full" aria-hidden>
        <text
          x="33"
          y="47"
          textAnchor="middle"
          fill="#fff"
          style={{ fontFamily: "var(--font-script)", fontWeight: 700, fontSize: "48px" }}
        >
          G
        </text>
      </svg>
    </span>
  );
}

// Caveat 視覺偏小，en 字級比一般 sans 放大一級
const SIZES = {
  sm: { mark: "h-6 w-6", en: "text-[26px]", zh: "text-xs" },
  md: { mark: "h-8 w-8", en: "text-[34px]", zh: "text-sm" },
  lg: { mark: "h-10 w-10", en: "text-[46px]", zh: "text-base" },
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
        className={`${s.en} font-bold leading-none tracking-tight text-stone-900`}
      >
        Groupo
      </span>
      <span className={`${s.zh} self-end pb-1 font-medium text-stone-400`}>
        購寶
      </span>
    </span>
  );
}
