"use client";

// 圖表共用零件。原本 useMeasuredWidth / Seg 在 /orders、StoreHeatMap、地區偏好頁
// 各抄了一份，加圖表時只會越抄越多份 —— 收在這裡，改一次全部生效。

import { useEffect, useRef, useState } from "react";

/**
 * 容器實際寬度（px）。
 * SVG 圖表要滿版又要維持字級／線寬不被 viewBox 縮放，只能量出來再照 px 畫
 * （preserveAspectRatio 會把 10px 的軸標在手機上縮成 4px）。
 */
export function useMeasuredWidth<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [width, setWidth] = useState(0);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    setWidth(Math.round(el.clientWidth));
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver((entries) => {
      setWidth(Math.round(entries[0]?.contentRect.width ?? 0));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, width] as const;
}

export function Seg({
  options, value, onChange,
}: {
  options: { key: string; label: string }[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="inline-flex overflow-hidden rounded-md border border-zinc-300 dark:border-zinc-700">
      {options.map((o) => (
        <button
          key={o.key}
          type="button"
          onClick={() => onChange(o.key)}
          className={`px-2.5 py-1 text-xs transition ${
            o.key === value
              ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
              : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

/** 圖表卡片外框：標題 / 副標 / 右上控制項 / 內容，各頁一致 */
export function ChartCard({
  title, subtitle, actions, children, footer,
}: {
  title: string;
  subtitle?: React.ReactNode;
  actions?: React.ReactNode;
  children: React.ReactNode;
  footer?: React.ReactNode;
}) {
  return (
    <section className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex flex-wrap items-start justify-between gap-3 border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">{title}</h2>
          {subtitle && <p className="mt-0.5 text-xs text-zinc-500">{subtitle}</p>}
        </div>
        {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
      </div>
      <div className="p-3">{children}</div>
      {footer && (
        <div className="border-t border-zinc-200 px-4 py-2 text-[11px] text-zinc-500 dark:border-zinc-800">
          {footer}
        </div>
      )}
    </section>
  );
}

export const num = (v: number | null | undefined) =>
  v == null ? "—" : Math.round(v).toLocaleString("zh-TW");
export const money = (v: number | null | undefined) =>
  v == null ? "—" : `$${Math.round(v).toLocaleString("zh-TW")}`;
export const pct = (v: number | null | undefined, digits = 0) =>
  v == null ? "—" : `${(v * 100).toFixed(digits)}%`;

export const DOW_LABEL = ["日", "一", "二", "三", "四", "五", "六"];

/** 單向紅色深淺（量的大小）。t 已正規化到 0~1。 */
export function heatRed(t: number) {
  if (!(t > 0)) return "transparent";
  return `rgba(239,68,68,${(0.06 + 0.54 * Math.min(1, t)).toFixed(3)})`;
}
