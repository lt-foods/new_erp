"use client";

import { Fragment, Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
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

  if (error) return <div className="p-6 text-sm text-red-700">{error}</div>;
  if (!receipts) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  const combined = receipts.length > 1;
  // payable 四捨五入到整數 NTD
  const orderPayable = (r: { order: Order; items: Item[] }) => {
    const sub = r.items.reduce((a, it) => a + lineSub(it), 0);
    const pct = Number(r.order?.discount_percent ?? 0);
    return Math.max(0, Math.round(sub * (1 - pct / 100) - Number(r.order?.discount_amount ?? 0)));
  };
  const grandTotal = receipts.reduce((s, r) => s + orderPayable(r), 0);
  const grandWalletPaid = receipts.reduce((s, r) => s + Number(r.order?.wallet_paid_amount ?? 0), 0);
  const grandBalanceDue = Math.max(0, grandTotal - grandWalletPaid);

  return (
    <>
      <style jsx global>{`
        @media print {
          @page { margin: 8mm; }
          body { background: white !important; }
          .no-print { display: none !important; }
          .receipt-single { page-break-inside: avoid; }
          .order-block { page-break-inside: avoid; }
        }
      `}</style>
      <div className="mx-auto max-w-2xl p-6">
        <div className="no-print mb-4 flex justify-end gap-2">
          <SpinButton onClick={() => window.print()} className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white hover:bg-zinc-700">🖨️ 列印</SpinButton>
          <SpinButton onClick={() => window.close()} className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100">關閉</SpinButton>
        </div>

        {combined ? (
          /* 整合單模式 — 多筆訂單共用 1 個 header / 1 組簽名,各訂單緊湊排列 */
          <div className="bg-white text-zinc-900">
            <div className="mb-3 border-b-2 border-zinc-700 pb-2 text-center">
              <h1 className="text-xl font-bold">取貨整合單</h1>
              <div className="mt-0.5 text-xs text-zinc-600">
                共 {receipts.length} 張訂單 · 列印時間 {new Date().toLocaleString("zh-TW")} · 合計 $
                {grandTotal.toLocaleString()}
              </div>
            </div>

            {receipts.map((r, idx) => {
              const sub = r.items.reduce((s, it) => s + lineSub(it), 0);
              const disc = Number(r.order?.discount_amount ?? 0);
              const pct = Number(r.order?.discount_percent ?? 0);
              const pay = Math.max(0, Math.round(sub * (1 - pct / 100) - disc));
              const pctDed = Math.max(0, sub - pay - disc);
              const walletPaid = Number(r.order?.wallet_paid_amount ?? 0);
              const balanceDue = Math.max(0, pay - walletPaid);
              return (
                <div
                  key={r.event.id}
                  className={`order-block ${idx > 0 ? "mt-3 border-t border-dashed border-zinc-400 pt-3" : ""}`}
                >
                  <div className="mb-1.5 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5 text-xs">
                    <span className="font-mono text-sm font-bold">{r.order?.order_no ?? "—"}</span>
                    <span>
                      {r.order?.member?.name ?? "—"}
                      {r.order?.member?.phone && (
                        <span className="ml-1 font-mono text-zinc-600">{r.order.member.phone}</span>
                      )}
                    </span>
                    <span className="text-zinc-600">{r.order?.store?.name ?? "—"}</span>
                    <span className="text-zinc-600">{r.order?.campaign?.name ?? "—"}</span>
                  </div>
                  <table className="w-full border-collapse text-xs">
                    <tbody>
                      {r.items.map((it) => {
                        const itSub = lineSub(it);
                        const itGross = lineGross(it);
                        const discounted = hasLineDisc(it);
                        return (
                          <Fragment key={it.id}>
                            <tr className={it.notes ? "" : "border-b border-zinc-200"}>
                              <td className="px-1 py-0.5">
                                <span className="font-medium">
                                  {it.sku?.variant_name ?? it.sku?.product_name ?? "—"}
                                </span>
                                {it.sku?.sku_code && (
                                  <span className="ml-1 font-mono text-[9px] text-zinc-500">
                                    {it.sku.sku_code}
                                  </span>
                                )}
                                {discounted && (
                                  <span className="ml-1 rounded bg-red-100 px-1 text-[9px] font-bold text-red-700">
                                    {Number(it.discount_percent ?? 0) > 0 ? `${it.discount_percent}%` : `減$${it.discount_amount}`}
                                  </span>
                                )}
                              </td>
                              <td className="px-1 py-0.5 text-right font-mono">× {Number(it.qty)}</td>
                              <td className="px-1 py-0.5 text-right font-mono text-zinc-500">
                                ${Number(it.unit_price)}
                              </td>
                              <td className="px-1 py-0.5 text-right font-mono">
                                {discounted ? (
                                  <>
                                    <span className="mr-1 text-zinc-400 line-through">${itGross}</span>
                                    <span className="font-bold text-red-700">${itSub}</span>
                                  </>
                                ) : (
                                  <>${itSub}</>
                                )}
                              </td>
                            </tr>
                            {it.notes && (
                              <tr className="border-b border-zinc-200">
                                <td colSpan={4} className="px-1 pb-1 text-[10px] italic text-zinc-600">
                                  ↳ 備註：{it.notes}
                                </td>
                              </tr>
                            )}
                          </Fragment>
                        );
                      })}
                      <tr>
                        <td colSpan={3} className="px-1 py-0.5 text-right text-zinc-600">本單小計</td>
                        <td className="px-1 py-0.5 text-right font-mono">${sub}</td>
                      </tr>
                      {pct > 0 && (
                        <tr>
                          <td colSpan={3} className="px-1 py-0.5 text-right text-zinc-600">− 折扣 {pct}%</td>
                          <td className="px-1 py-0.5 text-right font-mono">−${pctDed}</td>
                        </tr>
                      )}
                      {disc > 0 && (
                        <tr>
                          <td colSpan={3} className="px-1 py-0.5 text-right text-zinc-600">− 折扣金額</td>
                          <td className="px-1 py-0.5 text-right font-mono">−${disc}</td>
                        </tr>
                      )}
                      <tr className="font-bold">
                        <td colSpan={3} className="px-1 py-0.5 text-right">本單應收</td>
                        <td className="px-1 py-0.5 text-right font-mono">${pay}</td>
                      </tr>
                      {walletPaid > 0 && (
                        <>
                          <tr>
                            <td colSpan={3} className="px-1 py-0.5 text-right text-zinc-600">− 已用儲值金</td>
                            <td className="px-1 py-0.5 text-right font-mono">−${walletPaid}</td>
                          </tr>
                          <tr className="font-bold">
                            <td colSpan={3} className="px-1 py-0.5 text-right">
                              {balanceDue === 0 ? "✅ 已付清" : "應付剩餘"}
                            </td>
                            <td className="px-1 py-0.5 text-right font-mono">${balanceDue}</td>
                          </tr>
                        </>
                      )}
                    </tbody>
                  </table>
                  {r.order?.notes && (
                    <div className="mt-1 text-[10px] text-zinc-700">📝 訂單備註：{r.order.notes}</div>
                  )}
                  {r.event.notes && (
                    <div className="mt-1 text-[10px] text-zinc-600">取貨備註：{r.event.notes}</div>
                  )}
                </div>
              );
            })}

            <div className="mt-3 border-t-2 border-zinc-700 pt-2 text-right text-sm">
              <div className="font-bold">合計 ${grandTotal.toLocaleString()}</div>
              {grandWalletPaid > 0 && (
                <>
                  <div className="text-zinc-600">− 已用儲值金 ${grandWalletPaid.toLocaleString()}</div>
                  <div className="font-bold">
                    {grandBalanceDue === 0
                      ? "✅ 已付清"
                      : <>應付剩餘 ${grandBalanceDue.toLocaleString()}</>}
                  </div>
                </>
              )}
            </div>
          </div>
        ) : (
          /* 單筆模式 — 維持原本格式 */
          receipts.map((r) => (
            <div key={r.event.id} className="receipt-single bg-white p-4 text-zinc-900">
              <div className="mb-3 text-center">
                <h1 className="text-3xl font-bold">取貨單</h1>
                <div className="text-base text-zinc-500">
                  {r.event.event_type === "picked_up" ? "全部取貨" : "部分取貨"}
                </div>
              </div>

              <div className="mb-3 grid grid-cols-2 gap-x-4 gap-y-1.5 text-base">
                <Field label="訂單號" value={<span className="font-mono font-semibold">{r.order?.order_no ?? "—"}</span>} />
                <Field label="取貨時間" value={new Date(r.event.created_at).toLocaleString("zh-TW")} />
                <Field label="會員" value={r.order?.member ? `${r.order.member.name ?? "—"} (${r.order.member.member_no})` : "—"} />
                <Field label="電話" value={r.order?.member?.phone ?? "—"} />
                <Field label="取貨店" value={r.order?.store?.name ?? "—"} />
                <Field label="開團" value={r.order?.campaign ? `${r.order.campaign.campaign_no} ${r.order.campaign.name}` : "—"} />
              </div>

              <table className="mb-2 w-full border-collapse text-base">
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
                    const sub = lineSub(it);
                    const gross = lineGross(it);
                    const discounted = hasLineDisc(it);
                    return (
                      <Fragment key={it.id}>
                        <tr className={it.notes ? "" : "border-b border-zinc-200"}>
                          <td className="px-2 py-1">
                            <span className="font-medium">{it.sku?.variant_name ?? it.sku?.product_name ?? "—"}</span>
                            {it.sku?.sku_code && <span className="ml-1 font-mono text-xs text-zinc-500">{it.sku.sku_code}</span>}
                            {discounted && (
                              <span className="ml-1 rounded bg-red-100 px-1 text-[11px] font-bold text-red-700">
                                {Number(it.discount_percent ?? 0) > 0 ? `${it.discount_percent}%` : `減$${it.discount_amount}`}
                              </span>
                            )}
                          </td>
                          <td className="px-2 py-1 text-right font-mono">{Number(it.qty)}</td>
                          <td className="px-2 py-1 text-right font-mono">${Number(it.unit_price)}</td>
                          <td className="px-2 py-1 text-right font-mono">
                            {discounted ? (
                              <>
                                <span className="mr-1 text-zinc-400 line-through">${gross}</span>
                                <span className="font-bold text-red-700">${sub}</span>
                              </>
                            ) : (
                              <>${sub}</>
                            )}
                          </td>
                        </tr>
                        {it.notes && (
                          <tr className="border-b border-zinc-200">
                            <td colSpan={4} className="px-2 pb-1 text-xs italic text-zinc-600">
                              ↳ 備註：{it.notes}
                            </td>
                          </tr>
                        )}
                      </Fragment>
                    );
                  })}
                </tbody>
                <tfoot>
                  {(() => {
                    const sub = r.items.reduce((s, it) => s + lineSub(it), 0);
                    const disc = Number(r.order?.discount_amount ?? 0);
                    const pct = Number(r.order?.discount_percent ?? 0);
                    const pay = Math.max(0, Math.round(sub * (1 - pct / 100) - disc));
                    const pctDed = Math.max(0, sub - pay - disc);
                    const walletPaid = Number(r.order?.wallet_paid_amount ?? 0);
                    const balanceDue = Math.max(0, pay - walletPaid);
                    return (
                      <>
                        <tr className="border-t border-zinc-300">
                          <td colSpan={3} className="px-2 py-1 text-right text-sm text-zinc-600">小計</td>
                          <td className="px-2 py-1 text-right font-mono">${sub}</td>
                        </tr>
                        {pct > 0 && (
                          <tr>
                            <td colSpan={3} className="px-2 py-1 text-right text-sm text-zinc-600">− 折扣 {pct}%</td>
                            <td className="px-2 py-1 text-right font-mono">−${pctDed}</td>
                          </tr>
                        )}
                        {disc > 0 && (
                          <tr>
                            <td colSpan={3} className="px-2 py-1 text-right text-sm text-zinc-600">− 折扣金額</td>
                            <td className="px-2 py-1 text-right font-mono">−${disc}</td>
                          </tr>
                        )}
                        <tr className="border-t-2 border-zinc-400 text-xl font-bold">
                          <td colSpan={3} className="px-2 py-2 text-right">應收</td>
                          <td className="px-2 py-2 text-right font-mono">${pay}</td>
                        </tr>
                        {walletPaid > 0 && (
                          <>
                            <tr>
                              <td colSpan={3} className="px-2 py-1 text-right text-sm text-zinc-600">− 已用儲值金</td>
                              <td className="px-2 py-1 text-right font-mono">−${walletPaid}</td>
                            </tr>
                            <tr className="border-t border-zinc-300 font-bold">
                              <td colSpan={3} className="px-2 py-1 text-right">
                                {balanceDue === 0 ? "✅ 已付清" : "應付剩餘"}
                              </td>
                              <td className="px-2 py-1 text-right font-mono">${balanceDue}</td>
                            </tr>
                          </>
                        )}
                      </>
                    );
                  })()}
                </tfoot>
              </table>

              {r.order?.notes && (
                <div className="mb-1 text-sm text-zinc-700">📝 訂單備註：{r.order.notes}</div>
              )}
              {r.event.notes && (
                <div className="mb-2 text-sm text-zinc-600">取貨備註：{r.event.notes}</div>
              )}
            </div>
          ))
        )}
      </div>
    </>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <span className="text-sm text-zinc-500">{label}：</span>
      <span>{value}</span>
    </div>
  );
}
