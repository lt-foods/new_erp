"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

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
  campaign: { id: number; name: string } | null;
  store: { id: number; name: string } | null;
  items: {
    id: number;
    qty: number;
    unit_price: number;
    discount_amount: number;
    discount_percent: number;
    notes: string | null;
    status: string;
    sku: { variant_name: string | null; product_name: string | null } | null;
  }[];
};

function lineGross(it: { qty: number; unit_price: number }): number {
  return Number(it.qty) * Number(it.unit_price);
}
function lineSub(it: { qty: number; unit_price: number; discount_amount: number; discount_percent: number }): number {
  const gross = Number(it.qty) * Number(it.unit_price);
  const afterPct = gross * (1 - Number(it.discount_percent ?? 0) / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - Number(it.discount_amount ?? 0));
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
  const idsParam = useSearchParams().get("order_ids");
  const ids = idsParam ? idsParam.split(",").map(Number).filter(Boolean) : [];
  const [orders, setOrders] = useState<Order[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (ids.length === 0) {
      setError("缺 order_ids 參數");
      return;
    }
    (async () => {
      const sb = getSupabase();
      const { data, error: e } = await sb
        .from("customer_orders")
        .select(
          `id, order_no, status, discount_amount, discount_percent, wallet_paid_amount, payment_status, notes,
           member:members(id, member_no, name, phone),
           campaign:group_buy_campaigns(id, name),
           store:stores!customer_orders_pickup_store_id_fkey(id, name),
           items:customer_order_items(id, qty, unit_price, discount_amount, discount_percent, notes, status, sku:skus(variant_name, product_name))`,
        )
        .in("id", ids);
      if (cancelled) return;
      if (e) {
        setError(e.message);
        return;
      }
      setOrders((data ?? []) as unknown as Order[]);
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
  const orderSub = (o: Order) => {
    const active = o.items.filter((it) => ACTIVE_ITEM_STATUSES.has(it.status));
    return active.reduce((a, it) => a + lineSub(it), 0);
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
  const grandWalletPaid = orders.reduce((s, o) => s + Number(o.wallet_paid_amount ?? 0), 0);
  const grandBalanceDue = Math.max(0, grandTotal - grandWalletPaid);
  const totalQty = orders.reduce((s, o) => {
    const active = o.items.filter((it) => ACTIVE_ITEM_STATUSES.has(it.status));
    return s + active.reduce((a, it) => a + Number(it.qty), 0);
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
      <div className="mx-auto my-4 max-w-[80mm] bg-white p-3 font-mono text-[12px] leading-tight text-black shadow print:my-0 print:shadow-none">
        <div className="no-print mb-3 flex justify-end gap-2">
          <button
            onClick={() => window.print()}
            className="rounded bg-zinc-900 px-3 py-1 text-xs text-white"
          >
            🖨️ 列印
          </button>
          <button
            onClick={() => window.close()}
            className="rounded border border-zinc-300 px-3 py-1 text-xs"
          >
            關閉
          </button>
        </div>

        <div className="text-center">
          <div className="text-[16px] font-bold">取貨清單</div>
          <div className="text-[10px] text-zinc-500">picking list (待確認)</div>
        </div>

        <div className="mt-2 border-y border-dashed border-black py-1.5">
          <div className="font-bold">{member?.name ?? "—"}</div>
          <div className="text-[11px]">
            {member?.member_no}
            {member?.phone && <span className="ml-2">{member.phone}</span>}
          </div>
          {store && <div className="text-[11px]">取貨店：{store.name}</div>}
          <div className="text-[10px] text-zinc-500">
            {new Date().toLocaleString("zh-TW", { hour12: false })}
          </div>
        </div>

        <div className="mt-2 space-y-2">
          {orders.map((o) => {
            const active = o.items.filter((it) => ACTIVE_ITEM_STATUSES.has(it.status));
            const disc = Number(o.discount_amount ?? 0);
            const pct = Number(o.discount_percent ?? 0);
            const sub = orderSub(o);
            const pay = orderPay(o);
            // pctDed 倒推（subtotal − pct − amt = payable，所以 pctDed = subtotal − payable − amt）
            const pctDed = Math.max(0, sub - pay - disc);
            return (
              <div key={o.id} className="border-b border-dashed border-zinc-400 pb-1">
                <div>{o.campaign?.name ?? "(未知活動)"}</div>
                {o.notes && (
                  <div className="text-[10px] italic">📝 {o.notes}</div>
                )}
                {active.map((it) => {
                  const subtotal = lineSub(it);
                  const gross = lineGross(it);
                  const discounted = hasLineDisc(it);
                  return (
                    <div key={it.id}>
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="min-w-0 flex-1 break-words font-bold">
                          {it.sku?.variant_name || it.sku?.product_name || "—"}
                        </span>
                        <span className="whitespace-nowrap">
                          × {Number(it.qty)}
                          {discounted ? (
                            <>
                              <span className="ml-1.5 text-[10px] line-through">${gross}</span>
                              <span className="ml-1 text-[11px] font-bold">${subtotal}</span>
                            </>
                          ) : (
                            <span className="ml-1.5 text-[11px]">${subtotal}</span>
                          )}
                        </span>
                      </div>
                      {discounted && (
                        <div className="pl-2 text-[10px] font-bold text-red-700">
                          ↳ 折扣 {Number(it.discount_percent ?? 0) > 0
                            ? `${it.discount_percent}% (= -$${Math.round(gross * Number(it.discount_percent)) / 100})`
                            : `-$${it.discount_amount}`}
                        </div>
                      )}
                      {it.notes && (
                        <div className="pl-2 text-[10px] italic">↳ 備註：{it.notes}</div>
                      )}
                    </div>
                  );
                })}
                {pct > 0 && (
                  <div className="text-right text-[11px]">
                    <span className="text-zinc-600">本單{pct}%折扣 </span>
                    <span>−${pctDed}</span>
                  </div>
                )}
                {disc > 0 && (
                  <div className="text-right text-[11px]">
                    <span className="text-zinc-600">本單折扣金額 </span>
                    <span>−${disc}</span>
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <div className="mt-2 border-t-2 border-black pt-1.5 text-right text-[12px]">
          <div>小計 $ {grandSubtotal.toLocaleString()}</div>
          {totalOrderDisc > 0 && <div>− 整單折扣 $ {totalOrderDisc.toLocaleString()}</div>}
          <div className="text-[14px] font-bold">合計 {totalQty} 項　$ {grandTotal.toLocaleString()}</div>
          {grandWalletPaid > 0 && (
            <>
              <div className="mt-1">− 已用儲值金 $ {grandWalletPaid.toLocaleString()}</div>
              <div className="text-[13px] font-bold">
                {grandBalanceDue === 0
                  ? "✅ 已付清"
                  : <>應付剩餘 $ {grandBalanceDue.toLocaleString()}</>}
              </div>
            </>
          )}
        </div>

      </div>
    </>
  );
}
