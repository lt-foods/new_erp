"use client";

import { useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

// 取消配單：把波次到貨自動配單配給這一行的貨收回可配量。
// 見 20260827010000 migration（rpc_unallocate_order_item）。
//
// 跟「↩️ 取消配貨」（UnassignStockModal）的分工：那顆收的是「📦 從庫存配貨」
// 開的 DN 覆蓋；這顆收的是波次到貨自動配單（身上沒有 DN、閘門靠 Path A/B/C
// 放行）。做法是把品項標成「待補貨」—— 取貨閘門立刻關掉、貨回到別張單的
// 可配量。要重新配就按「📦 從庫存配貨」，或等下一批貨收進來自動重配。
//
// 整行一起退（不拆行）：qty>1 只想退一部分，先到訂單頁改數量再取消。

export function CancelAllocationModal({
  itemId,
  skuLabel,
  qty,
  onClose,
  onSaved,
}: {
  itemId: number;
  skuLabel: string;
  qty: number;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function save() {
    if (busy) return;
    if (
      !confirm(
        `取消「${skuLabel}」${qty} 件的配單？\n\n` +
          `這一行會退回「等貨中」（取貨頁就勾不到了），那 ${qty} 件回到可配量、` +
          `可以配給別的客人。\n` +
          `庫存數量不會變動（配單本來就沒扣庫存）。\n`,
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_unallocate_order_item", {
        p_item_id: itemId,
        p_operator: operator,
        p_reason: reason.trim() || null,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as { qty?: number; reverted?: boolean };
      alert(
        `✅ 已取消配單（${Number(r.qty ?? qty)} 件），這些貨回到可配量了。\n` +
          `這一行退回「等貨中」，要重新配就按「📦 從庫存配貨」，` +
          `下一批貨收進來時數量夠也會自動重配。\n` +
          (r.reverted ? "整張單退回「已確認（等貨中）」。\n" : "") +
          `⚠️ 客人若已收過「到貨通知」，請記得自行知會。`,
      );
      onSaved();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={onClose} title="↩️ 取消配單（收回可配量）" maxWidth="max-w-lg">
      <div className="space-y-3 text-sm">
        {error && (
          <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900/60">
          <div className="font-medium text-zinc-900 dark:text-zinc-100">{skuLabel}</div>
          <div className="mt-0.5 text-xs text-zinc-500">
            這一行已由到貨自動配單配到 <b className="text-violet-700 dark:text-violet-400">{qty}</b> 件
            —— 整行一起取消（只想退一部分請先改訂單數量）。
          </div>
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：客人晚點才來拿／貨要先給更急的單"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-300">
          <b>庫存數量不會變</b> —— 配單本來就沒扣庫存，取消只是把「這批貨有主人」的
          標記拿掉，那幾件馬上回到可配量、可以配給別的客人。
          <br />
          這一行會退回「等貨中」（系統標記為待補貨）、整張單退回「已確認」；客人若已收過到貨通知請自行知會。
        </div>

        <div className="flex items-center justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            關閉
          </SpinButton>
          <SpinButton
            onClick={save}
            disabled={busy}
            className="rounded-md bg-amber-600 px-5 py-2 font-semibold text-white hover:bg-amber-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {busy ? "處理中…" : `取消配單 ${qty} 件`}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

export default CancelAllocationModal;
