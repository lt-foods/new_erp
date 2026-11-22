// 商品「介紹影片連結」欄位用的後台小工具（解析本體在 videoEmbed.ts，那份跟會員端逐字相同，不要往裡面加東西）。
import { isTikTokShortLink, parseVideoEmbed, safeHttpsUrl, tiktokPlayerUrl } from "./videoEmbed";

export type VideoLinkStatus =
  | { kind: "empty" }
  /** 會員商品頁可以直接播 */
  | { kind: "embed"; label: string }
  /** TikTok 分享短連結：存檔前要先換成帶影片代號的網址 */
  | { kind: "tiktok_short" }
  /** 合法的 https 連結，但不是認得的影片網址 → 客人點了會跳去開那個連結 */
  | { kind: "link_only" }
  | { kind: "invalid" };

export function videoLinkStatus(raw: string): VideoLinkStatus {
  const s = raw.trim();
  if (!s) return { kind: "empty" };
  const safe = safeHttpsUrl(s);
  if (!safe || /\s/.test(s)) return { kind: "invalid" };
  const embed = parseVideoEmbed(safe);
  if (embed) return { kind: "embed", label: embed.label };
  if (isTikTokShortLink(safe)) return { kind: "tiktok_short" };
  return { kind: "link_only" };
}

/**
 * TikTok App 按「分享 → 複製連結」拿到的是短連結（vt.tiktok.com/…），裡面沒有影片代號、嵌不了。
 * 問 TikTok 官方的 oEmbed（有開 CORS，瀏覽器可以直接打）換成影片代號，回我們要存的播放器網址。
 * 換不到（連結失效、影片不公開、網路不通）回 null —— 呼叫端照原樣存，客人點了改成開連結。
 */
export async function resolveTikTokShortLink(raw: string): Promise<string | null> {
  const safe = safeHttpsUrl(raw);
  if (!safe || !isTikTokShortLink(safe)) return null;
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 8000);
    const res = await fetch(`https://www.tiktok.com/oembed?url=${encodeURIComponent(safe)}`, { signal: ctl.signal });
    clearTimeout(timer);
    if (!res.ok) return null;
    const data = (await res.json()) as { embed_product_id?: unknown };
    return typeof data.embed_product_id === "string" ? tiktokPlayerUrl(data.embed_product_id) : null;
  } catch {
    return null;
  }
}
