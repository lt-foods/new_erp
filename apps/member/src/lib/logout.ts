// 完整登出 —— 把這台裝置恢復成「從沒登入過」的狀態。
//
// 為什麼不能只 clearSession()：會員端的狀態散在五個地方，漏掉任何一個，
// 下次登入就會撈到上一輪的殘留（最典型的是 LIFF 自己記著已登入，
// 於是「登出」後一進 LINE 又用舊帳號自動登入，看起來像登出失敗）。
//
// 主要用途是測試與換帳號，所以寧可清過頭：這裡清掉的東西全都能重新取得。

import { clearSession } from "./session";
import { initLiff } from "./liff";
import { setAppBadgeCount } from "./appBadge";
import { clearLocalLogs } from "./clientLog";

/** 一步一步回報進度，讓 /logout 頁面能顯示到底清了什麼 */
export type LogoutStep = { label: string; ok: boolean; detail?: string };

/** clearSession() 管不到、但會影響下次登入的 localStorage key */
const EXTRA_LOCAL_KEYS = [
  "last_store_id",     // 記住的門市 —— 不清的話下次直接跳過選店
  "pwa_pair_token",    // 上一輪沒領完的 PWA 配對 token
  "sw_register_error", // service worker 註冊失敗的紀錄
];

/** 往 LIFF 彈過一次的旗標（sessionStorage） */
const SESSION_KEYS = ["liff_login_retry"];

export async function hardLogout(): Promise<LogoutStep[]> {
  const steps: LogoutStep[] = [];
  const run = async (label: string, fn: () => Promise<string | void> | string | void) => {
    try {
      const detail = await fn();
      steps.push({ label, ok: true, detail: detail || undefined });
    } catch (e) {
      steps.push({ label, ok: false, detail: e instanceof Error ? e.message : String(e) });
    }
  };

  // 1) LIFF 的登入狀態 —— 最容易漏掉的一個。
  //    不呼叫 liff.logout()，下次在 LINE 裡開就會直接用舊帳號自動登入，
  //    使用者會覺得「明明登出了卻還是原本的人」。
  await run("清除 LINE LIFF 登入狀態", async () => {
    const liff = await initLiff();
    if (!liff) return "未設定 LIFF 或不在 LIFF 環境，略過";
    if (!liff.isLoggedIn()) return "本來就未登入";
    liff.logout();
    return "已呼叫 liff.logout()";
  });

  // 2) 推播訂閱 —— 不退訂的話，換帳號後這台裝置還會收到前一個帳號的通知
  await run("取消推播訂閱", async () => {
    if (!("serviceWorker" in navigator)) return "此瀏覽器不支援，略過";
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = await reg?.pushManager?.getSubscription();
    if (!sub) return "沒有訂閱";
    await sub.unsubscribe();
    return "已退訂";
  });

  // 3) 會員 session 與其他 localStorage 殘留
  await run("清除登入資料", () => {
    clearSession();
    EXTRA_LOCAL_KEYS.forEach((k) => localStorage.removeItem(k));
    clearLocalLogs();
    return `含門市、配對 token、錯誤紀錄`;
  });

  await run("清除暫存旗標", () => {
    SESSION_KEYS.forEach((k) => sessionStorage.removeItem(k));
  });

  // 4) 桌面圖示上的未讀數
  await run("清除 App 圖示未讀數", async () => {
    await setAppBadgeCount(0);
  });

  // 5) PWA 快取與 service worker。
  //    放最後：unregister 之後這一頁就沒有 SW 了，前面幾步若還需要它會失敗。
  await run("清除 PWA 快取", async () => {
    if (typeof caches === "undefined") return "此瀏覽器不支援，略過";
    const keys = await caches.keys();
    await Promise.all(keys.map((k) => caches.delete(k)));
    return keys.length ? `${keys.length} 組快取` : "沒有快取";
  });

  await run("註銷 Service Worker", async () => {
    if (!("serviceWorker" in navigator)) return "此瀏覽器不支援，略過";
    const regs = await navigator.serviceWorker.getRegistrations();
    await Promise.all(regs.map((r) => r.unregister()));
    return regs.length ? `${regs.length} 個` : "沒有註冊";
  });

  return steps;
}
