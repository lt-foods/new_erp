"use client";

import { useMemo, useState, type ChangeEvent } from "react";
import { getSupabase } from "@/lib/supabase";

type Props = {
  value: string[];
  onChange: (next: string[]) => void;
};

const BUCKET = "products";

export function ProductImagesField({ value, onChange }: Props) {
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const urls = useMemo(() => {
    const sb = getSupabase();
    return value.map((p) => sb.storage.from(BUCKET).getPublicUrl(p).data.publicUrl);
  }, [value]);

  async function onFilesSelected(e: ChangeEvent<HTMLInputElement>) {
    const files = e.target.files;
    if (!files || files.length === 0) return;
    setError(null);
    setUploading(true);
    try {
      const sb = getSupabase();
      const { data } = await sb.auth.getSession();
      const tenantId = (data.session?.user?.app_metadata as Record<string, unknown> | undefined)
        ?.tenant_id as string | undefined;
      if (!tenantId) throw new Error("JWT 缺 tenant_id claim、無法上傳");

      const uploaded: string[] = [];
      for (const file of Array.from(files)) {
        const ext = (file.name.split(".").pop() || "jpg").toLowerCase();
        const path = `${tenantId}/${crypto.randomUUID()}.${ext}`;
        const { error: upErr } = await sb.storage
          .from(BUCKET)
          .upload(path, file, { cacheControl: "3600", upsert: false });
        if (upErr) throw upErr;
        uploaded.push(path);
      }
      onChange([...value, ...uploaded]);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setUploading(false);
      e.target.value = "";
    }
  }

  async function remove(idx: number) {
    const path = value[idx];
    const next = value.filter((_, i) => i !== idx);
    onChange(next);
    // 同步刪 Storage 檔案（失敗不擋、留 orphan 可接受）
    try {
      await getSupabase().storage.from(BUCKET).remove([path]);
    } catch {
      // ignore
    }
  }

  function move(idx: number, dir: -1 | 1) {
    const target = idx + dir;
    if (target < 0 || target >= value.length) return;
    const next = [...value];
    [next[idx], next[target]] = [next[target], next[idx]];
    onChange(next);
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-3">
        {urls.map((url, i) => (
          <div
            key={value[i]}
            className="group relative h-24 w-24 overflow-hidden rounded-md border border-zinc-300 bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-800"
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={url} alt="" className="h-full w-full object-cover" />
            {i === 0 && (
              <span className="absolute top-1 left-1 rounded bg-black/60 px-1 text-[10px] font-medium text-white">
                封面
              </span>
            )}
            <div className="absolute inset-x-0 bottom-0 flex justify-between bg-black/50 opacity-0 transition group-hover:opacity-100">
              <button
                type="button"
                onClick={() => move(i, -1)}
                disabled={i === 0}
                className="flex-1 text-white text-xs hover:bg-black/40 disabled:opacity-30"
                aria-label="前移"
              >
                ←
              </button>
              <button
                type="button"
                onClick={() => remove(i)}
                className="flex-1 text-white text-xs hover:bg-red-700"
                aria-label="刪除"
              >
                ✕
              </button>
              <button
                type="button"
                onClick={() => move(i, 1)}
                disabled={i === value.length - 1}
                className="flex-1 text-white text-xs hover:bg-black/40 disabled:opacity-30"
                aria-label="後移"
              >
                →
              </button>
            </div>
          </div>
        ))}
        <label
          className={`flex h-24 w-24 cursor-pointer flex-col items-center justify-center rounded-md border-2 border-dashed text-xs text-zinc-500 transition hover:border-zinc-500 dark:border-zinc-700 dark:hover:border-zinc-500 ${uploading ? "opacity-50" : ""}`}
        >
          <input
            type="file"
            accept="image/png,image/jpeg,image/webp,image/gif"
            multiple
            disabled={uploading}
            onChange={onFilesSelected}
            className="hidden"
          />
          <span className="text-2xl leading-none">+</span>
          <span>{uploading ? "上傳中…" : "上傳"}</span>
        </label>
      </div>
      <p className="text-xs text-zinc-500">第一張為封面。每檔 ≤ 5 MB（png / jpg / webp / gif）。</p>
      {error && (
        <p className="rounded bg-red-50 px-2 py-1 text-xs text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </p>
      )}
    </div>
  );
}
