// 商品介紹影片：把後台貼的連結（IG Reel / TikTok / YouTube / Facebook）換成可以嵌在頁面裡播的網址。
//
// ⚠ 這個檔有兩份，內容必須一模一樣：
//     apps/member/src/lib/videoEmbed.ts   會員商品頁用來播
//     apps/admin/src/lib/videoEmbed.ts    後台貼連結時用來提示「這個連結能不能直接播」
//   兩個 app 沒有共用套件，只能各放一份；apps/admin/src/lib/videoEmbed.test.mjs 會比對兩份
//   是不是逐字相同，改一邊忘了另一邊測試就紅。
//
// 安全：iframe 的 src 只會是下面四個網站自己的嵌入網址（主機名寫死、影片代號只收英數與 -_），
// 後台存什麼進來都不會變成「把任意網址嵌進會員頁」。認不得的連結回 null，
// 畫面改成「到原網站開啟」的一般連結（一樣只收 https）。

export type VideoProvider = "youtube" | "instagram" | "tiktok" | "facebook";

export type VideoEmbed = {
  provider: VideoProvider;
  /** 給客人看的網站名稱 */
  label: string;
  /** iframe src */
  embedUrl: string;
  /** 直式（9:16）還是橫式（16:9）：決定播放框的形狀 */
  portrait: boolean;
};

const PROVIDER_LABEL: Record<VideoProvider, string> = {
  youtube: "YouTube",
  instagram: "Instagram",
  tiktok: "TikTok",
  facebook: "Facebook",
};

const ID = /^[A-Za-z0-9_-]{5,40}$/;

function hostOf(u: URL): string {
  return u.hostname.toLowerCase().replace(/^(www|m|mobile)\./, "");
}

/** 只收 https 的網址；其他（含 javascript: / http:）一律 null。 */
export function safeHttpsUrl(raw: string | null | undefined): string | null {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === "https:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/**
 * TikTok 的分享短連結（vt.tiktok.com/… 、vm.tiktok.com/… 、tiktok.com/t/…）：網址裡沒有影片代號，
 * 沒辦法直接嵌。後台存檔前會先問 TikTok 換成帶代號的網址（見 admin 的 resolveTikTokShortLink）。
 */
export function isTikTokShortLink(raw: string | null | undefined): boolean {
  const safe = safeHttpsUrl(raw);
  if (!safe) return false;
  const u = new URL(safe);
  const host = hostOf(u);
  if (host === "vt.tiktok.com" || host === "vm.tiktok.com") return true;
  return host === "tiktok.com" && /^\/t\/[A-Za-z0-9]+/.test(u.pathname);
}

/** 影片代號 → 我們存進資料庫的 TikTok 網址（播放器網址，裡面就有代號）。 */
export function tiktokPlayerUrl(videoId: string): string | null {
  return /^\d{8,25}$/.test(videoId) ? `https://www.tiktok.com/player/v1/${videoId}` : null;
}

export function parseVideoEmbed(raw: string | null | undefined): VideoEmbed | null {
  const safe = safeHttpsUrl(raw);
  if (!safe) return null;
  const u = new URL(safe);
  const host = hostOf(u);
  const seg = u.pathname.split("/").filter(Boolean);
  const make = (provider: VideoProvider, embedUrl: string, portrait: boolean): VideoEmbed =>
    ({ provider, label: PROVIDER_LABEL[provider], embedUrl, portrait });

  // ── YouTube ────────────────────────────────────────────────────────────
  if (host === "youtu.be" || host === "youtube.com" || host === "youtube-nocookie.com") {
    let id: string | null = null;
    let portrait = false;
    if (host === "youtu.be") id = seg[0] ?? null;
    else if (seg[0] === "watch") id = u.searchParams.get("v");
    else if (seg[0] === "shorts") { id = seg[1] ?? null; portrait = true; }
    else if (seg[0] === "embed" || seg[0] === "live") id = seg[1] ?? null;
    if (!id || !ID.test(id)) return null;
    return make("youtube", `https://www.youtube.com/embed/${id}?playsinline=1&rel=0&autoplay=1`, portrait);
  }

  // ── Instagram：/reel/<代號>、/reels/<代號>、/p/<代號>、/tv/<代號>，前面可能多一段帳號 ──
  if (host === "instagram.com") {
    const at = seg.findIndex((s) => s === "reel" || s === "reels" || s === "p" || s === "tv");
    const code = at >= 0 ? seg[at + 1] : null;
    if (!code || !ID.test(code)) return null;
    const kind = seg[at] === "p" ? "p" : seg[at] === "tv" ? "tv" : "reel";
    return make("instagram", `https://www.instagram.com/${kind}/${code}/embed/`, true);
  }

  // ── TikTok：/@帳號/video/<數字>、/player/v1/<數字>、/embed/v2/<數字> ──────────
  if (host === "tiktok.com") {
    let id: string | null = null;
    const at = seg.indexOf("video");
    if (at >= 0) id = seg[at + 1] ?? null;
    else if (seg[0] === "player" && seg[1] === "v1") id = seg[2] ?? null;
    else if (seg[0] === "embed") id = seg[seg.length - 1] ?? null;
    else if (seg[0] === "v") id = (seg[1] ?? "").replace(/\.html$/, "");
    const playerUrl = id ? tiktokPlayerUrl(id) : null;
    if (!playerUrl) return null;
    return make("tiktok", `${playerUrl}?autoplay=1&rel=0`, true);
  }

  // ── Facebook：交給官方的影片外掛，它自己認得 reel / videos / watch / share 這幾種網址 ──
  if (host === "facebook.com" || host === "fb.watch") {
    const looksLikeVideo = host === "fb.watch"
      || seg.includes("reel") || seg.includes("videos") || seg[0] === "watch"
      || (seg[0] === "share" && (seg[1] === "r" || seg[1] === "v"));
    if (!looksLikeVideo) return null;
    const portrait = seg.includes("reel") || (seg[0] === "share" && seg[1] === "r");
    return make(
      "facebook",
      `https://www.facebook.com/plugins/video.php?href=${encodeURIComponent(safe)}&show_text=false&autoplay=true`,
      portrait,
    );
  }

  return null;
}
