"use client";

import { useEffect, useState } from "react";
import { callLiffApi } from "./supabase";

const VAPID_PUBLIC_KEY =
  "BPu5IptVgyuZFTpZEMkP3CB9C-EDkd16kcGIY3cAMnM2VeqeixebwRm4r-giCPX9UeewLLHQgsVabx04Uxss-xE";

function urlBase64ToUint8Array(base64String: string) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) outputArray[i] = rawData.charCodeAt(i);
  return outputArray;
}

// 等到 SW registration 真的有 active worker 才回傳。
// `getRegistration()` 在 installing/waiting 階段就會回 reg(active=null),
// pushManager.subscribe() 在這狀態下會丟「subscribing for push requires an active service worker」。
// 必須等 `.ready`(保證 active 已就緒),並用 timeout 防呆。
async function getActiveRegistration(timeoutMs: number): Promise<ServiceWorkerRegistration> {
  const existing = await navigator.serviceWorker.getRegistration();
  if (existing?.active) return existing;
  return await Promise.race([
    navigator.serviceWorker.ready,
    new Promise<never>((_, reject) =>
      setTimeout(
        () =>
          reject(new Error(`Service Worker 啟用超時(>${Math.round(timeoutMs / 1000)}s),請重開 App`)),
        timeoutMs,
      ),
    ),
  ]);
}

export type PushNotificationState = {
  isSupported: boolean;
  isPWA: boolean;
  subscription: PushSubscription | null;
  permission: NotificationPermission;
  debugStatus: string;
  subscribe: () => Promise<void>;
  rebind: () => void;
};

/**
 * 集中管理 PWA Web Push 訂閱狀態。
 * 在 /me 頁面 call 一次,把 state 傳到頭像區 chip 跟底部 PushNotificationManager 兩處用。
 * 直接 call 兩次會 double-subscribe / double-fetch,所以一律 lift state up。
 */
export function usePushNotification(jwt: string | null): PushNotificationState {
  const [isSupported, setIsSupported] = useState(false);
  const [permission, setPermission] = useState<NotificationPermission>("default");
  const [subscription, setSubscription] = useState<PushSubscription | null>(null);
  const [debugStatus, setDebugStatus] = useState<string>("");
  const [isPWA, setIsPWA] = useState(false);

  useEffect(() => {
    const standalone =
      (window.navigator as { standalone?: boolean }).standalone ||
      window.matchMedia("(display-mode: standalone)").matches;
    setIsPWA(!!standalone);

    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      setDebugStatus("不支援 Web Push (iOS 需 16.4+)");
      return;
    }

    setIsSupported(true);
    setPermission(Notification.permission);

    const swErr = (() => {
      try {
        return localStorage.getItem("sw_register_error");
      } catch {
        return null;
      }
    })();
    if (swErr) {
      setDebugStatus(`SW 註冊失敗: ${swErr}`);
      return;
    }

    setDebugStatus(standalone ? "等待 Service Worker 啟用..." : "請加入主畫面以啟用通知");

    let cancelled = false;
    (async () => {
      try {
        const registration = await getActiveRegistration(8000);
        if (cancelled) return;
        setDebugStatus(standalone ? "PWA 已就緒" : "請加入主畫面以啟用通知");

        const sub = await registration.pushManager.getSubscription();
        if (cancelled) return;
        setSubscription(sub);

        if (sub && jwt) {
          setDebugStatus("發現舊訂閱,同步中...");
          const subJson = sub.toJSON();
          try {
            await callLiffApi(jwt, {
              action: "upsert_push_subscription",
              endpoint: subJson.endpoint,
              p256dh: subJson.keys?.p256dh,
              auth: subJson.keys?.auth,
              user_agent: navigator.userAgent,
            });
            if (!cancelled) setDebugStatus("同步成功");
          } catch (err) {
            if (cancelled) return;
            setDebugStatus(`同步失敗: ${err instanceof Error ? err.message : String(err)}`);
          }
        }
      } catch (err) {
        if (cancelled) return;
        setDebugStatus(`SW 等待失敗: ${err instanceof Error ? err.message : String(err)}`);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [jwt]);

  const rebind = () => {
    if (!confirm("這將重新連動 LINE 並更新身分資料,確定嗎?")) return;
    const storeId = localStorage.getItem("member_store_id") || "1";
    localStorage.clear();
    const url = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/line-oauth-start?store=${storeId}`;
    window.location.href = url;
  };

  const subscribe = async () => {
    if (!jwt) {
      alert("請先登入");
      return;
    }
    if (!isPWA) {
      alert("iOS 必須「加入主畫面」後從桌面開啟 App 才能訂閱通知。");
      return;
    }

    try {
      setDebugStatus("請求通知權限...");
      const result = await Notification.requestPermission();
      setPermission(result);

      if (result !== "granted") {
        setDebugStatus(`權限被拒絕 (${result})`);
        alert("未獲得通知權限。請到手機「設定 > 通知」開啟權限。");
        return;
      }

      setDebugStatus("正在取得 Service Worker...");
      const registration = await getActiveRegistration(15000);

      if (!registration.pushManager) {
        setDebugStatus("PushManager 不可用");
        alert("此裝置不支援 PushManager (或需重開 App)");
        return;
      }

      setDebugStatus("正在向 Push Server 註冊...");
      const sub = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
      });

      setSubscription(sub);
      const subJson = sub.toJSON();

      setDebugStatus("正在寫入資料庫...");
      await callLiffApi(jwt, {
        action: "upsert_push_subscription",
        endpoint: subJson.endpoint,
        p256dh: subJson.keys?.p256dh,
        auth: subJson.keys?.auth,
        user_agent: navigator.userAgent,
      });

      setDebugStatus("訂閱成功!");
      alert("通知訂閱成功!");
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setDebugStatus(`錯誤: ${msg}`);
      alert(`訂閱失敗:${msg}`);
      if ("serviceWorker" in navigator) {
        navigator.serviceWorker.register("/sw.js").catch(() => {});
      }
    }
  };

  return { isSupported, isPWA, subscription, permission, debugStatus, subscribe, rebind };
}
