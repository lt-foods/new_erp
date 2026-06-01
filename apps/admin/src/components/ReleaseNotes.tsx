"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import SpinButton from "@/components/SpinButton";
import {
  LATEST_RELEASE,
  RELEASE_NOTES,
  RELEASE_NOTES_DISMISS_KEY,
  TAG_COLOR,
  TAG_LABEL,
} from "@/lib/releaseNotes";

type ReleaseNotesCtx = {
  /** 手動開啟公告面板（點鈴鐺） */
  open: () => void;
  /** 是否有尚未「不再顯示」的最新公告（鈴鐺紅點） */
  hasUnread: boolean;
};

const Ctx = createContext<ReleaseNotesCtx | null>(null);

export function useReleaseNotes(): ReleaseNotesCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useReleaseNotes 必須在 ReleaseNotesProvider 內使用");
  return ctx;
}

export function ReleaseNotesProvider({ children }: { children: ReactNode }) {
  const [isOpen, setIsOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
  // 使用者上次按「不再顯示」時記錄的公告 id（null = 從未）
  const [dismissedId, setDismissedId] = useState<string | null>(null);
  const [dontShowAgain, setDontShowAgain] = useState(false);

  const latestId = LATEST_RELEASE?.id ?? null;

  // 載入已讀狀態，並在有未讀公告時自動跳出
  useEffect(() => {
    let stored: string | null = null;
    try {
      stored = localStorage.getItem(RELEASE_NOTES_DISMISS_KEY);
    } catch {
      /* noop */
    }
    setDismissedId(stored);
    setMounted(true);
    if (latestId && stored !== latestId) {
      setIsOpen(true);
    }
  }, [latestId]);

  const hasUnread = mounted && !!latestId && dismissedId !== latestId;

  const open = useCallback(() => {
    setDontShowAgain(false);
    setIsOpen(true);
  }, []);

  const close = useCallback(() => {
    setIsOpen(false);
    if (dontShowAgain && latestId) {
      try {
        localStorage.setItem(RELEASE_NOTES_DISMISS_KEY, latestId);
      } catch {
        /* noop */
      }
      setDismissedId(latestId);
    }
  }, [dontShowAgain, latestId]);

  // 開著時鎖背景捲動 + ESC 關閉
  useEffect(() => {
    if (!isOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [isOpen, close]);

  return (
    <Ctx.Provider value={{ open, hasUnread }}>
      {children}
      {isOpen && (
        <div
          className="fixed inset-0 z-50 flex items-start justify-center bg-zinc-900/50 px-4 py-4 backdrop-blur-sm sm:py-8"
          aria-modal="true"
          role="dialog"
        >
          <div className="flex w-full max-w-lg max-h-[calc(100dvh-2rem)] flex-col rounded-lg border border-zinc-200 bg-white shadow-2xl dark:border-zinc-800 dark:bg-zinc-900 sm:max-h-[calc(100dvh-4rem)]">
            <div className="flex shrink-0 items-center justify-between border-b border-zinc-200 px-5 py-3 dark:border-zinc-800">
              <h2 className="flex items-center gap-2 text-base font-semibold">
                <BellIcon className="h-4 w-4" />
                更新公告
              </h2>
              <SpinButton
                onClick={close}
                aria-label="關閉"
                className="rounded-md p-1 text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
              >
                ✕
              </SpinButton>
            </div>

            <div className="flex-1 space-y-5 overflow-y-auto p-5">
              {RELEASE_NOTES.map((note, i) => (
                <div key={note.id}>
                  <div className="flex items-baseline justify-between gap-2">
                    <h3 className="text-sm font-semibold">
                      {note.title}
                      {i === 0 && (
                        <span className="ml-2 inline-flex rounded-full bg-rose-100 px-1.5 py-0.5 align-middle text-[10px] font-medium text-rose-700 dark:bg-rose-900/30 dark:text-rose-300">
                          最新
                        </span>
                      )}
                    </h3>
                    <span className="shrink-0 font-mono text-[11px] text-zinc-400 dark:text-zinc-500">
                      {note.date}
                    </span>
                  </div>
                  <ul className="mt-2 space-y-1.5">
                    {note.items.map((it, j) => (
                      <li key={j} className="flex items-start gap-2 text-sm text-zinc-600 dark:text-zinc-300">
                        <span
                          className={`mt-0.5 inline-flex shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${TAG_COLOR[it.tag]}`}
                        >
                          {TAG_LABEL[it.tag]}
                        </span>
                        <span className="leading-relaxed">{it.text}</span>
                      </li>
                    ))}
                  </ul>
                  {i < RELEASE_NOTES.length - 1 && (
                    <hr className="mt-5 border-zinc-100 dark:border-zinc-800" />
                  )}
                </div>
              ))}
            </div>

            <div className="flex shrink-0 items-center justify-between gap-3 border-t border-zinc-200 px-5 py-3 dark:border-zinc-800">
              <label className="flex cursor-pointer select-none items-center gap-2 text-sm text-zinc-600 dark:text-zinc-300">
                <input
                  type="checkbox"
                  checked={dontShowAgain}
                  onChange={(e) => setDontShowAgain(e.target.checked)}
                  className="h-4 w-4 rounded border-zinc-300 dark:border-zinc-600"
                />
                不再顯示此公告
              </label>
              <SpinButton
                onClick={close}
                className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
              >
                我知道了
              </SpinButton>
            </div>
          </div>
        </div>
      )}
    </Ctx.Provider>
  );
}

/** 右上角的通知鈴鐺，點開更新公告面板。需在 ReleaseNotesProvider 內使用。 */
export function ReleaseNotesBell({ className = "" }: { className?: string }) {
  const { open, hasUnread } = useReleaseNotes();
  return (
    <SpinButton
      type="button"
      onClick={open}
      aria-label="更新公告"
      title="更新公告"
      className={`relative inline-flex h-9 w-9 items-center justify-center rounded-md border border-zinc-300 text-zinc-700 transition hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800 ${className}`}
    >
      <BellIcon className="h-5 w-5" />
      {hasUnread && (
        <span className="absolute right-1.5 top-1.5 h-2 w-2 rounded-full bg-rose-500 ring-2 ring-white dark:ring-zinc-900" />
      )}
    </SpinButton>
  );
}

function BellIcon({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden
    >
      <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
      <path d="M13.73 21a2 2 0 0 1-3.46 0" />
    </svg>
  );
}
