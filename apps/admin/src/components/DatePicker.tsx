"use client";

import { useEffect, useRef, useState } from "react";
import { DayPicker } from "react-day-picker";
import "react-day-picker/style.css";
import SpinButton from "@/components/SpinButton";

type DatePickerProps = {
  value: string;
  onChange: (s: string) => void;
  placeholder?: string;
  disabled?: boolean;
  min?: string;
  max?: string;
  className?: string;
  /** "fixed"：日曆彈層在所有斷點都固定置中（供 overflow-hidden 容器內使用，避免被裁切） */
  popover?: "auto" | "fixed";
};

export function DatePicker({
  value,
  onChange,
  placeholder = "選擇日期",
  disabled = false,
  min,
  max,
  className = "",
  popover = "auto",
}: DatePickerProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const selected = value ? parseLocal(value) : undefined;
  const minDate = min ? parseLocal(min) : undefined;
  const maxDate = max ? parseLocal(max) : undefined;

  const disabledMatchers: any[] = [];
  if (minDate) disabledMatchers.push({ before: minDate });
  if (maxDate) disabledMatchers.push({ after: maxDate });

  return (
    <div ref={ref} className="relative inline-block">
      <SpinButton
        type="button"
        disabled={disabled}
        onClick={() => setOpen((o) => !o)}
        className={
          className ||
          "rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
        }
      >
        {value || <span className="text-zinc-400">{placeholder}</span>}
      </SpinButton>
      {open && (
        <>
          <div
            className={`fixed inset-0 z-40 bg-black/20 ${popover === "fixed" ? "" : "sm:hidden"}`}
            aria-hidden="true"
            onClick={() => setOpen(false)}
          />
          <div
            className={`fixed left-1/2 top-1/2 z-50 max-h-[85vh] max-w-[calc(100vw-1.5rem)] -translate-x-1/2 -translate-y-1/2 overflow-auto rounded-md border border-zinc-200 bg-white p-2 shadow-lg dark:border-zinc-800 dark:bg-zinc-900 ${
              popover === "fixed"
                ? ""
                : "sm:absolute sm:left-0 sm:right-auto sm:top-full sm:mt-1 sm:max-h-none sm:max-w-none sm:translate-x-0 sm:translate-y-0 sm:overflow-visible"
            }`}
          >
            <DayPicker
              mode="single"
              selected={selected}
              onSelect={(d) => {
                if (d) {
                  onChange(formatLocal(d));
                  setOpen(false);
                }
              }}
              disabled={disabledMatchers.length > 0 ? disabledMatchers : undefined}
              weekStartsOn={0}
            />
          </div>
        </>
      )}
    </div>
  );
}

function parseLocal(s: string): Date {
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d);
}

function formatLocal(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}
