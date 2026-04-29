"use client";

import { useEffect, useState } from "react";
import { lineOauthStartUrl } from "@/lib/supabase";
import { loadLiff } from "@/lib/liff";

type Status = "loading" | "idle" | "liff_auth" | "error";

export default function LandingPage() {
  const [storeId, setStoreId] = useState<string | null>(null);
  const [status, setStatus] = useState<Status>("loading");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const errInUrl = new URLSearchParams(window.location.search).get("error");
      if (errInUrl) setError(errInUrl);

      const liffId = process.env.NEXT_PUBLIC_LIFF_ID;

      // 若有 LIFF ID → 先跑 liff.init()，它會把 liff.state 裡的 query 還原回 URL
      if (liffId) {
        try {
          const liff = await loadLiff();
          await liff.init({ liffId });

          // init 完後才讀 URL（liff.state 已還原）
          const s = readStore();
          setStoreId(s);

          if (!s) {
            setStatus("idle");
            return;
          }

          if (liff.isInClient()) {
            // 在 LINE 內 → 自動完成登入 + 註冊
            setStatus("liff_auth");

            if (!liff.isLoggedIn()) {
              liff.login();
              return;
            }

            const idToken = liff.getIDToken();
            if (!idToken) throw new Error("LIFF getIDToken returned null");

            await runLiffSession(idToken, s);
            return;
          }

          // 不在 LINE 內（直接打網址）→ 維持 OAuth 按鈕流程
          setStatus("idle");
          return;
        } catch (e) {
          console.warn("liff init failed, falling back:", e);
          // fall-through 到一般流程
        }
      }

      // 無 LIFF ID 或 init 失敗 → 普通瀏覽器流程
      const s = readStore();
      setStoreId(s);
      setStatus("idle");
    })();
  }, []);

  const start = () => {
    if (!storeId) return;
    window.location.href = lineOauthStartUrl(storeId);
  };

  return (
    <main className="mx-auto flex w-full max-w-md flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-semibold">團購店會員</h1>
      <p className="text-base text-zinc-500">歡迎加入！點下方按鈕用 LINE 快速註冊。</p>

      {error && (
        <div className="w-full rounded-md border border-red-200 bg-red-50 p-3 text-base text-red-800">
          登入失敗：{error}
        </div>
      )}

      {status === "loading" && (
        <p className="text-base text-zinc-400">載入中…</p>
      )}

      {status === "liff_auth" && (
        <p className="text-base text-zinc-500">LINE 驗證中…請稍候</p>
      )}

      {status === "idle" && !storeId && (
        <div className="w-full rounded-md border border-amber-300 bg-amber-50 p-4 text-base text-amber-900">
          請從門市 LINE 官方帳號提供的連結進入。
          <div className="mt-1 font-mono text-sm text-amber-700">缺少 store 參數</div>
        </div>
      )}

      {status === "idle" && storeId && (
        <button
          onClick={start}
          className="w-full rounded-md bg-[#06C755] px-4 py-3 text-base font-medium text-white shadow hover:bg-[#05b04c]"
        >
          用 LINE 註冊 / 登入
        </button>
      )}

      <p className="text-center text-sm text-zinc-400">
        門市代號：{storeId ?? "—"}
      </p>
    </main>
  );
}

function readStore(): string | null {
  // liff.init 後 liff.state 已展開；直接讀 search
  const sp = new URLSearchParams(window.location.search);
  const s = sp.get("store");
  if (s) return s;

  // 備援：少數情境 liff.init 沒展開時、自己從 liff.state 解
  const raw = sp.get("liff.state");
  if (raw) {
    const inner = new URLSearchParams(raw.startsWith("?") ? raw.slice(1) : raw);
    return inner.get("store");
  }
  return null;
}

async function runLiffSession(idToken: string, storeId: string) {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");

  const resp = await fetch(`${base}/functions/v1/liff-session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id_token: idToken, store: storeId }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    throw new Error(
      (data as { error?: string; detail?: string }).detail
      ?? (data as { error?: string }).error
      ?? `liff-session ${resp.status}`,
    );
  }

  const frag = new URLSearchParams({
    token:        String(data.token),
    store:        String(data.store),
    bound:        "1",
    member_id:    String(data.member_id),
    line_user_id: String(data.line_user_id ?? ""),
  });
  if (data.line_name)    frag.set("line_name",    String(data.line_name));
  if (data.line_picture) frag.set("line_picture", String(data.line_picture));
  window.location.href = `/me#${frag.toString()}`;
}
