"use client";

import { useState } from "react";
import { NoteVideoPicker } from "@/components/NoteVideoPicker";
import { finalizeVideoLink, videoLinkStatus } from "@/lib/videoLink";

/**
 * 介紹影片的輸入區（商品編輯頁與編輯開團共用）：
 *   連結輸入框 ＋ 當場講「客人會看到什麼」的提示 ＋「從 LINE 記事本挑影片」。
 *
 * 只管輸入，不管存檔 —— 存到哪裡（products.intro_video_url）、什麼時候存，由外面決定：
 * 商品頁跟著整張表單的「儲存」，編輯開團是自己一顆「存」。
 * 存檔前外面要再呼叫一次 finalizeVideoLink（使用者可能貼完 TikTok 短連結沒離開欄位就按存）。
 *
 * 這一塊會出現在 <form> 裡面，裡面的按鈕都是 type="button"（見 NoteVideoPicker）。
 */
export function VideoLinkEditor({
  value,
  onChange,
  inputClassName,
}: {
  value: string;
  onChange: (next: string) => void;
  inputClassName: string;
}) {
  const [resolving, setResolving] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  // TikTok App 複製出來的是短連結，嵌不了；離開欄位時換成帶影片代號的網址。換不到就維持原樣。
  const onBlur = async () => {
    if (videoLinkStatus(value).kind !== "tiktok_short") return;
    setResolving(true);
    const final = await finalizeVideoLink(value);
    setResolving(false);
    if (final !== value.trim()) {
      onChange(final);
      setNote("已把 TikTok 短連結換成可以直接播放的網址。");
    } else {
      setNote("這個 TikTok 短連結換不到影片（可能失效或不公開）。照樣可以存，客人點了會跳去 TikTok 開啟。");
    }
  };

  return (
    <>
      <input
        type="url"
        inputMode="url"
        value={value}
        onChange={(e) => { onChange(e.target.value); setNote(null); }}
        onBlur={() => { void onBlur(); }}
        placeholder="從下方挑 LINE 記事本的影片，或貼上 YouTube / TikTok / IG Reel / Facebook 影片的連結"
        aria-label="介紹影片連結"
        className={inputClassName}
      />
      <VideoLinkHint url={value} resolving={resolving} note={note} />
      <NoteVideoPicker current={value} onPick={(url) => { onChange(url); setNote(null); }} />
    </>
  );
}

// 貼完連結當場講「客人會看到什麼」：能直接播、只能跳出去開、還是根本不是網址。
function VideoLinkHint({ url, resolving, note }: { url: string; resolving: boolean; note: string | null }) {
  const cls = "mt-1 block text-[11px]";
  if (resolving) return <span className={`${cls} text-zinc-500`}>正在向 TikTok 查這支影片…</span>;
  const st = videoLinkStatus(url);
  const noteLine = note ? <span className={`${cls} text-zinc-500`}>{note}</span> : null;
  if (st.kind === "empty") {
    return (
      <span className={`${cls} text-zinc-500`}>
        有填的話，會員商品頁會出現一個浮動的小視窗自動播放這支影片（客人可以拖動、可以關掉），點一下放大看有聲音的完整版。影片要設成公開。
      </span>
    );
  }
  if (st.kind === "invalid") {
    return <span className={`${cls} text-red-600`}>這不是 https:// 開頭的網址，請重新複製影片的連結。</span>;
  }
  if (st.kind === "embed") {
    return (
      <>
        <span className={`${cls} text-emerald-700 dark:text-emerald-400`}>
          ✓ {st.label === "影片" ? "影片檔" : `${st.label} 影片`}，會員商品頁會出現浮動小視窗
          {st.label === "LINE 記事本" || st.label === "影片" || st.label === "YouTube" ? "，而且會自動播放（靜音）。" : "。"}
        </span>
        {st.label === "Instagram" && (
          <span className={`${cls} text-amber-700 dark:text-amber-400`}>
            Instagram 不讓影片在小視窗裡自動播放，客人看到的會是一張靜止的預覽、點了才播。要自動播請改貼 YouTube、TikTok 或影片檔的連結。
          </span>
        )}
        {noteLine}
      </>
    );
  }
  if (st.kind === "tiktok_short") {
    return noteLine ?? <span className={`${cls} text-zinc-500`}>TikTok 短連結，離開這一格時會自動換成可以直接播放的網址。</span>;
  }
  return (
    <span className={`${cls} text-amber-700 dark:text-amber-400`}>
      這種連結沒辦法嵌在頁面裡播：不會有浮動小視窗，只有一顆「影片介紹」按鈕，客人點了會跳去開這個連結。要小視窗請貼 YouTube、TikTok、IG Reel、Facebook 影片或影片檔（.mp4）的連結。
    </span>
  );
}
