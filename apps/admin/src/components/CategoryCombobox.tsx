"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

export type CategoryOption = { id: number; name: string; code: string };

export function CategoryCombobox({
  value,
  options,
  onChange,
  onCreated,
}: {
  value: number | null;
  options: CategoryOption[];
  onChange: (id: number | null) => void;
  onCreated: (cat: CategoryOption) => void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    function onClickAway(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
        setQuery("");
        setError(null);
      }
    }
    if (open) document.addEventListener("mousedown", onClickAway);
    return () => document.removeEventListener("mousedown", onClickAway);
  }, [open]);

  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  const selected = value != null ? options.find((c) => c.id === value) ?? null : null;

  const q = query.trim().toLowerCase();
  const filtered = q
    ? options.filter(
        (c) => c.name.toLowerCase().includes(q) || c.code.toLowerCase().includes(q)
      )
    : options.slice(0, 50);
  const exactMatch = q
    ? options.some((c) => c.name.toLowerCase() === q)
    : true;

  async function handleCreate() {
    const name = query.trim();
    if (!name) return;
    setError(null);
    setCreating(true);
    try {
      const sb = getSupabase();
      const { data: id, error: rpcErr } = await sb.rpc("rpc_upsert_category", {
        p_id: null,
        p_parent_id: null,
        p_code: name,
        p_name: name,
        p_level: 1,
        p_sort_order: 0,
        p_is_active: true,
      });
      if (rpcErr) throw rpcErr;
      const newCat: CategoryOption = { id: Number(id), name, code: name };
      onCreated(newCat);
      onChange(Number(id));
      setQuery("");
      setOpen(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCreating(false);
    }
  }

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
              <span className="rounded bg-blue-100 px-2 py-0.5 text-xs text-blue-800 dark:bg-blue-950 dark:text-blue-300">
                {selected.name}
              </span>
              <span className="text-xs text-zinc-500">{selected.code}</span>
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
              setError(null);
            } else if (e.key === "Enter") {
              e.preventDefault();
              if (filtered.length > 0) {
                onChange(filtered[0].id);
                setOpen(false);
                setQuery("");
              } else if (q && !exactMatch) {
                void handleCreate();
              }
            }
          }}
          placeholder="搜尋分類，或輸入新名稱建立"
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      )}

      {open && (
        <div className="absolute left-0 right-0 z-20 mt-1 max-h-72 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
          {value != null && (
            <SpinButton
              type="button"
              onClick={() => {
                onChange(null);
                setOpen(false);
                setQuery("");
              }}
              className="block w-full border-b border-zinc-200 px-3 py-2 text-left text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
            >
              清除選擇
            </SpinButton>
          )}
          {filtered.length === 0 && q === "" ? (
            <p className="px-3 py-2 text-xs text-zinc-500">尚無分類</p>
          ) : (
            filtered.map((c) => (
              <SpinButton
                key={c.id}
                type="button"
                onClick={() => {
                  onChange(c.id);
                  setOpen(false);
                  setQuery("");
                }}
                className={`flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800 ${
                  c.id === value ? "bg-blue-50 dark:bg-blue-950" : ""
                }`}
              >
                <span className="truncate">{c.name}</span>
                <span className="ml-2 shrink-0 text-xs text-zinc-500">{c.code}</span>
              </SpinButton>
            ))
          )}
          {q && !exactMatch && (
            <SpinButton
              type="button"
              onClick={handleCreate}
              disabled={creating}
              className="block w-full border-t border-zinc-200 px-3 py-2 text-left text-sm text-blue-700 hover:bg-blue-50 disabled:opacity-50 dark:border-zinc-700 dark:text-blue-300 dark:hover:bg-blue-950"
            >
              {creating ? "建立中…" : `+ 建立分類「${query.trim()}」`}
            </SpinButton>
          )}
          {error && (
            <p className="border-t border-zinc-200 px-3 py-2 text-xs text-red-600 dark:border-zinc-700 dark:text-red-400">
              {error}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
