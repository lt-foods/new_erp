"use client";

import { useEffect, useRef, useState } from "react";
import RingSpinner from "./Spinner";

const THRESHOLD = 64;
const MAX_PULL = 110;

/**
 * iOS-style pull-to-refresh。當頁面滾動到頂(scrollY === 0)時,
 * 下拉超過 THRESHOLD 放開 → 觸發 onRefresh。
 */
export default function PullToRefresh({
  onRefresh,
  children,
}: {
  onRefresh: () => Promise<void> | void;
  children: React.ReactNode;
}) {
  const [pull, setPull] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const startY = useRef<number | null>(null);
  const armed = useRef(false);

  useEffect(() => {
    const onTouchStart = (e: TouchEvent) => {
      if (refreshing) return;
      // 只有捲到最頂才 arm
      if (window.scrollY > 0 || document.documentElement.scrollTop > 0) {
        armed.current = false;
        startY.current = null;
        return;
      }
      armed.current = true;
      startY.current = e.touches[0].clientY;
    };

    const onTouchMove = (e: TouchEvent) => {
      if (!armed.current || startY.current === null || refreshing) return;
      const dy = e.touches[0].clientY - startY.current;
      if (dy <= 0) {
        setPull(0);
        return;
      }
      // 阻力曲線:越拉越鈍
      const damped = Math.min(MAX_PULL, dy * 0.5);
      setPull(damped);
      // 防止頁面跟著捲動 / iOS 橡皮筋
      if (dy > 5 && e.cancelable) e.preventDefault();
    };

    const onTouchEnd = async () => {
      if (!armed.current) return;
      armed.current = false;
      startY.current = null;
      const wasOverThreshold = pull >= THRESHOLD;
      if (wasOverThreshold && !refreshing) {
        setRefreshing(true);
        setPull(56); // 固定停在那邊轉
        try {
          await onRefresh();
        } finally {
          setRefreshing(false);
          setPull(0);
        }
      } else {
        setPull(0);
      }
    };

    document.addEventListener("touchstart", onTouchStart, { passive: true });
    document.addEventListener("touchmove", onTouchMove, { passive: false });
    document.addEventListener("touchend", onTouchEnd);
    document.addEventListener("touchcancel", onTouchEnd);
    return () => {
      document.removeEventListener("touchstart", onTouchStart);
      document.removeEventListener("touchmove", onTouchMove);
      document.removeEventListener("touchend", onTouchEnd);
      document.removeEventListener("touchcancel", onTouchEnd);
    };
  }, [pull, refreshing, onRefresh]);

  const ratio = Math.min(1, pull / THRESHOLD);

  return (
    <>
      <div
        aria-hidden
        className="pointer-events-none fixed inset-x-0 top-0 z-50 flex justify-center"
        style={{
          transform: `translateY(${Math.max(0, pull - 28)}px)`,
          opacity: pull > 4 ? 1 : 0,
          transition: refreshing || pull === 0 ? "transform 0.25s ease-out, opacity 0.2s" : "none",
        }}
      >
        <div
          className="mt-3 flex h-9 w-9 items-center justify-center rounded-full bg-white shadow-[0_2px_8px_rgba(0,0,0,0.12)]"
          style={{ paddingTop: "env(safe-area-inset-top)" }}
        >
          <Spinner
            spinning={refreshing}
            ratio={ratio}
            ready={!refreshing && pull >= THRESHOLD}
          />
        </div>
      </div>

      <div
        style={{
          transform: `translateY(${pull}px)`,
          transition: refreshing || pull === 0 ? "transform 0.25s ease-out" : "none",
        }}
      >
        {children}
      </div>
    </>
  );
}

function Spinner({
  spinning,
  ratio,
  ready,
}: {
  spinning: boolean;
  ratio: number;
  ready: boolean;
}) {
  if (spinning) {
    return <RingSpinner size={20} />;
  }
  // 拉動時:箭頭在到達閾值時翻轉
  return (
    <svg
      className="h-5 w-5 transition-transform"
      viewBox="0 0 24 24"
      fill="none"
      stroke={ready ? "var(--brand-strong)" : "#8e8e93"}
      strokeWidth="2.2"
      style={{
        transform: `rotate(${ready ? 180 : 0}deg)`,
        opacity: 0.4 + ratio * 0.6,
      }}
    >
      <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14M6 13l6 6 6-6" />
    </svg>
  );
}
