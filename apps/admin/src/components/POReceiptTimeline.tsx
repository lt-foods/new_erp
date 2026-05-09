"use client";

// PO 完成度 timeline — 顯示一張 PO 的進貨歷程
// 用於:/wms/receiving 點 PO 列開 modal、未來可重用在 PO 編輯頁

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type POHead = {
  id: number;
  po_no: string;
  status: string;
  sent_at: string | null;
  supplier_name: string;
  supplier_code: string | null;
  is_restock: boolean;
};

type POLine = {
  po_item_id: number;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_ordered: number;
  qty_received: number;
  qty_damaged_total: number;
};

type GRRow = {
  id: number;
  gr_no: string;
  status: string;
  supplier_invoice_no: string | null;
  notes: string | null;
  receive_date: string;
  created_at: string;
  confirmed_at: string | null;
  received_by_name: string | null;
  total_qty: number;
  total_damaged: number;
  lines: GRLine[];
};

type GRLine = {
  po_item_id: number;
  sku_id: number;
  qty_received: number;
  qty_damaged: number;
  unit_cost: number;
  variance_reason: string | null;
};

const PO_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  sent: "🔴 未收",
  partially_received: "⏳ 部分收",
  fully_received: "✓ 全收",
  cancelled: "已取消",
};

const PO_STATUS_COLOR: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700",
  sent: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
  partially_received: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  fully_received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-400",
};

export function POReceiptTimeline({ poId }: { poId: number }) {
  const [po, setPO] = useState<POHead | null>(null);
  const [lines, setLines] = useState<POLine[] | null>(null);
  const [grs, setGRs] = useState<GRRow[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const [{ data: po, error: poErr }, { data: items, error: itemsErr }, { data: grHead, error: grErr }, { data: restocks }] = await Promise.all([
          sb.from("purchase_orders").select("id, po_no, status, sent_at, suppliers(code, name)").eq("id", poId).single(),
          sb.from("purchase_order_items").select("id, sku_id, qty_ordered, qty_received").eq("po_id", poId).order("id"),
          sb.from("goods_receipts").select("id, gr_no, status, supplier_invoice_no, notes, receive_date, created_at, confirmed_at, received_by").eq("po_id", poId).order("created_at", { ascending: true }),
          sb.from("restock_requests").select("linked_pr_id").not("linked_pr_id", "is", null),
        ]);
        if (poErr) throw new Error(poErr.message);
        if (itemsErr) throw new Error(itemsErr.message);
        if (grErr) throw new Error(grErr.message);

        type RawItem = { id: number; sku_id: number; qty_ordered: number; qty_received: number };
        const itemRows = (items ?? []) as RawItem[];
        const skuIds = Array.from(new Set(itemRows.map((r) => r.sku_id)));
        const skuMap = new Map<number, { code: string | null; product_name: string | null; variant_name: string | null }>();
        if (skuIds.length) {
          const { data: skuData } = await sb.from("skus").select("id, sku_code, variant_name, product_name").in("id", skuIds);
          for (const r of (skuData as Array<{ id: number; sku_code: string | null; variant_name: string | null; product_name: string | null }> | null) ?? []) {
            skuMap.set(r.id, { code: r.sku_code, product_name: r.product_name, variant_name: r.variant_name });
          }
        }

        // PO 是否來自 restock
        const restockPrIds = new Set(((restocks ?? []) as { linked_pr_id: number }[]).map((r) => r.linked_pr_id));
        const { data: priRows } = await sb
          .from("purchase_request_items")
          .select("po_item_id, pr_id")
          .in("po_item_id", itemRows.map((p) => p.id));
        const isRestock = ((priRows ?? []) as { po_item_id: number | null; pr_id: number }[])
          .some((r) => r.po_item_id !== null && restockPrIds.has(r.pr_id));

        // GR 明細
        const grHeadRows = (grHead ?? []) as Array<{ id: number; gr_no: string; status: string; supplier_invoice_no: string | null; notes: string | null; receive_date: string; created_at: string; confirmed_at: string | null; received_by: string | null }>;
        const grIds = grHeadRows.map((g) => g.id);
        const griByGr = new Map<number, GRLine[]>();
        const dmgByItem = new Map<number, number>();
        if (grIds.length) {
          const { data: griRows } = await sb.from("goods_receipt_items").select("gr_id, po_item_id, sku_id, qty_received, qty_damaged, unit_cost, variance_reason").in("gr_id", grIds);
          for (const it of ((griRows ?? []) as Array<{ gr_id: number; po_item_id: number; sku_id: number; qty_received: number; qty_damaged: number | null; unit_cost: number; variance_reason: string | null }>)) {
            const arr = griByGr.get(it.gr_id) ?? [];
            arr.push({
              po_item_id: it.po_item_id,
              sku_id: it.sku_id,
              qty_received: Number(it.qty_received),
              qty_damaged: Number(it.qty_damaged ?? 0),
              unit_cost: Number(it.unit_cost),
              variance_reason: it.variance_reason,
            });
            griByGr.set(it.gr_id, arr);
            dmgByItem.set(it.po_item_id, (dmgByItem.get(it.po_item_id) ?? 0) + Number(it.qty_damaged ?? 0));
          }
        }

        // operator 名稱
        const operatorIds = Array.from(new Set(grHeadRows.map((g) => g.received_by).filter((x): x is string => !!x)));
        const operatorMap = new Map<string, string>();
        if (operatorIds.length) {
          const { data: opRes } = await sb.rpc("rpc_get_staff_names", { p_uids: operatorIds });
          if (opRes) {
            for (const r of (opRes as Array<{ uid: string; name: string }>)) operatorMap.set(r.uid, r.name);
          }
        }

        const supplier = (() => {
          const s = (po as unknown as { suppliers: { code: string | null; name: string } | { code: string | null; name: string }[] | null }).suppliers;
          if (!s) return { code: null, name: "" };
          return Array.isArray(s) ? (s[0] ?? { code: null, name: "" }) : s;
        })();

        const poHead: POHead = {
          id: (po as { id: number }).id,
          po_no: (po as { po_no: string }).po_no,
          status: (po as { status: string }).status,
          sent_at: (po as { sent_at: string | null }).sent_at,
          supplier_name: supplier.name,
          supplier_code: supplier.code,
          is_restock: isRestock,
        };

        const poLines: POLine[] = itemRows.map((it) => {
          const sku = skuMap.get(it.sku_id);
          return {
            po_item_id: it.id,
            sku_id: it.sku_id,
            sku_code: sku?.code ?? null,
            sku_label: `${sku?.product_name ?? ""}${sku?.variant_name ? ` / ${sku.variant_name}` : ""}`,
            qty_ordered: Number(it.qty_ordered),
            qty_received: Number(it.qty_received ?? 0),
            qty_damaged_total: dmgByItem.get(it.id) ?? 0,
          };
        });

        const grRows: GRRow[] = grHeadRows.map((g) => {
          const grLines = griByGr.get(g.id) ?? [];
          return {
            id: g.id,
            gr_no: g.gr_no,
            status: g.status,
            supplier_invoice_no: g.supplier_invoice_no,
            notes: g.notes,
            receive_date: g.receive_date,
            created_at: g.created_at,
            confirmed_at: g.confirmed_at,
            received_by_name: g.received_by ? operatorMap.get(g.received_by) ?? null : null,
            total_qty: grLines.reduce((s, l) => s + l.qty_received, 0),
            total_damaged: grLines.reduce((s, l) => s + l.qty_damaged, 0),
            lines: grLines,
          };
        });

        if (!cancelled) {
          setPO(poHead);
          setLines(poLines);
          setGRs(grRows);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [poId]);

  if (error) return <div className="p-4 text-sm text-red-600">{error}</div>;
  if (!po || !lines) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  const totalOrdered = lines.reduce((s, l) => s + l.qty_ordered, 0);
  const totalReceived = lines.reduce((s, l) => s + l.qty_received, 0);
  const totalDamaged = lines.reduce((s, l) => s + l.qty_damaged_total, 0);
  const totalRemaining = Math.max(0, totalOrdered - totalReceived);
  const completionPct = totalOrdered > 0 ? Math.round((totalReceived / totalOrdered) * 100) : 0;
  const isFullyReceived = po.status === "fully_received";
  const totalShortage = isFullyReceived && totalReceived < totalOrdered ? totalOrdered - totalReceived : 0;
  const totalInTransit = !isFullyReceived ? totalRemaining : 0;

  return (
    <div className="flex flex-col gap-4 text-sm">
      {/* PO header */}
      <div className="flex flex-wrap items-start justify-between gap-3 rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <div>
          <div className="flex flex-wrap items-baseline gap-2">
            <span className="font-mono text-base font-semibold">{po.po_no}</span>
            <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${PO_STATUS_COLOR[po.status] ?? PO_STATUS_COLOR.draft}`}>{PO_STATUS_LABEL[po.status] ?? po.status}</span>
            {po.is_restock && <span className="inline-flex rounded bg-indigo-100 px-1.5 py-0.5 text-[10px] text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300">🔁 補貨來源</span>}
          </div>
          <div className="mt-1 text-xs text-zinc-500">
            {po.supplier_name}
            {po.supplier_code && <span className="ml-1 font-mono text-zinc-400">{po.supplier_code}</span>}
            {po.sent_at && <> · 送單 {new Date(po.sent_at).toLocaleDateString("zh-TW")}</>}
          </div>
        </div>
        <Link
          href={`/purchase/orders/receive?po=${po.id}`}
          className={`rounded-md px-3 py-1.5 text-sm font-semibold ${
            isFullyReceived
              ? "border border-zinc-300 text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700"
              : "bg-blue-600 text-white hover:bg-blue-700"
          }`}
        >
          {isFullyReceived ? "再次進貨" : "📥 進貨"}
        </Link>
      </div>

      {/* Progress + KPI */}
      <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mb-2 flex items-baseline justify-between">
          <span className="text-xs font-semibold text-zinc-700 dark:text-zinc-300">📊 整體進度</span>
          <span className="text-xs text-zinc-500">完成度 {completionPct}%</span>
        </div>
        <div className="mb-3 h-2 overflow-hidden rounded-full bg-zinc-100 dark:bg-zinc-800">
          <div
            className={`h-full transition-all ${isFullyReceived && totalShortage > 0 ? "bg-rose-500" : "bg-emerald-500"}`}
            style={{ width: `${Math.min(100, completionPct)}%` }}
          />
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-5">
          <KPI label="原訂購" value={totalOrdered} />
          <KPI label="累計已收" value={totalReceived} accent="text-emerald-700 dark:text-emerald-400" />
          <KPI label="瑕疵" value={totalDamaged} accent={totalDamaged > 0 ? "text-rose-700 dark:text-rose-400" : undefined} />
          <KPI label={isFullyReceived ? "—" : "在途"} value={totalInTransit} accent="text-amber-700 dark:text-amber-400" />
          <KPI label="短少" value={totalShortage} accent={totalShortage > 0 ? "text-rose-700 dark:text-rose-400" : undefined} />
        </div>
      </div>

      {/* Per-line breakdown */}
      <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="border-b border-zinc-200 px-3 py-2 text-xs font-semibold text-zinc-700 dark:border-zinc-800 dark:text-zinc-300">
          📦 各品項進度 ({lines.length})
        </div>
        <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
          <thead className="bg-zinc-50 text-zinc-500 dark:bg-zinc-900">
            <tr>
              <th className="px-3 py-2 text-left">品項</th>
              <th className="px-3 py-2 text-right">訂購</th>
              <th className="px-3 py-2 text-right">已到</th>
              <th className="px-3 py-2 text-right">瑕疵</th>
              <th className="px-3 py-2 text-right">差額</th>
              <th className="px-3 py-2 text-right">完成%</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {lines.map((l) => {
              const diff = l.qty_ordered - l.qty_received;
              const lp = l.qty_ordered > 0 ? Math.round((l.qty_received / l.qty_ordered) * 100) : 0;
              return (
                <tr key={l.po_item_id}>
                  <td className="px-3 py-2">
                    <div className="font-mono text-[10px] text-zinc-500">{l.sku_code ?? "—"}</div>
                    <div>{l.sku_label}</div>
                  </td>
                  <td className="px-3 py-2 text-right font-mono">{l.qty_ordered}</td>
                  <td className={`px-3 py-2 text-right font-mono ${l.qty_received < l.qty_ordered ? "" : "font-semibold text-emerald-700 dark:text-emerald-400"}`}>{l.qty_received}</td>
                  <td className={`px-3 py-2 text-right font-mono ${l.qty_damaged_total > 0 ? "text-rose-600" : "text-zinc-400"}`}>{l.qty_damaged_total}</td>
                  <td className={`px-3 py-2 text-right font-mono ${diff > 0 && isFullyReceived ? "font-bold text-rose-600" : diff > 0 ? "text-amber-600" : "text-zinc-400"}`}>
                    {diff === 0 ? "—" : `${diff}${diff > 0 && isFullyReceived ? " ⚠" : ""}`}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-zinc-500">{lp}%</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* GR Timeline */}
      <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="border-b border-zinc-200 px-3 py-2 text-xs font-semibold text-zinc-700 dark:border-zinc-800 dark:text-zinc-300">
          📜 進貨歷程 ({grs.length})
        </div>
        {grs.length === 0 ? (
          <div className="p-6 text-center text-xs text-zinc-500">尚未有任何 GR — 等待第一次進貨</div>
        ) : (
          <ol className="relative space-y-4 p-4">
            {grs.map((g, i) => {
              const isLast = i === grs.length - 1;
              const variances = g.lines.filter((l) => l.variance_reason);
              return (
                <li key={g.id} className="relative pl-6">
                  {/* timeline dot */}
                  <div className="absolute left-0 top-1.5 h-3 w-3 rounded-full border-2 border-emerald-500 bg-white dark:bg-zinc-900" />
                  {/* timeline line */}
                  {!isLast && <div className="absolute left-[5px] top-5 h-full w-px bg-zinc-200 dark:bg-zinc-800" />}
                  <div className="flex flex-wrap items-baseline gap-2">
                    <span className="font-mono text-xs">{g.gr_no}</span>
                    <span className={`inline-flex rounded px-1.5 py-0.5 text-[10px] ${
                      g.status === "confirmed" ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300" :
                      g.status === "draft" ? "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300" :
                      "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300"
                    }`}>{g.status}</span>
                    <span className="text-xs text-zinc-500">{new Date(g.created_at).toLocaleString("zh-TW")}</span>
                    {g.received_by_name && <span className="text-xs text-zinc-400">by {g.received_by_name}</span>}
                  </div>
                  <div className="mt-1 flex flex-wrap items-baseline gap-3 text-xs">
                    <span>實到 <span className="font-mono font-semibold">{g.total_qty}</span></span>
                    {g.total_damaged > 0 && <span className="text-rose-600">瑕疵 <span className="font-mono">{g.total_damaged}</span></span>}
                    {g.supplier_invoice_no && <span className="text-zinc-500">發票 <span className="font-mono">{g.supplier_invoice_no}</span></span>}
                  </div>
                  {g.notes && <div className="mt-1 text-xs text-zinc-500">📝 {g.notes}</div>}
                  {variances.length > 0 && (
                    <div className="mt-2 rounded border border-amber-200 bg-amber-50 p-2 text-[11px] dark:border-amber-800 dark:bg-amber-950/40">
                      {variances.map((v, idx) => {
                        const line = lines.find((l) => l.po_item_id === v.po_item_id);
                        return (
                          <div key={idx} className="text-amber-800 dark:text-amber-300">
                            <span className="font-mono text-[10px] text-zinc-500">{line?.sku_code ?? `#${v.po_item_id}`}</span>
                            <span className="mx-1">⚠</span>
                            <span>{v.variance_reason}</span>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </li>
              );
            })}
          </ol>
        )}
      </div>
    </div>
  );
}

function KPI({ label, value, accent = "text-zinc-900 dark:text-zinc-100" }: { label: string; value: number; accent?: string }) {
  return (
    <div className="rounded border border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-800 dark:bg-zinc-950">
      <div className="text-[10px] text-zinc-500">{label}</div>
      <div className={`font-mono text-lg font-semibold tabular-nums ${accent}`}>{value}</div>
    </div>
  );
}

export default POReceiptTimeline;
