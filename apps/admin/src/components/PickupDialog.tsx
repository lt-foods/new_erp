"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";
import { translateRpcError } from "@/lib/rpcError";

type PickableItem = {
  id: number;
  qty: number;
  unit_price: number;
  discount_amount: number;
  discount_percent: number;
  status: string;
  sku: { id: number; sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

type OrderHead = {
  discount_amount: number;
  discount_percent: number;
  member_id: number | null;
  wallet_paid_amount: number;
  payment_status: string | null;
};

function lineSub(it: PickableItem): number {
  const gross = Number(it.qty) * Number(it.unit_price);
  const afterPct = gross * (1 - Number(it.discount_percent ?? 0) / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - Number(it.discount_amount ?? 0));
}

export function PickupDialog({
  open,
  onClose,
  orderId,
  orderNo,
  onPickedUp,
}: {
  open: boolean;
  onClose: () => void;
  orderId: number;
  orderNo: string;
  onPickedUp: (result: { event_id: number; new_order_status: string; picked_count: number; active_remaining: number }) => void;
}) {
  const [items, setItems] = useState<PickableItem[] | null>(null);
  const [discount, setDiscount] = useState(0);
  const [discountPercent, setDiscountPercent] = useState(0);
  const [memberId, setMemberId] = useState<number | null>(null);
  const [walletPaidSoFar, setWalletPaidSoFar] = useState(0);
  const [walletBalance, setWalletBalance] = useState<number | null>(null);
  const [walletAmount, setWalletAmount] = useState("");
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [iRes, hRes] = await Promise.all([
        sb.from("customer_order_items")
          .select("id, qty, unit_price, discount_amount, discount_percent, status, sku:skus(id, sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .in("status", ["pending", "reserved", "ready"])
          .order("id"),
        sb.from("customer_orders")
          .select("discount_amount, discount_percent, member_id, wallet_paid_amount, payment_status")
          .eq("id", orderId)
          .maybeSingle<OrderHead>(),
      ]);
      if (cancelled) return;
      if (iRes.error) { setErr(iRes.error.message); return; }
      const list = (iRes.data ?? []) as unknown as PickableItem[];
      setItems(list);
      setPicked(new Set(list.map((it) => it.id)));
      const head = hRes.data;
      setDiscount(Number(head?.discount_amount ?? 0));
      setDiscountPercent(Number(head?.discount_percent ?? 0));
      setMemberId(head?.member_id ?? null);
      setWalletPaidSoFar(Number(head?.wallet_paid_amount ?? 0));
      // 抓會員儲值餘額 + 預填本次抵扣（min(餘額, 應收)）
      if (head?.member_id) {
        const { data: wb } = await sb.from("wallet_balances")
          .select("balance").eq("member_id", head.member_id).maybeSingle<{ balance: number }>();
        if (!cancelled) {
          const bal = Number(wb?.balance ?? 0);
          setWalletBalance(bal);
          // 預填：min(餘額, 本次應收) — 已選全 item 預設算
          const itemSubtotal = list.reduce((s, it) => s + lineSub(it), 0);
          const pct = Math.round(itemSubtotal * Number(head?.discount_percent ?? 0)) / 100;
          const initialPayable = Math.max(0, itemSubtotal - pct - Number(head?.discount_amount ?? 0));
          const preFill = Math.min(bal, initialPayable);
          setWalletAmount(preFill > 0 ? String(preFill) : "");
        }
      } else {
        setWalletBalance(null);
        setWalletAmount("");
      }
    })();
    return () => { cancelled = true; };
  }, [open, orderId]);

  function toggle(id: number) {
    setPicked((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  async function submit() {
    if (picked.size === 0) { setErr("至少選一個 item"); return; }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setErr("尚未登入"); return; }

      // Step 1：先扣儲值金（若有）— 失敗就中止，pickup 不寫
      const wAmt = Number(walletAmount);
      if (wAmt > 0) {
        const { error: wErr } = await sb.rpc("rpc_wallet_pay_order", {
          p_order_id: orderId,
          p_amount: wAmt,
          p_operator: operator,
        });
        if (wErr) { setErr(`儲值金扣款失敗：${translateRpcError(wErr)}`); return; }
      }

      // Step 2：寫 pickup
      const { data, error } = await sb.rpc("rpc_record_pickup", {
        p_order_id: orderId,
        p_item_ids: Array.from(picked),
        p_operator: operator,
        p_notes: notes || null,
      });
      if (error) { setErr(error.message); return; }
      const result = data as { event_id: number; new_order_status: string; picked_count: number; active_remaining: number };
      window.open(withBasePath(`/pickup/print?event_ids=${result.event_id}`), "_blank");
      window.open(withBasePath(`/pickup/print-list?order_ids=${orderId}`), "_blank");
      onPickedUp(result);
    } finally {
      setBusy(false);
    }
  }

  const subtotal = items
    ? items.filter((it) => picked.has(it.id)).reduce((s, it) => s + lineSub(it), 0)
    : 0;
  const percentDeduction = Math.round(subtotal * discountPercent) / 100;
  const payableAmount = Math.max(0, subtotal - percentDeduction - discount);

  // 儲值金抵扣計算：本次最多扣 = min(會員餘額, 本次應收)
  const walletNum = Number(walletAmount) || 0;
  const walletMax = Math.min(walletBalance ?? 0, payableAmount);
  const cashAmount = Math.max(0, payableAmount - walletNum);
  const walletInvalid =
    walletNum < 0 ||
    walletNum > walletMax ||
    (walletBalance != null && walletNum > walletBalance);

  return (
    <Modal open={open} onClose={onClose} title={`✅ 確認取貨 — 訂單 ${orderNo}`} maxWidth="max-w-2xl">
      {items === null ? (
        <p className="text-sm text-zinc-500">載入中…</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-zinc-500">無可取貨 item（皆已取貨/取消/逾期）。</p>
      ) : (
        <div className="space-y-3">
          <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="px-3 py-2 text-left text-xs">取</th>
                  <th className="px-3 py-2 text-left text-xs">商品</th>
                  <th className="px-3 py-2 text-right text-xs">數量</th>
                  <th className="px-3 py-2 text-right text-xs">單價</th>
                  <th className="px-3 py-2 text-right text-xs">小計</th>
                  <th className="px-3 py-2 text-left text-xs">狀態</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {items.map((it) => {
                  const sub = lineSub(it);
                  const hasLineDisc = Number(it.discount_amount ?? 0) > 0 || Number(it.discount_percent ?? 0) > 0;
                  return (
                    <tr key={it.id} className={picked.has(it.id) ? "bg-emerald-50 dark:bg-emerald-950" : ""}>
                      <td className="px-3 py-2">
                        <input
                          type="checkbox"
                          checked={picked.has(it.id)}
                          onChange={() => toggle(it.id)}
                          className="h-4 w-4"
                        />
                      </td>
                      <td className="px-3 py-2">
                        <span className="font-medium">{it.sku?.variant_name ?? it.sku?.product_name ?? "—"}</span>
                        {it.sku?.sku_code && (
                          <span className="ml-2 font-mono text-[10px] text-zinc-400">{it.sku.sku_code}</span>
                        )}
                        {hasLineDisc && (
                          <span className="ml-2 text-[10px] text-red-600 dark:text-red-400">
                            (折{Number(it.discount_percent ?? 0) > 0 ? `${it.discount_percent}%` : ""}{Number(it.discount_amount ?? 0) > 0 ? ` -$${it.discount_amount}` : ""})
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right font-mono">{Number(it.qty)}</td>
                      <td className="px-3 py-2 text-right font-mono text-zinc-500">${Number(it.unit_price)}</td>
                      <td className="px-3 py-2 text-right font-mono">${sub}</td>
                      <td className="px-3 py-2 text-xs text-zinc-500">{it.status}</td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <td colSpan={4} className="px-3 py-1 text-right text-xs text-zinc-500">取貨小計</td>
                  <td className="px-3 py-1 text-right font-mono">${subtotal}</td>
                  <td className="px-3 py-1 text-xs text-zinc-500">{picked.size}/{items.length} 項</td>
                </tr>
                {discountPercent > 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-1 text-right text-xs text-zinc-500">− 全單折扣 {discountPercent}%</td>
                    <td className="px-3 py-1 text-right font-mono text-red-600 dark:text-red-400">−${percentDeduction}</td>
                    <td />
                  </tr>
                )}
                {discount > 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-1 text-right text-xs text-zinc-500">− 全單折扣金額</td>
                    <td className="px-3 py-1 text-right font-mono text-red-600 dark:text-red-400">−${discount}</td>
                    <td />
                  </tr>
                )}
                <tr>
                  <td colSpan={4} className="px-3 py-2 text-right text-xs text-zinc-500">應收</td>
                  <td className="px-3 py-2 text-right font-mono text-base font-semibold">${payableAmount}</td>
                  <td />
                </tr>
              </tfoot>
            </table>
          </div>

          {memberId != null && (
            <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
              <div className="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-xs text-zinc-600 dark:text-zinc-400">
                <span>會員儲值餘額：
                  {walletBalance == null
                    ? <span className="text-zinc-500">載入中…</span>
                    : <span className={`font-mono font-semibold ${walletBalance <= 0 ? "text-zinc-400" : ""}`}>${walletBalance}</span>}
                </span>
                {walletPaidSoFar > 0 && (
                  <span>本訂單已扣：<span className="font-mono">${walletPaidSoFar}</span></span>
                )}
              </div>
              <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
                <label className="block">
                  <span className="mb-1 block text-xs text-zinc-500">本次抵扣儲值金</span>
                  <input
                    type="number"
                    min={0}
                    max={walletMax}
                    step="0.01"
                    value={walletAmount}
                    onChange={(e) => setWalletAmount(e.target.value)}
                    placeholder={walletMax > 0 ? `最多 $${walletMax}` : "餘額不足"}
                    disabled={walletMax <= 0}
                    className={`w-full rounded-md border px-3 py-2 font-mono dark:bg-zinc-800 ${walletInvalid ? "border-red-400 dark:border-red-700" : "border-zinc-300 dark:border-zinc-700"} disabled:opacity-50`}
                  />
                </label>
                <div className="block">
                  <span className="mb-1 block text-xs text-zinc-500">需收現金</span>
                  <div className="rounded-md border border-zinc-200 bg-white px-3 py-2 font-mono dark:border-zinc-800 dark:bg-zinc-950">${cashAmount}</div>
                </div>
                {walletMax > 0 && (
                  <button
                    type="button"
                    onClick={() => setWalletAmount(String(walletMax))}
                    className="self-end rounded-md border border-emerald-300 bg-emerald-50 px-3 py-2 text-xs font-medium text-emerald-800 hover:bg-emerald-100 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300 dark:hover:bg-emerald-900/40"
                  >全用儲值金 ${walletMax}</button>
                )}
              </div>
              {walletInvalid && (
                <p className="mt-2 text-xs text-red-600 dark:text-red-400">金額超過餘額或本次應收上限</p>
              )}
            </div>
          )}

          <label className="block text-sm">
            <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
            <input
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              placeholder="如：客人現金付清"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>

          {err && (
            <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
              <p className="font-mono text-xs">{err}</p>
            </div>
          )}

          <div className="flex flex-wrap justify-end gap-2">
            <button
              onClick={onClose}
              disabled={busy}
              className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              取消
            </button>
            <button
              onClick={() => {
                window.open(withBasePath(`/pickup/print-list?order_ids=${orderId}`), "_blank");
              }}
              disabled={busy}
              className="rounded-md border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:border-zinc-300 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
              title="先印小白單給客人看，未確認取貨"
            >
              🖨️ 列印小白單
            </button>
            <button
              onClick={submit}
              disabled={busy || picked.size === 0 || walletInvalid}
              className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
            >
              {busy
                ? "處理中…"
                : walletNum > 0
                  ? `✅ 確認取貨 (儲值 $${walletNum} + 收現 $${cashAmount})`
                  : `✅ 確認取貨 (${picked.size} 項 · $${payableAmount})`}
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}
