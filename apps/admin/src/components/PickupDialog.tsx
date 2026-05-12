"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { EditableDiscount, deriveDiscount, type DiscountValue } from "@/components/EditableDiscount";

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
  const [discountValue, setDiscountValue] = useState<DiscountValue>({ kind: "amount", value: 0 });
  const [originalDiscount, setOriginalDiscount] = useState<{ amount: number; percent: number }>({ amount: 0, percent: 0 });
  const [memberId, setMemberId] = useState<number | null>(null);
  const [walletPaidSoFar, setWalletPaidSoFar] = useState(0);
  const [paymentStatus, setPaymentStatus] = useState<string | null>(null);
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
      const headAmt = Number(head?.discount_amount ?? 0);
      const headPct = Number(head?.discount_percent ?? 0);
      setOriginalDiscount({ amount: headAmt, percent: headPct });
      setDiscountValue(deriveDiscount(headPct, headAmt));
      setMemberId(head?.member_id ?? null);
      const alreadyPaid = Number(head?.wallet_paid_amount ?? 0);
      const isPaid = head?.payment_status === "paid";
      setWalletPaidSoFar(alreadyPaid);
      setPaymentStatus(head?.payment_status ?? null);
      // 抓會員儲值餘額 + 預填本次抵扣（扣掉已付的）
      if (head?.member_id) {
        const { data: wb } = await sb.from("wallet_balances")
          .select("balance").eq("member_id", head.member_id).maybeSingle<{ balance: number }>();
        if (!cancelled) {
          const bal = Number(wb?.balance ?? 0);
          setWalletBalance(bal);
          // 已付清 → 不再扣；否則：min(餘額, 本次應收 - 已付)
          if (isPaid) {
            setWalletAmount("");
          } else {
            const itemSubtotal = list.reduce((s, it) => s + lineSub(it), 0);
            const dpct = Number(head?.discount_percent ?? 0);
            const damt = Number(head?.discount_amount ?? 0);
            const initialPayable = Math.max(0, Math.round(itemSubtotal * (1 - dpct / 100) - damt));
            const remainingPayable = Math.max(0, initialPayable - alreadyPaid);
            const preFill = Math.min(bal, remainingPayable);
            setWalletAmount(preFill > 0 ? String(preFill) : "");
          }
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

  // 把 discount draft 寫進 customer_orders（沒變動就 no-op）。成功 → true，更新 originalDiscount。
  async function persistDiscountDraft(): Promise<boolean> {
    const newPct = discountValue.kind === "percent" ? Number(discountValue.value) : 0;
    const newAmt = discountValue.kind === "amount" ? Number(discountValue.value) : 0;
    if (newPct === originalDiscount.percent && newAmt === originalDiscount.amount) return true;
    const sb = getSupabase();
    const { data: sess } = await sb.auth.getSession();
    const operator = sess.session?.user?.id;
    if (!operator) { setErr("尚未登入"); return false; }
    if (newPct !== originalDiscount.percent) {
      const { error: dpErr } = await sb.rpc("rpc_update_order_discount_percent", {
        p_order_id: orderId, p_new_percent: newPct, p_operator: operator, p_reason: null,
      });
      if (dpErr) { setErr(`折扣%儲存失敗:${translateRpcError(dpErr)}`); return false; }
    }
    if (newAmt !== originalDiscount.amount) {
      const { error: daErr } = await sb.rpc("rpc_update_order_discount", {
        p_order_id: orderId, p_new_discount: newAmt, p_operator: operator, p_reason: null,
      });
      if (daErr) { setErr(`折扣$儲存失敗:${translateRpcError(daErr)}`); return false; }
    }
    setOriginalDiscount({ amount: newAmt, percent: newPct });
    return true;
  }

  async function printSlip() {
    setBusy(true);
    setErr(null);
    try {
      // 先把折扣存 DB,小白單才會印出最新折扣
      const ok = await persistDiscountDraft();
      if (!ok) return;
      // 儲值金尚未實扣,用 ?wallet_preview= 帶到小白單上預覽（不寫 DB）
      const params = new URLSearchParams({ order_ids: String(orderId) });
      const wPrev = Number(walletAmount) || 0;
      if (wPrev > 0) params.set("wallet_preview", String(wPrev));
      window.open(withBasePath(`/pickup/print-list?${params.toString()}`), "_blank");
    } finally {
      setBusy(false);
    }
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

      // Step 0：先存「整單折扣」（若有變動）— 失敗中止，wallet/pickup 都不寫
      const ok = await persistDiscountDraft();
      if (!ok) return;

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
      // 取貨單一定印（收據）
      window.open(withBasePath(`/pickup/print?event_ids=${result.event_id}`), "_blank");
      // 取貨清單只在「部分取貨」時印（提醒客人剩下未取的 items）；全取完省略
      if (result.active_remaining > 0) {
        window.open(withBasePath(`/pickup/print-list?order_ids=${orderId}`), "_blank");
      }
      onPickedUp(result);
    } finally {
      setBusy(false);
    }
  }

  const subtotal = items
    ? items.filter((it) => picked.has(it.id)).reduce((s, it) => s + lineSub(it), 0)
    : 0;
  const discountPercent = discountValue.kind === "percent" ? Number(discountValue.value) : 0;
  const discount = discountValue.kind === "amount" ? Number(discountValue.value) : 0;
  // payable 四捨五入到整數 NTD；deduction 倒推、確保 subtotal − pct − amt = payable 完全對齊
  const payableAmount = Math.max(0, Math.round(subtotal * (1 - discountPercent / 100) - discount));
  const totalDeduction = subtotal - payableAmount;
  const percentDeduction = Math.max(0, totalDeduction - discount);
  const discountDirty =
    Number(originalDiscount.percent) !== discountPercent ||
    Number(originalDiscount.amount) !== discount;

  // 折扣 / picked 變動後，若 walletAmount 超過新上限就 clamp（避免按鈕被卡 disabled）
  const isPaid = paymentStatus === "paid";
  const remainingPayable = Math.max(0, payableAmount - walletPaidSoFar);
  const walletMax = isPaid ? 0 : Math.min(walletBalance ?? 0, remainingPayable);
  useEffect(() => {
    if (walletAmount === "") return;
    const n = Number(walletAmount);
    if (n > walletMax) setWalletAmount(walletMax > 0 ? String(walletMax) : "");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [walletMax]);

  // 儲值金抵扣計算：本次最多扣 = min(會員餘額, 本次應收 - 已付)
  const walletNum = Number(walletAmount) || 0;
  const cashAmount = Math.max(0, remainingPayable - walletNum);
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
                <tr>
                  <td colSpan={2} className="px-3 py-1 text-right text-xs text-zinc-500">
                    整單折扣
                    {discountDirty && (
                      <span className="ml-1 rounded bg-yellow-100 px-1 text-[10px] text-yellow-800 dark:bg-yellow-950 dark:text-yellow-300">
                        待存
                      </span>
                    )}
                  </td>
                  <td colSpan={2} className="px-3 py-1 text-left">
                    <EditableDiscount
                      value={discountValue}
                      onChange={setDiscountValue}
                      referenceAmount={subtotal}
                      compact
                    />
                  </td>
                  <td className="px-3 py-1 text-right font-mono text-red-600 dark:text-red-400">
                    {totalDeduction > 0
                      ? `−$${Math.round(totalDeduction)}`
                      : <span className="text-zinc-400">—</span>}
                  </td>
                  <td className="px-3 py-1 text-[10px] text-zinc-500">
                    {discountPercent > 0 && discount > 0
                      ? `${discountPercent}% + $${discount}`
                      : discountPercent > 0
                        ? `(其中% −$${Math.round(percentDeduction)})`
                        : null}
                  </td>
                </tr>
                <tr>
                  <td colSpan={4} className="px-3 py-2 text-right text-xs text-zinc-500">應收</td>
                  <td className="px-3 py-2 text-right font-mono text-base font-semibold">${Math.round(payableAmount)}</td>
                  <td />
                </tr>
                {walletPaidSoFar > 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-1 text-right text-xs text-zinc-500">− 已用儲值金</td>
                    <td className="px-3 py-1 text-right font-mono text-zinc-500">−${Math.round(walletPaidSoFar)}</td>
                    <td />
                  </tr>
                )}
                {walletPaidSoFar > 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-2 text-right text-xs text-zinc-500">應付剩餘</td>
                    <td className={`px-3 py-2 text-right font-mono text-base font-semibold ${remainingPayable === 0 ? "text-emerald-700 dark:text-emerald-400" : ""}`}>${Math.round(remainingPayable)}</td>
                    <td>{isPaid && <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">已付清</span>}</td>
                  </tr>
                )}
              </tfoot>
            </table>
          </div>

          {memberId != null && (
            <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
              <div className="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-xs text-zinc-600 dark:text-zinc-400">
                <span>會員儲值餘額：
                  {walletBalance == null
                    ? <span className="text-zinc-500">載入中…</span>
                    : <span className={`font-mono font-semibold ${walletBalance <= 0 ? "text-zinc-400" : ""}`}>${Math.round(walletBalance)}</span>}
                </span>
                {walletPaidSoFar > 0 && (
                  <span>本訂單已扣：<span className="font-mono">${Math.round(walletPaidSoFar)}</span></span>
                )}
                {isPaid && (
                  <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-medium text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">✅ 已付清，本次無需再扣</span>
                )}
              </div>
              <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
                <label className="block">
                  <span className="mb-1 block text-xs text-zinc-500">本次抵扣儲值金</span>
                  <input
                    type="number"
                    min={0}
                    max={walletMax}
                    step="1"
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
                  <SpinButton
                    type="button"
                    onClick={() => setWalletAmount(String(walletMax))}
                    className="self-end rounded-md border border-emerald-300 bg-emerald-50 px-3 py-2 text-xs font-medium text-emerald-800 hover:bg-emerald-100 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300 dark:hover:bg-emerald-900/40"
                  >全用儲值金 ${walletMax}</SpinButton>
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
            <SpinButton
              onClick={onClose}
              disabled={busy}
              className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              取消
            </SpinButton>
            <SpinButton
              onClick={printSlip}
              disabled={busy}
              className="rounded-md border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:border-zinc-300 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
              title={discountDirty ? "會先存折扣再印（沒按確認取貨也保留折扣）" : "先印小白單給客人看，未確認取貨"}
            >
              🖨️ 列印小白單{discountDirty && "（含折扣）"}
            </SpinButton>
            <SpinButton
              onClick={submit}
              disabled={busy || picked.size === 0 || walletInvalid}
              className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
            >
              {busy
                ? "處理中…"
                : walletNum > 0
                  ? `✅ 確認取貨 (儲值 $${walletNum} + 收現 $${cashAmount})`
                  : `✅ 確認取貨 (${picked.size} 項 · $${payableAmount})`}
            </SpinButton>
          </div>
        </div>
      )}
    </Modal>
  );
}
