// PWA 桌面圖示上的未讀數小紅點（Badging API）
//
// 支援度（MDN browser-compat-data，2026-08 查）：
//   iOS Safari 16.4+   ✅ 但僅限「加到主畫面」的 PWA，且要有通知權限
//   Chrome Android     ❌ 完全沒實作 —— Android 會員不會看到數字，這是平台限制
//   Chrome/Edge 桌面   ✅ Windows / macOS 81+（Linux 沒有系統級 badge）
//   Firefox            ❌
// 所以一律特性偵測 + 靜默失敗：拿不到 badge 不該影響任何功能。
//
// 這個檔同時被主執行緒（useUnreadNotifications）與 service worker（sw.ts）import，
// 因此不能碰 window / document，只能用 globalThis。

/** Badging API 在 Navigator 與 WorkerNavigator 上都有，兩邊都要能取到 */
type BadgeNavigator = {
  setAppBadge?: (count?: number) => Promise<void>;
  clearAppBadge?: () => Promise<void>;
};

function badgeNav(): BadgeNavigator | null {
  const nav = (globalThis as { navigator?: BadgeNavigator }).navigator;
  if (!nav || typeof nav.setAppBadge !== "function") return null;
  return nav;
}

/** 這個裝置支不支援 badge（給 UI 決定要不要顯示相關說明用） */
export function supportsAppBadge(): boolean {
  return badgeNav() !== null;
}

/**
 * 設定圖示上的未讀數。<= 0 一律走 clearAppBadge()。
 *
 * 為什麼不直接 setAppBadge(0)：iOS 上傳 0 是「清除」，但其他平台是
 * 「顯示一個沒有數字的點」。統一走 clear 才會兩邊行為一致。
 */
export async function setAppBadgeCount(count: number): Promise<void> {
  const nav = badgeNav();
  if (!nav) return;
  try {
    if (count > 0) await nav.setAppBadge?.(count);
    else await nav.clearAppBadge?.();
  } catch {
    // 權限沒給 / 不是安裝過的 PWA 都會 reject —— 不是錯誤，不用記
  }
}

// ── SW 與主執行緒之間共用的計數 ────────────────────────────────────────────
// service worker 收到 push 時 app 是關著的，查不到真正的未讀數（要 token），
// 只能在本地累加。開啟 app 後主執行緒會用後端的真值覆蓋，誤差自我修正。
// 用 Cache Storage 是因為它同 origin 共享，SW 與主執行緒都存取得到。

const BADGE_CACHE = "app-badge";
const BADGE_KEY = "/__badge_count";

export async function readStoredBadge(): Promise<number> {
  try {
    const c = await caches.open(BADGE_CACHE);
    const r = await c.match(BADGE_KEY);
    if (!r) return 0;
    const n = Number(await r.text());
    return Number.isFinite(n) && n > 0 ? n : 0;
  } catch {
    return 0;
  }
}

export async function writeStoredBadge(count: number): Promise<void> {
  try {
    const c = await caches.open(BADGE_CACHE);
    await c.put(BADGE_KEY, new Response(String(Math.max(0, count))));
  } catch {
    /* 存不進去頂多下次 push 從 0 重數，不影響功能 */
  }
}

/** 主執行緒用：以後端的真實未讀數覆蓋 badge 與本地計數 */
export async function syncAppBadge(count: number): Promise<void> {
  await Promise.all([setAppBadgeCount(count), writeStoredBadge(count)]);
}
