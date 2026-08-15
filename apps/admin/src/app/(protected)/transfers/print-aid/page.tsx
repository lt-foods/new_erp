"use client";

// 互助出貨單列印 — 以「互助訂單」為主體（不是單一 transfer）。
//
// 為什麼不共用 /transfers/print：
//   經總倉的互助會拆成兩段（20260510000004 rpc_ship_aid_order）：
//     Leg-1 來源店 → 總倉（customer_order_id = NULL）
//     Leg-2 總倉   → 收貨店（customer_order_id = 本單）
//   Leg-1 身上沒有訂單、目的地寫的是總倉 —— 拿它去印,紙上永遠看不出「這箱貨
//   最後要去哪一家店」,總倉沒辦法照單轉交（這正是店家反映的痛點）。
//   而且派貨（rpc_ship_aid_order）之前根本還沒有 transfer,來源店要裝箱時無單可印。
//   所以這張單一律從 customer_orders 出發,把整條路徑（來源店 →〔總倉〕→ 收貨店）
//   印在同一張紙上,已建立的 AT- 段號附在下面對帳用。
//
// query params:
//   order_id: 互助訂單 id（必填）
//   copies:   逗號分隔; 預設 "driver,stub"。可傳 "driver" 只印一份。

import { Fragment, Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { getTenantName } from "@/lib/tenant";
import { useAuth } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

type SkuRef = { sku_code: string | null; product_name: string | null; variant_name: string | null };

type ItemRow = {
  id: number;
  qty: number;
  status: string;
  source: string | null;
  notes: string | null;
  sku: SkuRef | null;
};

type OrderHead = {
  id: number;
  order_no: string;
  status: string;
  is_air_transfer: boolean | null;
  notes: string | null;
  created_at: string;
  shipping_at: string | null;
  nickname_snapshot: string | null;
  transferred_from_order_id: number | null;
  member: { name: string | null; member_no: string; phone: string | null } | null;
  campaign: { campaign_no: string; name: string } | null;
  store: { name: string } | null;
};

type Leg = {
  id: number;
  transfer_no: string;
  status: string;
  source_name: string;
  dest_name: string;
  shipped_at: string | null;
  received_at: string | null;
};

type CopyKind = "driver" | "stub";

const COPY_LABEL: Record<CopyKind, string> = {
  driver: "隨貨聯 (隨箱)",
  stub: "出貨店存根聯",
};

const LEG_STATUS_LABEL: Record<string, string> = {
  draft: "待出貨",
  confirmed: "已確認",
  shipped: "已出貨",
  received: "已收貨",
  cancelled: "已取消",
  closed: "已結案",
};

// 實際會被裝箱寄出的品項（對齊 rpc_ship_aid_order 只出 source='aid_transfer' 的品項）
const ACTIVE_ITEM_STATUSES = new Set(["pending", "reserved", "ready", "picked_up"]);

export default function AidTransferPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const orderId = Number(sp.get("order_id"));
  const copiesParam = sp.get("copies") ?? "driver,stub";
  const copies: CopyKind[] = useMemo(() => {
    const raw = copiesParam.split(",").map((s) => s.trim()).filter(Boolean);
    const valid = raw.filter((k): k is CopyKind => k === "driver" || k === "stub");
    return valid.length > 0 ? valid : ["driver"];
  }, [copiesParam]);

  const [head, setHead] = useState<OrderHead | null>(null);
  const [items, setItems] = useState<ItemRow[] | null>(null);
  const [sourceStore, setSourceStore] = useState<string | null>(null);
  const [hqName, setHqName] = useState<string | null>(null);
  const [legs, setLegs] = useState<Leg[]>([]);
  const [err, setErr] = useState<string | null>(null);

  const paramError = !orderId ? "缺 order_id 參數" : null;

  useEffect(() => {
    if (paramError) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [hRes, iRes] = await Promise.all([
        sb
          .from("customer_orders")
          .select(
            "id, order_no, status, is_air_transfer, notes, created_at, shipping_at, nickname_snapshot, " +
              "transferred_from_order_id, member:members(name, member_no, phone), " +
              "campaign:group_buy_campaigns(campaign_no, name), " +
              "store:stores!customer_orders_pickup_store_id_fkey(name)",
          )
          .eq("id", orderId)
          .maybeSingle(),
        sb
          .from("customer_order_items")
          .select("id, qty, status, source, notes, sku:skus(sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .order("id"),
      ]);
      if (cancelled) return;
      if (hRes.error || !hRes.data) { setErr(hRes.error?.message ?? "找不到此訂單"); return; }
      const h = hRes.data as unknown as OrderHead;
      setHead(h);

      const allItems = (iRes.data ?? []) as unknown as ItemRow[];
      const active = allItems.filter((it) => ACTIVE_ITEM_STATUSES.has(it.status));
      // 互助品項一律是 source='aid_transfer'；混到別的來源（同一張單後來又加了團購品項）
      // 時只印互助那些 —— 出貨店裝箱時不該把不屬於這次互助的貨也寄出去。
      const aidItems = active.filter((it) => it.source === "aid_transfer");
      setItems(aidItems.length > 0 ? aidItems : active);

      // 來源店（貨從哪一家出去）
      if (h.transferred_from_order_id != null) {
        const { data: srcRow } = await sb
          .from("customer_orders")
          .select("store:stores!customer_orders_pickup_store_id_fkey(name)")
          .eq("id", h.transferred_from_order_id)
          .maybeSingle();
        if (cancelled) return;
        const st = (srcRow as unknown as { store: { name: string } | { name: string }[] | null } | null)?.store;
        setSourceStore((Array.isArray(st) ? st[0]?.name : st?.name) ?? null);
      }

      // 轉移單段：Leg-2（掛本單）+ 反查 Leg-1（next_transfer_id 指向 Leg-2）
      const cols = "id, transfer_no, status, source_location, dest_location, next_transfer_id, shipped_at, received_at";
      const { data: tailRows } = await sb.from("transfers").select(cols).eq("customer_order_id", orderId);
      if (cancelled) return;
      type Raw = {
        id: number; transfer_no: string; status: string;
        source_location: number; dest_location: number;
        next_transfer_id: number | null; shipped_at: string | null; received_at: string | null;
      };
      const tail = (tailRows ?? []) as unknown as Raw[];
      let chain: Raw[] = tail;
      if (tail.length > 0) {
        const { data: prevRows } = await sb
          .from("transfers")
          .select(cols)
          .in("next_transfer_id", tail.map((t) => t.id));
        if (cancelled) return;
        chain = [...((prevRows ?? []) as unknown as Raw[]), ...tail];
      }

      const locIds = Array.from(new Set(chain.flatMap((t) => [t.source_location, t.dest_location])));
      const locMap = new Map<number, string>();
      if (locIds.length > 0) {
        const { data: locRows } = await sb.from("locations").select("id, name").in("id", locIds);
        if (cancelled) return;
        for (const l of (locRows ?? []) as { id: number; name: string }[]) locMap.set(l.id, l.name);
      }
      setLegs(
        chain.map((t) => ({
          id: t.id,
          transfer_no: t.transfer_no,
          status: t.status,
          source_name: locMap.get(t.source_location) ?? `#${t.source_location}`,
          dest_name: locMap.get(t.dest_location) ?? `#${t.dest_location}`,
          shipped_at: t.shipped_at,
          received_at: t.received_at,
        })),
      );

      // 經總倉：還沒派貨時沒有 Leg 可以拿總倉名字，直接查一次 location
      if (!h.is_air_transfer) {
        const { data: hqRow } = await sb
          .from("locations")
          .select("name")
          .eq("type", "central_warehouse")
          .eq("is_active", true)
          .order("id")
          .limit(1)
          .maybeSingle();
        if (cancelled) return;
        setHqName((hqRow as { name: string } | null)?.name ?? "總倉");
      }
    })();
    return () => { cancelled = true; };
  }, [orderId, paramError]);

  // PDF 存檔 / 列印對話框預設檔名 → 用訂單號
  useEffect(() => {
    if (!head) return;
    const original = document.title;
    document.title = head.order_no;
    return () => { document.title = original; };
  }, [head]);

  // 資料載入完成 → 自動跳列印
  useEffect(() => {
    if (head && items) {
      const t = setTimeout(() => window.print(), 400);
      return () => clearTimeout(t);
    }
  }, [head, items]);

  if (paramError) return <div className="p-6 text-sm text-red-700">{paramError}</div>;
  if (err) return <div className="p-6 text-sm text-red-700">{err}</div>;
  if (!head || !items) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  return (
    <>
      {/* 80mm 熱感出單機版型（對齊 /transfers/print 的轉貨單） */}
      <style jsx global>{`
        @media print {
          @page { margin: 3mm; size: 80mm auto; }
          body { background: white !important; }
          .no-print { display: none !important; }
          .copy-page { page-break-after: always; }
          .copy-page:last-child { page-break-after: auto; }
        }
        @media screen {
          body { background: #f0f0f0; }
          .copy-page { margin-bottom: 24px; }
        }
      `}</style>
      <div className="mx-auto my-4 max-w-[80mm] print:my-0">
        <div className="no-print mb-3 flex justify-end gap-2">
          <SpinButton
            onClick={() => window.print()}
            className="rounded bg-zinc-900 px-3 py-1 text-xs text-white hover:bg-zinc-700"
          >
            🖨️ 再次列印
          </SpinButton>
          <SpinButton
            onClick={() => window.close()}
            className="rounded border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100"
          >
            關閉
          </SpinButton>
        </div>

        {copies.map((kind, idx) => (
          <Slip
            key={`${kind}-${idx}`}
            kind={kind}
            head={head}
            items={items}
            sourceStore={sourceStore}
            hqName={hqName}
            legs={legs}
          />
        ))}
      </div>
    </>
  );
}

function Slip({
  kind, head, items, sourceStore, hqName, legs,
}: {
  kind: CopyKind;
  head: OrderHead;
  items: ItemRow[];
  sourceStore: string | null;
  hqName: string | null;
  legs: Leg[];
}) {
  const { tenant } = useAuth();
  const tenantName = tenant?.name ?? getTenantName();
  const viaHq = !head.is_air_transfer;
  const destStore = head.store?.name ?? "—";
  const totalQty = items.reduce((s, it) => s + Number(it.qty ?? 0), 0);
  const customer = head.member?.name ?? head.nickname_snapshot ?? "—";

  return (
    <div className="copy-page bg-white p-2 font-mono text-[13px] leading-tight text-black shadow print:shadow-none">
      <div className="border-b-2 border-black pb-1 text-center">
        <div className="text-[14px] font-bold">{tenantName}</div>
        <div className="text-[20px] font-bold">互助出貨單</div>
        <div className="mt-0.5 flex items-center justify-center gap-2">
          <span className="inline-block rounded border-2 border-black px-1.5 py-0.5 text-[13px] font-bold">
            {COPY_LABEL[kind]}
          </span>
          <span className="text-[13px] font-bold">{head.order_no}</span>
        </div>
      </div>

      {/* 路徑 —— 經總倉時最終收貨店要一眼看得到，總倉才知道要往哪家轉 */}
      <div className="border-b border-dashed border-black py-1.5">
        <div className="text-[15px] font-bold">
          {sourceStore ?? "—"}
          {viaHq && (
            <>
              <span className="font-normal"> → </span>
              {hqName ?? "總倉"}
            </>
          )}
          <span className="font-normal"> → </span>
          {destStore}
        </div>
        <div className="mt-0.5 border border-black p-1 text-center text-[15px] font-bold">
          {viaHq ? "經總倉中轉" : "✈ 空中轉直送"} · 收貨店：{destStore}
        </div>
        <div className="mt-1 text-[12px]">客人 {customer}</div>
        {head.campaign && (
          <div className="text-[12px]">開團 {head.campaign.campaign_no}</div>
        )}
        <div className="text-[12px]">
          建立 {new Date(head.created_at).toLocaleString("zh-TW", { hour12: false })}
        </div>
        {head.shipping_at && (
          <div className="text-[12px]">
            出貨 {new Date(head.shipping_at).toLocaleString("zh-TW", { hour12: false })}
          </div>
        )}
      </div>

      <table className="w-full border-collapse">
        <thead>
          <tr className="border-b border-black text-[12px]">
            <th className="w-5 py-1 text-left">#</th>
            <th className="py-1 text-left">品名 / 規格</th>
            <th className="w-10 py-1 text-right">數量</th>
            <th className="w-8 py-1 text-center">點收</th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr><td colSpan={4} className="py-2 text-center text-zinc-500">無明細</td></tr>
          ) : (
            items.map((it, idx) => (
              <Fragment key={it.id}>
                <tr className="border-b border-dashed border-zinc-400">
                  <td className="py-1 align-top">{idx + 1}</td>
                  <td className="py-1 align-top">
                    <span className="break-words font-bold">{it.sku?.product_name || "—"}</span>
                    {it.sku?.variant_name && <span className="ml-1">/ {it.sku.variant_name}</span>}
                    {it.sku?.sku_code && (
                      <div className="text-[10px] text-zinc-500">{it.sku.sku_code}</div>
                    )}
                    {it.notes && <div className="text-[11px] italic">↳ {it.notes}</div>}
                  </td>
                  <td className="py-1 text-right align-top font-bold">{Number(it.qty)}</td>
                  <td className="py-1 text-center align-top text-[15px]">☐</td>
                </tr>
              </Fragment>
            ))
          )}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-black font-bold">
            <td colSpan={2} className="py-1 text-right">合計</td>
            <td className="py-1 text-right">{totalQty}</td>
            <td className="py-1 text-center text-[11px]">{items.length} 項</td>
          </tr>
        </tfoot>
      </table>

      {head.notes && (
        <div className="mt-1.5 border border-black p-1.5 text-[12px]">
          <span className="font-bold">備註：</span>
          {head.notes}
        </div>
      )}

      {/* 已建立的轉移單段（派貨後才有）— 出了問題時對得回系統單據 */}
      {legs.length > 0 && (
        <div className="mt-1.5 text-[11px]">
          {legs.map((l) => (
            <div key={l.id}>
              {l.transfer_no}（{l.source_name}→{l.dest_name}・{LEG_STATUS_LABEL[l.status] ?? l.status}）
            </div>
          ))}
        </div>
      )}

      {/* 簽收欄：經總倉多一格給總倉點收，貨才不會在中轉站不明不白地掉 */}
      <div className="mt-2 space-y-2 text-[12px]">
        {viaHq && (
          <div className="border border-black p-1.5">
            <div className="font-bold">{hqName ?? "總倉"}點收</div>
            <div className="mt-3 border-b border-black" />
            <div className="mt-0.5 text-[10px] text-zinc-500">簽名 / 日期</div>
          </div>
        )}
        <div className="border border-black p-1.5">
          <div className="font-bold">{destStore} 收貨簽收</div>
          <div className="mt-3 border-b border-black" />
          <div className="mt-0.5 text-[10px] text-zinc-500">簽名 / 日期（收到後請在「收貨」頁點收）</div>
        </div>
      </div>

      <div className="mt-1 text-right text-[10px] text-zinc-500">
        列印時間 {new Date().toLocaleString("zh-TW", { hour12: false })}
      </div>
    </div>
  );
}
