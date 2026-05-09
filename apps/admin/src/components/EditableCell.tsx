"use client";

import { useEffect, useRef, useState } from "react";
import SpinButton from "@/components/SpinButton";

export function EditableNumber({
  value,
  onSave,
  disabled,
  className,
  min,
  prefix,
}: {
  value: number;
  onSave: (newValue: number) => Promise<void>;
  disabled?: boolean;
  className?: string;
  min?: number;
  prefix?: string;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(String(value));
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => { setDraft(String(value)); }, [value]);
  useEffect(() => { if (editing) inputRef.current?.select(); }, [editing]);

  async function commit() {
    const n = Number(draft);
    if (Number.isNaN(n) || (min != null && n < min)) {
      alert(`數值無效（需 >= ${min ?? "any"}）`);
      setDraft(String(value));
      setEditing(false);
      return;
    }
    if (n === Number(value)) { setEditing(false); return; }
    setBusy(true);
    try {
      await onSave(n);
      setEditing(false);
    } catch (e) {
      alert(`儲存失敗：${(e as Error).message}`);
      setDraft(String(value));
    } finally {
      setBusy(false);
    }
  }

  function cancel() {
    setDraft(String(value));
    setEditing(false);
  }

  if (disabled) {
    return <span className={className}>{prefix ?? ""}{Number(value)}</span>;
  }

  if (!editing) {
    return (
      <SpinButton
        type="button"
        onClick={() => setEditing(true)}
        className={`${className ?? ""} cursor-pointer rounded px-1 hover:bg-yellow-50 dark:hover:bg-yellow-950`}
        title="點擊編輯"
      >
        {prefix ?? ""}{Number(value)}
      </SpinButton>
    );
  }

  return (
    <input
      ref={inputRef}
      type="number"
      value={draft}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => { if (!busy) commit(); }}
      onKeyDown={(e) => {
        if (e.key === "Enter") { e.preventDefault(); commit(); }
        if (e.key === "Escape") cancel();
      }}
      step="any"
      min={min}
      disabled={busy}
      className={`${className ?? ""} w-24 rounded border border-blue-400 bg-white px-1 text-right font-mono dark:bg-zinc-900`}
    />
  );
}

export function EditableText({
  value,
  onSave,
  disabled,
  placeholder,
  className,
  multiline,
}: {
  value: string | null;
  onSave: (newValue: string | null) => Promise<void>;
  disabled?: boolean;
  placeholder?: string;
  className?: string;
  multiline?: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value ?? "");
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement | HTMLTextAreaElement>(null);

  useEffect(() => { setDraft(value ?? ""); }, [value]);
  useEffect(() => { if (editing) inputRef.current?.focus(); }, [editing]);

  async function commit() {
    const trimmed = draft.trim();
    const newVal: string | null = trimmed === "" ? null : draft;
    if (newVal === (value ?? null)) { setEditing(false); return; }
    setBusy(true);
    try {
      await onSave(newVal);
      setEditing(false);
    } catch (e) {
      alert(`儲存失敗：${(e as Error).message}`);
      setDraft(value ?? "");
    } finally {
      setBusy(false);
    }
  }

  function cancel() {
    setDraft(value ?? "");
    setEditing(false);
  }

  if (disabled) {
    return (
      <span className={`${className ?? ""} ${value ? "" : "text-zinc-400"}`}>
        {value || placeholder || "—"}
      </span>
    );
  }

  if (!editing) {
    return (
      <SpinButton
        type="button"
        onClick={() => setEditing(true)}
        className={`${className ?? ""} cursor-pointer rounded px-1 text-left hover:bg-yellow-50 dark:hover:bg-yellow-950 ${value ? "" : "italic text-zinc-400"}`}
        title="點擊編輯"
      >
        {value || placeholder || "（點此加備註）"}
      </SpinButton>
    );
  }

  if (multiline) {
    return (
      <textarea
        ref={inputRef as React.RefObject<HTMLTextAreaElement>}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={() => { if (!busy) commit(); }}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); commit(); }
          if (e.key === "Escape") cancel();
        }}
        rows={2}
        disabled={busy}
        className={`${className ?? ""} w-full rounded border border-blue-400 bg-white px-1 dark:bg-zinc-900`}
      />
    );
  }

  return (
    <input
      ref={inputRef as React.RefObject<HTMLInputElement>}
      type="text"
      value={draft}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => { if (!busy) commit(); }}
      onKeyDown={(e) => {
        if (e.key === "Enter") { e.preventDefault(); commit(); }
        if (e.key === "Escape") cancel();
      }}
      disabled={busy}
      placeholder={placeholder}
      className={`${className ?? ""} w-full rounded border border-blue-400 bg-white px-1 dark:bg-zinc-900`}
    />
  );
}
