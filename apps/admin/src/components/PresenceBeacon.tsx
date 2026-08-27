"use client";

import { useEffect } from "react";
import { getSupabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";

const INTERVAL_MS = 60_000;

/**
 * 在線心跳（app_presence）：登入後每 60 秒回報一次，儀表板「同時在線／今日活躍」
 * 數的就是這個。分頁在背景不打，回到前景立刻補一發（防抖 55 秒）。
 * 純加值訊號：失敗安靜吞掉，下一分鐘自然重試。
 */
export default function PresenceBeacon() {
  const { session } = useAuth();

  useEffect(() => {
    if (!session) return;
    let last = 0;
    const beat = () => {
      if (document.visibilityState !== "visible") return;
      if (Date.now() - last < INTERVAL_MS - 5_000) return;
      last = Date.now();
      void getSupabase().rpc("rpc_heartbeat").then(() => {});
    };
    beat();
    const timer = setInterval(beat, INTERVAL_MS);
    document.addEventListener("visibilitychange", beat);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", beat);
    };
  }, [session]);

  return null;
}
