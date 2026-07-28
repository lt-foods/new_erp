"use client";

// 會員刪除 — 兩種模式：
//   徹底刪除（預設）— 呼叫 rpc_member_purge（20260728000010）：
//     members 資料列連同點數/儲值流水、卡片、標籤、LINE 綁定、推播訂閱實體刪除，
//     會員完全消失；訂單/候補/欠品僅解除會員連結（單據保留）。
//     分店內部會員（store_internal）後端會擋。
//   保留紀錄刪除 — 呼叫 rpc_member_gdpr_delete（20260618000040）：
//     清 PII、status='deleted'、退卡、移除標籤；流水/訂單保留（稅捐稽徵法 7 年）。
//
// 權限：RPC 為 SECURITY DEFINER 不自帶 role gate（與 rpc_merge_member 同慣例，
//   由呼叫端把關）。本 modal 只在 isAdmin(role) 時於 MemberDetail 掛出，
//   並要求「輸入會員編號二次確認」避免誤刪。

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

type DeleteMode = "purge" | "gdpr";

export function MemberDeleteModal({
  open,
  onClose,
  member,
  onDeleted,
}: {
  open: boolean;
  onClose: () => void;
  member: { id: number; member_no: string; name: string | null };
  onDeleted: () => void;
}) {
  const [mode, setMode] = useState<DeleteMode>("purge");
  const [confirmText, setConfirmText] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 二次確認：必須完整輸入會員編號
  const confirmed = confirmText.trim() === member.member_no;

  function reset() {
    setMode("purge");
    setConfirmText("");
    setReason("");
    setErr(null);
  }

  async function submit() {
    if (!confirmed) {
      setErr("請正確輸入會員編號以確認刪除");
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();

      if (mode === "purge") {
        const { error } = await sb.rpc("rpc_member_purge", {
          p_member_id: member.id,
          p_reason: reason.trim() || null,
        });
        if (error) {
          setErr(translateRpcError(error));
          return;
        }
        alert(`已徹底刪除會員 #${member.member_no}（會員資料與點數／儲值紀錄已完全移除）`);
      } else {
        const { data: sess } = await sb.auth.getSession();
        const operator = sess.session?.user?.id;
        const { error } = await sb.rpc("rpc_member_gdpr_delete", {
          p_member_id: member.id,
          p_reason: reason.trim() || null,
          p_operator: operator ?? null,
        });
        if (error) {
          setErr(translateRpcError(error));
          return;
        }
        alert(`已刪除會員 #${member.member_no}（個資已清除，歷史交易紀錄依稅務規定保留）`);
      }
      reset();
      onDeleted();
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open={open}
      onClose={() => {
        if (busy) return;
        reset();
        onClose();
      }}
      title="刪除會員"
      maxWidth="max-w-lg"
    >
      <div className="space-y-4 text-sm">
        <div className="rounded-md border border-red-300 bg-red-50 p-3 dark:border-red-800 dark:bg-red-950/40">
          <div className="font-medium text-red-800 dark:text-red-300">
            ⚠️ 此動作不可還原
          </div>
          <div className="mt-1 text-xs text-red-700 dark:text-red-300">
            即將刪除會員：
            <b className="mx-1">{member.name ?? "—"}</b>
            <span className="font-mono">#{member.member_no}</span>
          </div>
        </div>

        <div className="space-y-2">
          <label className="flex cursor-pointer items-start gap-2 rounded-md border border-zinc-200 p-3 has-[:checked]:border-red-400 has-[:checked]:bg-red-50/50 dark:border-zinc-800 dark:has-[:checked]:border-red-800 dark:has-[:checked]:bg-red-950/20">
            <input
              type="radio"
              name="delete-mode"
              checked={mode === "purge"}
              onChange={() => setMode("purge")}
              className="mt-0.5"
            />
            <span>
              <span className="block font-medium">徹底刪除</span>
              <span className="mt-0.5 block text-xs text-zinc-500">
                會員資料完全從系統移除：個資、積分／儲值流水、會員卡、標籤、LINE
                綁定、推播訂閱全數刪除。訂單等營運單據保留，但不再掛在此會員名下。
              </span>
            </span>
          </label>
          <label className="flex cursor-pointer items-start gap-2 rounded-md border border-zinc-200 p-3 has-[:checked]:border-red-400 has-[:checked]:bg-red-50/50 dark:border-zinc-800 dark:has-[:checked]:border-red-800 dark:has-[:checked]:bg-red-950/20">
            <input
              type="radio"
              name="delete-mode"
              checked={mode === "gdpr"}
              onChange={() => setMode("gdpr")}
              className="mt-0.5"
            />
            <span>
              <span className="block font-medium">保留紀錄刪除</span>
              <span className="mt-0.5 block text-xs text-zinc-500">
                清除個資（姓名／電話／Email／生日／LINE／大頭照）、退卡、移除標籤；
                <b>積分／儲值流水、訂單、銷售紀錄保留</b>（依稅捐稽徵法留存 7 年）。
              </span>
            </span>
          </label>
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">刪除原因（選填，會記入稽核紀錄）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="如：會員要求刪除個資 / 重複建檔"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">
            請輸入會員編號 <span className="font-mono text-zinc-700 dark:text-zinc-300">{member.member_no}</span> 以確認
          </span>
          <input
            value={confirmText}
            onChange={(e) => setConfirmText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && confirmed) {
                e.preventDefault();
                submit();
              }
            }}
            placeholder={member.member_no}
            autoComplete="off"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-sm focus:border-red-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="flex justify-end gap-2">
          <SpinButton
            onClick={() => {
              if (busy) return;
              reset();
              onClose();
            }}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={submit}
            disabled={busy || !confirmed}
            className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
          >
            {busy
              ? "刪除中…"
              : mode === "purge"
                ? "🗑️ 徹底刪除（不可還原）"
                : "🗑️ 確認刪除（不可還原）"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
