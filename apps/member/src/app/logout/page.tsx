"use client";

import { useState } from "react";
import { hardLogout, type LogoutStep } from "@/lib/logout";
import Spinner from "@/components/Spinner";

/**
 * 登出 / 重置這台裝置。
 *
 * 做成獨立路徑（直接開 /logout 就能到）是為了測試：要驗證登入流程時，
 * 需要一個可靠的方法回到「從沒登入過」的狀態，而不是靠手動清瀏覽器資料。
 *
 * 不在載入時就自動清 —— 誤觸或被分享到這個網址會直接把人登出。
 * 先列出會清什麼，按下才執行。
 */
export default function LogoutPage() {
  const [state, setState] = useState<"idle" | "running" | "done">("idle");
  const [steps, setSteps] = useState<LogoutStep[]>([]);

  const run = async () => {
    setState("running");
    setSteps(await hardLogout());
    setState("done");
  };

  return (
    <main className="mx-auto flex min-h-[100dvh] w-full max-w-md flex-col px-6 py-10">
      <h1 className="text-[22px] font-bold text-[var(--foreground)]">登出並重置</h1>
      <p className="mt-2 text-[14px] leading-relaxed text-[var(--secondary-label)]">
        把這台裝置恢復成「從沒登入過」的狀態。下次進入時會重新選門市、重新用 LINE 登入。
      </p>

      {state === "idle" && (
        <>
          <ul className="card mt-5 space-y-2 p-5 text-[14px] text-[var(--secondary-label)]">
            <li>· LINE LIFF 的登入狀態</li>
            <li>· 推播訂閱</li>
            <li>· 會員登入資料、記住的門市</li>
            <li>· PWA 快取與 Service Worker</li>
            <li>· App 圖示上的未讀數</li>
          </ul>
          <button
            onClick={run}
            className="mt-5 w-full rounded-xl bg-[var(--ios-red)] px-4 py-3.5 text-[16px] font-semibold text-white transition active:scale-[0.98]"
          >
            確定登出並清除
          </button>
          <a
            href="/"
            className="mx-auto mt-4 block text-[14px] font-medium text-[var(--secondary-label)] underline underline-offset-4"
          >
            取消，回首頁
          </a>
        </>
      )}

      {state === "running" && (
        <div className="card mt-5 flex flex-col items-center gap-3 p-8">
          <Spinner size={28} />
          <p className="text-[15px] text-[var(--secondary-label)]">清除中…</p>
        </div>
      )}

      {state === "done" && (
        <>
          <ul className="card mt-5 space-y-2.5 p-5">
            {steps.map((s, i) => (
              <li key={i} className="flex gap-2 text-[14px]">
                <span className={s.ok ? "text-[var(--ios-green,#34c759)]" : "text-[#c4271d]"}>
                  {s.ok ? "✓" : "✕"}
                </span>
                <span className="flex-1">
                  <span className="text-[var(--foreground)]">{s.label}</span>
                  {s.detail && (
                    <span className="block text-[12px] text-[var(--tertiary-label)]">
                      {s.detail}
                    </span>
                  )}
                </span>
              </li>
            ))}
          </ul>

          <p className="mt-4 text-[13px] leading-relaxed text-[var(--tertiary-label)]">
            如果這是安裝在桌面的 App，建議把它從多工列滑掉再重開，確保舊的
            Service Worker 完全結束。
          </p>

          {/* 用 a 而非 router：要的是完整重新載入，讓剛註銷的 SW 不再接管這一頁 */}
          <a
            href="/"
            className="mt-5 block w-full rounded-xl brand-gradient px-4 py-3.5 text-center text-[16px] font-semibold text-white transition active:scale-[0.98]"
          >
            回到首頁重新登入
          </a>
        </>
      )}
    </main>
  );
}
