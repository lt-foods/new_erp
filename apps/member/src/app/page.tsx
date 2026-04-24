"use client";

import { useEffect, useState } from "react";
import { lineOauthStartUrl } from "@/lib/supabase";

/**
 * Landing / signup
 * 期望 URL：/signup?store=123  或  /?store=123
 */
export default function LandingPage() {
  const [storeId, setStoreId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const sp = new URLSearchParams(window.location.search);
    const s = sp.get("store");
    const err = sp.get("error");
    if (err) setError(err);
    if (s) setStoreId(s);
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

      {!storeId ? (
        <div className="w-full rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
          請從門市 LINE 官方帳號提供的連結進入。
          <div className="mt-1 font-mono text-xs text-amber-700">缺少 store 參數</div>
        </div>
      ) : (
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
