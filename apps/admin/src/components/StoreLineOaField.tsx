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
  storeId, liffId = null,
}: { storeId: number | null; liffId?: string | null }) {
  const role = useRole();
  const [status, setStatus] = useState<Status>(null);
  const [loaded, setLoaded] = useState(false);
  const [channelId, setChannelId] = useState("");
  const [channelSecret, setChannelSecret] = useState("");
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

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

          <StoreLiffField storeId={storeId} initial={liffId} />
        </>
      )}
    </div>
  );
}

/**
 * 該店登入用的 LIFF ID。
 *
 * 為什麼要分店設定：LINE 的 user ID 綁 Provider。各店 OA 在自己的 Provider 底下，
 * 會員必須用「所屬分店那支 Login channel 的 LIFF」登入，取得的 line_user_id
 * 才跟該店 OA 通用 —— 否則存進資料庫也推不動（2026-08-07 實測：取樣 12 位
 * 松山店會員，用舊 ID 查該店 OA 的 profile 全部 404）。
 *
 * 留空 = 退回會員站的 NEXT_PUBLIC_LIFF_ID（租戶預設）。
 */
function StoreLiffField({ storeId, initial }: { storeId: number; initial: string | null }) {
  const [value, setValue] = useState(initial ?? "");
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const dirty = value.trim() !== (initial ?? "");

  async function save() {
    setSaving(true);
    setErr(null);
    setMsg(null);
    try {
      const { error } = await getSupabase().rpc("rpc_set_store_line_liff", {
        p_store_id: storeId,
        p_liff_id: value.trim(),
      });
      if (error) { setErr(translateRpcError(error)); return; }
      if (!value.trim()) { setMsg("已清除，改用租戶預設 LIFF"); return; }

      // 存起來不代表能用：endpoint 若不在會員站網域底下，LIFF context 會消失、
      // 登入直接 400（CLAUDE.md 記過的坑）。純前端抓不到 liff.line.me，走後端驗。
      setMsg("已儲存，驗證 endpoint 中…");
      const { data: { session } } = await getSupabase().auth.getSession();
      const resp = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/admin-line-push`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session?.access_token}` },
        body: JSON.stringify({ action: "verify_liff", liff_id: value.trim() }),
      });
      const result = await resp.json().catch(() => ({}));
      if (result.ok) {
        setMsg(result.message ?? "✓ 已儲存");
      } else {
        setMsg(null);
        setErr(result.message || result.error || `驗證失敗（HTTP ${resp.status}）`);
      }
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="mt-3 border-t border-zinc-200 pt-3 dark:border-zinc-700">
      <div className="mb-1 text-xs font-medium text-zinc-700 dark:text-zinc-300">
        登入用 LIFF ID
      </div>
      <p className="mb-2 text-[11px] text-zinc-500">
        這家店 Provider 底下的 LINE Login channel 所建的 LIFF app ID。會員要用這支登入，
        取得的身分才跟本店官方帳號相通、收得到推播。留空 = 用預設。
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <input
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="2001234567-AbCdEfGh"
          autoComplete="off"
          className="min-w-[220px] flex-1 rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono text-xs dark:border-zinc-700 dark:bg-zinc-900"
        />
        {dirty && (
          <SpinButton
            onClick={save}
            disabled={saving}
            className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {saving ? "儲存中…" : "💾 儲存"}
          </SpinButton>
        )}
      </div>
      {(msg || err) && (
        <div className={`mt-1 text-[11px] ${err ? "text-red-700 dark:text-red-400" : "text-emerald-700 dark:text-emerald-400"}`}>
          {err ?? msg}
        </div>
      )}
    </div>
  );
}
