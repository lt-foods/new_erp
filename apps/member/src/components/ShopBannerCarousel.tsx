"use client";

import { useEffect, useRef, useState } from "react";

type Banner = {
  /** 唯一 key, 用來 React 渲染 + dots 識別 */
  key: string;
  /** 整個 banner 卡片內容 (含 Link / Image / 文案) */
  node: React.ReactNode;
};

/**
 * /shop 頂部 banner 跑馬燈。
 * - 0 張 → 不渲染
 * - 1 張 → 單張顯示, 不啟用 scroll/auto-play/dots
 * - 2+ 張 → horizontal scroll-snap, auto-play 4s, 觸碰暫停 8s
 *
 * scroll-snap-x mandatory，每張**整框寬**（w-full）：一次只看得到一張，
 * 在同一個框裡換頁。可滑的提示交給下面的 dots，不要靠露出下一張的邊
 * —— 露邊會把 banner 裡的標題／價格／倒數切一半，看起來像壞掉的版。
 *
 * ⚠ slideWidth 的算式（offsetWidth + 12）跟這裡的 gap-3 綁在一起，
 *   改 gap 要三處一起改（scroll 同步、auto-play、dots 點擊）。
 *   snapAlign 用 center：左右 padding 對稱時 scrollLeft 剛好 = i × slideWidth，
 *   跟那三處的算法對得上。
 */
export default function ShopBannerCarousel({ banners }: { banners: Banner[] }) {
  const scrollerRef = useRef<HTMLDivElement>(null);
  const [activeIdx, setActiveIdx] = useState(0);
  const pausedUntilRef = useRef<number>(0);

  // 用 scroll 事件 + 卡片寬度算出 active index (給 dots 同步)
  useEffect(() => {
    if (banners.length <= 1) return;
    const el = scrollerRef.current;
    if (!el) return;
    const onScroll = () => {
      const slide = el.querySelector<HTMLDivElement>("[data-slide]");
      if (!slide) return;
      const slideWidth = slide.offsetWidth + 12; // 12 = gap
      const idx = Math.round(el.scrollLeft / slideWidth);
      setActiveIdx(Math.max(0, Math.min(banners.length - 1, idx)));
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, [banners.length]);

  // Auto-play: 每 4s 切到下一張 (循環); 觸碰時暫停 8s
  useEffect(() => {
    if (banners.length <= 1) return;
    const el = scrollerRef.current;
    if (!el) return;
    const id = setInterval(() => {
      if (Date.now() < pausedUntilRef.current) return;
      const slide = el.querySelector<HTMLDivElement>("[data-slide]");
      if (!slide) return;
      const slideWidth = slide.offsetWidth + 12;
      const currentIdx = Math.round(el.scrollLeft / slideWidth);
      const nextIdx = (currentIdx + 1) % banners.length;
      el.scrollTo({ left: nextIdx * slideWidth, behavior: "smooth" });
    }, 4000);
    return () => clearInterval(id);
  }, [banners.length]);

  // 觸碰 / 拖曳時暫停 auto-play 8s
  useEffect(() => {
    if (banners.length <= 1) return;
    const el = scrollerRef.current;
    if (!el) return;
    const pause = () => { pausedUntilRef.current = Date.now() + 8000; };
    el.addEventListener("pointerdown", pause);
    el.addEventListener("touchstart", pause, { passive: true });
    return () => {
      el.removeEventListener("pointerdown", pause);
      el.removeEventListener("touchstart", pause);
    };
  }, [banners.length]);

  if (banners.length === 0) return null;

  // 單張 → 直接渲染, 不做 carousel
  if (banners.length === 1) {
    return <div className="block">{banners[0].node}</div>;
  }

  return (
    <div className="-mx-1">
      <div
        ref={scrollerRef}
        className="flex gap-3 overflow-x-auto px-1 pb-1 [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden"
        style={{ scrollSnapType: "x mandatory" }}
      >
        {banners.map((b) => (
          <div
            key={b.key}
            data-slide
            className="w-full shrink-0"
            style={{ scrollSnapAlign: "center" }}
          >
            {b.node}
          </div>
        ))}
      </div>
      {/* dots indicator */}
      <div className="mt-2 flex justify-center gap-1.5">
        {banners.map((b, i) => (
          <button
            key={b.key}
            type="button"
            aria-label={`切換到第 ${i + 1} 張`}
            onClick={() => {
              pausedUntilRef.current = Date.now() + 8000;
              const el = scrollerRef.current;
              const slide = el?.querySelector<HTMLDivElement>("[data-slide]");
              if (!el || !slide) return;
              const slideWidth = slide.offsetWidth + 12;
              el.scrollTo({ left: i * slideWidth, behavior: "smooth" });
            }}
            className={`h-1.5 rounded-full transition-all ${
              activeIdx === i
                ? "w-6 bg-[var(--brand-strong)]"
                : "w-1.5 bg-zinc-300 dark:bg-zinc-700"
            }`}
          />
        ))}
      </div>
    </div>
  );
}
