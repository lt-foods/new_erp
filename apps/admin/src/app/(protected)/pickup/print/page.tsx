"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

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
  member: { id: number; member_no: string; name: string | null; phone: string | null } | null;
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
};

type Item = {
  id: number;
  qty: number;
  unit_price: number;
  status: string;
  sku: { sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

export default function PickupPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm">載入中…</div>}>
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
          .select("id, order_no, status, pickup_store_id, member:members(id, member_no, name, phone), campaign:group_buy_campaigns(id, campaign_no, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
          .in("id", orderIds),
        allItemIds.length > 0
          ? sb.from("customer_order_items").select("id, qty, unit_price, status, sku:skus(sku_code, product_name, variant_name)").in("id", allItemIds)
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

  if (error) return <div className="p-6 text-sm text-red-700">{error}</div>;
  if (!receipts) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  return (
    <>
      <style jsx global>{`
        @media print {
          @page { margin: 10mm; }
          body { background: white !important; }
          .no-print { display: none !important; }
          .receipt { page-break-inside: avoid; }
        }
      `}</style>
      <div className="mx-auto max-w-2xl p-6">
        <div className="no-print mb-4 flex justify-end gap-2">
          <button onClick={() => window.print()} className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white hover:bg-zinc-700">🖨️ 列印</button>
          <button onClick={() => window.close()} className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100">關閉</button>
        </div>
        {receipts.length > 1 && (
          <div className="mb-3 text-center">
            <h1 className="text-xl font-bold">取貨單（共 {receipts.length} 張）</h1>
          </div>
        )}
        {receipts.map((r, i) => (
          <div key={r.event.id} className={`receipt bg-white p-4 text-zinc-900 ${i < receipts.length - 1 ? "border-b-2 border-dashed border-zinc-400" : ""}`}>
            {receipts.length === 1 && (
              <div className="mb-3 text-center">
                <h1 className="text-xl font-bold">取貨單</h1>
                <div className="text-xs text-zinc-500">
                  {r.event.event_type === "picked_up" ? "全部取貨" : "部分取貨"}
                </div>
              </div>
            )}

            <div className="mb-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
              <Field label="訂單號" value={<span className="font-mono font-semibold">{r.order?.order_no ?? "—"}</span>} />
              <Field label="取貨時間" value={new Date(r.event.created_at).toLocaleString("zh-TW")} />
              <Field label="會員" value={r.order?.member ? `${r.order.member.name ?? "—"} (${r.order.member.member_no})` : "—"} />
              <Field label="電話" value={r.order?.member?.phone ?? "—"} />
              <Field label="取貨店" value={r.order?.store?.name ?? "—"} />
              <Field label="開團" value={r.order?.campaign ? `${r.order.campaign.campaign_no} ${r.order.campaign.name}` : "—"} />
            </div>

            <table className="mb-2 w-full border-collapse text-xs">
              <thead>
                <tr className="border-b-2 border-zinc-400">
                  <th className="px-2 py-1 text-left">商品</th>
                  <th className="px-2 py-1 text-right">數量</th>
                  <th className="px-2 py-1 text-right">單價</th>
                  <th className="px-2 py-1 text-right">小計</th>
                </tr>
              </thead>
              <tbody>
                {r.items.map((it) => {
                  const sub = Number(it.qty) * Number(it.unit_price);
                  return (
                    <tr key={it.id} className="border-b border-zinc-200">
                      <td className="px-2 py-1">
                        {it.sku?.variant_name ?? it.sku?.product_name ?? "—"}
                        {it.sku?.sku_code && <span className="ml-1 font-mono text-[10px] text-zinc-500">{it.sku.sku_code}</span>}
                      </td>
                      <td className="px-2 py-1 text-right font-mono">{Number(it.qty)}</td>
                      <td className="px-2 py-1 text-right font-mono">${Number(it.unit_price)}</td>
                      <td className="px-2 py-1 text-right font-mono">${sub}</td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot>
                <tr className="border-t-2 border-zinc-400 font-bold">
                  <td colSpan={3} className="px-2 py-2 text-right">合計</td>
                  <td className="px-2 py-2 text-right font-mono">
                    ${r.items.reduce((s, it) => s + Number(it.qty) * Number(it.unit_price), 0)}
                  </td>
                </tr>
              </tfoot>
            </table>

            {r.event.notes && (
              <div className="mb-2 text-xs text-zinc-600">備註：{r.event.notes}</div>
            )}
          </div>
        ))}

        <div className="mt-4 grid grid-cols-2 gap-8 text-xs">
          <div className="border-t border-zinc-400 pt-2 text-center">顧客簽名</div>
          <div className="border-t border-zinc-400 pt-2 text-center">店員簽名</div>
        </div>
      </div>
    </>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <span className="text-xs text-zinc-500">{label}：</span>
      <span>{value}</span>
    </div>
  );
}
