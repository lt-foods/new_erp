"use client";

// LINE 帳號連結（account link）的落地頁。
//
// 為什麼需要這一頁：LINE 的 user ID 是綁 Provider 的，各店官方帳號看到的
// 顧客 ID，跟會員站登入拿到的那組完全不同。店家要能主動推播，就得知道
// 「這位會員在該店 OA 的 ID 是哪一個」，而 LINE 官方提供的答案就是 account link。
//
// 顧客體驗上這頁應該幾乎沒有存在感：他在店家 LINE 裡問訂單，收到一則
// 「這裡可以查看您的訂單」，點進來（多半已登入）→ 自動轉一圈 → 回到 LINE。
// 綁定是副作用，他不需要理解「綁定」兩個字。所以這頁不解釋、不要求操作，
// 只在「還沒登入」時借用既有的登入流程。
//
// 登入一律走 useLineLogin，不在這裡重寫 —— 那條路上每個分支都是踩雷換來的。

import { useEffect, useRef, useState } from "react";
import { logCaught, logClientError } from "@/lib/clientLog";
import { readParam } from "@/lib/lineAuth";
import { getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import { useLineLogin } from "@/lib/useLineLogin";
import Spinner, { LoadingScreen } from "@/components/Spinner";

type Phase = "working" | "need_login" | "error";

export default function LinkPage() {
  const { status, error: loginError, start, storeId, chooseStore, stores } = useLineLogin({
    autoSelectSingleStore: true,
  });
  const [phase, setPhase] = useState<Phase>("working");
  const [message, setMessage] = useState<string | null>(null);
  // 轉址只能跑一次：React 嚴格模式會重跑 effect，跑兩次會把 nonce 浪費掉
  const startedRef = useRef(false);

  useEffect(() => {
    if (startedRef.current) return;

    const linkToken = readParam("lt");
    const storeCode = readParam("store");
    if (!linkToken || !storeCode) {
      setPhase("error");
      setMessage("連結不完整，請回到官方帳號重新點一次。");
      logClientError("account_link_missing_params", "缺 lt 或 store");
      return;
    }

    // 從店家 OA 進來時 useLineLogin 還在跑（可能正在 LIFF 自動登入），
    // 等它把 session 準備好再動作；沒登入就顯示登入按鈕。
    const session = getSession();
    if (!session?.memberId) {
      if (status === "loading" || status === "liff_auth") return;
      setPhase("need_login");
      return;
    }

    startedRef.current = true;
    (async () => {
      try {
        const { nonce } = await callLiffApi<{ nonce: string }>(session.token, {
          action: "create_account_link_nonce",
          store: storeCode,
        });
        // 交給 LINE 完成連結；成功後 LINE 會把使用者送回官方帳號對話，
        // 並對我們的 webhook 發一則 accountLink 事件（帶著同一個 nonce）。
        window.location.href =
          `https://access.line.me/dialog/bot/accountLink?linkToken=${encodeURIComponent(linkToken)}` +
          `&nonce=${encodeURIComponent(nonce)}`;
      } catch (e) {
        startedRef.current = false;
        setPhase("error");
        setMessage("連結失敗，請回到官方帳號再傳一次訊息取得新的連結。");
        logCaught("account_link_nonce_failed", e, { store: storeCode });
      }
    })();
  }, [status]);

  if (phase === "working") return <LoadingScreen />;

  if (phase === "need_login") {
    return (
      <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 p-6 text-center">
        <h1 className="text-lg font-semibold">查看我的訂單</h1>
        <p className="text-sm text-zinc-500">
          請先用 LINE 登入，登入後就會自動帶您回去。
        </p>

        {stores.length > 1 && !storeId && (
          <select
            value={storeId ?? ""}
            onChange={(e) => chooseStore(e.target.value || null)}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm"
          >
            <option value="">— 請選擇取貨門市 —</option>
            {stores.map((s) => (
              <option key={s.id} value={s.code}>{s.name}</option>
            ))}
          </select>
        )}

        <button
          onClick={start}
          disabled={!storeId}
          className="rounded-md bg-[#06C755] px-4 py-3 font-semibold text-white disabled:opacity-50"
        >
          {status === "loading" ? <Spinner /> : "用 LINE 登入"}
        </button>

        {loginError && <p className="text-xs text-red-600">{loginError}</p>}
      </main>
    );
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-3 p-6 text-center">
      <p className="text-sm text-red-600">{message}</p>
    </main>
  );
}
