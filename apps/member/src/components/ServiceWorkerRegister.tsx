"use client";

import { useEffect } from "react";

/**
 * 是否在 LINE app 內建瀏覽器（LIFF in-client webview）。
 * LINE 內建瀏覽器的 UA 會帶 "Line/x.x.x"（外部瀏覽器開 LIFF 不會）。
 * 這裡只靠 UA 判斷，因為要在 LIFF SDK init 之前就決定「要不要載 SW」。
 */
function isLineInAppBrowser(): boolean {
  if (typeof navigator === "undefined") return false;
  return / Line\//i.test(navigator.userAgent);
}

export default function ServiceWorkerRegister() {
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;

    // LINE LIFF 內建瀏覽器不要載 PWA：
    // Serwist SW 會 precache + runtime cache，在 LINE webview 內會回舊的快取頁面，
    // 造成 LIFF 卡在載入 / 看到過期內容。推播又只有 standalone PWA 才能用，
    // 所以在 LINE 內完全不需要 SW。順手把先前殘留的 SW 與 cache 清掉，確保走網路。
    if (isLineInAppBrowser()) {
      navigator.serviceWorker
        .getRegistrations()
        .then((regs) => Promise.all(regs.map((r) => r.unregister())))
        .catch(() => {});
      if (typeof caches !== "undefined") {
        caches
          .keys()
          .then((keys) => Promise.all(keys.map((k) => caches.delete(k))))
          .catch(() => {});
      }
      return;
    }

    try { localStorage.removeItem("sw_register_error"); } catch {}

    navigator.serviceWorker
      .register("/sw.js")
      .then((registration) => {
        console.log("Service Worker registered with scope:", registration.scope);
      })
      .catch((error) => {
        console.error("Service Worker registration failed:", error);
        try {
          const msg = error instanceof Error ? error.message : String(error);
          localStorage.setItem("sw_register_error", msg);
        } catch {}
      });
  }, []);

  return null;
}
