/// <reference lib="webworker" />

import { defaultCache } from "@serwist/next/worker";
import type { PrecacheEntry, SerwistGlobalConfig } from "serwist";
import { Serwist } from "serwist";
import { readStoredBadge, setAppBadgeCount, writeStoredBadge } from "@/lib/appBadge";

declare global {
  interface ServiceWorkerGlobalScope extends SerwistGlobalConfig {
    __SW_MANIFEST: (string | PrecacheEntry)[] | undefined;
  }
}

const serwist = new Serwist({
  // @ts-ignore
  precacheEntries: self.__SW_MANIFEST,
  skipWaiting: true,
  clientsClaim: true,
  navigationPreload: true,
  runtimeCaching: defaultCache,
});

// @ts-ignore
self.addEventListener("push", (event: PushEvent) => {
  const data = event.data?.json();
  if (!data) return;

  const title = data.title || "新訊息";
  const options = {
    body: data.body || "您有一則新通知",
    icon: "/icons/android/launchericon-192x192.png",
    badge: "/icons/android/launchericon-192x192.png",
    data: data.url || "/",
  };

  event.waitUntil(
    (async () => {
      // @ts-ignore
      await self.registration.showNotification(title, options);
      // app 關著時查不到真正的未讀數（要 member token），只能本地累加。
      // 使用者開啟 app 後 useUnreadNotifications 會用後端真值覆蓋，誤差自我修正。
      const next = (await readStoredBadge()) + 1;
      await writeStoredBadge(next);
      await setAppBadgeCount(next);
    })(),
  );
});

// @ts-ignore
self.addEventListener("notificationclick", (event: NotificationEvent) => {
  event.notification.close();
  event.waitUntil(
    // @ts-ignore
    self.clients.openWindow(event.notification.data)
  );
});

serwist.addEventListeners();
