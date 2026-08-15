// 把站內的頁面分享出去（目前用於團購商品頁）。
//
// 分享的價值全在那張預覽卡：連結的 og tag 由 server 端的 generateMetadata 產生
// （見 app/shop/c/[id]/page.tsx），所以這裡只負責「把網址送進 LINE」。
//
// 為什麼不是一行 window.open：會員站有三種跑法，能用的 API 完全不同 ——
// LINE 裡面（LIFF）、安裝成 App 的 PWA、一般瀏覽器。跟 lineInquiry.ts 同一套
// 思路：一條一條退，最差也要留一條路（複製連結）給使用者走，不要讓按鈕看起來壞掉。

import { initLiff } from "@/lib/liff";
import { SITE_URL } from "@/lib/site";
import { logCaught } from "@/lib/clientLog";

export type ShareResult =
  /** LIFF 的分享目標選擇器送出成功 */
  | "shared_in_line"
  /** 使用者在選擇器裡按了取消（不是錯誤，畫面不要報錯） */
  | "cancelled"
  /** 已交棒給 LINE 的網頁分享頁 */
  | "opened_line"
  /** 三條都不通，退成複製到剪貼簿 */
  | "copied"
  | "failed";

/** 團購商品頁的分享網址。
 *
 *  一律用 SITE_URL 重組，不要拿 `window.location.href` ——
 *  現場的網址可能帶著登入用的 fragment / query（`consumeFragmentToSession`
 *  吃的那些），把它分享出去等於把 session token 貼到群組裡。 */
export function campaignShareUrl(campaignId: number): string {
  return `${SITE_URL}/shop/c/${campaignId}`;
}

/** LINE 官方的網頁分享頁：手機會轉交給 LINE app，桌機開網頁版 LINE */
function lineWebShareUrl(url: string, text: string): string {
  const qs = new URLSearchParams({ url });
  if (text) qs.set("text", text);
  return `https://social-plugins.line.me/lineit/share?${qs.toString()}`;
}

/**
 * 分享到 LINE。三條路，依序退：
 *
 * 1. **LINE 裡面（LIFF）** → `liff.shareTargetPicker()`
 *    跳出好友 / 群組選擇器，以使用者身分送出，人留在 App 裡。
 *    需要該 LIFF app 在 Developers Console 打開 shareTargetPicker，
 *    沒開會 reject → 自動掉到第 2 條（所以就算忘了開，按鈕也不會壞）。
 * 2. **其他環境（PWA / 瀏覽器）** → LINE 的網頁分享頁
 *    手機上會直接交棒給 LINE app 選聊天室。
 * 3. **連開頁都失敗** → 複製連結，請使用者自己貼。
 */
export async function shareToLine(opts: {
  url: string;
  /** 附在連結前面的一行字（團名之類）。LINE 會另外自己抓 og 預覽卡。 */
  text?: string;
}): Promise<ShareResult> {
  const text = opts.text?.trim() ?? "";
  const message = text ? `${text}\n${opts.url}` : opts.url;

  // 1. LIFF：分享目標選擇器
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

  // 2. 網頁分享頁
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

  // 3. 最後退路：複製連結
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
