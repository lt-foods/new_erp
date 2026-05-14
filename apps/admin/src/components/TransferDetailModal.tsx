"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";

type TransferRow = {
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
  source_name: string | null;
  dest_name: string | null;
};

type Item = {
  id: number;
  sku_id: number;
  qty_requested: number;
  qty_shipped: number;
  qty_received: number | null;
  sku_code: string;
  sku_name: string;
  variant_name: string | null;
};

const TYPE_LABEL: Record<string, string> = {
  hq_to_store: "總倉派貨",
  store_to_store: "店轉店",
  store_to_hq: "店退總倉",
  return_to_hq: "退貨回總倉",
  aid_handoff: "互助轉移",
};
const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  confirmed: "已確認",
  shipped: "已出貨",
  received: "已收貨",
  cancelled: "已取消",
  closed: "已結案",
};

export default function TransferDetailModal({
  open,
  transferId,
  onClose,
}: {
  open: boolean;
  transferId: number | null;
  onClose: () => void;
}) {
  const [tx, setTx] = useState<TransferRow | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open || transferId == null) { setTx(null); setItems(null); setErr(null); return; }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      // 用 join locations 取名稱
      const { data: tDataRaw, error: tErr } = await sb
        .from("transfers")
        .select(
          "id, transfer_no, source_location, dest_location, status, transfer_type, notes, " +
            "shipping_temp, is_air_transfer, customer_order_id, shipped_at, received_at, created_at"
        )
        .eq("id", transferId)
        .maybeSingle();
      if (cancelled) return;
      if (tErr || !tDataRaw) {
        setErr(tErr?.message ?? "找不到此單");
        setTx(null);
        return;
      }
      const tData = tDataRaw as unknown as Omit<TransferRow, "source_name" | "dest_name">;

      const [{ data: locs }, { data: tis }] = await Promise.all([
        sb.from("locations").select("id, name").in("id", [tData.source_location, tData.dest_location]),
        sb
          .from("transfer_items")
          .select("id, sku_id, qty_requested, qty_shipped, qty_received")
          .eq("transfer_id", transferId)
          .order("id"),
      ]);
      if (cancelled) return;
      const locArr = (locs ?? []) as { id: number; name: string }[];
      const locMap = new Map<number, string>(locArr.map((l) => [l.id, l.name]));
      setTx({
        ...tData,
        source_name: locMap.get(tData.source_location) ?? null,
        dest_name: locMap.get(tData.dest_location) ?? null,
      });

      type ApiItem = {
        id: number;
        sku_id: number;
        qty_requested: number | null;
        qty_shipped: number | null;
        qty_received: number | null;
      };
      const tiRows = (tis ?? []) as ApiItem[];

      // transfer_items.sku_id 沒設 FK，所以分開撈 skus + products
      const skuIds = Array.from(new Set(tiRows.map((r) => r.sku_id))).filter((x) => x != null);
      type SkuJoined = {
        id: number;
        sku_code: string;
        variant_name: string | null;
        product_id: number | null;
      };
      let skuMap = new Map<number, { code: string; variant: string | null; name: string }>();
      if (skuIds.length > 0) {
        const { data: skuRows } = await sb
          .from("skus")
          .select("id, sku_code, variant_name, product_id")
          .in("id", skuIds);
        const skus = (skuRows ?? []) as SkuJoined[];
        const prodIds = Array.from(new Set(skus.map((s) => s.product_id).filter((x): x is number => x != null)));
        let prodMap = new Map<number, string>();
        if (prodIds.length > 0) {
          const { data: prods } = await sb.from("products").select("id, name").in("id", prodIds);
          prodMap = new Map(((prods ?? []) as { id: number; name: string }[]).map((p) => [p.id, p.name]));
        }
        skuMap = new Map(skus.map((s) => [s.id, {
          code: s.sku_code,
          variant: s.variant_name,
          name: s.product_id != null ? (prodMap.get(s.product_id) ?? "") : "",
        }]));
      }
      if (cancelled) return;

      const rows: Item[] = tiRows.map((r) => {
        const sku = skuMap.get(r.sku_id);
        return {
          id: r.id,
          sku_id: r.sku_id,
          qty_requested: Number(r.qty_requested ?? 0),
          qty_shipped: Number(r.qty_shipped ?? 0),
          qty_received: r.qty_received == null ? null : Number(r.qty_received),
          sku_code: sku?.code ?? `#${r.sku_id}`,
          sku_name: sku?.name ?? "",
          variant_name: sku?.variant ?? null,
        };
      });
      setItems(rows);
    })();
    return () => {
      cancelled = true;
    };
  }, [open, transferId]);

  const title = tx ? `🚚 ${tx.transfer_no}` : "轉貨單";

  return (
    <Modal open={open} onClose={onClose} title={title} maxWidth="max-w-3xl">
      {err && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {err}
        </div>
      )}
      {!tx && !err && <p className="text-sm text-zinc-500">載入中…</p>}
      {tx && (
        <div className="space-y-4">
          <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
            <Field label="類型" value={TYPE_LABEL[tx.transfer_type] ?? tx.transfer_type} />
            <Field label="狀態" value={STATUS_LABEL[tx.status] ?? tx.status} />
            <Field label="來源" value={tx.source_name ?? `#${tx.source_location}`} />
            <Field label="目的" value={tx.dest_name ?? `#${tx.dest_location}`} />
            <Field label="建立時間" value={new Date(tx.created_at).toLocaleString("zh-TW")} />
            <Field
              label="出貨時間"
              value={tx.shipped_at ? new Date(tx.shipped_at).toLocaleString("zh-TW") : "—"}
            />
            <Field
              label="收貨時間"
              value={tx.received_at ? new Date(tx.received_at).toLocaleString("zh-TW") : "—"}
            />
            <Field label="溫層 / 空運" value={`${tx.shipping_temp ?? "—"}${tx.is_air_transfer ? " · ✈ 空運" : ""}`} />
            {tx.customer_order_id != null && (
              <Field label="關聯訂單" value={`#${tx.customer_order_id}`} />
            )}
            {tx.notes && <Field label="備註" value={tx.notes} full />}
          </dl>

          <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                  <th className="px-3 py-2">SKU</th>
                  <th className="px-3 py-2">品名 / 規格</th>
                  <th className="px-3 py-2 text-right">應出</th>
                  <th className="px-3 py-2 text-right">已出</th>
                  <th className="px-3 py-2 text-right">已收</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {items === null ? (
                  <tr><td colSpan={5} className="p-4 text-center text-zinc-500">載入中…</td></tr>
                ) : items.length === 0 ? (
                  <tr><td colSpan={5} className="p-4 text-center text-zinc-500">無明細</td></tr>
                ) : (
                  items.map((it) => (
                    <tr key={it.id}>
                      <td className="px-3 py-2 font-mono text-xs">{it.sku_code}</td>
                      <td className="px-3 py-2 text-xs">
                        {it.sku_name || "—"}
                        {it.variant_name && <span className="ml-1 text-zinc-500">/ {it.variant_name}</span>}
                      </td>
                      <td className="px-3 py-2 text-right font-mono">{it.qty_requested}</td>
                      <td className="px-3 py-2 text-right font-mono">{it.qty_shipped}</td>
                      <td className="px-3 py-2 text-right font-mono">{it.qty_received ?? "—"}</td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </Modal>
  );
}

function Field({ label, value, full = false }: { label: string; value: string; full?: boolean }) {
  return (
    <div className={full ? "col-span-2" : ""}>
      <dt className="text-xs text-zinc-500">{label}</dt>
      <dd className="text-sm text-zinc-900 dark:text-zinc-100">{value}</dd>
    </div>
  );
}
