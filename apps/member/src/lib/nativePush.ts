// 原生推播（Capacitor）— iOS 走 APNs、Android 走 FCM。
// @capacitor/push-notifications 只在原生平台動態 import，避免進到瀏覽器 bundle。
import { getPlatform } from "./platform";

export type PushProvider = "fcm" | "apns";

type RegisterOpts = {
  /** 拿到 device token 後回呼（把 token 寫進後端 push_subscriptions）。 */
  onToken: (
    token: string,
    provider: PushProvider,
    platform: "ios" | "android",
  ) => Promise<void> | void;
  /** 使用者點擊推播時回呼，data 內含 deep link（如 { url: "/orders" }）。 */
  onNotificationTap?: (data: Record<string, unknown>) => void;
};

/**
 * 在原生 App 內請求權限並向 APNs/FCM 註冊，取得 device token。
 * 回傳權限結果；token 透過 opts.onToken 非同步回拋。
 */
export async function registerNativePush(
  opts: RegisterOpts,
): Promise<{ permission: "granted" | "denied" }> {
  const platform = getPlatform();
  if (platform === "web") return { permission: "denied" };

  const { PushNotifications } = await import("@capacitor/push-notifications");

  const perm = await PushNotifications.requestPermissions();
  if (perm.receive !== "granted") return { permission: "denied" };

  // 必須在 register() 前掛好 registration / error listener，否則可能漏接 token
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const done = (err?: Error) => {
      if (settled) return;
      settled = true;
      err ? reject(err) : resolve();
    };

    PushNotifications.addListener("registration", async (token) => {
      try {
        const provider: PushProvider = platform === "ios" ? "apns" : "fcm";
        await opts.onToken(token.value, provider, platform);
        done();
      } catch (e) {
        done(e instanceof Error ? e : new Error(String(e)));
      }
    });

    PushNotifications.addListener("registrationError", (err) => {
      done(new Error(String((err as { error?: unknown })?.error ?? "registration error")));
    });

    void PushNotifications.register();
  });

  if (opts.onNotificationTap) {
    PushNotifications.addListener("pushNotificationActionPerformed", (action) => {
      opts.onNotificationTap?.(action.notification?.data ?? {});
    });
  }

  return { permission: "granted" };
}
