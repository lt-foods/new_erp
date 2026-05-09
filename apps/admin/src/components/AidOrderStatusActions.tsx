"use client";

import { useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ORDER_STATUS_LABEL as STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";
import SpinButton from "@/components/SpinButton";

// 互助訂單狀態流程:
//   pending → confirmed   (rpc_advance_order_status)
//   confirmed → shipping  (rpc_ship_aid_order — 派貨 + outbound 庫存 + 建 transfer chain)
//   shipping → ready      (由店家在「收貨」代辦頁觸發,rpc_receive_transfer 內部自動推進)
//   ready → completed     (由門市在「取貨」流程觸發、HQ 不需手動推進)
const ADVANCE_NEXT: Partial<Record<OrderStatus, OrderStatus>> = {
  pending: "confirmed",
};

export type AidOrderStatusActionsProps = {
  order: { id: number; status: OrderStatus };
  onChanged: () => void;
  /** 顯示模式: "inline" 在表格內 (compact)、"detail" 在訂單明細頁 */
  variant?: "inline" | "detail";
};

export function AidOrderStatusActions({ order, onChanged, variant = "inline" }: AidOrderStatusActionsProps) {
  const [busy, setBusy] = useState(false);
  const advanceNext = ADVANCE_NEXT[order.status];
  const isShipAction = order.status === "confirmed";
  const isCancellable = ["pending", "confirmed", "shipping"].includes(order.status);

  async function getOperator(): Promise<string | null> {
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    return sess.session?.user?.id ?? null;
  }

  async function advance() {
    if (!advanceNext) return;
    if (!confirm(`將狀態 ${STATUS_LABEL[order.status]} → ${STATUS_LABEL[advanceNext]}?`)) return;
    setBusy(true);
    try {
      const operator = await getOperator();
      if (!operator) { alert("尚未登入"); return; }
      const { error } = await getSupabase().rpc("rpc_advance_order_status", {
        p_order_id: order.id,
        p_new_status: advanceNext,
        p_operator: operator,
      });
      if (error) { alert(`狀態更新失敗:${translateRpcError(error)}`); return; }
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  async function ship() {
    if (!confirm("確定派貨?將從來源店出貨並建立轉移單。")) return;
    setBusy(true);
    try {
      const operator = await getOperator();
      if (!operator) { alert("尚未登入"); return; }
      const { error } = await getSupabase().rpc("rpc_ship_aid_order", {
        p_order_id: order.id,
        p_operator: operator,
      });
      if (error) { alert(`派貨失敗:${translateRpcError(error)}`); return; }
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  async function cancel() {
    const reason = prompt(
      order.status === "shipping" ? "撤回派貨原因(會反向回收已出庫存):" : "取消原因:",
    );
    if (reason === null) return;
    setBusy(true);
    try {
      const operator = await getOperator();
      if (!operator) { alert("尚未登入"); return; }
      const { error } = await getSupabase().rpc("rpc_cancel_aid_order", {
        p_order_id: order.id,
        p_reason: reason,
        p_operator: operator,
      });
      if (error) { alert(`取消失敗:${translateRpcError(error)}`); return; }
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  const sizeCls =
    variant === "detail"
      ? "px-3 py-1.5 text-xs"
      : "px-2 py-0.5 text-[10px]";

  return (
    <div className="flex flex-wrap items-center gap-1">
      {advanceNext && (
        <SpinButton
          onClick={advance}
          disabled={busy}
          title={`點擊 → ${STATUS_LABEL[advanceNext]}`}
          className={`rounded bg-blue-600 font-semibold text-white shadow-sm hover:bg-blue-700 disabled:opacity-50 ${sizeCls}`}
        >
          → {STATUS_LABEL[advanceNext]}
        </SpinButton>
      )}
      {isShipAction && (
        <SpinButton
          onClick={ship}
          disabled={busy}
          className={`rounded bg-emerald-600 font-semibold text-white shadow-sm hover:bg-emerald-700 disabled:opacity-50 ${sizeCls}`}
        >
          🚚 派貨
        </SpinButton>
      )}
      {order.status === "shipping" && (
        <span className="text-[10px] text-zinc-400" title="此狀態由店家在「收貨」代辦頁點收貨後自動推進到「可取貨」">
          (待店家收貨)
        </span>
      )}
      {order.status === "ready" && (
        <span className="text-[10px] text-zinc-400" title="此狀態由門市在「取貨」流程點取貨後自動推進到「已完成」">
          (待門市取貨)
        </span>
      )}
      {isCancellable && (
        <SpinButton
          onClick={cancel}
          disabled={busy}
          className={`rounded bg-rose-600 font-semibold text-white shadow-sm hover:bg-rose-700 disabled:opacity-50 ${sizeCls}`}
        >
          {order.status === "shipping" ? "撤回" : "取消"}
        </SpinButton>
      )}
    </div>
  );
}

export default AidOrderStatusActions;
