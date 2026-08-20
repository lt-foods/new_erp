// 把站內的頁面分享出去（目前用於團購商品頁）。
//
// 分享的價值全在那張預覽卡：連結的 og tag 由 server 端的 generateMetadata 產生
// （見 app/shop/c/[id]/page.tsx），所以這裡只負責「把網址交出去」。
//
// 主線是**手機自帶的分享面板**（Web Share API）—— iOS / Android 都是使用者最熟的
// 那張表，LINE、訊息、AirDrop、複製都在裡面，我們不用替他決定要分享到哪。
// 但會員站有三種跑法（LINE 裡的 LIFF、安裝成 App 的 PWA、一般瀏覽器），
// 不是每種都有這個 API，所以比照 lineInquiry.ts 一條一條退，
// 最差也要留一條路（複製連結）給使用者走，不要讓按鈕看起來壞掉。

import { initLiff } from "@/lib/liff";
import { SITE_URL } from "@/lib/site";
import { logCaught } from "@/lib/clientLog";

export type ShareResult =
  /** 叫出了手機自帶的分享面板 */
  | "shared_native"
  /** 退到 LIFF 的分享目標選擇器並送出成功 */
  | "shared_in_line"
  /** 使用者自己取消（不是錯誤，畫面不要報錯） */
  | "cancelled"
  /** 已交棒給 LINE 的網頁分享頁 */
  | "opened_line"
  /** 都不通，退成複製到剪貼簿 */
  | "copied"
  | "failed";

/** 團購商品頁的分享網址。
 *
 *  一律用 SITE_URL 重組，不要拿 `window.location.href` ——
 *  現場的網址可能帶著登入用的 fragment / query（`consumeFragmentToSession`
 *  吃的那些），把它分享出去等於把 session token 貼到群組裡。 */
export function campaignShareUrl(campaignId: number, path = "/shop/c"): string {
  return `${SITE_URL}${path}/${campaignId}`;
}

/** LINE 官方的網頁分享頁：手機會轉交給 LINE app，桌機開網頁版 LINE */
function lineWebShareUrl(url: string, text: string): string {
  const qs = new URLSearchParams({ url });
  if (text) qs.set("text", text);
  return `https://social-plugins.line.me/lineit/share?${qs.toString()}`;
}

/** 使用者在原生面板 / 選擇器按取消 —— 要跟真的失敗分開，不然會誤跳錯誤提示 */
function isAbort(e: unknown): boolean {
  return e instanceof Error && (e.name === "AbortError" || e.name === "NotAllowedError");
}

/**
 * 分享這一頁。四條路，依序退：
 *
 * 1. **手機自帶的分享面板**（`navigator.share`）
 *    iOS / Android / 桌機 Chrome 都有，使用者自己挑 LINE、訊息、AirDrop…。
 *    需要 https + user gesture，所以呼叫端一定要直接掛在 onClick 上，
 *    不要先 await 別的東西（等過再叫，Safari 會判定不是手勢而拒絕）。
 * 2. **LINE 裡面（LIFF）沒有原生面板時** → `liff.shareTargetPicker()`
 *    跳好友 / 群組選擇器，以使用者身分送出，人留在 App 裡。
 *    需要該 LIFF app 在 Developers Console 打開 shareTargetPicker，沒開會 reject。
 * 3. **LINE 的網頁分享頁** → 手機交棒給 LINE app 選聊天室，桌機開網頁版。
 * 4. **連開頁都失敗** → 複製連結，請使用者自己貼。
 *
 * 任何一條走到「使用者按取消」都直接回 cancelled，不要再往下退 ——
 * 他已經表達不想分享了，繼續彈下一個面板只會很煩。
 */
export async function sharePage(opts: {
  url: string;
  /** 標題（原生面板顯示用，例：團名） */
  title?: string;
  /** 附在連結前面的一行字。LINE 會另外自己抓 og 預覽卡。 */
  text?: string;
}): Promise<ShareResult> {
  const title = opts.title?.trim() || undefined;
  const text = opts.text?.trim() ?? "";

  // 1. 手機自帶的分享面板
  if (typeof navigator !== "undefined" && typeof navigator.share === "function") {
    try {
      await navigator.share({ title, text: text || undefined, url: opts.url });
      return "shared_native";
    } catch (e) {
      if (isAbort(e)) return "cancelled";
      // 有 API 但叫不出來（webview 沒開權限、非 https…）→ 往下退
      logCaught("native_share_failed", e, { url: opts.url });
    }
  }

  const message = text ? `${text}\n${opts.url}` : opts.url;

  // 2. LIFF：分享目標選擇器
  try {
    const liff = await initLiff();
    if (liff?.isInClient() && typeof liff.shareTargetPicker === "function") {
      const r = await liff.shareTargetPicker([{ type: "text", text: message }]);
      // 取消時 SDK 是 resolve(null)，不是 reject —— 當成錯誤會誤跳提示
      return r ? "shared_in_line" : "cancelled";
    }
  } catch (e) {
    // 沒開 shareTargetPicker / SDK 太舊 / init 失敗。使用者只會看到「沒反應」，
    // 而這只在他手機上重現得出來，一定要留 log。
    logCaught("share_target_picker_failed", e, { url: opts.url });
  }

  // 3. LINE 網頁分享頁
  const webShare = lineWebShareUrl(opts.url, text);
  try {
    const liff = await initLiff();
    // LIFF 內要 external 才會跳出去給 LINE 本體處理
    if (liff?.isInClient() && typeof liff.openWindow === "function") {
      liff.openWindow({ url: webShare, external: true });
      return "opened_line";
    }
  } catch {
    // 落到一般的開新視窗
  }
  try {
    // 已經 await 過，不算 user gesture 了，開新視窗可能被擋 → 擋掉就導頁
    const w = window.open(webShare, "_blank", "noopener,noreferrer");
    if (w) return "opened_line";
    window.location.href = webShare;
    return "opened_line";
  } catch (e) {
    logCaught("line_web_share_failed", e, { url: opts.url });
  }

  // 4. 最後退路：複製連結
  return (await copyText(opts.url)) ? "copied" : "failed";
}

/** 複製文字到剪貼簿。非 https / 舊 webview 沒有 clipboard API，回 false 讓
 *  呼叫端把連結顯示出來給使用者自己長按複製。 */
export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}
