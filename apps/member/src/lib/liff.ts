// LIFF SDK loader — 用 CDN 載入官方 SDK，不用 npm 套件（免動 package-lock）
// 官方建議 CDN：https://static.line-scdn.net/liff/edge/2/sdk.js

type LiffStatic = {
  init: (cfg: { liffId: string }) => Promise<void>;
  isInClient: () => boolean;
  isLoggedIn: () => boolean;
  login: (cfg?: { redirectUri?: string }) => void;
  logout: () => void;
  getIDToken: () => string | null;
  getAccessToken: () => string | null;
  getProfile: () => Promise<{
    userId: string;
    displayName: string;
    pictureUrl?: string;
    statusMessage?: string;
  }>;
  getLanguage: () => string;
  getOS: () => "ios" | "android" | "web";
  getLineVersion: () => string | null;
  getDecodedIDToken: () => Record<string, unknown> | null;
  closeWindow: () => void;
  /** 以使用者身分把訊息送進「開啟這個 LIFF 的那個聊天室」。
   *  需要 LIFF app 開 `chat_message.write` scope，且要有 chat context
   *  （從 OA 聊天室 / 圖文選單進來）。條件不符會 reject。 */
  sendMessages?: (messages: Array<{ type: "text"; text: string }>) => Promise<void>;
  openWindow?: (params: { url: string; external?: boolean }) => void;
  getContext?: () => { type?: string } | null;
};

declare global {
  interface Window {
    liff?: LiffStatic;
  }
}

const SDK_URL = "https://static.line-scdn.net/liff/edge/2/sdk.js";
let loadPromise: Promise<LiffStatic> | null = null;

/** 載入 LIFF SDK（冪等）。回傳 window.liff */
export function loadLiff(): Promise<LiffStatic> {
  if (typeof window === "undefined") {
    return Promise.reject(new Error("LIFF can only be used in browser"));
  }
  if (window.liff) return Promise.resolve(window.liff);
  if (loadPromise) return loadPromise;

  loadPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${SDK_URL}"]`);
    if (existing) {
      existing.addEventListener("load", () => {
        if (window.liff) resolve(window.liff);
        else reject(new Error("LIFF SDK loaded but window.liff missing"));
      });
      existing.addEventListener("error", () => reject(new Error("LIFF SDK load error")));
      return;
    }
    const s = document.createElement("script");
    s.src = SDK_URL;
    s.async = true;
    s.charset = "utf-8";
    s.onload = () => {
      if (window.liff) resolve(window.liff);
      else reject(new Error("LIFF SDK loaded but window.liff missing"));
    };
    s.onerror = () => reject(new Error("LIFF SDK load error"));
    document.head.appendChild(s);
  });
  return loadPromise;
}

/**
 * 載入並 init LIFF SDK（整個 app 只跑一次，之後回同一個 promise）。
 *
 * 用途：登入頁以外的頁面（例如現貨詳情要用 liff.sendMessages 對 LINE@ 送訊息）
 * 也需要一個 init 過的 liff 實例，但那些頁面不該各自重跑 init。
 *
 * 回 null 的情況：沒設 NEXT_PUBLIC_LIFF_ID、非瀏覽器環境、SDK 載入或 init 失敗。
 * 呼叫端一律要能在 null 時走非 LIFF 的退路（PWA / 一般瀏覽器就是這條）。
 */
let initPromise: Promise<LiffStatic | null> | null = null;

export function initLiff(): Promise<LiffStatic | null> {
  if (initPromise) return initPromise;
  initPromise = (async () => {
    if (typeof window === "undefined") return null;
    const liffId = process.env.NEXT_PUBLIC_LIFF_ID;
    if (!liffId) return null;
    try {
      const liff = await loadLiff();
      await liff.init({ liffId });
      return liff;
    } catch {
      return null;
    }
  })();
  return initPromise;
}
