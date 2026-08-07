"use client";

// 對單一會員經 LINE 官方帳號發訊息（文字 + 截圖）。
// 後端：admin-line-push edge function（函式內驗 staff JWT）。
//
// 圖片流程：不管來源格式，一律 canvas 轉 JPEG 再上傳 line-media bucket —
//   original ≤ 2048px（LINE originalContentUrl 上限 10MB，轉完遠低於此）
//   preview  ≤  800px（LINE previewImageUrl 上限 1MB，聊天室縮圖用）
// 順便鋪白底（截圖常有透明背景，JPEG 沒有 alpha）、去掉 EXIF。
//
// 開啟時先打 action:check 預檢「推不推得到」：404 = 沒加好友或
// Login channel 跟 OA 不同 provider — 這是營運前置條件問題，不是 bug，
// 所以要在發送前就讓店員看到，而不是發了才失敗。

import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";

const BUCKET = "line-media";
const FN_URL = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/admin-line-push`;

type Reachable =
  | { state: "checking" }
  | { state: "ok"; displayName: string | null }
  | { state: "unreachable"; message: string }
  | { state: "not_configured"; message: string }
  | { state: "error"; message: string };

// limit=null = 方案無則數上限。額度只算「主動推播」（這個功能就是），
// OA 後台 1:1 聊天不吃額度，所以這裡的數字跟後台聊天量對不上是正常的。
type Quota = { limit: number | null; used: number };

async function callFn(body: Record<string, unknown>) {
  const sb = getSupabase();
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error("尚未登入");
  const resp = await fetch(FN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(body),
  });
  const result = await resp.json().catch(() => ({}));
  return { status: resp.status, result };
}

/** canvas 轉 JPEG：縮到 maxDim 內、鋪白底（透明截圖）、去 EXIF */
async function encodeJpeg(file: File, maxDim: number, quality: number): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  try {
    const scale = Math.min(1, maxDim / Math.max(bmp.width, bmp.height));
    const w = Math.max(1, Math.round(bmp.width * scale));
    const h = Math.max(1, Math.round(bmp.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("無法建立 canvas");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(bmp, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((res) => canvas.toBlob(res, "image/jpeg", quality));
    if (!blob) throw new Error("圖片轉檔失敗");
    return blob;
  } finally {
    bmp.close();
  }
}

export function LineMessageModal({
  open, onClose, member, tenantId,
}: {
  open: boolean;
  onClose: () => void;
  member: { id: number; name: string | null; member_no: string };
  tenantId: string;
}) {
  const [reachable, setReachable] = useState<Reachable>({ state: "checking" });
  const [quota, setQuota] = useState<Quota | null>(null);
  const [text, setText] = useState("");
  const [image, setImage] = useState<File | null>(null);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // 開啟時預檢可達性（modal 是條件渲染、每次開啟重新 mount，初始 state 即 checking）
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      try {
        const { status, result } = await callFn({ action: "check", member_id: member.id });
        if (cancelled) return;
        if (result.ok && result.reachable) {
          setReachable({ state: "ok", displayName: result.display_name ?? null });
        } else if (result.ok && !result.reachable) {
          setReachable({ state: "unreachable", message: result.message });
        } else if (result.error === "not_configured") {
          setReachable({ state: "not_configured", message: result.message });
        } else {
          setReachable({ state: "error", message: result.message || result.error || `HTTP ${status}` });
        }
      } catch (e) {
        if (!cancelled) setReachable({ state: "error", message: e instanceof Error ? e.message : String(e) });
      }
    })();
    // 額度另外抓，失敗就不顯示（不擋發送流程）
    (async () => {
      try {
        const { result } = await callFn({ action: "quota" });
        if (!cancelled && result.ok) setQuota({ limit: result.limit ?? null, used: result.used ?? 0 });
      } catch { /* 額度顯示是輔助資訊，抓不到就算了 */ }
    })();
    return () => { cancelled = true; };
  }, [open, member.id]);

  // 貼上截圖（Ctrl/Cmd+V）— modal 開著時掛在 document 上，不用先點進哪個欄位
  useEffect(() => {
    if (!open) return;
    function onPaste(e: ClipboardEvent) {
      const item = Array.from(e.clipboardData?.items ?? []).find((i) => i.type.startsWith("image/"));
      const file = item?.getAsFile();
      if (file) {
        e.preventDefault();
        setError(null);
        setImage(file);
      }
    }
    document.addEventListener("paste", onPaste);
    return () => document.removeEventListener("paste", onPaste);
  }, [open]);

  // objectURL 隨 image 換發 / 卸載時回收
  const imagePreview = useMemo(() => (image ? URL.createObjectURL(image) : null), [image]);
  useEffect(() => {
    return () => { if (imagePreview) URL.revokeObjectURL(imagePreview); };
  }, [imagePreview]);

  function pickImage(file: File) {
    if (!file.type.startsWith("image/")) {
      setError("只能附圖片檔");
      return;
    }
    setError(null);
    setImage(file);
  }

  async function send() {
    if (!text.trim() && !image) {
      setError("請輸入訊息或附上截圖");
      return;
    }
    setSending(true);
    setError(null);
    try {
      let imageUrl: string | undefined;
      let previewUrl: string | undefined;

      if (image) {
        const sb = getSupabase();
        const [original, preview] = await Promise.all([
          encodeJpeg(image, 2048, 0.9),
          encodeJpeg(image, 800, 0.8),
        ]);
        const base = `${tenantId}/${crypto.randomUUID()}`;
        for (const [path, blob] of [[`${base}.jpg`, original], [`${base}_preview.jpg`, preview]] as const) {
          const { error: upErr } = await sb.storage
            .from(BUCKET)
            .upload(path, blob, { contentType: "image/jpeg", cacheControl: "3600", upsert: false });
          if (upErr) throw new Error(`截圖上傳失敗：${upErr.message}`);
        }
        imageUrl = sb.storage.from(BUCKET).getPublicUrl(`${base}.jpg`).data.publicUrl;
        previewUrl = sb.storage.from(BUCKET).getPublicUrl(`${base}_preview.jpg`).data.publicUrl;
      }

      const { status, result } = await callFn({
        action: "send",
        member_id: member.id,
        text: text.trim() || undefined,
        image_url: imageUrl,
        preview_url: previewUrl,
      });

      if (result.ok) {
        alert("已發送 ✓");
        setText("");
        setImage(null);
        onClose();
      } else {
        const parts = [result.message || result.error || `HTTP ${status}`];
        if (result.hint) parts.push(result.hint);
        setError(parts.join("\n"));
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSending(false);
    }
  }

  const canSend = !sending
    && reachable.state !== "checking"
    && reachable.state !== "not_configured"
    && (text.trim().length > 0 || !!image);

  return (
    <Modal open={open} onClose={onClose} title={`發送 LINE 訊息 — ${member.name ?? `#${member.member_no}`}`} maxWidth="max-w-lg">
      <div className="space-y-4">
        {/* 可達性預檢 */}
        {reachable.state === "checking" && (
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            檢查會員是否可接收 LINE 訊息…
          </div>
        )}
        {reachable.state === "ok" && (
          <div className="rounded-md border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
            ✓ 可發送{reachable.displayName ? `（LINE 名稱：${reachable.displayName}）` : ""}
          </div>
        )}
        {reachable.state === "unreachable" && (
          <div className="rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
            ⚠ {reachable.message}（仍可嘗試發送，但預期會失敗）
          </div>
        )}
        {(reachable.state === "not_configured" || reachable.state === "error") && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {reachable.message}
          </div>
        )}

        {/* 本月推播額度（只算主動推播；OA 後台 1:1 聊天不吃額度） */}
        {quota && (
          quota.limit !== null && quota.used >= quota.limit ? (
            <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
              本月推播額度已用完（{quota.used} / {quota.limit} 則），發送會失敗。額度每月 1 號重置；OA 後台 1:1 聊天不受影響。
            </div>
          ) : (
            <div className="text-xs text-zinc-500" title="只計算主動推播（此功能 / 群發）；官方帳號後台 1:1 聊天不吃額度">
              本月推播已用 {quota.used} / {quota.limit ?? "無上限"} 則
            </div>
          )
        )}

        <label className="block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">訊息內容</span>
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            rows={4}
            maxLength={5000}
            placeholder="輸入要發給會員的訊息…"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        <div>
          <span className="mb-1 block text-xs text-zinc-500">
            截圖 / 圖片（可直接 Ctrl+V 貼上）
          </span>
          {imagePreview ? (
            <div className="relative inline-block">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={imagePreview} alt="附圖預覽" className="max-h-48 rounded-md border border-zinc-200 dark:border-zinc-800" />
              <SpinButton
                onClick={() => setImage(null)}
                aria-label="移除圖片"
                className="absolute -right-2 -top-2 rounded-full bg-zinc-700 px-1.5 py-0.5 text-xs text-white hover:bg-zinc-900"
              >
                ✕
              </SpinButton>
            </div>
          ) : (
            <SpinButton
              onClick={() => fileInputRef.current?.click()}
              className="rounded-md border border-dashed border-zinc-300 px-4 py-3 text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              📎 選擇圖片或直接貼上截圖
            </SpinButton>
          )}
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) pickImage(f);
              e.target.value = "";
            }}
          />
        </div>

        {error && (
          <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="flex justify-end gap-2">
          <SpinButton
            onClick={onClose}
            disabled={sending}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={send}
            disabled={!canSend}
            className="rounded-md bg-green-600 px-4 py-2 text-sm font-semibold text-white hover:bg-green-700 disabled:opacity-50"
          >
            {sending ? "發送中…" : "💬 發送"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
