/**
 * 品項縮圖（商品主圖，沒有就畫購物袋 placeholder）。
 *
 * 團購商品常常沒上傳自己的圖，只有開團封面 —— 呼叫端可以用
 * `url={it.image_url ?? campaign_cover_url}` 退一層，兩張都沒有才會看到 placeholder。
 * 商品頁與訂單卡共用同一支，placeholder 的樣子才不會各長各的。
 */
export default function SkuThumb({
  url,
  /** 斷貨 / 已取消的行：跟旁邊的刪除線一起淡掉 */
  muted = false,
  className = "h-14 w-14",
}: {
  url: string | null;
  muted?: boolean;
  className?: string;
}) {
  if (url) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={url}
        alt=""
        loading="lazy"
        className={`${className} shrink-0 rounded-xl bg-[var(--brand-soft)]/40 object-cover ${
          muted ? "opacity-45 grayscale" : ""
        }`}
      />
    );
  }
  return (
    <div
      className={`${className} flex shrink-0 items-center justify-center rounded-xl bg-[var(--brand-soft)] text-[var(--brand)] ${
        muted ? "opacity-45 grayscale" : ""
      }`}
    >
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.4} className="h-6 w-6">
        <path strokeLinecap="round" strokeLinejoin="round" d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z" />
        <path strokeLinecap="round" strokeLinejoin="round" d="M9 8V6.5a3 3 0 0 1 6 0V8" />
      </svg>
    </div>
  );
}
