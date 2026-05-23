"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { PR_TERM_ZH } from "@/lib/prStatus";

type RestockRow = {
  id: number;
  requesting_store_id: number;
  store_name: string | null;
  status: string;
  notes: string | null;
  rejected_reason: string | null;
  requested_at: string;
  approved_at: string | null;
  rejected_at: string | null;
  linked_transfer_id: number | null;
  linked_pr_id: number | null;
  linked_transfer_no: string | null;
  linked_pr_no: string | null;
};

type Line = {
  id: number;
  sku_id: number;
  qty: number;
  unit_price: number;
  sku_code: string;
  sku_name: string;
  variant_name: string | null;
};

const STATUS_LABEL: Record<string, string> = {
  pending: "待處理",
  approved_transfer: "已派庫存",
  approved_pr: "已下訂",
  shipped: "已出貨",
  received: "已收貨",
  rejected: "已拒絕",
  cancelled: "已取消",
};

export default function RestockDetailModal({
  open,
  restockId,
  onClose,
}: {
  open: boolean;
  restockId: number | null;
  onClose: () => void;
}) {
  const [hd, setHd] = useState<RestockRow | null>(null);
  const [lines, setLines] = useState<Line[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open || restockId == null) { setHd(null); setLines(null); setErr(null); return; }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: rData, error: rErr } = await sb
        .from("restock_requests")
        .select(
          "id, requesting_store_id, status, notes, rejected_reason, requested_at, approved_at, rejected_at, linked_transfer_id, linked_pr_id, " +
            "stores(name), transfers(transfer_no), purchase_requests(pr_no)"
        )
        .eq("id", restockId)
        .maybeSingle();
      if (cancelled) return;
      if (rErr || !rData) {
        setErr(rErr?.message ?? "找不到此補貨申請");
        setHd(null);
        return;
      }
      type ApiR = {
        id: number;
        requesting_store_id: number;
        status: string;
        notes: string | null;
        rejected_reason: string | null;
        requested_at: string;
        approved_at: string | null;
        rejected_at: string | null;
        linked_transfer_id: number | null;
        linked_pr_id: number | null;
        stores: { name?: string } | { name?: string }[] | null;
        transfers: { transfer_no?: string } | { transfer_no?: string }[] | null;
        purchase_requests: { pr_no?: string } | { pr_no?: string }[] | null;
      };
      const r = rData as unknown as ApiR;
      const storeObj = Array.isArray(r.stores) ? r.stores[0] : r.stores;
      const txObj = Array.isArray(r.transfers) ? r.transfers[0] : r.transfers;
      const prObj = Array.isArray(r.purchase_requests) ? r.purchase_requests[0] : r.purchase_requests;
      setHd({
        id: r.id,
        requesting_store_id: r.requesting_store_id,
        store_name: storeObj?.name ?? null,
        status: r.status,
        notes: r.notes,
        rejected_reason: r.rejected_reason,
        requested_at: r.requested_at,
        approved_at: r.approved_at,
        rejected_at: r.rejected_at,
        linked_transfer_id: r.linked_transfer_id,
        linked_pr_id: r.linked_pr_id,
        linked_transfer_no: txObj?.transfer_no ?? null,
        linked_pr_no: prObj?.pr_no ?? null,
      });

      const { data: lData } = await sb
        .from("restock_request_lines")
        .select("id, sku_id, qty, unit_price, skus(sku_code, variant_name, products(name))")
        .eq("request_id", restockId)
        .order("id");
      if (cancelled) return;
      type ApiL = {
        id: number;
        sku_id: number;
        qty: number;
        unit_price: number;
        skus:
          | { sku_code: string; variant_name: string | null; products: { name?: string } | { name?: string }[] | null }
          | Array<{ sku_code: string; variant_name: string | null; products: { name?: string } | { name?: string }[] | null }>
          | null;
      };
      const rows: Line[] = ((lData ?? []) as unknown as ApiL[]).map((row) => {
        const skuObj = Array.isArray(row.skus) ? row.skus[0] : row.skus;
        const prodObj = skuObj ? (Array.isArray(skuObj.products) ? skuObj.products[0] : skuObj.products) : null;
        return {
          id: row.id,
          sku_id: row.sku_id,
          qty: Number(row.qty),
          unit_price: Number(row.unit_price),
          sku_code: skuObj?.sku_code ?? `#${row.sku_id}`,
          sku_name: prodObj?.name ?? "",
          variant_name: skuObj?.variant_name ?? null,
        };
      });
      setLines(rows);
    })();
    return () => {
      cancelled = true;
    };
  }, [open, restockId]);

  const total = (lines ?? []).reduce((acc, l) => acc + l.qty * l.unit_price, 0);
  const title = hd ? `📦 補貨申請 RESTOCK#${hd.id}` : "補貨申請";

  return (
    <Modal open={open} onClose={onClose} title={title} maxWidth="max-w-3xl">
      {err && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {err}
        </div>
      )}
      {!hd && !err && <p className="text-sm text-zinc-500">載入中…</p>}
      {hd && (
        <div className="space-y-4">
          <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
            <Field label="申請門市" value={hd.store_name ?? `#${hd.requesting_store_id}`} />
            <Field label="狀態" value={STATUS_LABEL[hd.status] ?? hd.status} />
            <Field label="申請時間" value={new Date(hd.requested_at).toLocaleString("zh-TW")} />
            <Field
              label="核可時間"
              value={hd.approved_at ? new Date(hd.approved_at).toLocaleString("zh-TW") : "—"}
            />
            {hd.linked_transfer_id != null && (
              <div className="col-span-2">
                <dt className="text-xs text-zinc-500">轉貨單</dt>
                <dd className="text-sm">
                  <Link
                    href={`/hq/inbox?source=transfer&id=${hd.linked_transfer_id}`}
                    className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {hd.linked_transfer_no ?? `#${hd.linked_transfer_id}`}
                  </Link>
                </dd>
              </div>
            )}
            {hd.linked_pr_id != null && (
              <div className="col-span-2">
                <dt className="text-xs text-zinc-500">{PR_TERM_ZH}</dt>
                <dd className="text-sm">
                  <Link
                    href={`/purchase/requests/edit?id=${hd.linked_pr_id}`}
                    className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {hd.linked_pr_no ?? `#${hd.linked_pr_id}`}
                  </Link>
                </dd>
              </div>
            )}
            {hd.status === "rejected" && hd.rejected_reason && (
              <Field label="拒絕原因" value={hd.rejected_reason} full />
            )}
            {hd.notes && <Field label="備註" value={hd.notes} full />}
          </dl>

          <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                  <th className="px-3 py-2">SKU</th>
                  <th className="px-3 py-2">品名 / 規格</th>
                  <th className="px-3 py-2 text-right">數量</th>
                  <th className="px-3 py-2 text-right">單價</th>
                  <th className="px-3 py-2 text-right">小計</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {lines === null ? (
                  <tr><td colSpan={5} className="p-4 text-center text-zinc-500">載入中…</td></tr>
                ) : lines.length === 0 ? (
                  <tr><td colSpan={5} className="p-4 text-center text-zinc-500">無明細</td></tr>
                ) : (
                  <>
                    {lines.map((l) => (
                      <tr key={l.id}>
                        <td className="px-3 py-2 font-mono text-xs">{l.sku_code}</td>
                        <td className="px-3 py-2 text-xs">
                          {l.sku_name || "—"}
                          {l.variant_name && <span className="ml-1 text-zinc-500">/ {l.variant_name}</span>}
                        </td>
                        <td className="px-3 py-2 text-right font-mono">{l.qty}</td>
                        <td className="px-3 py-2 text-right font-mono">${l.unit_price}</td>
                        <td className="px-3 py-2 text-right font-mono">${(l.qty * l.unit_price).toFixed(0)}</td>
                      </tr>
                    ))}
                    <tr className="bg-zinc-50 dark:bg-zinc-900">
                      <td colSpan={4} className="px-3 py-2 text-right text-xs text-zinc-500">合計</td>
                      <td className="px-3 py-2 text-right font-mono font-semibold">${total.toFixed(0)}</td>
                    </tr>
                  </>
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
      <dd className="text-sm text-zinc-900 dark:text-zinc-100 whitespace-pre-wrap">{value}</dd>
    </div>
  );
}
