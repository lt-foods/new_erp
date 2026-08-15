"use client";

import { useState } from "react";
import { copyText, shareToLine, type ShareResult } from "@/lib/shareLink";

/**
 * 「分享到 LINE / 複製連結」兩顆鈕。
 *
 * 分享出去的連結長什麼樣（縮圖、團名、起跳價）是伺服器端的 og tag 決定的，
 * 這個元件只負責把網址交給 LINE，實際的退路鏈在 lib/shareLink.ts。
 *
 * 提示訊息一律畫在按鈕下方而不是用 alert：LIFF / PWA 裡的 alert 會蓋掉整個
 * 畫面，而「已複製」這種回饋值不了那個代價。複製失敗（非 https / 舊 webview
 * 沒有 clipboard API）時把連結原地顯示出來，讓使用者長按自己複製 ——
 * 不要只留一句「複製失敗」。
 */
export default function ShareButtons({
  url,
  text,
  className = "",
}: {
  url: string;
  /** 附在連結前面的一行字（例：團名） */
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

  const onShare = async () => {
    if (busy) return;
    setBusy(true);
    setFallbackUrl(null);
    try {
      const r: ShareResult = await shareToLine({ url, text });
      if (r === "copied") flash("這個裝置不能直接開 LINE，連結已複製，貼給朋友就可以了");
      else if (r === "failed") {
        setFallbackUrl(url);
        flash("分享失敗，請長按下面的連結複製");
      } else if (r === "shared_in_line") flash("已分享 🎉");
      // cancelled / opened_line 不提示：使用者自己取消，或畫面已經交棒給 LINE
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
          className="inline-flex items-center gap-1.5 rounded-full bg-[#06C755] px-3.5 py-1.5 text-[14px] font-semibold text-white shadow-[0_6px_14px_-8px_rgba(6,199,85,0.9)] transition-transform active:scale-[0.97] disabled:opacity-60"
        >
          <ShareIcon className="h-4 w-4" />
          分享到 LINE
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
