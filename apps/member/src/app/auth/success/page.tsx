"use client";

import { useEffect, useState } from "react";
import { consumeFragmentToSession } from "@/lib/session";
import { AUTH_CODE_INTENT_KEY, clearSessionFlag, sessionFlag } from "@/lib/lineAuth";

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

    // 登入成功的人**預設就該進商店**，這頁只是 OAuth 的落點，不是目的地。
    //
    // 只有兩種人要留在這裡：
    //   1. paired=1 —— PWA 自動配對回流，要提示他回桌面開 App
    //   2. want_code —— PWA 自動配對失敗，照指引跑來瀏覽器取那 6 碼
    // 除此之外（自己從 /join 或首頁登入的人）一律送進 /shop。
    //
    // 原本的條件是「只有 LINE webview 內才送進商店」，於是從 /join 用 Safari
    // 登入的人會停在這頁的「前往安裝步驟 + 6 位數驗證碼」畫面 —— 對他來說
    // 那組碼毫無意義，而他要的商品在哪完全沒講，等於推廣流量走到一半斷掉。
    const wantsCode = sessionFlag(AUTH_CODE_INTENT_KEY);
    if (session && session.memberId && !isPaired && !wantsCode) {
      window.location.replace("/shop");
      return;
    }
    // 取碼意圖只用這一次，用完就清掉，否則同一個分頁之後每次登入都會卡在取碼頁
    if (wantsCode) clearSessionFlag(AUTH_CODE_INTENT_KEY);

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
