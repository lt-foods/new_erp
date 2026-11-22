/**
 * 特價牌：黃底、粗紅字的賣場手寫 POP 風格（老闆 2026-11-22：「像唐吉訶德那種特價然後劃掉」）。
 * 上排小字是原價（黑字、紅線劃掉），下排大字是現在的售價。
 *
 * 只在「有原價、而且原價比售價高」時用；沒有原價的商品維持原本的品牌漸層價格，
 * 整頁才不會每張卡都是黃牌（那樣就沒有哪一張是特價了）。
 *
 * 顏色寫死、不跟品牌色走：這塊牌子要的就是從粉色系的頁面裡跳出來。
 * 只用老手機也有的 CSS（-webkit-text-stroke / transform / box-shadow；最低支援 Safari 13.1）。
 */
type Size = "sm" | "md" | "lg";

const SIZES: Record<Size, { pad: string; price: string; unit: string; orig: string; badge: string; stroke: string }> = {
  // 商品頁的規格列、下單視窗
  sm: { pad: "px-2 py-1", price: "text-[20px]", unit: "text-[12px]", orig: "text-[12px]", badge: "text-[10px] px-1", stroke: "0.5px" },
  // 商城兩欄卡片
  md: { pad: "px-2 py-1.5", price: "text-[26px]", unit: "text-[13px]", orig: "text-[12px]", badge: "text-[10px] px-1", stroke: "0.6px" },
  // 限時專區大卡
  lg: { pad: "px-3 py-2", price: "text-[32px]", unit: "text-[15px]", orig: "text-[14px]", badge: "text-[11px] px-1.5", stroke: "0.8px" },
};

export default function SalePriceTag({
  price,
  original,
  suffix,
  size = "md",
  className = "",
}: {
  /** 現在的售價 */
  price: number;
  /** 原價（呼叫端要先確認它比 price 高） */
  original: number;
  /** 價格後面的小字，例如「起」 */
  suffix?: string;
  size?: Size;
  className?: string;
}) {
  const s = SIZES[size];
  return (
    <span
      className={`inline-flex flex-col items-start rounded-[6px] border-2 border-[#111] bg-[#ffe600] leading-none ${s.pad} ${className}`}
      style={{ transform: "rotate(-2deg)", boxShadow: "2px 2px 0 #111" }}
    >
      <span className="flex items-center gap-1">
        <span className={`rounded-[3px] bg-[#e60012] py-[2px] font-black text-white ${s.badge}`}>特價</span>
        <span
          className={`font-bold tabular-nums text-[#111] ${s.orig}`}
          style={{ textDecoration: "line-through", textDecorationColor: "#e60012", textDecorationThickness: "2px" }}
        >
          ${original.toLocaleString()}
        </span>
      </span>
      <span
        className={`mt-1 font-black tabular-nums text-[#e60012] ${s.price}`}
        style={{ WebkitTextStroke: `${s.stroke} #e60012`, letterSpacing: "-0.02em" }}
      >
        ${price.toLocaleString()}
        {suffix ? <span className={`ml-0.5 font-black ${s.unit}`} style={{ WebkitTextStroke: "0" }}>{suffix}</span> : null}
      </span>
    </span>
  );
}
