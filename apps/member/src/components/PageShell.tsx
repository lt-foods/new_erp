"use client";

import { useEffect, useState } from "react";
import MemberTabBar from "./MemberTabBar";

/**
 * iOS 大標題樣式的頁面外殼。
 * - 頁面背景：交給 body 的暖色漸層（這層保持透明讓它透出來）
 * - 大標題：32px bold，sticky 凍頂，frosted blur + 頂端品牌光暈
 * - 內容寬度上限 max-w-md，居中
 * - 底部留 tab bar 高度（含 safe-area-inset-bottom）
 */
export default function PageShell({
  title,
  rightAction,
  children,
}: {
  title?: string;
  rightAction?: React.ReactNode;
  children: React.ReactNode;
}) {
  const [tabBarHidden, setTabBarHidden] = useState(false);
  useEffect(() => {
    if (typeof window === "undefined") return;
    const isLine = /Line\//i.test(navigator.userAgent);
    const isStandalone =
      (window.navigator as { standalone?: boolean }).standalone === true ||
      window.matchMedia("(display-mode: standalone)").matches;
    setTabBarHidden(isLine && !isStandalone);
  }, []);

  return (
    <div
      className="relative min-h-[100dvh]"
      style={{
        paddingBottom: tabBarHidden
          ? "env(safe-area-inset-bottom)"
          : "calc(92px + env(safe-area-inset-bottom))",
      }}
    >
      <main className="relative mx-auto w-full max-w-md">
        {title !== undefined && (
          <header
            className="sticky top-0 z-20 overflow-hidden px-5 pb-2.5 backdrop-blur-xl"
            style={{ paddingTop: "calc(env(safe-area-inset-top) + 16px)" }}
          >
            {/* 頂端品牌光暈：每頁標題都帶一抹暖玫瑰，取代純黑字 on 灰底 */}
            <div
              className="pointer-events-none absolute inset-0"
              style={{
                background:
                  "linear-gradient(180deg, color-mix(in srgb, var(--brand-tint) 92%, transparent) 0%, color-mix(in srgb, var(--background) 76%, transparent) 100%)",
              }}
              aria-hidden
            />
            <div
              className="pointer-events-none absolute -right-10 -top-12 h-32 w-32 rounded-full opacity-60 blur-2xl"
              style={{ background: "radial-gradient(circle, var(--brand-soft) 0%, transparent 70%)" }}
              aria-hidden
            />
            <div className="relative flex items-end justify-between gap-3">
              <div className="flex items-center gap-2.5">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src="/brand/logo.jpg"
                  alt=""
                  className="h-9 w-9 shrink-0 rounded-full object-cover shadow-[0_2px_8px_-2px_rgba(158,47,80,0.45)] ring-1 ring-white/70"
                  aria-hidden
                />
                <h1 className="text-[32px] font-bold tracking-tight text-[var(--foreground)] leading-tight">
                  {title}
                </h1>
              </div>
              {rightAction && <div className="pb-1.5">{rightAction}</div>}
            </div>
          </header>
        )}
        {children}
      </main>
      <MemberTabBar />
    </div>
  );
}
