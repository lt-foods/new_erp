"use client";

// 會員批次刪除（GDPR 軟刪除）— 呼叫 rpc_member_gdpr_delete_bulk
// 行為與單筆版（MemberDeleteModal）相同，只是一次處理多筆：
//   清 PII / 退卡 / 移除標籤 / 流水訂單保留；不可還原；已刪除/已合併會被後端略過。
// 二次確認：須輸入「刪除」二字，避免誤刪一整批。

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

const CONFIRM_WORD = "刪除";

export type BulkDeleteTarget = { id: number; member_no: string; name: string | null };

export function MemberBulkDeleteModal({
  open,
  onClose,
  members,
  onDeleted,
}: {
  open: boolean;
  onClose: () => void;
  members: BulkDeleteTarget[];
  /** 後端回傳實際刪除筆數 */
  onDeleted: (deletedCount: number) => void;
}) {
  const [confirmText, setConfirmText] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const count = members.length;
  const confirmed = confirmText.trim() === CONFIRM_WORD;

  function reset() {
    setConfirmText("");
    setReason("");
    setErr(null);
  }

  async function submit() {
    if (!confirmed) {
      setErr(`請輸入「${CONFIRM_WORD}」以確認`);
      return;
    }
    if (count === 0) return;
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { error, data } = await sb.rpc("rpc_member_gdpr_delete_bulk", {
        p_member_ids: members.map((m) => m.id),
        p_reason: reason.trim() || null,
      });
      if (error) {
        setErr(translateRpcError(error));
        return;
      }
      const deleted = typeof data === "number" ? data : count;
      alert(`已刪除 ${deleted} 位會員（個資已清除，歷史交易紀錄依稅務規定保留）`);
      reset();
      onDeleted(deleted);
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
      title={`批次刪除會員（${count} 筆）`}
      maxWidth="max-w-lg"
    >
      <div className="space-y-4 text-sm">
        <div className="rounded-md border border-red-300 bg-red-50 p-3 dark:border-red-800 dark:bg-red-950/40">
          <div className="font-medium text-red-800 dark:text-red-300">
            ⚠️ 即將刪除 {count} 位會員，此動作不可還原
          </div>
        </div>

        <div className="max-h-40 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <ul className="divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
            {members.map((m) => (
              <li key={m.id} className="flex items-center justify-between gap-2 px-3 py-1.5">
                <span>{m.name ?? "—"}</span>
                <span className="font-mono text-zinc-500">#{m.member_no}</span>
              </li>
            ))}
          </ul>
        </div>

        <div className="rounded-md border border-zinc-200 p-3 text-xs text-zinc-600 dark:border-zinc-800 dark:text-zinc-400">
          <div className="mb-1 font-medium text-zinc-700 dark:text-zinc-300">刪除後：</div>
          <ul className="list-disc space-y-0.5 pl-4">
            <li>清除個資（姓名 / 電話 / Email / 生日 / LINE 綁定 / 大頭照）</li>
            <li>會員卡全部退卡、標籤全部移除</li>
            <li>
              <b>積分 / 儲值流水、訂單、銷售紀錄會保留</b>（依稅捐稽徵法需留存 7 年）
            </li>
            <li>已刪除 / 已合併的會員會自動略過</li>
          </ul>
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">刪除原因（選填，會記入稽核紀錄）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="如：清理測試帳號 / 會員要求刪除個資"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">
            請輸入「<span className="font-medium text-zinc-700 dark:text-zinc-300">{CONFIRM_WORD}</span>」以確認
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
            placeholder={CONFIRM_WORD}
            autoComplete="off"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-red-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
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
            disabled={busy || !confirmed || count === 0}
            className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
          >
            {busy ? "刪除中…" : `🗑️ 確認刪除 ${count} 筆（不可還原）`}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
