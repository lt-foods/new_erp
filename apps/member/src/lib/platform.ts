// 平台偵測 — 區分「Capacitor 原生 App」與「瀏覽器 / PWA」。
// @capacitor/core 在瀏覽器環境也能安全載入（getPlatform() 回 "web"）。
import { Capacitor } from "@capacitor/core";

/** 是否跑在 Capacitor 原生殼（iOS / Android App）內。 */
export function isNativeApp(): boolean {
  try {
    return Capacitor.isNativePlatform();
  } catch {
    return false;
  }
}

export type NativePlatform = "ios" | "android" | "web";

/** 目前平台。瀏覽器 / PWA 回 "web"。 */
export function getPlatform(): NativePlatform {
  try {
    const p = Capacitor.getPlatform();
    return p === "ios" || p === "android" ? p : "web";
  } catch {
    return "web";
  }
}
