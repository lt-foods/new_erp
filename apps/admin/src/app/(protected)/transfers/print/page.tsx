"use client";

// 轉貨單列印 — 司機聯 (隨貨交付司機) + 店家存根聯 (店內留存)
// query params:
//   transfer_id: 轉貨單 id (必填)
//   copies: 逗號分隔; 預設 "driver,stub"。可傳 "driver" 只印一份。

import { Fragment, Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { getTenantName } from "@/lib/tenant";
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
  shipped_at: string | null;
  received_at: string | null;
  created_at: string;
  source_name: string;
  dest_name: string;
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
            "shipping_temp, is_air_transfer, customer_order_id, shipped_at, received_at, created_at"
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
      <style jsx global>{`
        @media print {
          @page { size: A5; margin: 6mm; }
          body { background: white !important; }
          .no-print { display: none !important; }
          .copy-page { page-break-after: always; }
          .copy-page:last-child { page-break-after: auto; }
        }
        @media screen {
          .copy-page { margin-bottom: 24px; }
        }
      `}</style>
      <div className="mx-auto max-w-2xl p-4">
        <div className="no-print mb-3 flex justify-end gap-2">
          <SpinButton
            onClick={() => window.print()}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white hover:bg-zinc-700"
          >
            🖨️ 再次列印
          </SpinButton>
          <SpinButton
            onClick={() => window.close()}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100"
          >
            關閉
          </SpinButton>
        </div>

        {copies.map((kind, idx) => (
          <Slip key={`${kind}-${idx}`} kind={kind} tx={tx} items={items} />
        ))}
      </div>
    </>
  );
}

function Slip({ kind, tx, items }: { kind: CopyKind; tx: Transfer; items: Item[] }) {
  const typeLabel = TYPE_LABEL[tx.transfer_type] ?? tx.transfer_type;
  const tempLabel = tx.shipping_temp ? (TEMP_LABEL[tx.shipping_temp] ?? tx.shipping_temp) : "—";
  const totalQty = items.reduce((s, it) => s + it.qty_shipped, 0);
  const totalEst = items.reduce((s, it) => s + (it.estimated_amount ?? 0), 0);

  return (
    <div className="copy-page bg-white text-zinc-900">
      <div className="mb-2 flex items-baseline justify-between border-b-2 border-zinc-700 pb-1">
        <div>
          <div className="text-base font-semibold">{getTenantName()}</div>
          <div className="text-xl font-bold">{typeLabel}出貨單</div>
        </div>
        <div className="text-right">
          <div className="inline-block rounded border-2 border-zinc-700 px-2 py-0.5 text-sm font-bold">
            {COPY_LABEL[kind]}
          </div>
          <div className="mt-1 font-mono text-sm font-bold">{tx.transfer_no}</div>
        </div>
      </div>

      <table className="mb-2 w-full text-xs">
        <tbody>
          <tr>
            <td className="w-16 py-0.5 text-zinc-500">來源店</td>
            <td className="py-0.5 font-semibold">{tx.source_name}</td>
            <td className="w-16 py-0.5 text-zinc-500">目的店</td>
            <td className="py-0.5 font-semibold">{tx.dest_name}</td>
          </tr>
          <tr>
            <td className="py-0.5 text-zinc-500">建立</td>
            <td className="py-0.5 font-mono">{new Date(tx.created_at).toLocaleString("zh-TW")}</td>
            <td className="py-0.5 text-zinc-500">溫層</td>
            <td className="py-0.5">{tempLabel}{tx.is_air_transfer ? " · 空運" : ""}</td>
          </tr>
          {tx.shipped_at && (
            <tr>
              <td className="py-0.5 text-zinc-500">出貨</td>
              <td className="py-0.5 font-mono">{new Date(tx.shipped_at).toLocaleString("zh-TW")}</td>
              {tx.customer_order_id != null ? (
                <>
                  <td className="py-0.5 text-zinc-500">關聯訂單</td>
                  <td className="py-0.5 font-mono">#{tx.customer_order_id}</td>
                </>
              ) : (
                <>
                  <td className="py-0.5"></td>
                  <td className="py-0.5"></td>
                </>
              )}
            </tr>
          )}
        </tbody>
      </table>

      <table className="mb-2 w-full border-collapse text-xs">
        <thead>
          <tr className="border-y-2 border-zinc-700">
            <th className="w-8 px-1 py-1 text-left">#</th>
            <th className="px-1 py-1 text-left">品名 / 描述</th>
            <th className="w-16 px-1 py-1 text-right">應出</th>
            <th className="w-16 px-1 py-1 text-right">實出</th>
            <th className="w-12 px-1 py-1 text-center">點收</th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr><td colSpan={5} className="px-1 py-2 text-center text-zinc-500">無明細</td></tr>
          ) : (
            items.map((it, idx) => (
              <Fragment key={it.id}>
                <tr className="border-b border-zinc-200">
                  <td className="px-1 py-1 font-mono align-top">{idx + 1}</td>
                  <td className="px-1 py-1 align-top">
                    {it.description ? (
                      <span>{it.description}</span>
                    ) : (
                      <>
                        <span className="font-medium">{it.sku_name || "—"}</span>
                        {it.variant_name && <span className="ml-1 text-zinc-600">/ {it.variant_name}</span>}
                        {it.sku_code && (
                          <span className="ml-1 font-mono text-[10px] text-zinc-500">{it.sku_code}</span>
                        )}
                      </>
                    )}
                    {it.notes && (
                      <div className="text-[10px] italic text-zinc-600">↳ {it.notes}</div>
                    )}
                  </td>
                  <td className="px-1 py-1 text-right font-mono align-top">{it.qty_requested}</td>
                  <td className="px-1 py-1 text-right font-mono align-top font-semibold">{it.qty_shipped}</td>
                  <td className="px-1 py-1 text-center align-top">☐</td>
                </tr>
              </Fragment>
            ))
          )}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-zinc-700 font-semibold">
            <td colSpan={2} className="px-1 py-1 text-right">合計</td>
            <td className="px-1 py-1 text-right font-mono">{items.reduce((s, it) => s + it.qty_requested, 0)}</td>
            <td className="px-1 py-1 text-right font-mono">{totalQty}</td>
            <td className="px-1 py-1 text-center text-[10px] text-zinc-500">{items.length} 項</td>
          </tr>
          {totalEst > 0 && (
            <tr>
              <td colSpan={4} className="px-1 py-0.5 text-right text-[10px] text-zinc-600">估價合計</td>
              <td className="px-1 py-0.5 text-right font-mono text-[10px]">${totalEst.toFixed(0)}</td>
            </tr>
          )}
        </tfoot>
      </table>

      {tx.notes && (
        <div className="mb-2 rounded border border-zinc-300 p-1.5 text-[11px]">
          <span className="font-semibold">備註：</span>
          {tx.notes}
        </div>
      )}

      <div className="mt-1 text-right text-[9px] text-zinc-500">
        列印時間 {new Date().toLocaleString("zh-TW")}
      </div>
    </div>
  );
}
