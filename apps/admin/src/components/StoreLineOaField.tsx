"use client";

// 分店的 LINE Messaging API 憑證（Channel ID / Channel Secret）。
//
// 這個租戶每家加盟店各有自己的 LINE 官方帳號，好友關係綁在單一 OA 上，
// 所以推播憑證必須 per-store —— 拿 B 店的憑證推 A 店的好友一定失敗。
//
// ⚠ secret 是**只寫不讀**：後端 rpc_get_store_line_oa_status 只回 channel_id，
//   永遠不回 secret（存 secret 的表對前端連 select 權限都沒有）。
//   所以這裡沒有「顯示目前 secret」這種功能，只能整組重設。

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { isAdmin, useRole } from "@/lib/role";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

type Status = { channel_id: string; updated_at: string } | null;

export function StoreLineOaField({
  storeId, storeCode,
}: { storeId: number | null; storeCode: string }) {
  const role = useRole();
  const [status, setStatus] = useState<Status>(null);
  const [loaded, setLoaded] = useState(false);
  const [channelId, setChannelId] = useState("");
  const [channelSecret, setChannelSecret] = useState("");
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  // 每家店一個 URL，結尾的 ?store= 不能省 —— line-webhook 要靠它決定用哪一把
  // channel secret 驗簽（驗簽必須先於信任 body，所以不能改從 body 讀）。
  const webhookUrl = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/line-webhook?store=${encodeURIComponent(storeCode)}`;

  useEffect(() => {
    // storeId 為 null 時走的是「請先儲存分店」那個分支，用不到 loaded
    if (storeId == null) return;
    let cancelled = false;
    (async () => {
      const { data, error } = await getSupabase().rpc("rpc_get_store_line_oa_status");
      if (cancelled) return;
      if (!error && Array.isArray(data)) {
        const row = (data as { store_id: number; channel_id: string; updated_at: string }[])
          .find((r) => r.store_id === storeId);
        setStatus(row ? { channel_id: row.channel_id, updated_at: row.updated_at } : null);
      }
      setLoaded(true);
    })();
    return () => { cancelled = true; };
  }, [storeId]);

  if (!isAdmin(role)) return null;

  async function save(clear: boolean) {
    if (storeId == null) return;
    setSaving(true);
    setErr(null);
    setMsg(null);
    try {
      const { error } = await getSupabase().rpc("rpc_set_store_line_oa", {
        p_store_id: storeId,
        p_channel_id: clear ? "" : channelId.trim(),
        p_channel_secret: clear ? "" : channelSecret.trim(),
      });
      if (error) { setErr(translateRpcError(error)); return; }
      setChannelId("");
      setChannelSecret("");
      setStatus(clear ? null : { channel_id: channelId.trim(), updated_at: new Date().toISOString() });
      if (clear) {
        setMsg("已清除此分店的 LINE 憑證");
        return;
      }

      // 存起來不代表能用：Login channel 的憑證一樣換得到 token，
      // 要打一支 Messaging API 端點才知道。現在就驗，不要等到發訊息才炸。
      setMsg("已儲存，驗證中…");
      const { data: { session } } = await getSupabase().auth.getSession();
      const resp = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/admin-line-push`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session?.access_token}` },
        body: JSON.stringify({ action: "verify_store", store_id: storeId }),
      });
      const result = await resp.json().catch(() => ({}));
      if (result.ok) {
        setMsg(`✓ 驗證通過 — 已接上官方帳號「${result.display_name ?? "?"}」${result.basic_id ?? ""}`);
      } else {
        setMsg(null);
        setErr(result.message || result.detail || result.error || `驗證失敗（HTTP ${resp.status}）`);
      }
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="sm:col-span-4 rounded-md border border-zinc-300 bg-white/60 p-3 dark:border-zinc-700 dark:bg-zinc-900/40">
      <div className="mb-1 text-xs font-medium text-zinc-700 dark:text-zinc-300">
        LINE 推播憑證（Messaging API）
      </div>

      {storeId == null ? (
        <p className="text-[11px] text-zinc-500">請先儲存這家分店，再回來設定 LINE 憑證。</p>
      ) : (
        <>
          <p className="mb-2 text-[11px] text-zinc-500">
            從「LINE 官方帳號管理後台 → 設定 → Messaging API」取得，用來對這家店的
            會員發送 LINE 訊息。每家店各自一組，不能共用。
          </p>

          {loaded && (
            status ? (
              <div className="mb-2 rounded bg-emerald-50 px-2 py-1 text-[11px] text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                ✓ 已設定　Channel ID：<span className="font-mono">{status.channel_id}</span>
                　（{new Date(status.updated_at).toLocaleDateString("zh-TW")} 更新）
              </div>
            ) : (
              <div className="mb-2 rounded bg-zinc-100 px-2 py-1 text-[11px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400">
                尚未設定 — 這家店的會員目前無法收到 LINE 推播
              </div>
            )
          )}

          <div className="mb-3 rounded border border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-700 dark:bg-zinc-900">
            <div className="mb-1 text-[11px] font-medium text-zinc-700 dark:text-zinc-300">
              Webhook URL（貼到 LINE 後台 → 設定 → Messaging API）
            </div>
            <div className="flex items-center gap-2">
              <code className="flex-1 overflow-x-auto whitespace-nowrap rounded bg-white px-2 py-1 text-[11px] text-zinc-800 dark:bg-zinc-950 dark:text-zinc-200">
                {webhookUrl}
              </code>
              <SpinButton
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText(webhookUrl);
                    setCopied(true);
                    setTimeout(() => setCopied(false), 2000);
                  } catch {
                    // 非 https / 舊瀏覽器沒有 clipboard API，讓使用者自己選取複製
                    setErr("此瀏覽器不允許自動複製，請手動選取上方網址");
                  }
                }}
                className="shrink-0 rounded-md border border-zinc-300 px-2 py-1 text-[11px] hover:bg-zinc-100 dark:border-zinc-600 dark:hover:bg-zinc-800"
              >
                {copied ? "✓ 已複製" : "複製"}
              </SpinButton>
            </div>
            <p className="mt-1 text-[11px] text-zinc-500">
              貼上後按 LINE 後台的 Verify 應顯示 Success。
              {!status && "（要先儲存下方憑證，webhook 才驗得過簽章）"}
            </p>
          </div>

          <div className="grid gap-2 sm:grid-cols-2">
            <label className="block text-xs">
              <span className="mb-0.5 block text-zinc-500">Channel ID</span>
              <input
                value={channelId}
                onChange={(e) => setChannelId(e.target.value)}
                placeholder={status ? "留空 = 不變更" : "例：2001234567"}
                autoComplete="off"
                className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono text-xs dark:border-zinc-700 dark:bg-zinc-900"
              />
            </label>
            <label className="block text-xs">
              <span className="mb-0.5 block text-zinc-500">Channel Secret</span>
              <input
                value={channelSecret}
                onChange={(e) => setChannelSecret(e.target.value)}
                type="password"
                placeholder={status ? "留空 = 不變更" : "貼上 secret"}
                autoComplete="new-password"
                className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono text-xs dark:border-zinc-700 dark:bg-zinc-900"
              />
            </label>
          </div>

          {(msg || err) && (
            <div className={`mt-2 text-[11px] ${err ? "text-red-700 dark:text-red-400" : "text-emerald-700 dark:text-emerald-400"}`}>
              {err ?? msg}
            </div>
          )}

          <div className="mt-2 flex gap-2">
            <SpinButton
              onClick={() => save(false)}
              disabled={saving || !channelId.trim() || !channelSecret.trim()}
              className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
            >
              {saving ? "儲存中…" : "💾 儲存憑證"}
            </SpinButton>
            {status && (
              <SpinButton
                onClick={() => {
                  if (window.confirm("清除後這家店的會員就收不到 LINE 推播，確定？")) save(true);
                }}
                disabled={saving}
                className="rounded-md border border-red-300 px-3 py-1 text-xs text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
              >
                清除
              </SpinButton>
            )}
          </div>
          <p className="mt-1 text-[11px] text-zinc-500">
            基於安全，secret 存進去後無法再讀出來（要換只能重填整組）。
          </p>

        </>
      )}
    </div>
  );
}
