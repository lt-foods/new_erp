"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { stripTransferNotes, stripItemNotes } from "@/lib/orderNotes";
import { internalOrderSource } from "@/lib/orderTitle";
import { itemDisplayName } from "@/lib/skuLabel";
import { settlementNo } from "@/lib/settlementNo";
import { GIFT_ITEM_SELECT, isGiftLine } from "@/lib/orderGift";
import SpinButton from "@/components/SpinButton";
import { CutoffText } from "@/components/CampaignCutoff";

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
  campaign: { id: number; campaign_no: string; name: string; cutoff_date: string | null } | null;
  store: { id: number; name: string; store_short_code: string | null } | null;
};

type Item = {
  id: number;
  qty: number;
  unit_price: number;
  discount_amount: number;
  discount_percent: number;
  notes: string | null;
  status: string;
  is_gift: boolean | null;
  gift_reason: string | null;
  campaign_item: { is_gift: boolean | null; gift_reason: string | null } | null;
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
// 一批品項的應收 — payable 四捨五入到整數 NTD（對齊 PickupDialog / v_customer_order_summary）
function batchPayOf(order: Order, items: Item[]): number {
  const sub = items.reduce((a, it) => a + lineSub(it), 0);
  const pct = Number(order?.discount_percent ?? 0);
  return Math.max(0, Math.round(sub * (1 - pct / 100) - Number(order?.discount_amount ?? 0)));
}

export default function PickupPrintPage() {
  return (
    <Suspense fallback={<div className="p-4 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

// 這張收據（一次取貨事件）實際抵掉的儲值金。
//
// customer_orders.wallet_paid_amount 是整張單累計的；分批取貨時直接印它會把前幾批
// 扣過的錢在每一批都再抵一次（2026-10-01 古華：第 3 批扣 $79、第 4 批 $456 的貨印成
// 「應付 $377」）。改成依 wallet_ledger 還原「這一趟收了多少」：
//   1. 本趟的扣款 = 掛在本單、落在（上一次取貨事件, 本次取貨事件 + 2s] 時間窗內、
//      未被沖銷的 spend —— 前端一律「先 rpc_wallet_pay_order 再 rpc_record_pickup」，
//      這個窗口就是這趟的收款（與 rpc_undo_pickup 的退款邏輯同一套，20260902040000）。
//   2. 不在任何取貨窗口裡的已扣額（訂單頁「儲值金結帳」先付清再分批取）＝預付額度，
//      依取貨順序被前面幾批用掉（每批吃 應收 − 該批自己的扣款），剩下的才抵本批。
// 補列印舊收據也走同一套，所以補印第 1 批不會把第 3 批才扣的錢印上去。
type LedgerRow = { id: number; source_id: number; type: string; change: number; created_at: string; reverses: number | null };
function walletAppliedToEvent(
  ev: PickupEvent,
  order: Order,
  allEvents: PickupEvent[],
  ledger: LedgerRow[],
  itemMap: Map<number, Item>,
  batchPayOf: (order: Order, items: Item[]) => number,
): number {
  const evs = allEvents.filter((e) => e.order_id === ev.order_id).sort((a, b) => a.id - b.id);
  const reversed = new Set(ledger.filter((l) => l.type === "reversal" && l.reverses != null).map((l) => l.reverses as number));
  const spends = ledger.filter((l) => l.source_id === ev.order_id && l.type === "spend" && !reversed.has(l.id));
  const windowSpend = (e: PickupEvent): number => {
    const idx = evs.findIndex((x) => x.id === e.id);
    const prevAt = idx > 0 ? new Date(evs[idx - 1].created_at).getTime() : null;
    const endAt = new Date(e.created_at).getTime() + 2000;
    return spends.reduce((s, l) => {
      const t = new Date(l.created_at).getTime();
      return t <= endAt && (prevAt == null || t > prevAt) ? s + Math.abs(Number(l.change)) : s;
    }, 0);
  };
  const itemsOf = (e: PickupEvent): Item[] => (e.item_ids ?? []).map((id) => itemMap.get(id)).filter((x): x is Item => !!x);
  // 品項最後一次被哪個事件取走 —— 撤銷過再重取的，舊事件就不算「前面已取」
  const latestEventByItem = new Map<number, number>();
  for (const e of evs) for (const id of e.item_ids ?? []) latestEventByItem.set(id, Math.max(latestEventByItem.get(id) ?? 0, e.id));
  const effective = (e: PickupEvent): boolean =>
    (e.item_ids ?? []).length > 0
    && (e.item_ids ?? []).every((id) => latestEventByItem.get(id) === e.id && itemMap.get(id)?.status === "picked_up");

  const batchPay = batchPayOf(order, itemsOf(ev));
  const thisSpend = windowSpend(ev);
  const walletPaid = Number(order.wallet_paid_amount ?? 0);
  const inWindows = evs.reduce((s, e) => s + windowSpend(e), 0);
  const prepaid = Math.max(0, walletPaid - inWindows);
  const consumedBefore = evs
    .filter((e) => e.id < ev.id && effective(e))
    .reduce((s, e) => s + Math.max(0, batchPayOf(order, itemsOf(e)) - windowSpend(e)), 0);
  const creditLeft = Math.max(0, prepaid - consumedBefore);
  return Math.max(0, Math.min(batchPay, thisSpend + creditLeft));
}

function Body() {
  const eventIds = useSearchParams().get("event_ids");
  const ids = eventIds ? eventIds.split(",").map(Number).filter(Boolean) : [];
  const [receipts, setReceipts] = useState<{ event: PickupEvent; order: Order; items: Item[]; walletApplied: number }[] | null>(null);
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
      // 品項、取貨事件、儲值金流水都抓**整張單**的 —— 這張收據抵了多少儲值金要看
      // 前幾批取走了什麼、扣了多少（walletAppliedToEvent），不是只看本次的品項。
      const [{ data: ords }, { data: itms }, { data: allEvts }, { data: ledg }] = await Promise.all([
        sb.from("customer_orders")
          .select("id, order_no, status, pickup_store_id, discount_amount, discount_percent, wallet_paid_amount, payment_status, notes, member:members(id, member_no, name, phone), campaign:group_buy_campaigns(id, campaign_no, name, cutoff_date), store:stores!customer_orders_pickup_store_id_fkey(id, name, store_short_code)")
          .in("id", orderIds),
        sb.from("customer_order_items").select(`id, qty, unit_price, discount_amount, discount_percent, notes, status, ${GIFT_ITEM_SELECT}, sku:skus(sku_code, product_name, variant_name)`).in("order_id", orderIds),
        sb.from("order_pickup_events")
          .select("id, order_id, pickup_store_id, event_type, item_ids, notes, created_at")
          .in("order_id", orderIds)
          .in("event_type", ["picked_up", "partial_pickup"]),
        sb.from("wallet_ledger")
          .select("id, source_id, type, change, created_at, reverses")
          .eq("source_type", "customer_order")
          .in("source_id", orderIds)
          .in("type", ["spend", "reversal"]),
      ]);
      const ordMap = new Map<number, Order>();
      for (const o of (ords ?? []) as unknown as Order[]) ordMap.set(o.id, o);
      const itemMap = new Map<number, Item>();
      for (const i of (itms ?? []) as unknown as Item[]) itemMap.set(i.id, i);
      const allEvents = (allEvts ?? []) as unknown as PickupEvent[];
      const ledger = (ledg ?? []) as unknown as LedgerRow[];

      const result = events.map((ev) => {
        const order = ordMap.get(ev.order_id) as Order;
        return {
          event: ev,
          order,
          items: (ev.item_ids ?? []).map((id) => itemMap.get(id)).filter((x): x is Item => !!x),
          walletApplied: order ? walletAppliedToEvent(ev, order, allEvents, ledger, itemMap, batchPayOf) : 0,
        };
      });
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
  const orderPay = (r: { order: Order; items: Item[] }) => batchPayOf(r.order, r.items);
  const grandSubtotal = receipts.reduce((s, r) => s + orderSub(r), 0);
  const grandTotal = receipts.reduce((s, r) => s + orderPay(r), 0);
  const totalOrderDisc = grandSubtotal - grandTotal; // 倒推、含取整誤差
  // 這幾張收據各自抵掉的儲值金（不是訂單累計的 wallet_paid_amount，見 walletAppliedToEvent）
  const grandWalletPaid = receipts.reduce((s, r) => s + r.walletApplied, 0);
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
                <div className="text-[13px]">
                  {r.order?.campaign?.campaign_no?.startsWith("__")
                    ? internalOrderSource(r.order?.order_no)?.label ?? "店內現貨"
                    : r.order?.campaign?.name ?? "(未知活動)"}
                  <CutoffText date={r.order?.campaign?.cutoff_date} />
                </div>
                <div className="text-[13px]">
                  結單編號: {settlementNo(r.order?.id ?? r.event.order_id, r.order?.store?.store_short_code)}
                </div>
                {orderNotes && (
                  <div className="text-[13px] italic">📝 {orderNotes}</div>
                )}
                <div className="divide-y divide-dashed divide-zinc-300">
                {r.items.map((it) => {
                  const subtotal = lineSub(it);
                  const gross = lineGross(it);
                  const discounted = hasLineDisc(it);
                  return (
                    <div key={it.id} className="py-1">
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="min-w-0 flex-1 break-words text-[16px] font-bold">
                          {itemDisplayName(it.sku, r.order?.campaign?.name)}
                        </span>
                        <span className="whitespace-nowrap text-[15px]">
                          {/* 贈品：$0 是刻意的。收據上不標的話，客人與店員都會以為是漏打價格 */}
                          {isGiftLine(it) && (
                            <span className="mr-1.5 text-[15px] font-bold">🎁 贈品</span>
                          )}
                          {Number(it.qty)} × ${Number(it.unit_price)} =
                          {discounted ? (
                            <>
                              <span className="ml-1 text-[13px] line-through">${gross}</span>
                              <span className="ml-1 text-[15px] font-bold">${subtotal}</span>
                            </>
                          ) : (
                            <span className="ml-1 text-[15px] font-bold">${subtotal}</span>
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
                      {stripItemNotes(it.notes) && (
                        <div className="pl-2 text-[13px] italic">↳ 備註：{stripItemNotes(it.notes)}</div>
                      )}
                    </div>
                  );
                })}
                </div>
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
          <div className="text-[16px] font-bold">總數量：{totalQty}</div>
          <div className="mt-1 text-[20px] font-bold">
            {grandWalletPaid > 0 && grandBalanceDue === 0
              ? "✅ 已付清"
              : <>應付 {grandBalanceDue.toLocaleString()} 元</>}
          </div>
          <div className="text-[13px]">
            (總金額: {grandSubtotal.toLocaleString()}元, 折扣抵: {totalOrderDisc.toLocaleString()}元,
            錢包抵: {grandWalletPaid.toLocaleString()}元)
          </div>
        </div>
      </div>
    </>
  );
}
