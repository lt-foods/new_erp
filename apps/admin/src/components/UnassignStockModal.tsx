"use client";

import { useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

// 取消配貨：把「📦 從庫存配貨」配給這一行的店內現貨收回庫存。
// 見 20260825020000 migration（rpc_unassign_stock_from_order_item）。
//
// 「收回庫存」是什麼意思：配貨當下本來就沒扣庫存（DN 只是取貨閘門的覆蓋，
// 貨到取貨那一刻才扣），所以取消只是把「這批貨已經有主人」的主張拿掉，
// on_hand 一件都不會動 —— 那幾件會重新出現在別人的可配量裡。
//
// 已取貨的行按不到這一顆（貨真的交出去了，要收回是退貨的職責）。

export function UnassignStockModal({
  itemId,
  skuLabel,
  assigned,
  fromPool,
  onClose,
  onSaved,
}: {
  itemId: number;
  skuLabel: string;
  assigned: number;
  fromPool: number;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [qty, setQty] = useState(assigned);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const canSubmit = !busy && qty > 0 && qty <= assigned;
  const toPool = Math.max(0, qty - Math.max(assigned - fromPool, 0));

  async function save() {
    if (!canSubmit) return;
    if (
      !confirm(
        `把「${skuLabel}」已配的 ${qty} 件收回庫存？\n\n` +
          `這一行會變回「等貨中」，那 ${qty} 件會回到可配量、可以配給別的客人。\n` +
          (toPool > 0 ? `其中 ${toPool} 件會還回【內部】店現貨池。\n` : "") +
          `庫存數量不會變動（配貨本來就沒扣庫存）。\n`,
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
      const { data: res, error: e } = await sb.rpc("rpc_unassign_stock_from_order_item", {
        p_item_id: itemId,
        // 全部收回時傳 null，讓伺服端自己算（避免畫面上的數字過期）
        p_qty: qty >= assigned ? null : qty,
        p_operator: operator,
        p_reason: reason.trim() || null,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as {
        qty?: number; remaining?: number; to_pool?: number; pool_missing?: number;
        merged_qty?: number; reverted?: boolean;
      };
      const n = (v: unknown) => (v == null ? 0 : Number(v));
      alert(
        `✅ 已收回 ${n(r.qty)} 件，這些貨回到可配量了。\n` +
          (n(r.to_pool) > 0 ? `其中 ${n(r.to_pool)} 件已還回【內部】店現貨池。\n` : "") +
          (n(r.pool_missing) > 0
            ? `⚠️ 有 ${n(r.pool_missing)} 件還不回現貨池（那幾列已被別的作業動過），` +
              `已改以一般庫存回到可配量。\n`
            : "") +
          (n(r.merged_qty) > 0 ? `配貨時拆出去的 ${n(r.merged_qty)} 件待補貨已併回原本那一行。\n` : "") +
          (n(r.remaining) > 0 ? `這一行還有 ${n(r.remaining)} 件是配過的（沒有一起收回）。\n` : "") +
          (r.reverted ? "整張單退回「已確認（等貨中）」。" : ""),
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
    <Modal open onClose={onClose} title="↩️ 取消配貨（收回庫存）" maxWidth="max-w-lg">
      <div className="space-y-3 text-sm">
        {error && (
          <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900/60">
          <div className="font-medium text-zinc-900 dark:text-zinc-100">{skuLabel}</div>
          <div className="mt-0.5 text-xs text-zinc-500">
            這一行從庫存配過 <b className="text-violet-700 dark:text-violet-400">{assigned}</b> 件
            {fromPool > 0 && <span className="ml-1 text-zinc-400">（其中 {fromPool} 件來自內部現貨池）</span>}
          </div>
          {toPool > 0 && (
            <div className="mt-1.5 text-[11px] text-amber-700 dark:text-amber-400">
              收回的量裡有 <b>{toPool}</b> 件會還回【內部】店現貨池（配貨時是從那裡扣的）。
            </div>
          )}
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">收回數量</span>
          <input
            type="number"
            min={1}
            max={assigned}
            value={qty}
            onChange={(e) => {
              const v = Math.floor(Number(e.target.value));
              setQty(Number.isFinite(v) ? Math.max(0, Math.min(v, assigned)) : 0);
            }}
            className="w-28 rounded-md border border-zinc-300 bg-white px-3 py-2 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
          />
          <span className="ml-2 text-[11px] text-zinc-400">上限 {assigned}</span>
        </label>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：配錯人／改配給更早的單"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-300">
          <b>庫存數量不會變</b> —— 配貨本來就沒扣庫存，收回只是把「這批貨有主人」的
          標記拿掉，那幾件馬上回到可配量、可以配給別的客人。
          <br />
          這一行會變回「等貨中」；配貨時拆出去的待補貨行會併回來。
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
            disabled={!canSubmit}
            className="rounded-md bg-amber-600 px-5 py-2 font-semibold text-white hover:bg-amber-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {busy ? "處理中…" : `收回 ${qty} 件`}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

export default UnassignStockModal;
