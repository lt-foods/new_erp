"use client";

import { useCallback, useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { getSession } from "./session";
import { callLiffApi } from "./supabase";

/**
 * 提供 tab bar 上的「通知」未讀數
 *
 * 觸發 refresh 的時機:
 * 1. 元件 mount
 * 2. pathname 變化(切到 /notifications 後標已讀,回來會自動歸零)
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

  useEffect(() => {
    refresh();
  }, [refresh, pathname]);

  return { count, refresh };
}
