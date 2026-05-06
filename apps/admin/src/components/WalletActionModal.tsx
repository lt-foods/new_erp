"use client";

// 儲值金後台寫入操作 modal：加值 / 扣款 / 退款 / 調整 / 反向
// 對應 RPCs: rpc_wallet_topup / rpc_wallet_spend / rpc_wallet_refund
//            rpc_wallet_adjust / rpc_wallet_reverse

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

export type WalletActionMode = "topup" | "spend" | "refund" | "adjust" | "reverse";

type ReverseTarget = {
  id: number;
  type: string;
  change: number;
  balance_after: number;
  payment_method: string | null;
  reason: string | null;
  created_at: string;
};

type Props = {
  open: boolean;
  onClose: () => void;
  onSuccess: () => void;
  tenantId: string;
  memberId: number;
  mode: WalletActionMode;
  reverseTarget?: ReverseTarget;
};

const TITLES: Record<WalletActionMode, string> = {
  topup:   "加值（topup）",
  spend:   "扣款（spend）",
  refund:  "退款（refund）",
  adjust:  "調整（adjust）",
  reverse: "反向（reversal）",
};

const PAYMENT_METHODS = [
  { value: "cash",        label: "現金 cash" },
  { value: "credit_card", label: "信用卡 credit_card" },
  { value: "transfer",    label: "轉帳 transfer" },
];

export function WalletActionModal({
  open, onClose, onSuccess,
  tenantId, memberId, mode, reverseTarget,
}: Props) {
  const [amount, setAmount] = useState("");
  const [paymentMethod, setPaymentMethod] = useState("cash");
  const [sourceType, setSourceType] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 開啟時清空欄位
  useEffect(() => {
    if (!open) return;
    setAmount("");
    setPaymentMethod("cash");
    setSourceType(mode === "refund" ? "manual" : "");
    setReason("");
    setErr(null);
  }, [open, mode]);

  const reasonRequired = mode === "refund" || mode === "adjust" || mode === "reverse";
  const amountAllowsNegative = mode === "adjust";

  async function submit() {
    setErr(null);

    // Reason 驗證
    if (reasonRequired && reason.trim().length < 4) {
      setErr("請輸入原因（至少 4 字）");
      return;
    }

    // 金額驗證 (reverse 不需要 amount)
    let amountNum = 0;
    if (mode !== "reverse") {
      amountNum = Number(amount);
      if (!Number.isFinite(amountNum)) {
        setErr("金額格式錯誤");
        return;
      }
      if (mode === "adjust") {
        if (amountNum === 0) { setErr("變動金額不可為 0"); return; }
      } else {
        if (amountNum <= 0) { setErr("金額必須大於 0"); return; }
      }
    }

    setBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setErr("尚未登入"); return; }

      let rpcResult;
      if (mode === "topup") {
        rpcResult = await sb.rpc("rpc_wallet_topup", {
          p_tenant_id:      tenantId,
          p_member_id:      memberId,
          p_amount:         amountNum,
          p_payment_method: paymentMethod,
          p_source_type:    "manual",
          p_source_id:      null,
          p_operator:       operator,
        });
      } else if (mode === "spend") {
        rpcResult = await sb.rpc("rpc_wallet_spend", {
          p_tenant_id:   tenantId,
          p_member_id:   memberId,
          p_amount:      amountNum,
          p_source_type: "manual",
          p_source_id:   null,
          p_operator:    operator,
        });
      } else if (mode === "refund") {
        rpcResult = await sb.rpc("rpc_wallet_refund", {
          p_tenant_id:   tenantId,
          p_member_id:   memberId,
          p_amount:      amountNum,
          p_source_type: sourceType || "manual",
          p_source_id:   null,
          p_reason:      reason.trim(),
          p_operator:    operator,
        });
      } else if (mode === "adjust") {
        rpcResult = await sb.rpc("rpc_wallet_adjust", {
          p_tenant_id: tenantId,
          p_member_id: memberId,
          p_change:    amountNum,
          p_reason:    reason.trim(),
          p_operator:  operator,
        });
      } else {
        // reverse
        if (!reverseTarget) { setErr("缺少反向目標"); return; }
        rpcResult = await sb.rpc("rpc_wallet_reverse", {
          p_tenant_id: tenantId,
          p_ledger_id: reverseTarget.id,
          p_reason:    reason.trim(),
          p_operator:  operator,
        });
      }

      if (rpcResult.error) {
        setErr(translateRpcError(rpcResult.error));
        return;
      }
      onSuccess();
      onClose();
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`儲值金 — ${TITLES[mode]}`} maxWidth="max-w-md">
      <div className="space-y-4 text-sm">
        {/* reverse 模式：顯示原 ledger 摘要 */}
        {mode === "reverse" && reverseTarget && (
          <div className="rounded-md border border-amber-300 bg-amber-50 p-3 dark:border-amber-800 dark:bg-amber-950/40">
            <div className="text-xs text-amber-800 dark:text-amber-300">
              <b>反向目標 ledger #{reverseTarget.id}</b>
              <div className="mt-1 grid grid-cols-2 gap-x-3 gap-y-1">
                <div>類型：<span className="font-mono">{reverseTarget.type}</span></div>
                <div>變動：<span className={`font-mono ${reverseTarget.change >= 0 ? "text-green-700 dark:text-green-400" : "text-red-700 dark:text-red-400"}`}>{reverseTarget.change >= 0 ? "+" : ""}{reverseTarget.change}</span></div>
                <div>餘額：<span className="font-mono">{reverseTarget.balance_after}</span></div>
                <div>付款：<span className="font-mono">{reverseTarget.payment_method ?? "—"}</span></div>
                <div className="col-span-2">時間：{new Date(reverseTarget.created_at).toLocaleString("zh-TW")}</div>
                {reverseTarget.reason && <div className="col-span-2">原因：{reverseTarget.reason}</div>}
              </div>
              <div className="mt-2">送出後將新增一筆 <code>type=reversal</code> 紀錄，金額為 <span className="font-mono">{-reverseTarget.change >= 0 ? "+" : ""}{-reverseTarget.change}</span>。原 ledger 不會被修改。</div>
            </div>
          </div>
        )}

        {/* 金額（非 reverse） */}
        {mode !== "reverse" && (
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">
              {mode === "adjust" ? "變動金額（可正可負，不為 0）" : "金額（>0）"}
            </span>
            <input
              type="number"
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder={amountAllowsNegative ? "如 100 或 -50" : "如 1000"}
              autoFocus
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono dark:border-zinc-700 dark:bg-zinc-900"
            />
          </label>
        )}

        {/* topup: 付款方式 */}
        {mode === "topup" && (
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">付款方式</span>
            <select
              value={paymentMethod}
              onChange={(e) => setPaymentMethod(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-900"
            >
              {PAYMENT_METHODS.map((m) => (
                <option key={m.value} value={m.value}>{m.label}</option>
              ))}
            </select>
          </label>
        )}

        {/* refund: source_type */}
        {mode === "refund" && (
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">來源類型 (selectable: manual / customer_order)</span>
            <input
              value={sourceType}
              onChange={(e) => setSourceType(e.target.value)}
              placeholder="manual"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono dark:border-zinc-700 dark:bg-zinc-900"
            />
          </label>
        )}

        {/* 原因 */}
        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">
            原因 {reasonRequired ? <span className="text-red-600">*（必填，≥ 4 字）</span> : "（選填）"}
          </span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder={reasonRequired ? "請說明原因（會寫入 ledger.reason）" : "選填"}
            rows={2}
            required={reasonRequired}
            minLength={reasonRequired ? 4 : undefined}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </button>
          <button
            onClick={submit}
            disabled={busy}
            className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {busy ? "送出中…" : "✅ 確認"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
