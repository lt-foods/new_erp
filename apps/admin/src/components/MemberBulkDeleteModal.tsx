"use client";

// 會員批次刪除 — 兩種模式（與單筆版 MemberDeleteModal 相同）：
//   徹底刪除（預設）— rpc_member_purge_bulk：實體刪除會員與附屬資料，
//     訂單等單據保留但解除會員連結；分店內部會員（store_internal）自動略過。
//   保留紀錄刪除 — rpc_member_gdpr_delete_bulk：清 PII / 退卡 / 移除標籤，
//     流水訂單保留；已刪除／已合併會被後端略過。
// 二次確認：須輸入「刪除」二字，避免誤刪一整批。

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";

const CONFIRM_WORD = "刪除";

type DeleteMode = "purge" | "gdpr";

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
  const [mode, setMode] = useState<DeleteMode>("purge");
  const [confirmText, setConfirmText] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const count = members.length;
  const confirmed = confirmText.trim() === CONFIRM_WORD;

  function reset() {
    setMode("purge");
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

      if (mode === "purge") {
        const { error, data } = await sb.rpc("rpc_member_purge_bulk", {
          p_member_ids: members.map((m) => m.id),
          p_reason: reason.trim() || null,
        });
        if (error) {
          setErr(translateRpcError(error));
          return;
        }
        const result = (data ?? {}) as { purged?: number; skipped_internal?: number };
        const purged = result.purged ?? count;
        const skippedInternal = result.skipped_internal ?? 0;
        alert(
          `已徹底刪除 ${purged} 位會員（會員資料與點數／儲值紀錄已完全移除）` +
            (skippedInternal > 0 ? `\n略過 ${skippedInternal} 位分店內部會員（無法刪除）` : ""),
        );
        reset();
        onDeleted(purged);
      } else {
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
      }
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

        <div className="space-y-2">
          <label className="flex cursor-pointer items-start gap-2 rounded-md border border-zinc-200 p-3 has-[:checked]:border-red-400 has-[:checked]:bg-red-50/50 dark:border-zinc-800 dark:has-[:checked]:border-red-800 dark:has-[:checked]:bg-red-950/20">
            <input
              type="radio"
              name="bulk-delete-mode"
              checked={mode === "purge"}
              onChange={() => setMode("purge")}
              className="mt-0.5"
            />
            <span>
              <span className="block font-medium">徹底刪除</span>
              <span className="mt-0.5 block text-xs text-zinc-500">
                會員資料完全從系統移除：個資、積分／儲值流水、會員卡、標籤、LINE
                綁定、推播訂閱全數刪除。訂單等營運單據保留，但不再掛在會員名下。
                分店內部會員會自動略過。
              </span>
            </span>
          </label>
          <label className="flex cursor-pointer items-start gap-2 rounded-md border border-zinc-200 p-3 has-[:checked]:border-red-400 has-[:checked]:bg-red-50/50 dark:border-zinc-800 dark:has-[:checked]:border-red-800 dark:has-[:checked]:bg-red-950/20">
            <input
              type="radio"
              name="bulk-delete-mode"
              checked={mode === "gdpr"}
              onChange={() => setMode("gdpr")}
              className="mt-0.5"
            />
            <span>
              <span className="block font-medium">保留紀錄刪除</span>
              <span className="mt-0.5 block text-xs text-zinc-500">
                清除個資（姓名／電話／Email／生日／LINE／大頭照）、退卡、移除標籤；
                <b>積分／儲值流水、訂單、銷售紀錄保留</b>（依稅捐稽徵法留存 7 年）。
                已刪除／已合併的會員自動略過。
              </span>
            </span>
          </label>
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
            {busy
              ? "刪除中…"
              : mode === "purge"
                ? `🗑️ 徹底刪除 ${count} 筆（不可還原）`
                : `🗑️ 確認刪除 ${count} 筆（不可還原）`}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
