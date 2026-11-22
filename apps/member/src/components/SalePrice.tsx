/**
 * 特價數字（老闆 2026-11-22 給的樣稿）：
 *   - 售價：粗紅字，後面墊一抹黃色的筆刷底
 *   - 原價：灰色斜體，壓一條紅色斜線
 *   - 右上角兩撇黃色的小閃光
 *
 * 只在「有原價、而且原價比售價高」時用；沒有原價的商品維持原本的品牌色價格
 * （整頁都是特價樣式，就沒有哪一個是特價了）。
 *
 * 前一版做過黃底黑框的整塊牌子（唐吉訶德風），老闆看過說不要 —— 這一版是「只強調數字」，
 * 沒有外框、沒有底牌，不要再往那個方向加東西。
 *
 * 兩種排法：
 *   stack   原價在上、售價在下（商城卡片：左邊還要放已訂購／瀏覽數，橫向沒有位置）
 *   inline  售價在左、原價在右（商品頁規格列：列高不能長太多）
 *
 * 筆刷底與閃光是內嵌 SVG（不用圖檔、不用濾鏡）；顏色寫死，不跟品牌色走。
 */
type Size = "sm" | "md" | "lg";

const SIZES: Record<Size, { price: string; suffix: string; orig: string; pad: string; spark: number }> = {
  sm: { price: "text-[22px]", suffix: "text-[12px]", orig: "text-[13px]", pad: "px-1.5 py-0.5", spark: 12 },
  // 兩欄卡片內寬只有 ~150px：26px 的兩三位數價格才放得進「已訂購」右邊（樣稿的比例）
  md: { price: "text-[26px]", suffix: "text-[12px]", orig: "text-[14px]", pad: "px-1.5 py-0.5", spark: 14 },
  lg: { price: "text-[38px]", suffix: "text-[15px]", orig: "text-[17px]", pad: "px-2.5 py-1", spark: 20 },
};

/** 售價後面那一抹黃色筆刷：三筆粗細不一、稍微錯開的橫刷，拉伸到跟數字一樣寬。 */
function Brush() {
  return (
    <svg
      viewBox="0 0 100 40"
      preserveAspectRatio="none"
      aria-hidden
      className="pointer-events-none absolute inset-0 h-full w-full"
    >
      <g fill="none" stroke="#ffe680" strokeLinecap="round">
        <path d="M9 13 C 30 9, 62 10, 93 12" strokeWidth="13" />
        <path d="M5 22 C 28 19, 66 21, 96 20" strokeWidth="15" />
        <path d="M11 31 C 36 28, 60 31, 90 29" strokeWidth="12" />
      </g>
    </svg>
  );
}

/** 右上角的兩撇小閃光 */
function Spark({ size }: { size: number }) {
  return (
    <svg
      viewBox="0 0 20 20"
      width={size}
      height={size}
      aria-hidden
      className="pointer-events-none absolute"
      style={{ right: -size * 0.55, top: -size * 0.5 }}
    >
      <g fill="none" stroke="#ffc928" strokeWidth="3.2" strokeLinecap="round">
        <path d="M5 13 L8 4" />
        <path d="M11 16 L17 9" />
      </g>
    </svg>
  );
}

function Original({ value, className }: { value: number; className: string }) {
  return (
    <span className={`relative inline-block font-extrabold italic tabular-nums leading-none text-[#7a7a7a] ${className}`}>
      ${value.toLocaleString()}
      {/* 紅色斜線：比數字寬一點、往右上斜 */}
      <span
        aria-hidden
        className="pointer-events-none absolute left-[-12%] top-1/2 h-[2px] w-[124%] rounded-full bg-[#e8352e]"
        style={{ transform: "translateY(-50%) rotate(-9deg)" }}
      />
    </span>
  );
}

export default function SalePrice({
  price,
  original,
  suffix,
  size = "md",
  layout = "stack",
  className = "",
}: {
  /** 現在的售價 */
  price: number;
  /** 原價（呼叫端要先確認它比 price 高） */
  original: number;
  /** 價格後面的小字，例如「起」 */
  suffix?: string;
  size?: Size;
  layout?: "stack" | "inline";
  className?: string;
}) {
  const s = SIZES[size];
  const now = (
    <span className={`relative inline-block ${s.pad}`}>
      <Brush />
      <span className={`relative font-black tabular-nums leading-none text-[#d5121e] ${s.price}`} style={{ letterSpacing: "-0.02em" }}>
        ${price.toLocaleString()}
        {suffix ? <span className={`ml-0.5 font-extrabold ${s.suffix}`}>{suffix}</span> : null}
      </span>
      <Spark size={s.spark} />
    </span>
  );

  if (layout === "inline") {
    return (
      <span className={`inline-flex items-center gap-2 ${className}`}>
        {now}
        <Original value={original} className={s.orig} />
      </span>
    );
  }
  return (
    <span className={`inline-flex flex-col items-end ${className}`}>
      <Original value={original} className={`mb-0.5 mr-2 ${s.orig}`} />
      {now}
    </span>
  );
}
