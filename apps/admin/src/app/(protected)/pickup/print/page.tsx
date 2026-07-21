"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { stripTransferNotes } from "@/lib/orderNotes";
import SpinButton from "@/components/SpinButton";

type PickupEvent = {
  id: number;
  order_id: number;
  pickup_store_id: number;
  event_type: string;
  item_ids: number[];
  notes: string | null;
  created_at: string;
};

type Order = {
  id: number;
  order_no: string;
  status: string;
  pickup_store_id: number | null;
  discount_amount: number;
  discount_percent: number;
  wallet_paid_amount: number;
  payment_status: string | null;
  notes: string | null;
  member: { id: number; member_no: string; name: string | null; phone: string | null } | null;
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
};

type Item = {
  id: number;
  qty: number;
  unit_price: number;
  discount_amount: number;
  discount_percent: number;
  notes: string | null;
  status: string;
  sku: { sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

function lineGross(it: Item): number {
  return Number(it.qty) * Number(it.unit_price);
}
function lineSub(it: Item): number {
  const gross = lineGross(it);
  const afterPct = gross * (1 - Number(it.discount_percent ?? 0) / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - Number(it.discount_amount ?? 0));
}
function hasLineDisc(it: Item): boolean {
  return Number(it.discount_amount ?? 0) > 0 || Number(it.discount_percent ?? 0) > 0;
}

export default function PickupPrintPage() {
  return (
    <Suspense fallback={<div className="p-4 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const eventIds = useSearchParams().get("event_ids");
  const ids = eventIds ? eventIds.split(",").map(Number).filter(Boolean) : [];
  const [receipts, setReceipts] = useState<{ event: PickupEvent; order: Order; items: Item[] }[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (ids.length === 0) { setError("缺 event_ids 參數"); return; }
    (async () => {
      const sb = getSupabase();
      const { data: evts, error: e1 } = await sb
        .from("order_pickup_events")
        .select("id, order_id, pickup_store_id, event_type, item_ids, notes, created_at")
        .in("id", ids);
      if (cancelled) return;
      if (e1) { setError(e1.message); return; }
      const events = (evts ?? []) as unknown as PickupEvent[];
      if (events.length === 0) { setError("找不到對應取貨記錄"); return; }

      const orderIds = Array.from(new Set(events.map((e) => e.order_id)));
      const allItemIds = events.flatMap((e) => e.item_ids ?? []);
      const [{ data: ords }, { data: itms }] = await Promise.all([
        sb.from("customer_orders")
          .select("id, order_no, status, pickup_store_id, discount_amount, discount_percent, wallet_paid_amount, payment_status, notes, member:members(id, member_no, name, phone), campaign:group_buy_campaigns(id, campaign_no, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
          .in("id", orderIds),
        allItemIds.length > 0
          ? sb.from("customer_order_items").select("id, qty, unit_price, discount_amount, discount_percent, notes, status, sku:skus(sku_code, product_name, variant_name)").in("id", allItemIds)
          : Promise.resolve({ data: [] }),
      ]);
      const ordMap = new Map<number, Order>();
      for (const o of (ords ?? []) as unknown as Order[]) ordMap.set(o.id, o);
      const itemMap = new Map<number, Item>();
      for (const i of (itms ?? []) as unknown as Item[]) itemMap.set(i.id, i);

      const result = events.map((ev) => ({
        event: ev,
        order: ordMap.get(ev.order_id) as Order,
        items: (ev.item_ids ?? []).map((id) => itemMap.get(id)).filter((x): x is Item => !!x),
      }));
      if (!cancelled) setReceipts(result);
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [eventIds]);

  // 自動跳列印
  useEffect(() => {
    if (receipts && receipts.length > 0) {
      const t = setTimeout(() => window.print(), 500);
      return () => clearTimeout(t);
    }
  }, [receipts]);

  if (error) return <div className="p-4 text-sm text-red-700">{error}</div>;
  if (!receipts) return <div className="p-4 text-sm text-zinc-500">載入中…</div>;
  if (receipts.length === 0) return <div className="p-4 text-sm text-zinc-500">無取貨記錄</div>;

  // 80mm 小白單版型（對齊「取貨清單」）—— 同一會員的多張訂單共用 1 個表頭
  const member = receipts[0]?.order?.member;
  const store = receipts[0]?.order?.store;
  const headerEvent = receipts[0]?.event;

  const orderSub = (r: { items: Item[] }) => r.items.reduce((a, it) => a + lineSub(it), 0);
  // payable 四捨五入到整數 NTD
  const orderPay = (r: { order: Order; items: Item[] }) => {
    const sub = orderSub(r);
    const pct = Number(r.order?.discount_percent ?? 0);
    return Math.max(0, Math.round(sub * (1 - pct / 100) - Number(r.order?.discount_amount ?? 0)));
  };
  const grandSubtotal = receipts.reduce((s, r) => s + orderSub(r), 0);
  const grandTotal = receipts.reduce((s, r) => s + orderPay(r), 0);
  const totalOrderDisc = grandSubtotal - grandTotal; // 倒推、含取整誤差
  const grandWalletPaid = receipts.reduce((s, r) => s + Number(r.order?.wallet_paid_amount ?? 0), 0);
  const grandBalanceDue = Math.max(0, grandTotal - grandWalletPaid);
  const totalQty = receipts.reduce((s, r) => s + r.items.reduce((a, it) => a + Number(it.qty), 0), 0);

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
          <SpinButton onClick={() => window.print()} className="rounded bg-zinc-900 px-3 py-1 text-xs text-white">🖨️ 列印</SpinButton>
          <SpinButton onClick={() => window.close()} className="rounded border border-zinc-300 px-3 py-1 text-xs">關閉</SpinButton>
        </div>

        <div className="text-center">
          <div className="text-[22px] font-bold">取貨單</div>
          {headerEvent && (
            <div className="text-[12px] text-zinc-500">
              {headerEvent.event_type === "picked_up" ? "全部取貨" : "部分取貨"}
            </div>
          )}
        </div>

        <div className="mt-2 border-y border-dashed border-black py-1.5">
          <div className="text-[18px] font-bold">{member?.name ?? "—"}</div>
          <div className="text-[13px]">
            {member?.member_no}
            {member?.phone && <span className="ml-2">{member.phone}</span>}
          </div>
          {store && <div className="text-[13px]">取貨店：{store.name}</div>}
          <div className="text-[12px] text-zinc-500">
            {headerEvent ? new Date(headerEvent.created_at).toLocaleString("zh-TW", { hour12: false }) : ""}
          </div>
        </div>

        <div className="mt-2 space-y-2">
          {receipts.map((r) => {
            const disc = Number(r.order?.discount_amount ?? 0);
            const pct = Number(r.order?.discount_percent ?? 0);
            const sub = orderSub(r);
            const pay = orderPay(r);
            // pctDed 倒推（subtotal − pct − amt = payable，所以 pctDed = subtotal − payable − amt）
            const pctDed = Math.max(0, sub - pay - disc);
            const orderNotes = stripTransferNotes(r.order?.notes);
            return (
              <div key={r.event.id} className="border-b border-dashed border-zinc-400 pb-1">
                <div className="text-[13px]">{r.order?.campaign?.name ?? "(未知活動)"}</div>
                {orderNotes && (
                  <div className="text-[13px] italic">📝 {orderNotes}</div>
                )}
                {r.items.map((it) => {
                  const subtotal = lineSub(it);
                  const gross = lineGross(it);
                  const discounted = hasLineDisc(it);
                  return (
                    <div key={it.id}>
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="min-w-0 flex-1 break-words text-[16px] font-bold">
                          {it.sku?.variant_name || it.sku?.product_name || "—"}
                        </span>
                        <span className="whitespace-nowrap text-[15px]">
                          × {Number(it.qty)}
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
                {r.event.notes && (
                  <div className="text-[12px] text-zinc-500">取貨備註：{r.event.notes}</div>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-2 border-t-2 border-black pt-1.5 text-right text-[14px]">
          <div>小計 $ {grandSubtotal.toLocaleString()}</div>
          {totalOrderDisc > 0 && <div>− 整單折扣 $ {totalOrderDisc.toLocaleString()}</div>}
          <div className="text-[20px] font-bold">合計 {totalQty} 項　$ {grandTotal.toLocaleString()}</div>
          {grandWalletPaid > 0 && (
            <>
              <div className="mt-1">− 已用儲值金 $ {grandWalletPaid.toLocaleString()}</div>
              <div className="text-[17px] font-bold">
                {grandBalanceDue === 0
                  ? "✅ 已付清"
                  : <>應收現金 $ {grandBalanceDue.toLocaleString()}</>}
              </div>
            </>
          )}
        </div>
      </div>
    </>
  );
}
