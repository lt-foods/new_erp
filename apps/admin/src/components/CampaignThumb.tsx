// 開團商品縮圖（列表 / 加單頁共用）。url 由 lib/campaignCover.campaignCoverUrl 解析；
// 無圖時顯示品牌色購物袋佔位框。固定 64px（h-16 w-16）。

export function CampaignThumb({ url, name }: { url: string | null; name: string }) {
  if (!url) {
    return (
      <div className="flex h-16 w-16 items-center justify-center rounded-md border border-zinc-200 bg-zinc-50 text-zinc-300 dark:border-zinc-800 dark:bg-zinc-900">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5} className="h-7 w-7">
          <path strokeLinecap="round" strokeLinejoin="round" d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z" />
          <path strokeLinecap="round" strokeLinejoin="round" d="M9 8V6.5a3 3 0 0 1 6 0V8" />
        </svg>
      </div>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={url}
      alt={name}
      loading="lazy"
      className="h-16 w-16 rounded-md border border-zinc-200 object-cover dark:border-zinc-800"
    />
  );
}
