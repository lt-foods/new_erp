"use client";

import type { PushNotificationState } from "@/lib/usePushNotification";

/**
 * /me 頁面底部「通知設定」卡 — 留給:
 * - 重新連動 LINE
 * - 進階 debug 狀態
 * 通知開啟/關閉狀態與訂閱按鈕已上移到頭像區,所以這裡不再顯示狀態 chip。
 *
 * 訂閱狀態由 parent 透過 `usePushNotification(jwt)` lift up,以 props 傳入,
 * 避免 hook 在多處重跑造成 double subscribe / double fetch。
 */
export function PushNotificationManager({ state }: { state: PushNotificationState }) {
  if (!state.isSupported) return null;

  return (
    <section>
      <div className="px-4 pb-1 pt-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">
        通知設定
      </div>
      <div className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
        <div className="flex items-start justify-between gap-3 px-4 py-3.5">
          <div className="min-w-0 flex-1">
            <div className="text-[17px] text-[var(--foreground)]">推播通知</div>
            <p className="mt-0.5 text-[14px] text-[var(--secondary-label)]">
              {state.subscription
                ? "已啟用,新訂單到貨會即時通知。"
                : state.isPWA
                ? "尚未啟用。請至上方頭像區開啟。"
                : "請先「加入主畫面」開啟 App 才能訂閱。"}
            </p>
          </div>
          <button
            onClick={state.rebind}
            className="flex-shrink-0 text-[15px] text-[var(--ios-blue)] active:opacity-60"
          >
            重新連動 LINE
          </button>
        </div>

        {state.debugStatus && (
          <div className="border-t border-[var(--separator)] bg-[#7676800a] px-4 py-2 font-mono text-[11px] text-[var(--secondary-label)]">
            {state.debugStatus} {state.isPWA ? " · PWA" : " · Browser"}
          </div>
        )}
      </div>
    </section>
  );
}
