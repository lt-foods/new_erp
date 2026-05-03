"use client";

import { useCallback, useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { getSession, listenForSession } from "./session";
import { callLiffApi } from "./supabase";

/**
 * 提供 tab bar 上的「通知」未讀數
 *
 * 觸發 refresh 的時機:
 * 1. 元件 mount + pathname 變化(切到 /notifications 後標已讀,回來自動歸零)
 * 2. consumeFragmentToSession 廣播 LOGIN_SUCCESS(LIFF 第一次登入完 session
 *    才入 localStorage,首次 mount 時 getSession 會是 null,要靠這個補回)
 * 3. window focus / document visibilitychange(回到 PWA / 從背景切回前景時更新)
 *
 * 失敗一律靜默回 0,不要在 bar 上顯示錯誤。
 */
export function useUnreadNotifications() {
  const [count, setCount] = useState(0);
  const pathname = usePathname();

  const refresh = useCallback(async () => {
    const s = getSession();
    if (!s || !s.memberId || !s.token) {
      setCount(0);
      return;
    }
    try {
      const d = await callLiffApi<{ count: number }>(s.token, {
        action: "get_my_unread_notification_count",
      });
      setCount(Number(d.count ?? 0));
    } catch {
      // 靜默失敗,bar 上不要冒紅字
    }
  }, []);

  // mount + pathname 變化
  useEffect(() => {
    refresh();
  }, [refresh, pathname]);

  // 等 session 入 localStorage 後再補一輪 (LIFF 首次登入)
  useEffect(() => listenForSession(() => refresh()), [refresh]);

  // 回到前景就刷新一次
  useEffect(() => {
    if (typeof window === "undefined") return;
    const onFocus = () => refresh();
    const onVisibility = () => {
      if (document.visibilityState === "visible") refresh();
    };
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [refresh]);

  return { count, refresh };
}
