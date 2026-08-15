"use client";

import { useState } from "react";
import { copyText, sharePage, type ShareResult } from "@/lib/shareLink";

/**
 * 「分享 / 複製連結」兩顆鈕。
 *
 * 「分享」叫的是**手機自帶的分享面板**（iOS 那張由下往上的表、Android 的分享匣），
 * LINE、訊息、AirDrop 都在裡面 —— 不替使用者決定要分享到哪。沒有這個 API 的環境
 * 會自動退到 LINE 的分享路徑，退法在 lib/shareLink.ts。
 *
 * 分享出去的連結長什麼樣（縮圖、團名、起跳價）是伺服器端的 og tag 決定的，
 * 這個元件只負責把網址交出去。
 *
 * 提示訊息一律畫在按鈕下方而不是用 alert：LIFF / PWA 裡的 alert 會蓋掉整個
 * 畫面，而「已複製」這種回饋值不了那個代價。複製失敗（非 https / 舊 webview
 * 沒有 clipboard API）時把連結原地顯示出來，讓使用者長按自己複製 ——
 * 不要只留一句「複製失敗」。
 */
export default function ShareButtons({
  url,
  title,
  text,
  className = "",
}: {
  url: string;
  /** 原生分享面板顯示的標題（例：團名） */
  title?: string;
  /** 附在連結前面的一行字 */
  text?: string;
  className?: string;
}) {
  const [hint, setHint] = useState<string | null>(null);
  const [fallbackUrl, setFallbackUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const flash = (msg: string | null) => {
    setHint(msg);
    if (msg) window.setTimeout(() => setHint((cur) => (cur === msg ? null : cur)), 3000);
  };

  // 注意：不要在 sharePage() 之前 await 任何東西 —— navigator.share 需要
  // user gesture，先 await 過 Safari 就會判定不是手勢而拒絕叫出面板。
  const onShare = async () => {
    if (busy) return;
    setBusy(true);
    setFallbackUrl(null);
    try {
      const r: ShareResult = await sharePage({ url, title, text });
      if (r === "copied") flash("這個裝置叫不出分享面板，連結已複製，貼給朋友就可以了");
      else if (r === "failed") {
        setFallbackUrl(url);
        flash("分享失敗，請長按下面的連結複製");
      } else if (r === "shared_in_line") flash("已分享 🎉");
      // shared_native / cancelled / opened_line 不提示：
      // 面板自己會回饋，或使用者本來就取消了
    } finally {
      setBusy(false);
    }
  };

  const onCopy = async () => {
    setFallbackUrl(null);
    if (await copyText(url)) {
      flash("連結已複製");
      return;
    }
    setFallbackUrl(url);
    flash("這個裝置不能自動複製，請長按下面的連結");
  };

  return (
    <div className={className}>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onShare}
          disabled={busy}
          className="inline-flex items-center gap-1.5 rounded-full bg-[var(--brand-soft)] px-3.5 py-1.5 text-[14px] font-semibold text-[var(--brand-strong)] transition-transform active:scale-[0.97] disabled:opacity-60"
        >
          <ShareIcon className="h-4 w-4" />
          分享
        </button>
        <button
          type="button"
          onClick={onCopy}
          className="inline-flex items-center gap-1.5 rounded-full bg-[#7676801f] px-3.5 py-1.5 text-[14px] font-medium text-[var(--foreground)] transition-transform active:scale-[0.97]"
        >
          <LinkIcon className="h-4 w-4" />
          複製連結
        </button>
      </div>
      {hint && (
        <p className="mt-1.5 text-[13px] text-[var(--secondary-label)]">{hint}</p>
      )}
      {fallbackUrl && (
        <p className="mt-1 select-all break-all text-[13px] text-[var(--tertiary-label)]">
          {fallbackUrl}
        </p>
      )}
    </div>
  );
}

/** iOS 的分享圖示（方框 + 往上的箭頭），跟系統面板長一樣，使用者一眼認得 */
function ShareIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.9}
      aria-hidden
      className={`shrink-0 ${className}`}
    >
      <path strokeLinecap="round" strokeLinejoin="round" d="M12 15.5V3.5m0 0L8 7.5m4-4 4 4" />
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M5 12.5v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6"
      />
    </svg>
  );
}

function LinkIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.9}
      aria-hidden
      className={`shrink-0 ${className}`}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M10 13.5a3.5 3.5 0 0 0 5 0l3-3a3.5 3.5 0 1 0-5-5l-1 1"
      />
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M14 10.5a3.5 3.5 0 0 0-5 0l-3 3a3.5 3.5 0 1 0 5 5l1-1"
      />
    </svg>
  );
}
