"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";
import { printViaIframe } from "@/lib/printIframe";
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

// 以指定數量計算小計（line-level 折扣金額按比例分攤，對齊後端拆行邏輯）
function lineSubQty(it: PickableItem, qty: number): number {
  const fullQty = Number(it.qty) || 0;
  const ratio = fullQty > 0 ? qty / fullQty : 0;
  const gross = qty * Number(it.unit_price);
  const afterPct = gross * (1 - Number(it.discount_percent ?? 0) / 100);
  const discAmt = Number(it.discount_amount ?? 0) * ratio;
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - discAmt);
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
  // item.id → 已退數量（return_to_hq transfer 依 SKU 聚合後分攤到各品項行）
  const [returnedByItem, setReturnedByItem] = useState<Map<number, number>>(new Map());
  const [discountValue, setDiscountValue] = useState<DiscountValue>({ kind: "amount", value: 0 });
  const [originalDiscount, setOriginalDiscount] = useState<{ amount: number; percent: number }>({ amount: 0, percent: 0 });
  const [memberId, setMemberId] = useState<number | null>(null);
  const [walletPaidSoFar, setWalletPaidSoFar] = useState(0);
  const [paymentStatus, setPaymentStatus] = useState<string | null>(null);
  const [walletBalance, setWalletBalance] = useState<number | null>(null);
  const [walletAmount, setWalletAmount] = useState("");
  const [picked, setPicked] = useState<Set<number>>(new Set());
  // 每個 item 本次取貨數量（預設 = 全取）。key=item.id, value=數量字串（允許編輯中暫空）
  const [pickQty, setPickQty] = useState<Map<number, string>>(new Map());
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [iRes, hRes, rRes] = await Promise.all([
        sb.from("customer_order_items")
          .select("id, qty, unit_price, discount_amount, discount_percent, status, sku:skus(id, sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .in("status", ["pending", "reserved", "ready"])
          .order("id"),
        sb.from("customer_orders")
          .select("discount_amount, discount_percent, member_id, wallet_paid_amount, payment_status")
          .eq("id", orderId)
          .maybeSingle<OrderHead>(),
        // 已退回總倉量（return_to_hq transfer）— 退掉的貨店裡沒有、不可再取
        sb.from("transfers")
          .select("transfer_items(sku_id, qty_shipped)")
          .eq("customer_order_id", orderId)
          .eq("transfer_type", "return_to_hq")
          .in("status", ["shipped", "received"]),
      ]);
      if (cancelled) return;
      if (iRes.error) { setErr(iRes.error.message); return; }
      const list = (iRes.data ?? []) as unknown as PickableItem[];

      // ----- 退貨量依 SKU 聚合，再分攤到各 pending 品項行（list 已 order by id，分攤穩定）-----
      const returnedBySku = new Map<number, number>();
      for (const t of (rRes.data ?? []) as { transfer_items: { sku_id: number; qty_shipped: number | null }[] | null }[]) {
        for (const ti of t.transfer_items ?? []) {
          if (ti.sku_id == null) continue;
          returnedBySku.set(ti.sku_id, (returnedBySku.get(ti.sku_id) ?? 0) + Number(ti.qty_shipped ?? 0));
        }
      }
      const allocMap = new Map<number, number>();
      const remaining = new Map(returnedBySku);
      for (const it of list) {
        const skuId = it.sku?.id;
        if (skuId == null) { allocMap.set(it.id, 0); continue; }
        const rem = remaining.get(skuId) ?? 0;
        const alloc = Math.min(Number(it.qty), rem);
        allocMap.set(it.id, alloc);
        remaining.set(skuId, rem - alloc);
      }
      setReturnedByItem(allocMap);

      setItems(list);
      // 預設勾選 + 全取：只含「扣掉已退後仍有可取量」的品項
      const pickableQty = (it: PickableItem) => Math.max(0, Number(it.qty) - (allocMap.get(it.id) ?? 0));
      setPicked(new Set(list.filter((it) => pickableQty(it) > 0).map((it) => it.id)));
      setPickQty(new Map(list.map((it) => [it.id, String(pickableQty(it))])));
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
            const itemSubtotal = list.reduce((s, it) => s + lineSubQty(it, pickableQty(it)), 0);
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

  // 該品項已退回總倉量 / 仍可取量（= 訂購量 − 已退量）
  function returnedOf(it: PickableItem): number {
    return returnedByItem.get(it.id) ?? 0;
  }
  function pickableOf(it: PickableItem): number {
    return Math.max(0, Number(it.qty) - returnedOf(it));
  }

  // 取得某 item 本次有效取貨數量（clamp 到 1..可取量；空字串/非法 → 全取可取量）
  function effQty(it: PickableItem): number {
    const cap = pickableOf(it);
    const raw = pickQty.get(it.id);
    const n = Number(raw);
    if (raw === "" || raw == null || !Number.isFinite(n) || n <= 0) return cap;
    return Math.min(cap, Math.max(1, n));
  }
  function setQty(id: number, value: string) {
    setPickQty((m) => {
      const next = new Map(m);
      next.set(id, value);
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
      printViaIframe(withBasePath(`/pickup/print-list?${params.toString()}`));
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

      // Step 2：寫 pickup。只帶「部分取」的數量；整取的省略 → 後端視為整行取
      const itemQtys: Record<string, number> = {};
      if (items) {
        for (const it of items) {
          if (!picked.has(it.id)) continue;
          const take = effQty(it);
          if (take < Number(it.qty)) itemQtys[String(it.id)] = take;
        }
      }
      const hasPartial = Object.keys(itemQtys).length > 0;
      const { data, error } = await sb.rpc("rpc_record_pickup", {
        p_order_id: orderId,
        p_item_ids: Array.from(picked),
        p_operator: operator,
        p_notes: notes || null,
        ...(hasPartial ? { p_item_qtys: itemQtys } : {}),
      });
      if (error) { setErr(error.message); return; }
      const result = data as { event_id: number; new_order_status: string; picked_count: number; active_remaining: number };
      // 取貨單一定印（收據）— 隱藏 iframe,不跳新分頁
      printViaIframe(withBasePath(`/pickup/print?event_ids=${result.event_id}`));
      // 取貨清單只在「部分取貨」時印（提醒客人剩下未取的 items）；全取完省略
      if (result.active_remaining > 0) {
        printViaIframe(withBasePath(`/pickup/print-list?order_ids=${orderId}`));
      }
      onPickedUp(result);
    } finally {
      setBusy(false);
    }
  }

  const subtotal = items
    ? items.filter((it) => picked.has(it.id)).reduce((s, it) => s + lineSubQty(it, effQty(it)), 0)
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
          {!items.some((it) => pickableOf(it) > 0) && (
            <div className="rounded-md border border-orange-200 bg-orange-50 p-3 text-sm text-orange-800 dark:border-orange-900 dark:bg-orange-950/40 dark:text-orange-300">
              ↩ 本訂單商品已全數退回總倉，無可取貨項目。
            </div>
          )}
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
                  const returned = returnedOf(it);
                  const pickable = pickableOf(it);
                  const fullyReturned = pickable <= 0;
                  const take = effQty(it);
                  const sub = lineSubQty(it, take);
                  const partial = take < pickable;
                  const isPicked = picked.has(it.id);
                  const hasLineDisc = Number(it.discount_amount ?? 0) > 0 || Number(it.discount_percent ?? 0) > 0;
                  return (
                    <tr key={it.id} className={fullyReturned ? "opacity-50" : isPicked ? "bg-emerald-50 dark:bg-emerald-950" : ""}>
                      <td className="px-3 py-2">
                        <input
                          type="checkbox"
                          checked={isPicked}
                          onChange={() => toggle(it.id)}
                          disabled={fullyReturned}
                          className="h-4 w-4 disabled:opacity-40"
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
                        {returned > 0 && (
                          <span className="ml-2 rounded bg-orange-100 px-1.5 py-0.5 text-[10px] font-medium text-orange-800 dark:bg-orange-950 dark:text-orange-300">
                            ↩ 已退 {returned}
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right">
                        <div className="flex items-center justify-end gap-1">
                          <input
                            type="number"
                            min={1}
                            max={pickable}
                            step="1"
                            value={pickQty.get(it.id) ?? String(pickable)}
                            onChange={(e) => setQty(it.id, e.target.value)}
                            disabled={!isPicked || fullyReturned}
                            className="w-14 rounded-md border border-zinc-300 px-2 py-1 text-right font-mono text-sm disabled:opacity-40 dark:border-zinc-700 dark:bg-zinc-800"
                          />
                          <span className="font-mono text-[10px] text-zinc-400">/{pickable}</span>
                        </div>
                        {partial && isPicked && !fullyReturned && (
                          <div className="mt-0.5 text-[10px] text-amber-600 dark:text-amber-400">剩 {pickable - take} 留待下次</div>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right font-mono text-zinc-500">${Number(it.unit_price)}</td>
                      <td className="px-3 py-2 text-right font-mono">${sub}</td>
                      <td className="px-3 py-2 text-xs text-zinc-500">
                        {fullyReturned
                          ? <span className="rounded bg-orange-100 px-1.5 py-0.5 font-medium text-orange-800 dark:bg-orange-950 dark:text-orange-300">已退貨・不能取貨</span>
                          : it.status}
                      </td>
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
