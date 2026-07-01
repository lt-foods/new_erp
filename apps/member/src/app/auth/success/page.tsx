"use client";

import { useEffect, useState } from "react";
import { consumeFragmentToSession } from "@/lib/session";

export default function AuthSuccessPage() {
  const [code, setCode] = useState<string | null>(null);
  const [paired, setPaired] = useState(false);
  const [profile, setProfile] = useState<{ name: string | null; picture: string | null }>({
    name: null,
    picture: null,
  });

  useEffect(() => {
    // 從 hash / query 抓 code / paired 旗標 (line-oauth-callback 把全部塞進 fragment)
    const hp = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    const sp = new URLSearchParams(window.location.search);
    const isPaired = hp.get("paired") === "1" || sp.get("paired") === "1";

    // 把 fragment 寫進 localStorage 並清 URL（會回傳 session）
    const session = consumeFragmentToSession();

    // LINE webview 內、且不是 PWA 配對回流 → 直接進商店,不停在這個「安裝/取碼」頁。
    // (PWA 配對 paired=1 要留在這頁提示回桌面；桌機取碼流程也維持原樣)
    const isLine = typeof navigator !== "undefined" && / Line\//i.test(navigator.userAgent);
    if (session && session.memberId && isLine && !isPaired) {
      window.location.replace("/shop");
      return;
    }

    const c = hp.get("code") ?? sp.get("code");
    if (c) setCode(c);
    if (isPaired) setPaired(true);
    if (session) setProfile({ name: session.lineName, picture: session.linePicture });
  }, []);

  return (
    <main className="mx-auto flex w-full max-w-md flex-col items-center gap-8 p-6 pt-16 text-center">
      {profile.picture ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={profile.picture}
          alt=""
          className="h-20 w-20 rounded-full shadow-md"
          referrerPolicy="no-referrer"
        />
      ) : (
        <div className="flex h-20 w-20 items-center justify-center rounded-full bg-green-100">
          <svg className="h-10 w-10 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
          </svg>
        </div>
      )}

      <div className="space-y-2">
        <h1 className="text-2xl font-bold">{profile.name ?? "LINE 驗證成功"}</h1>
        {profile.name && (
          <p className="text-sm text-zinc-500">驗證成功</p>
        )}
        {paired ? (
          <p className="pt-2 text-base text-zinc-600">
            請關閉此視窗，回到桌面點擊 <span className="font-semibold">PWA App</span> 圖示
            <br />
            App 會自動完成登入
          </p>
        ) : (
          <a
            href="/install"
            className="mt-4 inline-block rounded-md bg-[#06C755] px-6 py-2.5 text-base font-medium text-white shadow hover:bg-[#05b04c] transition"
          >
            前往安裝步驟
          </a>
        )}
      </div>

      {code && !paired && (
        <div className="w-full space-y-4 rounded-xl border-2 border-dashed border-zinc-200 bg-zinc-50 p-6">
          <p className="text-sm font-medium text-zinc-400 uppercase tracking-wider">
            如果您正在使用 PWA App
          </p>
          <p className="text-base text-zinc-600">
            請回到 App 並輸入此 6 位數驗證碼：
          </p>
          <div className="text-5xl font-mono font-bold tracking-[0.5em] text-indigo-600">
            {code}
          </div>
          <p className="text-xs text-zinc-400">
            此驗證碼將於 5 分鐘後失效
          </p>
        </div>
      )}

      <p className="text-sm text-zinc-400">
        完成後您可以關閉此視窗。
      </p>
    </main>
  );
}
