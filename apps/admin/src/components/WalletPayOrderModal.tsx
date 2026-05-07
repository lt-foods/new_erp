"use client";

// 訂單用儲值金結帳 modal
// 對應 RPC: rpc_wallet_pay_order(p_order_id, p_amount, p_operator)

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

type Props = {
  open: boolean;
  onClose: () => void;
  onSuccess: () => void;
  orderId: number;
  orderNo: string;
  memberId: number;
  memberName: string | null;
  balanceDue: number;
};

export function WalletPayOrderModal({
  open, onClose, onSuccess,
  orderId, orderNo, memberId, memberName, balanceDue,
}: Props) {
  const [walletBalance, setWalletBalance] = useState<number | null>(null);
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setErr(null);
    setWalletBalance(null);
    setAmount("");
    (async () => {
      const sb = getSupabase();
      const { data } = await sb.from("wallet_balances")
        .select("balance").eq("member_id", memberId).maybeSingle<{ balance: number }>();
      const bal = Number(data?.balance ?? 0);
      setWalletBalance(bal);
      // 預設值 = min(balance_due, walletBalance)
      const def = Math.min(balanceDue, bal);
      if (def > 0) setAmount(String(def));
    })();
  }, [open, memberId, balanceDue]);

  async function submit() {
    setErr(null);
    const a = Number(amount);
    if (!Number.isFinite(a) || a <= 0) { setErr("金額必須 > 0"); return; }
    if (a > balanceDue)               { setErr(`金額不可超過應付剩餘 $${balanceDue}`); return; }
    if (walletBalance != null && a > walletBalance) {
      setErr(`金額超過會員餘額 $${walletBalance}`); return;
    }

    setBusy(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setErr("尚未登入"); return; }

      const { error } = await sb.rpc("rpc_wallet_pay_order", {
        p_order_id: orderId,
        p_amount:   a,
        p_operator: operator,
      });
      if (error) { setErr(translateRpcError(error)); return; }
      onSuccess();
      onClose();
    } finally {
      setBusy(false);
    }
  }

  const insufficientWallet = walletBalance != null && walletBalance <= 0;

  return (
    <Modal open={open} onClose={onClose} title={`用儲值金結帳`} maxWidth="max-w-md">
      <div className="space-y-4 text-sm">
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-800 dark:bg-zinc-900">
          <div>訂單：<span className="font-mono">{orderNo}</span></div>
          <div>會員：{memberName ?? "—"} <span className="font-mono text-zinc-500">#{memberId}</span></div>
          <div className="mt-1">應付剩餘：<span className="font-mono font-semibold">${balanceDue}</span></div>
          <div>會員餘額：
            {walletBalance == null
              ? <span className="text-zinc-500">載入中…</span>
              : <span className={`font-mono font-semibold ${insufficientWallet ? "text-red-600" : ""}`}>${walletBalance}</span>}
          </div>
        </div>

        {insufficientWallet && (
          <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300">
            ⚠️ 會員儲值金餘額為 0，請先到會員頁加值後再回來結帳。
          </div>
        )}

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">
            金額（&gt; 0，≤ 應付剩餘 ${balanceDue}{walletBalance != null ? ` / 餘額 $${walletBalance}` : ""}）
          </span>
          <input
            type="number"
            step="1"
            min={0}
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            disabled={insufficientWallet}
            autoFocus
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono dark:border-zinc-700 dark:bg-zinc-900 disabled:opacity-50"
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
            disabled={busy || insufficientWallet || walletBalance == null}
            className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {busy ? "結帳中…" : "💳 確認結帳"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
