"use client";

// 手機團控專用的商品圖上傳。存法照 components/ProductImagesField.tsx（products bucket、
// `${tenantId}/${uuid}.${ext}`、回傳 Storage 路徑陣列），差在：
// 只收 JPEG／PNG（LINE 記事本發文只帶得上這兩種）、往前／刪除／往後常駐顯示且點擊區 ≥44px、
// 對外回報上傳中（本頁上傳中不給按「建立開團」）。

import { useEffect, useMemo, useRef, useState, type ChangeEvent } from "react";
import { getSupabase } from "@/lib/supabase";
import { QUICK_IMAGE_ACCEPT, moveImage, quickImageExt } from "./quickControl";

type Props = {
  value: string[];
  onChange: (next: string[]) => void;
  onUploadingChange?: (uploading: boolean) => void;
  disabled?: boolean;
};

const BUCKET = "products";

const ctrlBtnCls =
  "min-h-[44px] min-w-[44px] touch-manipulation rounded-md border border-zinc-300 px-1 text-base text-zinc-700 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-200";

export function QuickImagesField({ value, onChange, onUploadingChange, disabled }: Props) {
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [skipped, setSkipped] = useState<string | null>(null);

  const urls = useMemo(() => {
    const sb = getSupabase();
    return value.map((p) => sb.storage.from(BUCKET).getPublicUrl(p).data.publicUrl);
  }, [value]);

  useEffect(() => {
    onUploadingChange?.(uploading);
  }, [onUploadingChange, uploading]);

  // 卸下時回報「沒在上傳」，旗標才不會卡住；本頁的回報函式會用世代號擋掉上一輪的
  const reportRef = useRef(onUploadingChange);
  useEffect(() => {
    reportRef.current = onUploadingChange;
  }, [onUploadingChange]);
  useEffect(() => {
    const report = reportRef;
    return () => {
      report.current?.(false);
    };
  }, []);

  async function onFilesSelected(e: ChangeEvent<HTMLInputElement>) {
    const files = e.target.files;
    if (!files || files.length === 0) return;
    setError(null);
    setSkipped(null);
    const picked: { file: File; ext: string }[] = [];
    const rejected: string[] = [];
    for (const file of Array.from(files)) {
      const ext = quickImageExt(file);
      if (ext) picked.push({ file, ext });
      else rejected.push(file.name);
    }
    if (rejected.length > 0) {
      setSkipped(`只收 JPG／PNG，已略過：${rejected.join("、")}`);
    }
    if (picked.length === 0) {
      e.target.value = "";
      return;
    }
    setUploading(true);
    try {
      const sb = getSupabase();
      const { data } = await sb.auth.getSession();
      const tenantId = (data.session?.user?.app_metadata as Record<string, unknown> | undefined)
        ?.tenant_id as string | undefined;
      if (!tenantId) throw new Error("JWT 缺 tenant_id claim、無法上傳");

      const uploaded: string[] = [];
      for (const { file, ext } of picked) {
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
    onChange(value.filter((_, i) => i !== idx));
    // 同步刪 Storage 檔案（失敗不擋、留 orphan 可接受）
    try {
      await getSupabase().storage.from(BUCKET).remove([path]);
    } catch {
      // ignore
    }
  }

  // 上傳中不給排序／刪除：上傳完會用開始上傳時的清單接上新圖，中途改的會被蓋回去
  const locked = disabled || uploading;

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-3">
        {urls.map((url, i) => (
          <div key={value[i]} className="w-36">
            <div className="relative h-36 w-36 overflow-hidden rounded-md border border-zinc-300 bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-800">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={url} alt="" className="h-full w-full object-cover" />
              {i === 0 && (
                <span className="absolute top-1 left-1 rounded bg-black/60 px-1 text-[10px] font-medium text-white">
                  第一張
                </span>
              )}
            </div>
            <div className="mt-1 grid grid-cols-3 gap-1">
              <button
                type="button"
                onClick={() => onChange(moveImage(value, i, -1))}
                disabled={locked || i === 0}
                className={ctrlBtnCls}
              >
                往前
              </button>
              <button
                type="button"
                onClick={() => void remove(i)}
                disabled={locked}
                className={`${ctrlBtnCls} text-red-700 dark:text-red-300`}
              >
                刪除
              </button>
              <button
                type="button"
                onClick={() => onChange(moveImage(value, i, 1))}
                disabled={locked || i === value.length - 1}
                className={ctrlBtnCls}
              >
                往後
              </button>
            </div>
          </div>
        ))}
        <label
          className={`flex h-36 w-36 cursor-pointer flex-col items-center justify-center rounded-md border-2 border-dashed text-base text-zinc-500 dark:border-zinc-700 ${locked ? "pointer-events-none opacity-50" : ""}`}
        >
          <input
            type="file"
            accept={QUICK_IMAGE_ACCEPT}
            multiple
            disabled={locked}
            onChange={onFilesSelected}
            className="hidden"
          />
          <span className="text-3xl leading-none">+</span>
          <span>{uploading ? "上傳中…" : "拍照／選照片"}</span>
        </label>
      </div>
      <p className="text-xs text-zinc-500">只收 JPG／PNG（LINE 記事本只帶得上這兩種）。</p>
      {skipped && (
        <p className="rounded bg-amber-50 px-2 py-1 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-200">
          {skipped}
        </p>
      )}
      {error && (
        <p className="rounded bg-red-50 px-2 py-1 text-xs text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </p>
      )}
    </div>
  );
}
