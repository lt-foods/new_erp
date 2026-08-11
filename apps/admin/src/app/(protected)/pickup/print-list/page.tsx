"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { stripTransferNotes } from "@/lib/orderNotes";
import { parseReturnNote } from "@/lib/returnNote";
import { itemDisplayName } from "@/lib/skuLabel";
import SpinButton from "@/components/SpinButton";
import { CutoffText } from "@/components/CampaignCutoff";

type Order = {
  id: number;
  order_no: string;
  status: string;
  discount_amount: number;
  discount_percent: number;
  wallet_paid_amount: number;
  payment_status: string | null;
  notes: string | null;
  member: { id: number; member_no: string; name: string | null; phone: string | null } | null;
  campaign: { id: number; name: string; cutoff_date: string | null } | null;
  store: { id: number; name: string } | null;
  items: {
    id: number;
    sku_id: number;
    qty: number;
    unit_price: number;
    discount_amount: number;
    discount_percent: number;
    notes: string | null;
    status: string;
    sku: { variant_name: string | null; product_name: string | null } | null;
  }[];
};

function lineGross(it: { unit_price: number }, qty: number): number {
  return qty * Number(it.unit_price);
}
// 以指定數量計算小計（line-level 折扣金額按比例分攤，對齊 PickupDialog.lineSubQty）
function lineSub(
  it: { qty: number; unit_price: number; discount_amount: number; discount_percent: number },
  qty: number,
): number {
  const fullQty = Number(it.qty) || 0;
  const ratio = fullQty > 0 ? qty / fullQty : 0;
  const gross = qty * Number(it.unit_price);
  const afterPct = gross * (1 - Number(it.discount_percent ?? 0) / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - Number(it.discount_amount ?? 0) * ratio);
}
function hasLineDisc(it: { discount_amount: number; discount_percent: number }): boolean {
  return Number(it.discount_amount ?? 0) > 0 || Number(it.discount_percent ?? 0) > 0;
}

const ACTIVE_ITEM_STATUSES = new Set(["pending", "reserved", "ready"]);

export default function PickupPrintListPage() {
  return (
    <Suspense fallback={<div className="p-4 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const idsParam = sp.get("order_ids");
  const ids = idsParam ? idsParam.split(",").map(Number).filter(Boolean) : [];
  // 由 PickupDialog 「列印小白單」帶入：本次「即將」扣的儲值金（尚未寫 DB,只在這張單上顯示）
  const walletPreview = Math.max(0, Number(sp.get("wallet_preview") ?? 0)) || 0;
  const [orders, setOrders] = useState<Order[] | null>(null);
  // order_id → (item_id → 已退量)。未取退貨（非「取貨後退回」）依 SKU 聚合後
  // 分攤到 active 品項行 — 退掉的貨不能取也不收錢（對齊 PickupDialog / v_customer_order_summary）
  const [returnedByItem, setReturnedByItem] = useState<Map<number, Map<number, number>>>(new Map());
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (ids.length === 0) {
      setError("缺 order_ids 參數");
      return;
    }
    (async () => {
      const sb = getSupabase();
      const [oRes, rRes] = await Promise.all([
        sb.from("customer_orders")
          .select(
            `id, order_no, status, discount_amount, discount_percent, wallet_paid_amount, payment_status, notes,
             member:members(id, member_no, name, phone),
             campaign:group_buy_campaigns(id, name, cutoff_date),
             store:stores!customer_orders_pickup_store_id_fkey(id, name),
             items:customer_order_items(id, sku_id, qty, unit_price, discount_amount, discount_percent, notes, status, sku:skus(variant_name, product_name))`,
          )
          .in("id", ids),
        sb.from("transfers")
          .select("customer_order_id, notes, transfer_items(sku_id, qty_shipped)")
          .in("customer_order_id", ids)
          .eq("transfer_type", "return_to_hq")
          .in("status", ["shipped", "received"]),
      ]);
      if (cancelled) return;
      if (oRes.error) {
        setError(oRes.error.message);
        return;
      }
      const orderList = (oRes.data ?? []) as unknown as Order[];

      // 未取退貨量：order → SKU 聚合（「取貨後退回」是已取走的貨，不佔未取額度）
      const returnedBySku = new Map<number, Map<number, number>>();
      type RetRow = { customer_order_id: number; notes: string | null; transfer_items: { sku_id: number; qty_shipped: number | null }[] | null };
      for (const t of (rRes.data ?? []) as RetRow[]) {
        if (parseReturnNote(t.notes).isRestock) continue;
        const m = returnedBySku.get(t.customer_order_id) ?? new Map<number, number>();
        for (const ti of t.transfer_items ?? []) {
          if (ti.sku_id == null) continue;
          m.set(ti.sku_id, (m.get(ti.sku_id) ?? 0) + Number(ti.qty_shipped ?? 0));
        }
        returnedBySku.set(t.customer_order_id, m);
      }
      // 分攤到各 active 品項行（依 id 排序，分攤穩定 — 對齊 PickupDialog）
      const alloc = new Map<number, Map<number, number>>();
      for (const o of orderList) {
        const remaining = new Map(returnedBySku.get(o.id) ?? []);
        const m = new Map<number, number>();
        const active = o.items
          .filter((it) => ACTIVE_ITEM_STATUSES.has(it.status))
          .sort((a, b) => a.id - b.id);
        for (const it of active) {
          const rem = remaining.get(it.sku_id) ?? 0;
          if (rem <= 0) continue;
          const a = Math.min(Number(it.qty), rem);
          m.set(it.id, a);
          remaining.set(it.sku_id, rem - a);
        }
        alloc.set(o.id, m);
      }
      setReturnedByItem(alloc);
      setOrders(orderList);
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [idsParam]);

  // 載入完自動觸發列印
  useEffect(() => {
    if (orders && orders.length > 0) {
      const t = setTimeout(() => window.print(), 400);
      return () => clearTimeout(t);
    }
  }, [orders]);

  if (error) return <div className="p-4 text-sm text-red-700">{error}</div>;
  if (!orders) return <div className="p-4 text-sm text-zinc-500">載入中…</div>;
  if (orders.length === 0) return <div className="p-4 text-sm text-zinc-500">無訂單</div>;

  // 假設 bulkConfirm 進來都是同一個會員
  const member = orders[0]?.member;
  const store = orders[0]?.store;
  // 該行已退量 / 實際可取量（= 訂購量 − 未取退貨量）— 小白單只列、只收「取得到的貨」
  const returnedOf = (o: Order, itemId: number) => returnedByItem.get(o.id)?.get(itemId) ?? 0;
  const effQty = (o: Order, it: Order["items"][number]) => Math.max(0, Number(it.qty) - returnedOf(o, it.id));
  const activeOf = (o: Order) =>
    o.items.filter((it) => ACTIVE_ITEM_STATUSES.has(it.status)).sort((a, b) => a.id - b.id);
  const orderSub = (o: Order) => {
    return activeOf(o).reduce((a, it) => a + lineSub(it, effQty(o, it)), 0);
  };
  // payable 四捨五入到整數 NTD（對齊 v_customer_order_summary）
  const orderPay = (o: Order) => {
    const sub = orderSub(o);
    const pct = Number(o.discount_percent ?? 0);
    return Math.max(0, Math.round(sub * (1 - pct / 100) - Number(o.discount_amount ?? 0)));
  };
  const grandSubtotal = orders.reduce((s, o) => s + orderSub(o), 0);
  const grandTotal = orders.reduce((s, o) => s + orderPay(o), 0);
  const totalOrderDisc = grandSubtotal - grandTotal; // 倒推、含取整誤差
  const grandWalletPaidDb = orders.reduce((s, o) => s + Number(o.wallet_paid_amount ?? 0), 0);
  // preview 僅在單張訂單時套用（避免多單時不確定分到哪張）；多單時忽略
  const previewable = orders.length === 1 ? walletPreview : 0;
  // 「將扣」金額 cap 在剩餘應付，避免 preview 過大導致負數
  const previewCapped = Math.min(previewable, Math.max(0, grandTotal - grandWalletPaidDb));
  const grandWalletPaid = grandWalletPaidDb + previewCapped;
  const grandBalanceDue = Math.max(0, grandTotal - grandWalletPaid);
  const totalQty = orders.reduce((s, o) => {
    return s + activeOf(o).reduce((a, it) => a + effQty(o, it), 0);
  }, 0);

  return (
    <>
      <style jsx global>{`
        @media print {
          @page { margin: 3mm; size: 80mm auto; }
          body { background: white !important; }
          .no-print { display: none !important; }
        }
        body { background: #f0f0f0; }
      `}</style>
      <div className="mx-auto my-4 max-w-[80mm] bg-white p-3 font-mono text-[14px] leading-tight text-black shadow print:my-0 print:shadow-none">
        <div className="no-print mb-3 flex justify-end gap-2">
          <SpinButton
            onClick={() => window.print()}
            className="rounded bg-zinc-900 px-3 py-1 text-xs text-white"
          >
            🖨️ 列印
          </SpinButton>
          <SpinButton
            onClick={() => window.close()}
            className="rounded border border-zinc-300 px-3 py-1 text-xs"
          >
            關閉
          </SpinButton>
        </div>

        <div className="text-center">
          <div className="text-[22px] font-bold">取貨清單</div>
        </div>

        <div className="mt-2 border-y border-dashed border-black py-1.5">
          <div className="text-[18px] font-bold">{member?.name ?? "—"}</div>
          <div className="text-[13px]">
            {member?.member_no}
            {member?.phone && <span className="ml-2">{member.phone}</span>}
          </div>
          {store && <div className="text-[13px]">取貨店：{store.name}</div>}
          <div className="text-[12px] text-zinc-500">
            {new Date().toLocaleString("zh-TW", { hour12: false })}
          </div>
        </div>

        <div className="mt-2 space-y-2">
          {orders.map((o) => {
            const active = activeOf(o);
            const disc = Number(o.discount_amount ?? 0);
            const pct = Number(o.discount_percent ?? 0);
            const sub = orderSub(o);
            const pay = orderPay(o);
            // pctDed 倒推（subtotal − pct − amt = payable，所以 pctDed = subtotal − payable − amt）
            const pctDed = Math.max(0, sub - pay - disc);
            const orderNotes = stripTransferNotes(o.notes);
            return (
              <div key={o.id} className="border-b border-dashed border-zinc-400 pb-1">
                <div className="text-[13px]">
                  {o.campaign?.name ?? "(未知活動)"}
                  <CutoffText date={o.campaign?.cutoff_date} />
                </div>
                {orderNotes && (
                  <div className="text-[13px] italic">📝 {orderNotes}</div>
                )}
                {active.map((it) => {
                  const returned = returnedOf(o, it.id);
                  const qty = effQty(o, it);
                  const subtotal = lineSub(it, qty);
                  const gross = lineGross(it, qty);
                  const discounted = hasLineDisc(it);
                  return (
                    <div key={it.id}>
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="min-w-0 flex-1 break-words text-[16px] font-bold">
                          {itemDisplayName(it.sku, o.campaign?.name)}
                        </span>
                        <span className="whitespace-nowrap text-[15px]">
                          × {qty}
                          {discounted ? (
                            <>
                              <span className="ml-1.5 text-[13px] line-through">${gross}</span>
                              <span className="ml-1 text-[15px] font-bold">${subtotal}</span>
                            </>
                          ) : (
                            <span className="ml-1.5 text-[15px]">${subtotal}</span>
                          )}
                        </span>
                      </div>
                      {returned > 0 && (
                        <div className="pl-2 text-[13px] font-bold">↳ ↩ 已退貨 {returned} 件（不收費）</div>
                      )}
                      {discounted && (
                        <div className="pl-2 text-[13px] font-bold text-red-700">
                          ↳ 折扣 {Number(it.discount_percent ?? 0) > 0
                            ? `${it.discount_percent}% (= -$${Math.round(gross * Number(it.discount_percent)) / 100})`
                            : `-$${it.discount_amount}`}
                        </div>
                      )}
                      {it.notes && (
                        <div className="pl-2 text-[13px] italic">↳ 備註：{it.notes}</div>
                      )}
                    </div>
                  );
                })}
                {pct > 0 && (
                  <div className="text-right text-[13px]">
                    <span className="text-zinc-600">本單{pct}%折扣 </span>
                    <span>−${pctDed}</span>
                  </div>
                )}
                {disc > 0 && (
                  <div className="text-right text-[13px]">
                    <span className="text-zinc-600">本單折扣金額 </span>
                    <span>−${disc}</span>
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-2 border-t-2 border-black pt-1.5 text-right text-[14px]">
          <div>小計 $ {grandSubtotal.toLocaleString()}</div>
          {totalOrderDisc > 0 && <div>− 整單折扣 $ {totalOrderDisc.toLocaleString()}</div>}
          <div className="text-[20px] font-bold">合計 {totalQty} 項　$ {grandTotal.toLocaleString()}</div>
          {grandWalletPaidDb > 0 && (
            <div className="mt-1">− 已用儲值金 $ {grandWalletPaidDb.toLocaleString()}</div>
          )}
          {previewCapped > 0 && (
            <div>− 本次抵扣儲值金 $ {previewCapped.toLocaleString()}</div>
          )}
          {grandWalletPaid > 0 && (
            <div className="text-[17px] font-bold">
              {grandBalanceDue === 0
                ? "✅ 已付清"
                : <>應收現金 $ {grandBalanceDue.toLocaleString()}</>}
            </div>
          )}
        </div>

      </div>
    </>
  );
}
