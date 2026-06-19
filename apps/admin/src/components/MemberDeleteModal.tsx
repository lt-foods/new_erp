"use client";

// 會員刪除（GDPR 軟刪除）— 呼叫 rpc_member_gdpr_delete
// 後端行為（見 supabase/migrations/20260618000040_rpc_member_gdpr_delete.sql）：
//   - members：清 PII（姓名 / 電話 / email / 生日 / LINE / 大頭照）、status='deleted'
//   - member_cards：全部退卡（retired）
//   - member_tags：全部刪除
//   - points_ledger / wallet_ledger / 訂單 / sales：保留（稅捐稽徵法 7 年留存）
//   - 不可還原；冪等（已刪除再按為 no-op）
//
// 權限：RPC 為 SECURITY DEFINER 不自帶 role gate（與 rpc_merge_member 同慣例，
//   由呼叫端把關）。本 modal 只在 isAdmin(role) 時於 MemberDetail 掛出，
//   並要求「輸入會員編號二次確認」避免誤刪。

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

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
  const [confirmText, setConfirmText] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 二次確認：必須完整輸入會員編號
  const confirmed = confirmText.trim() === member.member_no;

  function reset() {
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

        <div className="rounded-md border border-zinc-200 p-3 text-xs text-zinc-600 dark:border-zinc-800 dark:text-zinc-400">
          <div className="mb-1 font-medium text-zinc-700 dark:text-zinc-300">刪除後：</div>
          <ul className="list-disc space-y-0.5 pl-4">
            <li>清除個資（姓名 / 電話 / Email / 生日 / LINE 綁定 / 大頭照）</li>
            <li>會員卡全部退卡、標籤全部移除</li>
            <li>會員將從列表消失、無法再以電話 / 卡號查詢</li>
            <li>
              <b>積分 / 儲值流水、訂單、銷售紀錄會保留</b>（依稅捐稽徵法需留存 7 年）
            </li>
          </ul>
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
            {busy ? "刪除中…" : "🗑️ 確認刪除（不可還原）"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
