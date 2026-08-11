"use client";

// 已取品項自訂清單（80mm 熱感）—— 跟 /pickup/print（依「取貨當次」印當時那張收據）不同，
// 這頁是「從客人歷史取過的品項裡挑出來的那一堆」：可跨訂單、跨取貨次數，只印勾到的品項。
// 例：客人這次要對帳的是 A、B、D 三項（C 不在這批），就只印這三項。
//
// 版型與計價刻意對齊 /pickup/print-list（同一支出單機、同一組店員在看），
// 差別只在資料來源是 item_ids、且列的是「已取走」的品項。

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { stripTransferNotes } from "@/lib/orderNotes";
import { itemDisplayName } from "@/lib/skuLabel";
import SpinButton from "@/components/SpinButton";

type Item = {
  id: number;
  order_id: number;
  qty: number;
  unit_price: number;
  discount_amount: number;
  discount_percent: number;
  status: string;
  notes: string | null;
  sku: { product_name: string | null; variant_name: string | null } | null;
};

type Order = {
  id: number;
  order_no: string;
  discount_amount: number;
  discount_percent: number;
  notes: string | null;
  member: { id: number; member_no: string; name: string | null; phone: string | null } | null;
  campaign: { id: number; name: string } | null;
  store: { id: number; name: string } | null;
};

function lineGross(it: Item): number {
  return Number(it.qty) * Number(it.unit_price);
}
// 與 print-list.lineSub 同構（先套百分比再扣定額）
function lineSub(it: Item): number {
  const afterPct = lineGross(it) * (1 - Number(it.discount_percent ?? 0) / 100);
  return Math.max(0, Math.round(afterPct * 10000) / 10000 - Number(it.discount_amount ?? 0));
}
function hasLineDisc(it: Item): boolean {
  return Number(it.discount_amount ?? 0) > 0 || Number(it.discount_percent ?? 0) > 0;
}

export default function PickupPrintPickedPage() {
  return (
    <Suspense fallback={<div className="p-4 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const idsParam = useSearchParams().get("item_ids");
  const ids = idsParam ? idsParam.split(",").map(Number).filter(Boolean) : [];
  const [data, setData] = useState<{ items: Item[]; orders: Map<number, Order> } | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (ids.length === 0) { setError("缺 item_ids 參數"); return; }
    (async () => {
      const sb = getSupabase();
      const { data: itms, error: e1 } = await sb
        .from("customer_order_items")
        .select("id, order_id, qty, unit_price, discount_amount, discount_percent, status, notes, sku:skus(product_name, variant_name)")
        .in("id", ids)
        .order("id", { ascending: true });
      if (cancelled) return;
      if (e1) { setError(e1.message); return; }
      const items = (itms ?? []) as unknown as Item[];
      if (items.length === 0) { setError("找不到對應品項"); return; }

      const orderIds = Array.from(new Set(items.map((it) => it.order_id)));
      const { data: ords, error: e2 } = await sb
        .from("customer_orders")
        .select("id, order_no, discount_amount, discount_percent, notes, member:members(id, member_no, name, phone), campaign:group_buy_campaigns(id, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
        .in("id", orderIds);
      if (cancelled) return;
      if (e2) { setError(e2.message); return; }
      const orders = new Map<number, Order>();
      for (const o of (ords ?? []) as unknown as Order[]) orders.set(o.id, o);
      setData({ items, orders });
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [idsParam]);

  // 自動跳列印（與其它列印頁一致，printViaIframe 靠這個觸發）
  useEffect(() => {
    if (data && data.items.length > 0) {
      const t = setTimeout(() => window.print(), 500);
      return () => clearTimeout(t);
    }
  }, [data]);

  if (error) return <div className="p-4 text-sm text-red-700">{error}</div>;
  if (!data) return <div className="p-4 text-sm text-zinc-500">載入中…</div>;

  const { items, orders } = data;
  const first = orders.get(items[0].order_id);
  const member = first?.member;
  const store = first?.store;

  // 依訂單分段（同一張單的品項印在一起），段落順序＝品項 id 由小到大＝加單順序
  const byOrder: { order: Order | undefined; items: Item[] }[] = [];
  for (const it of items) {
    const last = byOrder[byOrder.length - 1];
    if (last && last.items[0].order_id === it.order_id) last.items.push(it);
    else byOrder.push({ order: orders.get(it.order_id), items: [it] });
  }

  const total = items.reduce((s, it) => s + lineSub(it), 0);
  const totalQty = items.reduce((s, it) => s + Number(it.qty), 0);
  // 整單折扣是「單頭層級」的，只挑部分品項時攤下去會失真 —— 一律不計入，改在單子上註明。
  const orderDiscounted = Array.from(new Set(items.map((it) => it.order_id)))
    .map((id) => orders.get(id))
    .some((o) => Number(o?.discount_amount ?? 0) > 0 || Number(o?.discount_percent ?? 0) > 0);

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
          <SpinButton onClick={() => window.print()} className="rounded bg-zinc-900 px-3 py-1 text-xs text-white">
            🖨️ 列印
          </SpinButton>
          <SpinButton onClick={() => window.close()} className="rounded border border-zinc-300 px-3 py-1 text-xs">
            關閉
          </SpinButton>
        </div>

        <div className="text-center">
          <div className="text-[22px] font-bold">取貨明細</div>
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
          {byOrder.map((grp, gi) => {
            const orderNotes = stripTransferNotes(grp.order?.notes ?? null);
            return (
              <div key={gi} className="border-b border-dashed border-zinc-400 pb-1">
                <div className="text-[13px]">{grp.order?.campaign?.name ?? "(未知活動)"}</div>
                {orderNotes && <div className="text-[13px] italic">📝 {orderNotes}</div>}
                {grp.items.map((it) => (
                  <div key={it.id}>
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="min-w-0 flex-1 break-words text-[16px] font-bold">
                        {itemDisplayName(it.sku, grp.order?.campaign?.name)}
                      </span>
                      <span className="whitespace-nowrap text-[15px]">
                        × {Number(it.qty)}
                        {hasLineDisc(it) ? (
                          <>
                            <span className="ml-1 line-through text-zinc-500">${lineGross(it)}</span>
                            <span className="ml-1 font-bold">${Math.round(lineSub(it))}</span>
                          </>
                        ) : (
                          <span className="ml-1">${Math.round(lineSub(it))}</span>
                        )}
                      </span>
                    </div>
                    {it.notes && <div className="text-[12px] italic text-zinc-600">・{it.notes}</div>}
                  </div>
                ))}
              </div>
            );
          })}
        </div>

        <div className="mt-2 border-t border-dashed border-black pt-1.5 text-[15px]">
          <div className="flex justify-between">
            <span>品項</span>
            <span>{items.length} 項 / {totalQty} 件</span>
          </div>
          <div className="mt-1 flex items-baseline justify-between text-[18px] font-bold">
            <span>合計</span>
            <span>${Math.round(total)}</span>
          </div>
          {orderDiscounted && (
            <div className="mt-1 text-[12px] text-zinc-600">
              ＊此清單只計品項金額，未含訂單整單折扣
            </div>
          )}
        </div>

        <div className="mt-2 text-center text-[12px] text-zinc-500">— 已取品項明細（非取貨收據）—</div>
      </div>
    </>
  );
}
