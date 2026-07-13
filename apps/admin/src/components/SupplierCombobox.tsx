"use client";

import { useEffect, useRef, useState } from "react";
import SpinButton from "@/components/SpinButton";

export type SupplierOption = { id: number; name: string; code: string };

export function SupplierCombobox({
  value,
  options,
  onChange,
}: {
  value: number | null;
  options: SupplierOption[];
  onChange: (id: number | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    function onClickAway(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
        setQuery("");
      }
    }
    if (open) document.addEventListener("mousedown", onClickAway);
    return () => document.removeEventListener("mousedown", onClickAway);
  }, [open]);

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  const selected = value != null ? options.find((s) => s.id === value) ?? null : null;

  const q = query.trim().toLowerCase();
  const filtered = q
    ? options.filter(
        (s) => s.name.toLowerCase().includes(q) || s.code.toLowerCase().includes(q)
      )
    : options;

  return (
    <div ref={containerRef} className="relative">
      {!open ? (
        <SpinButton
          type="button"
          onClick={() => setOpen(true)}
          className="flex w-full items-center justify-between rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          {selected ? (
            <span className="inline-flex items-center gap-2">
              <span className="truncate">{selected.name}</span>
              <span className="shrink-0 text-xs text-zinc-500">{selected.code}</span>
            </span>
          ) : (
            <span className="text-zinc-500">—（不設定）</span>
          )}
          <span className="text-zinc-400">▾</span>
        </SpinButton>
      ) : (
        <input
          ref={inputRef}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              setOpen(false);
              setQuery("");
            } else if (e.key === "Enter") {
              e.preventDefault();
              if (filtered.length > 0) {
                onChange(filtered[0].id);
                setOpen(false);
                setQuery("");
              }
            }
          }}
          placeholder="搜尋供應商名稱或代號"
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      )}

      {open && (
        <div className="absolute left-0 right-0 z-20 mt-1 max-h-72 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
          {value != null && (
            <SpinButton
              type="button"
              onClick={(e) => {
                // 取消 label 的 click 轉發，避免關閉後又被轉發的 click 重新打開
                e.preventDefault();
                onChange(null);
                setOpen(false);
                setQuery("");
              }}
              className="block w-full border-b border-zinc-200 px-3 py-2 text-left text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
            >
              清除選擇
            </SpinButton>
          )}
          {filtered.length === 0 ? (
            <p className="px-3 py-2 text-xs text-zinc-500">
              {q ? "找不到符合的供應商" : "尚無供應商"}
            </p>
          ) : (
            filtered.map((s) => (
              <SpinButton
                key={s.id}
                type="button"
                onClick={(e) => {
                  e.preventDefault();
                  onChange(s.id);
                  setOpen(false);
                  setQuery("");
                }}
                className={`flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800 ${
                  s.id === value ? "bg-blue-50 dark:bg-blue-950" : ""
                }`}
              >
                <span className="truncate">{s.name}</span>
                <span className="ml-2 shrink-0 text-xs text-zinc-500">{s.code}</span>
              </SpinButton>
            ))
          )}
        </div>
      )}
    </div>
  );
}
