"use client";

// 轉貨單列印 — 司機聯 (隨貨交付司機) + 店家存根聯 (店內留存)
// query params:
//   transfer_id: 轉貨單 id (必填)
//   copies: 逗號分隔; 預設 "driver,stub"。可傳 "driver" 只印一份。

import { Fragment, Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { getTenantName } from "@/lib/tenant";
import { useAuth } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

type Transfer = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  notes: string | null;
  shipping_temp: string | null;
  is_air_transfer: boolean | null;
  customer_order_id: number | null;
  next_transfer_id: number | null;
  shipped_at: string | null;
  received_at: string | null;
  created_at: string;
  source_name: string;
  dest_name: string;
};

// 掛在這張調撥單上的顧客訂單（互助 AT- 單才有）。
// 經總倉的互助會拆兩段（rpc_ship_aid_order）：Leg-1（來源店→總倉）身上是
// customer_order_id = NULL，訂單掛在 next_transfer_id 指到的 Leg-2 上 ——
// 只印本段的話，總倉手上那張紙看不出貨最後要送去哪一家店（正是店家回報的痛點），
// 所以這裡往後追一段，把最終收貨店印出來。
type LinkedOrder = {
  order_no: string;
  store_name: string | null;
  via_next_leg: boolean;
};

type Item = {
  id: number;
  qty_requested: number;
  qty_shipped: number;
  description: string | null;
  estimated_amount: number | null;
  sku_code: string | null;
  sku_name: string;
  variant_name: string | null;
  notes: string | null;
};

const TYPE_LABEL: Record<string, string> = {
  hq_to_store: "總倉派貨",
  store_to_store: "店轉店",
  store_to_hq: "店退總倉",
  return_to_hq: "退貨回總倉",
  aid_handoff: "互助轉移",
};

const TEMP_LABEL: Record<string, string> = {
  frozen: "冷凍",
  chilled: "冷藏",
  ambient: "常溫",
  mixed: "混合",
};

type CopyKind = "driver" | "stub";

const COPY_LABEL: Record<CopyKind, string> = {
  driver: "司機聯 (隨貨)",
  stub: "店家存根聯",
};

export default function TransferPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const transferId = Number(sp.get("transfer_id"));
  const copiesParam = sp.get("copies") ?? "driver,stub";
  const copies: CopyKind[] = useMemo(() => {
    const raw = copiesParam.split(",").map((s) => s.trim()).filter(Boolean);
    const valid = raw.filter((k): k is CopyKind => k === "driver" || k === "stub");
    return valid.length > 0 ? valid : ["driver"];
  }, [copiesParam]);

  const [tx, setTx] = useState<Transfer | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [linkedOrder, setLinkedOrder] = useState<LinkedOrder | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const paramError = !transferId ? "缺 transfer_id 參數" : null;

  useEffect(() => {
    if (paramError) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: tRow, error: e1 } = await sb
        .from("transfers")
        .select(
          "id, transfer_no, source_location, dest_location, status, transfer_type, notes, " +
            "shipping_temp, is_air_transfer, customer_order_id, next_transfer_id, shipped_at, received_at, created_at"
        )
        .eq("id", transferId)
        .maybeSingle();
      if (cancelled) return;
      if (e1 || !tRow) { setErr(e1?.message ?? "找不到此單"); return; }
      const t = tRow as unknown as Omit<Transfer, "source_name" | "dest_name">;

      const [{ data: locs }, { data: tis }] = await Promise.all([
        sb.from("locations").select("id, name").in("id", [t.source_location, t.dest_location]),
        sb
          .from("transfer_items")
          .select("id, sku_id, qty_requested, qty_shipped, description, estimated_amount, notes")
          .eq("transfer_id", transferId)
          .order("id"),
      ]);
      if (cancelled) return;
      const locArr = (locs ?? []) as { id: number; name: string }[];
      const locMap = new Map(locArr.map((l) => [l.id, l.name]));

      type ApiItem = {
        id: number;
        sku_id: number | null;
        qty_requested: number | null;
        qty_shipped: number | null;
        description: string | null;
        estimated_amount: number | null;
        notes: string | null;
      };
      const tiRows = (tis ?? []) as ApiItem[];

      const skuIds = Array.from(
        new Set(tiRows.filter((r) => !r.description && r.sku_id != null).map((r) => r.sku_id as number))
      );
      let skuMap = new Map<number, { code: string; variant: string | null; name: string }>();
      if (skuIds.length > 0) {
        const { data: skuRows } = await sb
          .from("skus")
          .select("id, sku_code, variant_name, product_id")
          .in("id", skuIds);
        type SkuRow = { id: number; sku_code: string; variant_name: string | null; product_id: number | null };
        const skus = (skuRows ?? []) as SkuRow[];
        const prodIds = Array.from(new Set(skus.map((s) => s.product_id).filter((x): x is number => x != null)));
        let prodMap = new Map<number, string>();
        if (prodIds.length > 0) {
          const { data: prods } = await sb.from("products").select("id, name").in("id", prodIds);
          prodMap = new Map(((prods ?? []) as { id: number; name: string }[]).map((p) => [p.id, p.name]));
        }
        skuMap = new Map(
          skus.map((s) => [s.id, {
            code: s.sku_code,
            variant: s.variant_name,
            name: s.product_id != null ? (prodMap.get(s.product_id) ?? "") : "",
          }])
        );
      }

      const rows: Item[] = tiRows.map((r) => {
        const sku = r.sku_id != null ? skuMap.get(r.sku_id) : undefined;
        return {
          id: r.id,
          qty_requested: Number(r.qty_requested ?? 0),
          qty_shipped: Number(r.qty_shipped ?? 0),
          description: r.description,
          estimated_amount: r.estimated_amount == null ? null : Number(r.estimated_amount),
          sku_code: sku?.code ?? null,
          sku_name: sku?.name ?? "",
          variant_name: sku?.variant ?? null,
          notes: r.notes,
        };
      });

      // 掛著的顧客訂單：本段沒有就往 next_transfer_id 追一段（經總倉的互助 Leg-1）。
      // 一定要在 setTx 之前解完 —— 資料到齊就會自動跳列印，晚一步紙上就少一行。
      let orderId = t.customer_order_id;
      let viaNextLeg = false;
      if (orderId == null && t.next_transfer_id != null) {
        const { data: nextRow } = await sb
          .from("transfers")
          .select("customer_order_id")
          .eq("id", t.next_transfer_id)
          .maybeSingle();
        if (cancelled) return;
        orderId = (nextRow as { customer_order_id: number | null } | null)?.customer_order_id ?? null;
        viaNextLeg = orderId != null;
      }
      if (orderId != null) {
        const { data: ordRow } = await sb
          .from("customer_orders")
          .select("order_no, store:stores!customer_orders_pickup_store_id_fkey(name)")
          .eq("id", orderId)
          .maybeSingle();
        if (cancelled) return;
        const ord = ordRow as unknown as
          { order_no: string; store: { name: string } | { name: string }[] | null } | null;
        if (ord) {
          const st = ord.store;
          setLinkedOrder({
            order_no: ord.order_no,
            store_name: (Array.isArray(st) ? st[0]?.name : st?.name) ?? null,
            via_next_leg: viaNextLeg,
          });
        }
      }

      if (!cancelled) {
        setTx({
          ...t,
          source_name: locMap.get(t.source_location) ?? `#${t.source_location}`,
          dest_name: locMap.get(t.dest_location) ?? `#${t.dest_location}`,
        });
        setItems(rows);
      }
    })();
    return () => { cancelled = true; };
  }, [transferId, paramError]);

  // PDF 存檔 / 列印對話框預設檔名 → 用轉貨單號 (而非通用的 /transfers/print)
  useEffect(() => {
    if (!tx) return;
    const original = document.title;
    document.title = tx.transfer_no;
    return () => { document.title = original; };
  }, [tx]);

  // 資料載入完成 → 自動跳列印
  useEffect(() => {
    if (tx && items) {
      const t = setTimeout(() => window.print(), 400);
      return () => clearTimeout(t);
    }
  }, [tx, items]);

  if (paramError) return <div className="p-6 text-sm text-red-700">{paramError}</div>;
  if (err) return <div className="p-6 text-sm text-red-700">{err}</div>;
  if (!tx || !items) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  return (
    <>
      {/* 80mm 熱感出單機版型（對齊取貨小白單）。門市出單機印 A5 版會整頁縮小到看不清楚 */}
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
          <Slip key={`${kind}-${idx}`} kind={kind} tx={tx} items={items} linkedOrder={linkedOrder} />
        ))}
      </div>
    </>
  );
}

function Slip({ kind, tx, items, linkedOrder }: {
  kind: CopyKind; tx: Transfer; items: Item[]; linkedOrder: LinkedOrder | null;
}) {
  const { tenant } = useAuth();
  const tenantName = tenant?.name ?? getTenantName();
  const typeLabel = TYPE_LABEL[tx.transfer_type] ?? tx.transfer_type;
  const tempLabel = tx.shipping_temp ? (TEMP_LABEL[tx.shipping_temp] ?? tx.shipping_temp) : "—";
  const totalQty = items.reduce((s, it) => s + it.qty_shipped, 0);
  const totalEst = items.reduce((s, it) => s + (it.estimated_amount ?? 0), 0);

  return (
    <div className="copy-page bg-white p-2 font-mono text-[13px] leading-tight text-black shadow print:shadow-none">
      <div className="border-b-2 border-black pb-1 text-center">
        <div className="text-[14px] font-bold">{tenantName}</div>
        <div className="text-[20px] font-bold">{typeLabel}出貨單</div>
        <div className="mt-0.5 flex items-center justify-center gap-2">
          <span className="inline-block rounded border-2 border-black px-1.5 py-0.5 text-[13px] font-bold">
            {COPY_LABEL[kind]}
          </span>
          <span className="text-[13px] font-bold">{tx.transfer_no}</span>
        </div>
      </div>

      <div className="border-b border-dashed border-black py-1.5">
        <div className="text-[15px] font-bold">
          {tx.source_name} <span className="font-normal">→</span> {tx.dest_name}
        </div>
        <div className="text-[12px]">
          建立 {new Date(tx.created_at).toLocaleString("zh-TW", { hour12: false })}
        </div>
        <div className="text-[12px]">
          溫層 {tempLabel}{tx.is_air_transfer ? " · ✈ 空運" : ""}
        </div>
        {tx.shipped_at && (
          <div className="text-[12px]">
            出貨 {new Date(tx.shipped_at).toLocaleString("zh-TW", { hour12: false })}
          </div>
        )}
        {linkedOrder ? (
          <>
            <div className="text-[12px]">關聯訂單 {linkedOrder.order_no}</div>
            {/* 這一段的目的地不是最終收貨店（互助 Leg-1 只到總倉）→ 把最終收貨店框起來，
                總倉才知道這箱貨要再轉給誰 */}
            {linkedOrder.store_name && linkedOrder.via_next_leg && (
              <div className="mt-0.5 border border-black p-1 text-center text-[15px] font-bold">
                最終收貨店：{linkedOrder.store_name}
              </div>
            )}
          </>
        ) : (
          tx.customer_order_id != null && (
            <div className="text-[12px]">關聯訂單 #{tx.customer_order_id}</div>
          )
        )}
      </div>

      <table className="w-full border-collapse">
        <thead>
          <tr className="border-b border-black text-[12px]">
            <th className="w-5 py-1 text-left">#</th>
            <th className="py-1 text-left">品名 / 描述</th>
            <th className="w-9 py-1 text-right">應出</th>
            <th className="w-9 py-1 text-right">實出</th>
            <th className="w-8 py-1 text-center">點收</th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr><td colSpan={5} className="py-2 text-center text-zinc-500">無明細</td></tr>
          ) : (
            items.map((it, idx) => (
              <Fragment key={it.id}>
                <tr className="border-b border-dashed border-zinc-400">
                  <td className="py-1 align-top">{idx + 1}</td>
                  <td className="py-1 align-top">
                    {it.description ? (
                      <span className="break-words font-bold">{it.description}</span>
                    ) : (
                      <>
                        <span className="break-words font-bold">{it.sku_name || "—"}</span>
                        {it.variant_name && <span className="ml-1">/ {it.variant_name}</span>}
                        {it.sku_code && (
                          <div className="text-[10px] text-zinc-500">{it.sku_code}</div>
                        )}
                      </>
                    )}
                    {it.notes && (
                      <div className="text-[11px] italic">↳ {it.notes}</div>
                    )}
                  </td>
                  <td className="py-1 text-right align-top">{it.qty_requested}</td>
                  <td className="py-1 text-right align-top font-bold">{it.qty_shipped}</td>
                  <td className="py-1 text-center align-top text-[15px]">☐</td>
                </tr>
              </Fragment>
            ))
          )}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-black font-bold">
            <td colSpan={2} className="py-1 text-right">合計</td>
            <td className="py-1 text-right">{items.reduce((s, it) => s + it.qty_requested, 0)}</td>
            <td className="py-1 text-right">{totalQty}</td>
            <td className="py-1 text-center text-[11px]">{items.length} 項</td>
          </tr>
          {totalEst > 0 && (
            <tr>
              <td colSpan={3} className="py-0.5 text-right text-[12px]">估價合計</td>
              <td colSpan={2} className="py-0.5 text-right text-[12px] font-bold">${totalEst.toFixed(0)}</td>
            </tr>
          )}
        </tfoot>
      </table>

      {tx.notes && (
        <div className="mt-1.5 border border-black p-1.5 text-[12px]">
          <span className="font-bold">備註：</span>
          {tx.notes}
        </div>
      )}

      <div className="mt-1 text-right text-[10px] text-zinc-500">
        列印時間 {new Date().toLocaleString("zh-TW", { hour12: false })}
      </div>
    </div>
  );
}
