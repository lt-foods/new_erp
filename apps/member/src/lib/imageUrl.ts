/**
 * Storage 圖片縮圖網址。
 *
 * 2026-10-02 Supabase 因 cached egress 超過方案額度把整個專案停掉（登入頁紅字
 * `exceed_cached_egress_quota`）。元凶是會員端每張 <img> 都直接吃 products bucket 的
 * 原圖：平均 334 kB、最大 5 MB，/shop 一次列 142 團 ≈ 52 MB／每次進頁。
 *
 * 這裡把 `/storage/v1/object/public/<bucket>/<path>` 改寫成
 * `/storage/v1/render/image/public/<bucket>/<path>?width=…&quality=…`，由 Supabase
 * Image Transformation 在 CDN 邊緣縮圖（實測 400px 寬 ≈ 54 kB，且會自動轉 WebP）。
 * 非 storage 的網址（LINE 大頭貼、blob:、外部 CDN）原樣回傳；已帶 query string 的也不動。
 *
 * width 挑法：CSS 寬 × 2（Retina）。列表卡 800、方形小卡 480、縮圖 240、全幅大圖 1080、放大 1600。
 */
const OBJECT_PUBLIC = "/storage/v1/object/public/";

export function thumb(
  url: string | null | undefined,
  width: number,
  quality = 75,
): string | null {
  if (!url) return null;
  const i = url.indexOf(OBJECT_PUBLIC);
  if (i < 0 || url.includes("?")) return url;
  const rest = url.slice(i + OBJECT_PUBLIC.length);
  // 動圖經 render 會變靜態，保留原圖
  if (/\.gif$/i.test(rest)) return url;
  return `${url.slice(0, i)}/storage/v1/render/image/public/${rest}?width=${width}&quality=${quality}`;
}
