"use client";

import { useEffect, type ReactNode } from "react";

export function Modal({
  open, onClose, title, children, maxWidth = "max-w-3xl",
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
  maxWidth?: string;
}) {
  useEffect(() => {
    if (!open) return;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = "";
    };
  }, [open]);

  if (!open) return null;

  // 不再支援 Esc / 背景點擊關閉，避免操作中 popup 不小心被關。
  // 只能按右上 ✕ 關（或 dialog 內部的明確按鈕）
  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-zinc-900/50 px-4 py-4 backdrop-blur-sm sm:py-8"
      aria-modal="true"
      role="dialog"
    >
      <div
        className={`flex w-full ${maxWidth} max-h-[calc(100vh-2rem)] flex-col rounded-lg border border-zinc-200 bg-white shadow-2xl dark:border-zinc-800 dark:bg-zinc-900 sm:max-h-[calc(100vh-4rem)]`}
      >
        <div className="flex shrink-0 items-center justify-between border-b border-zinc-200 px-5 py-3 dark:border-zinc-800">
          <h2 className="text-base font-semibold">{title}</h2>
          <button
            onClick={onClose}
            aria-label="關閉"
            className="rounded-md p-1 text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
          >
            ✕
          </button>
        </div>
        <div className="flex-1 overflow-y-auto p-5">{children}</div>
      </div>
    </div>
  );
}
