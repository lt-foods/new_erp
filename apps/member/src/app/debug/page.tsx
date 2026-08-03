"use client";

import { useEffect, useState } from "react";
import { clearLocalLogs, getLocalLogs, type ClientLogEntry } from "@/lib/clientLog";

/**
 * 客服用的錯誤紀錄頁：會員回報「壞掉」時，請他開 /debug 截圖或按「複製」貼給我們。
 *
 * 這頁只讀本機 ring buffer，不打 API — 因為最常見的情境就是網路 / 登入本身壞掉，
 * 這時候還能打的 API 也不多。完整紀錄在 DB 的 client_error_logs。
 */
export default function DebugPage() {
  const [logs, setLogs] = useState<ClientLogEntry[]>([]);
  const [copied, setCopied] = useState(false);
  const [env, setEnv] = useState<Record<string, string>>({});

  useEffect(() => {
    setLogs(getLocalLogs().slice().reverse());
    const nav = navigator as Navigator & { standalone?: boolean };
    setEnv({
      "在 LINE 內": / Line\//i.test(nav.userAgent) ? "是" : "否",
      "PWA (standalone)":
        nav.standalone === true ||
        window.matchMedia("(display-mode: standalone)").matches
          ? "是"
          : "否",
      "門市": localStorage.getItem("member_store_id") ?? "（無）",
      "已登入": localStorage.getItem("member_jwt") ? "是" : "否",
      "UA": nav.userAgent,
    });
  }, []);

  const copy = async () => {
    const text = JSON.stringify({ env, logs }, null, 2);
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // 剪貼簿被擋（LINE webview 常見）→ 請使用者截圖
      setCopied(false);
    }
  };

  return (
    <main className="mx-auto w-full max-w-md px-4 py-6">
      <h1 className="text-[20px] font-bold text-[var(--foreground)]">錯誤紀錄</h1>
      <p className="mt-1 text-[13px] text-[var(--secondary-label)]">
        回報問題時，請把這頁截圖或按「複製」貼給客服。
      </p>

      <div className="card mt-4 space-y-1.5 p-4">
        {Object.entries(env).map(([k, v]) => (
          <div key={k} className="flex gap-2 text-[13px]">
            <span className="shrink-0 text-[var(--secondary-label)]">{k}</span>
            <span className="break-all font-medium text-[var(--foreground)]">{v}</span>
          </div>
        ))}
      </div>

      <div className="mt-4 flex gap-2">
        <button
          onClick={copy}
          className="flex-1 rounded-xl brand-gradient px-4 py-2.5 text-[15px] font-semibold text-white active:scale-[0.98]"
        >
          {copied ? "已複製" : "複製全部"}
        </button>
        <button
          onClick={() => { clearLocalLogs(); setLogs([]); }}
          className="rounded-xl border border-[var(--separator)] px-4 py-2.5 text-[15px] font-medium text-[var(--secondary-label)] active:scale-[0.98]"
        >
          清除
        </button>
      </div>

      {logs.length === 0 ? (
        <p className="mt-6 text-center text-[14px] text-[var(--tertiary-label)]">
          目前沒有錯誤紀錄
        </p>
      ) : (
        <ul className="mt-4 space-y-2">
          {logs.map((l, i) => (
            <li key={i} className="card p-3">
              <div className="flex items-baseline justify-between gap-2">
                <span
                  className={
                    "text-[13px] font-bold " +
                    (l.level === "error"
                      ? "text-[#c4271d]"
                      : "text-[var(--secondary-label)]")
                  }
                >
                  {l.source}
                </span>
                <span className="shrink-0 text-[11px] text-[var(--tertiary-label)]">
                  {l.at.replace("T", " ").slice(0, 19)}
                </span>
              </div>
              <p className="mt-1 break-all text-[13px] text-[var(--foreground)]">
                {l.message}
              </p>
              {l.detail != null && (
                <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-all text-[11px] text-[var(--tertiary-label)]">
                  {JSON.stringify(l.detail)}
                </pre>
              )}
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
