"use client";

import { useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ORDER_STATUS_LABEL as STATUS_LABEL, type OrderStatus } from "@/lib/orderStatus";
import { RowAction } from "@/components/RowAction";

// 互助訂單狀態流程:
//   pending → confirmed   (rpc_advance_order_status)
//   confirmed → shipping  (rpc_ship_aid_order — 派貨 + outbound 庫存 + 建 transfer chain)
//     ※ 空中轉不走這一步:轉單當下就自動出貨、直接建成 shipping(20260814030000)。
//       這顆「派貨」只在 confirmed 出現,對空中轉來說 = 補推自動出貨前卡住的舊單。
//   shipping → ready      (由店家在「收貨」代辦頁觸發,rpc_receive_transfer 內部自動推進)
//   ready → completed     (由門市在「取貨」流程觸發、HQ 不需手動推進)
//   ready → (退回原店)     (接收店已收貨但要退,rpc_return_aid_order 反向退回原調出店 + 還原來源單)
const ADVANCE_NEXT: Partial<Record<OrderStatus, OrderStatus>> = {
  pending: "confirmed",
};

export type AidOrderStatusActionsProps = {
  order: { id: number; status: OrderStatus };
  onChanged: () => void;
};

export function AidOrderStatusActions({ order, onChanged }: AidOrderStatusActionsProps) {
  const [busy, setBusy] = useState(false);
  const advanceNext = ADVANCE_NEXT[order.status];
  const isShipAction = order.status === "confirmed";
  const isCancellable = ["pending", "confirmed", "shipping"].includes(order.status);
  // 已收貨(ready)不能走取消,要走「退回原店」— 反向退回原調出店並還原來源單
  const isReturnable = order.status === "ready";

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

  // 已收貨(ready)退回原店:反向退回原調出店、還原來源單(rpc_return_aid_order)
  async function returnToSource() {
    const reason = prompt("退回原店原因(會把已收貨品反向退回原調出店,並還原來源單):");
    if (reason === null) return;
    setBusy(true);
    try {
      const operator = await getOperator();
      if (!operator) { alert("尚未登入"); return; }
      const { error } = await getSupabase().rpc("rpc_return_aid_order", {
        p_order_id: order.id,
        p_reason: reason,
        p_operator: operator,
      });
      if (error) { alert(`退回失敗:${translateRpcError(error)}`); return; }
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      {advanceNext && (
        <RowAction
          variant="primary"
          onClick={advance}
          disabled={busy}
          title={`點擊 → ${STATUS_LABEL[advanceNext]}`}
        >
          → {STATUS_LABEL[advanceNext]}
        </RowAction>
      )}
      {isShipAction && (
        <RowAction variant="success" onClick={ship} disabled={busy}>
          派貨
        </RowAction>
      )}
      {isCancellable && (
        <RowAction variant="danger" onClick={cancel} disabled={busy}>
          {order.status === "shipping" ? "撤回" : "取消"}
        </RowAction>
      )}
      {isReturnable && (
        <RowAction
          variant="danger"
          onClick={returnToSource}
          disabled={busy}
          title="已收貨:反向退回原調出店並還原來源單"
        >
          退回原店
        </RowAction>
      )}
    </>
  );
}

export default AidOrderStatusActions;
