"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { parseVideoEmbed, safeHttpsUrl, type VideoEmbed } from "@/lib/videoEmbed";

/**
 * 商品介紹影片：浮動小視窗（蝦皮那種）＋點開後的大視窗。
 *
 * 老闆 2026-11-22：「我不要影片介紹這樣而已，要有一個小視窗影片，像蝦皮這樣，還要可以移動」。
 *
 * - 小視窗：進商品頁就浮在右下角，靜音自動播放，可以用手指拖到任何位置（放開會靠左或靠右貼邊），
 *   右上角 ✕ 關掉。點一下（沒拖動）開大視窗看有聲音的完整版。
 * - 關掉之後，圖片右下角留一顆「影片介紹」讓客人還找得回來。
 * - 大視窗開著時小視窗先收起來（不要兩邊同時播、同時出聲），關掉大視窗再回來。
 * - 小視窗裡的播放器整個被一層透明的板子蓋住：iframe 會把手指的動作吃掉，不蓋就拖不動。
 * - 認不得的連結（抖音、其他網站）沒辦法嵌 → 沒有小視窗，只有那顆按鈕，點了開連結。
 *
 * 各家在小視窗裡的樣子不一樣（對方播放器給什麼算什麼）：
 *   影片檔（.mp4 …）／YouTube：靜音自動循環播放。TikTok：自動播放，靜音靠 postMessage（盡力而為）。
 *   Facebook：外掛的靜音自動播放。Instagram：不支援自動播放，小視窗裡是一張靜止的貼文預覽。
 */

// 小視窗的實際尺寸；iframe 用 3 倍大小去算版面再縮回來（對方的播放器在 100px 寬下會排版壞掉）
const MINI_PORTRAIT = { w: 108, h: 192 };
const MINI_LANDSCAPE = { w: 176, h: 99 };
const IFRAME_SCALE = 3;
const EDGE = 10;            // 貼邊時離螢幕邊緣的距離
const BOTTOM_RESERVED = 104; // 底部常駐下單列的高度（含一點間距）
const TAP_SLOP = 6;         // 手指移動超過這個距離就算拖動，不算點擊

function Portal({ children }: { children: React.ReactNode }) {
  if (typeof document === "undefined") return null;
  return createPortal(children, document.body);
}

function PlayIcon({ className }: { className: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden>
      <path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5Z" />
    </svg>
  );
}

/** 小視窗裡的播放器（靜音預覽）。永遠被上層的透明板子蓋住，不會直接被點到。 */
function MiniPlayer({ embed, size }: { embed: VideoEmbed; size: { w: number; h: number } }) {
  const frameRef = useRef<HTMLIFrameElement | null>(null);

  // TikTok 的播放器沒有「靜音」的網址參數，要等它說 ready 再用 postMessage 叫它靜音並開始播
  useEffect(() => {
    if (embed.provider !== "tiktok") return;
    const onMessage = (e: MessageEvent) => {
      if (e.origin !== "https://www.tiktok.com") return;
      const data = e.data as { "x-tiktok-player"?: boolean; type?: string } | null;
      if (!data || data["x-tiktok-player"] !== true || data.type !== "onPlayerReady") return;
      const win = frameRef.current?.contentWindow;
      if (!win) return;
      win.postMessage({ "x-tiktok-player": true, type: "mute" }, "https://www.tiktok.com");
      win.postMessage({ "x-tiktok-player": true, type: "play" }, "https://www.tiktok.com");
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [embed.provider]);

  if (embed.kind === "file") {
    return (
      <video
        src={embed.previewUrl}
        muted
        autoPlay
        loop
        playsInline
        preload="metadata"
        className="h-full w-full object-cover"
      />
    );
  }
  return (
    <iframe
      ref={frameRef}
      src={embed.previewUrl}
      title="影片預覽"
      tabIndex={-1}
      aria-hidden
      allow="autoplay; encrypted-media; picture-in-picture"
      referrerPolicy="strict-origin-when-cross-origin"
      className="border-0"
      style={{
        width: size.w * IFRAME_SCALE,
        height: size.h * IFRAME_SCALE,
        transform: `scale(${1 / IFRAME_SCALE})`,
        transformOrigin: "0 0",
        pointerEvents: "none",
      }}
    />
  );
}

export default function VideoIntro({ url, campaignId }: { url: string | null; campaignId: number }) {
  const link = safeHttpsUrl(url);
  const embed = useMemo(() => parseVideoEmbed(link), [link]);
  const size = embed?.portrait === false ? MINI_LANDSCAPE : MINI_PORTRAIT;

  const clamp = useCallback((x: number, y: number) => {
    const maxX = Math.max(EDGE, window.innerWidth - size.w - EDGE);
    const maxY = Math.max(EDGE, window.innerHeight - size.h - EDGE);
    return { x: Math.min(Math.max(EDGE, x), maxX), y: Math.min(Math.max(EDGE, y), maxY) };
  }, [size.w, size.h]);

  const [dismissed, setDismissed] = useState(false);   // 小視窗被 ✕ 關掉
  const [open, setOpen] = useState(false);             // 大視窗
  const [dragging, setDragging] = useState(false);
  // 起始位置：右下角、底部下單列的上面。呼叫端用 key（商品＋影片連結）讓這個元件在換商品時整個重來，
  // 所以這裡只要算一次；伺服器端沒有 window → null（那時也還沒有影片連結，不會畫小視窗）。
  const [pos, setPos] = useState<{ x: number; y: number } | null>(() =>
    typeof window === "undefined" ? null : clamp(window.innerWidth, window.innerHeight - size.h - BOTTOM_RESERVED));
  const drag = useRef<{ id: number; px: number; py: number; x: number; y: number; moved: boolean } | null>(null);

  // 轉螢幕／視窗大小變了：拉回畫面內
  useEffect(() => {
    const onResize = () => setPos((p) => (p ? clamp(p.x, p.y) : p));
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [clamp]);

  // 大視窗開著時鎖住背景捲動
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = prev; };
  }, [open]);

  if (!link) return null;

  const pill = "absolute bottom-3 right-3 z-10 flex items-center gap-1.5 rounded-2xl bg-black/70 py-1.5 pl-1.5 pr-3 text-[14px] font-semibold text-white shadow-lg backdrop-blur active:scale-95";
  const pillIcon = (
    <span className="flex h-8 w-8 items-center justify-center rounded-full bg-gradient-to-br from-[#ff3b30] to-[#ff7a00]">
      <PlayIcon className="ml-0.5 h-4 w-4" />
    </span>
  );

  // 嵌不了的連結：只有按鈕，點了開連結
  if (!embed) {
    return (
      <a href={link} target="_blank" rel="noopener noreferrer" className={pill}>
        {pillIcon}
        影片介紹
      </a>
    );
  }

  const onPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!pos) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    drag.current = { id: e.pointerId, px: e.clientX, py: e.clientY, x: pos.x, y: pos.y, moved: false };
  };
  const onPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    const dx = e.clientX - d.px;
    const dy = e.clientY - d.py;
    if (!d.moved && Math.abs(dx) + Math.abs(dy) < TAP_SLOP) return;
    if (!d.moved) { d.moved = true; setDragging(true); }
    setPos(clamp(d.x + dx, d.y + dy));
  };
  const onPointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    drag.current = null;
    setDragging(false);
    if (!d.moved) { setOpen(true); return; }
    // 放開後貼到比較近的那一邊（不會停在畫面正中間擋住內容）
    setPos((p) => {
      if (!p) return p;
      const toLeft = p.x + size.w / 2 < window.innerWidth / 2;
      return clamp(toLeft ? EDGE : window.innerWidth, p.y);
    });
  };
  const onPointerCancel = () => { drag.current = null; setDragging(false); };

  const showMini = !dismissed && !open && pos !== null;

  return (
    <>
      {/* 小視窗關掉之後，圖片右下角留一顆按鈕找得回來 */}
      {dismissed && (
        <button type="button" onClick={() => setOpen(true)} className={pill} aria-label="看影片介紹">
          {pillIcon}
          影片介紹
        </button>
      )}

      {showMini && pos && (
        <Portal>
          <div
            data-testid="video-mini"
            className="fixed left-0 top-0 z-[45]"
            style={{
              width: size.w,
              height: size.h,
              transform: `translate3d(${pos.x}px, ${pos.y}px, 0)`,
              // 跟著手指時不要有動畫（會拖泥帶水）；放開貼邊時才滑過去
              transition: dragging ? "none" : "transform 180ms ease-out",
            }}
          >
            <div className="h-full w-full overflow-hidden rounded-[10px] bg-black shadow-[0_6px_20px_rgba(0,0,0,0.35)] ring-2 ring-white/90">
              <MiniPlayer key={`${campaignId}-${embed.previewUrl}`} embed={embed} size={size} />
            </div>
            {/* 透明板子：接住拖動與點擊（iframe 會把手指動作吃掉） */}
            <div
              role="button"
              tabIndex={0}
              aria-label="影片介紹，點一下放大，可拖動"
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={onPointerUp}
              onPointerCancel={onPointerCancel}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setOpen(true); } }}
              className="absolute inset-0 cursor-grab rounded-[10px] active:cursor-grabbing"
              style={{ touchAction: "none", WebkitTapHighlightColor: "transparent" }}
            >
              {/* 靜音提示：點了才有聲音 */}
              <span className="pointer-events-none absolute bottom-1.5 left-1.5 flex h-6 w-6 items-center justify-center rounded-full bg-black/55 text-white">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} className="h-3.5 w-3.5" aria-hidden>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M11 5 6.5 9H3v6h3.5L11 19V5Z" />
                  <path strokeLinecap="round" d="m16 9.5 5 5m0-5-5 5" />
                </svg>
              </span>
            </div>
            <button
              type="button"
              aria-label="關閉影片小視窗"
              onClick={() => setDismissed(true)}
              className="absolute -right-2 -top-2 flex h-6 w-6 items-center justify-center rounded-full bg-zinc-500/95 text-[13px] font-bold leading-none text-white shadow ring-2 ring-white"
            >
              ✕
            </button>
          </div>
        </Portal>
      )}

      {open && (
        <Portal>
          <div
            className="fixed inset-0 z-[70] flex flex-col items-center justify-center gap-3 bg-black/90 px-4"
            onClick={() => setOpen(false)}
          >
            <button
              type="button"
              aria-label="關閉"
              onClick={() => setOpen(false)}
              className="absolute right-4 flex h-9 w-9 items-center justify-center rounded-full bg-white/15 text-[20px] text-white backdrop-blur"
              style={{ top: "calc(env(safe-area-inset-top) + 12px)" }}
            >
              ✕
            </button>
            <div
              onClick={(e) => e.stopPropagation()}
              className="overflow-hidden rounded-2xl bg-black shadow-2xl"
              style={embed.portrait
                ? { height: "min(74vh, 640px)", aspectRatio: "9 / 16", maxWidth: "92vw" }
                : { width: "min(92vw, 720px)", aspectRatio: "16 / 9" }}
            >
              {embed.kind === "file" ? (
                <video src={embed.embedUrl} controls autoPlay playsInline className="h-full w-full bg-black object-contain" />
              ) : (
                <iframe
                  key={`${campaignId}-${embed.embedUrl}`}
                  src={embed.embedUrl}
                  title="影片介紹"
                  className="h-full w-full border-0"
                  allow="autoplay; encrypted-media; fullscreen; picture-in-picture; web-share"
                  allowFullScreen
                  referrerPolicy="strict-origin-when-cross-origin"
                />
              )}
            </div>
            {embed.kind === "iframe" && (
              <a
                href={link}
                target="_blank"
                rel="noopener noreferrer"
                onClick={(e) => e.stopPropagation()}
                className="rounded-full bg-white/15 px-4 py-2 text-[14px] font-medium text-white backdrop-blur active:opacity-70"
              >
                播不出來？到 {embed.label} 開啟
              </a>
            )}
          </div>
        </Portal>
      )}
    </>
  );
}
