"use client";

import { useEffect } from "react";
import { getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";

const INTERVAL_MS = 60_000;
const ANON_KEY = "presence_anon_id";

/** 訪客匿名 id：localStorage 一顆 UUID（舊 iOS 沒有 crypto.randomUUID，手拼一顆）。 */
function getAnonId(): string | null {
  try {
    let v = localStorage.getItem(ANON_KEY);
    if (!v) {
      if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
        v = crypto.randomUUID();
      } else {
        const hex = (n: number) =>
          Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
        v = `${hex(8)}-${hex(4)}-4${hex(3)}-${hex(4)}-${hex(12)}`;
      }
      localStorage.setItem(ANON_KEY, v);
    }
    return v;
  } catch {
    return null; // localStorage 不可用（無痕/封鎖）就不統計，功能照常
  }
}

/**
 * 在線心跳：admin 儀表板的「同時在線 / 今日活躍」數的就是這個。
 * - 已登入會員：走 liff-api 的 heartbeat（身分取自 token），每頁都算。
 * - 未登入訪客：只在商城（/shop*）頁面，用匿名 id 走免 token 的
 *   guest_heartbeat —— 分享連結點進來還沒登入的人也要算（Alex 2026-08-27）。
 * - 分頁在背景不打；回到前景立刻補一發（防抖 55 秒）。
 * - 純加值訊號：失敗安靜吞掉 —— 不進 client_error_logs，網路差時每分鐘
 *   記一筆只會把真正的錯誤淹掉；下一分鐘自然重試。
 */
export default function PresenceHeartbeat() {
  useEffect(() => {
    let last = 0;
    const beat = () => {
      if (document.visibilityState !== "visible") return;
      if (Date.now() - last < INTERVAL_MS - 5_000) return;

      const s = getSession();
      if (s?.token && s.bound) {
        last = Date.now();
        callLiffApi(s.token, { action: "heartbeat" }).catch(() => {});
        return;
      }

      if (!window.location.pathname.startsWith("/shop")) return;
      const anon = getAnonId();
      const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
      if (!anon || !base) return;
      last = Date.now();
      void fetch(`${base}/functions/v1/liff-api`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "guest_heartbeat", anon_id: anon }),
      }).catch(() => {});
    };
    beat();
    const timer = setInterval(beat, INTERVAL_MS);
    document.addEventListener("visibilitychange", beat);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", beat);
    };
  }, []);

  return null;
}
