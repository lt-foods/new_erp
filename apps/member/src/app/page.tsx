"use client";

import { useEffect, useState } from "react";
import { lineOauthStartUrl } from "@/lib/supabase";

type Status = "loading" | "idle" | "liff_auth" | "error";

export default function LandingPage() {
  const [storeId, setStoreId] = useState<string | null>(null);
  const [status, setStatus] = useState<Status>("loading");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const sp = new URLSearchParams(window.location.search);
    const s = sp.get("store");
    const err = sp.get("error");
    if (err) setError(err);
    setStoreId(s);

    if (!s) {
      setStatus("idle");
      return;
    }

    // 偵測 LIFF 環境；在 LINE 內 → 自動登入 + auto-register，完全跳過按鈕
    const liffId = process.env.NEXT_PUBLIC_LIFF_ID;
    if (!liffId) {
      setStatus("idle");
      return;
    }

    (async () => {
      try {
        const liffModule = await import("@line/liff");
        const liff = liffModule.default;
        await liff.init({ liffId });

        if (!liff.isInClient()) {
          // 正常瀏覽器 → 走 OAuth 按鈕流程
          setStatus("idle");
          return;
        }

        setStatus("liff_auth");

        if (!liff.isLoggedIn()) {
          liff.login();  // 會重導；回來時會走進 if(isLoggedIn) 分支
          return;
        }

        const idToken = liff.getIDToken();
        if (!idToken) throw new Error("LIFF getIDToken returned null");

        const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
        if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");

        const resp = await fetch(`${base}/functions/v1/liff-session`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id_token: idToken, store: s }),
        });
        const data = await resp.json().catch(() => ({}));
        if (!resp.ok) {
          throw new Error((data as { error?: string; detail?: string }).detail
            ?? (data as { error?: string }).error
            ?? `liff-session ${resp.status}`);
        }

        const frag = new URLSearchParams({
          token:    String(data.token),
          store:    String(data.store),
          bound:    "1",
          member_id: String(data.member_id),
          line_user_id: String(data.line_user_id ?? ""),
        });
        if (data.line_name)    frag.set("line_name",    String(data.line_name));
        if (data.line_picture) frag.set("line_picture", String(data.line_picture));
        window.location.href = `/me#${frag.toString()}`;
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
        setStatus("error");
      }
    })();
  }, []);

  const start = () => {
    if (!storeId) return;
    window.location.href = lineOauthStartUrl(storeId);
  };

  return (
    <main className="mx-auto flex w-full max-w-md flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-2xl font-semibold">團購店會員</h1>
      <p className="text-sm text-zinc-500">歡迎加入！點下方按鈕用 LINE 快速註冊。</p>

      {error && (
        <div className="w-full rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          登入失敗：{error}
        </div>
      )}

      {status === "loading" && (
        <p className="text-sm text-zinc-400">載入中…</p>
      )}

      {status === "liff_auth" && (
        <p className="text-sm text-zinc-500">LINE 驗證中…請稍候</p>
      )}

      {status === "idle" && !storeId && (
        <div className="w-full rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
          請從門市 LINE 官方帳號提供的連結進入。
          <div className="mt-1 font-mono text-xs text-amber-700">缺少 store 參數</div>
        </div>
      )}

      {status === "idle" && storeId && (
        <button
          onClick={start}
          className="w-full rounded-md bg-[#06C755] px-4 py-3 text-sm font-medium text-white shadow hover:bg-[#05b04c]"
        >
          用 LINE 註冊 / 登入
        </button>
      )}

      <p className="text-center text-xs text-zinc-400">
        門市代號：{storeId ?? "—"}
      </p>
    </main>
  );
}
