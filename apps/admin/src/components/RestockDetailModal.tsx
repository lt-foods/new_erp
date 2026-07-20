"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { PR_TERM_ZH, prStatusLabel } from "@/lib/prStatus";
import { transferStatusLabel } from "@/lib/transferStatus";

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
  stockout_at: string | null;
  linked_transfer_id: number | null;
  linked_pr_id: number | null;
  linked_transfer_no: string | null;
  linked_pr_no: string | null;
  // 進度時間軸用：出貨/收貨時間只有轉貨單有，restock 表沒有這兩個時間戳
  transfer_status: string | null;
  transfer_shipped_at: string | null;
  transfer_received_at: string | null;
  pr_status: string | null;
};

type Line = {
  id: number;
  sku_id: number;
  qty: number;
  unit_price: number;
  sku_code: string;
  sku_name: string;
  variant_name: string | null;
  linked_pr_id: number | null;
  linked_pr_no: string | null;
  cancelled: boolean;
  stockout: boolean;
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
  const [hdState, setHd] = useState<RestockRow | null>(null);
  const [linesState, setLines] = useState<Line[] | null>(null);
  const [errState, setErr] = useState<string | null>(null);
  // 以 restockId 為 key 判斷載入結果是否屬於目前開啟的申請：
  // 換單/關閉不需同步 reset state（react-hooks/set-state-in-effect）
  const [loadedFor, setLoadedFor] = useState<number | null>(null);

  useEffect(() => {
    if (!open || restockId == null) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: rData, error: rErr } = await sb
        .from("restock_requests")
        .select(
          "id, requesting_store_id, status, notes, rejected_reason, requested_at, approved_at, rejected_at, stockout_at, linked_transfer_id, linked_pr_id, " +
            "stores(name), transfers(transfer_no, status, shipped_at, received_at), purchase_requests(pr_no, status)"
        )
        .eq("id", restockId)
        .maybeSingle();
      if (cancelled) return;
      if (rErr || !rData) {
        setErr(rErr?.message ?? "找不到此補貨申請");
        setHd(null);
        setLines(null);
        setLoadedFor(restockId);
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
        stockout_at: string | null;
        linked_transfer_id: number | null;
        linked_pr_id: number | null;
        stores: { name?: string } | { name?: string }[] | null;
        transfers:
          | { transfer_no?: string; status?: string; shipped_at?: string | null; received_at?: string | null }
          | { transfer_no?: string; status?: string; shipped_at?: string | null; received_at?: string | null }[]
          | null;
        purchase_requests: { pr_no?: string; status?: string } | { pr_no?: string; status?: string }[] | null;
      };
      const r = rData as unknown as ApiR;
      setErr(null);
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
        stockout_at: r.stockout_at,
        linked_transfer_id: r.linked_transfer_id,
        linked_pr_id: r.linked_pr_id,
        linked_transfer_no: txObj?.transfer_no ?? null,
        linked_pr_no: prObj?.pr_no ?? null,
        transfer_status: txObj?.status ?? null,
        transfer_shipped_at: txObj?.shipped_at ?? null,
        transfer_received_at: txObj?.received_at ?? null,
        pr_status: prObj?.status ?? null,
      });

      const { data: lData } = await sb
        .from("restock_request_lines")
        .select("id, sku_id, qty, unit_price, linked_pr_id, cancelled_at, stockout_at, purchase_requests(pr_no), skus(sku_code, variant_name, products(name))")
        .eq("request_id", restockId)
        .order("id");
      if (cancelled) return;
      type ApiL = {
        id: number;
        sku_id: number;
        qty: number;
        unit_price: number;
        linked_pr_id: number | null;
        cancelled_at: string | null;
        stockout_at: string | null;
        purchase_requests: { pr_no?: string } | { pr_no?: string }[] | null;
        skus:
          | { sku_code: string; variant_name: string | null; products: { name?: string } | { name?: string }[] | null }
          | Array<{ sku_code: string; variant_name: string | null; products: { name?: string } | { name?: string }[] | null }>
          | null;
      };
      const rows: Line[] = ((lData ?? []) as unknown as ApiL[]).map((row) => {
        const skuObj = Array.isArray(row.skus) ? row.skus[0] : row.skus;
        const prodObj = skuObj ? (Array.isArray(skuObj.products) ? skuObj.products[0] : skuObj.products) : null;
        const prObj = Array.isArray(row.purchase_requests) ? row.purchase_requests[0] : row.purchase_requests;
        return {
          id: row.id,
          sku_id: row.sku_id,
          qty: Number(row.qty),
          unit_price: Number(row.unit_price),
          sku_code: skuObj?.sku_code ?? `#${row.sku_id}`,
          sku_name: prodObj?.name ?? "",
          variant_name: skuObj?.variant_name ?? null,
          linked_pr_id: row.linked_pr_id ?? null,
          linked_pr_no: prObj?.pr_no ?? null,
          cancelled: row.cancelled_at !== null,
          stockout: row.stockout_at !== null,
        };
      });
      setLines(rows);
      setLoadedFor(restockId);
    })();
    return () => {
      cancelled = true;
    };
  }, [open, restockId]);

  const ready = open && restockId != null && loadedFor === restockId;
  const hd = ready ? hdState : null;
  const lines = ready ? linesState : null;
  const err = ready ? errState : null;

  const total = (lines ?? []).filter((l) => !l.cancelled).reduce((acc, l) => acc + l.qty * l.unit_price, 0);
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
                <dd className="flex items-center gap-2 text-sm">
                  <Link
                    href={`/hq/inbox?source=transfer&id=${hd.linked_transfer_id}`}
                    className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {hd.linked_transfer_no ?? `#${hd.linked_transfer_id}`}
                  </Link>
                  {hd.transfer_status && (
                    <span className="inline-flex rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                      {transferStatusLabel(hd.transfer_status)}
                    </span>
                  )}
                </dd>
              </div>
            )}
            {hd.linked_pr_id != null && (
              <div className="col-span-2">
                <dt className="text-xs text-zinc-500">{PR_TERM_ZH}</dt>
                <dd className="flex items-center gap-2 text-sm">
                  <Link
                    href={`/purchase/requests/edit?id=${hd.linked_pr_id}`}
                    className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {hd.linked_pr_no ?? `#${hd.linked_pr_id}`}
                  </Link>
                  {hd.pr_status && (
                    <span className="inline-flex rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                      {prStatusLabel(hd.pr_status)}
                    </span>
                  )}
                </dd>
              </div>
            )}
            {hd.status === "rejected" && hd.rejected_reason && (
              <Field label="拒絕原因" value={hd.rejected_reason} full />
            )}
            {hd.notes && <Field label="備註" value={hd.notes} full />}
          </dl>

          <ProgressTimeline hd={hd} />

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
                        <td className={`px-3 py-2 text-xs ${l.cancelled ? "line-through opacity-60" : ""}`}>
                          {l.sku_name || "—"}
                          {l.variant_name && <span className="ml-1 text-zinc-500">/ {l.variant_name}</span>}
                          {l.cancelled && <span className="ml-2 text-red-600 no-underline dark:text-red-400">{l.stockout ? "⛔ 斷貨" : "已刪除"}</span>}
                          {l.linked_pr_id != null && (
                            <div>
                              <Link
                                href={`/purchase/requests/edit?id=${l.linked_pr_id}`}
                                className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                              >
                                → {l.linked_pr_no ?? `${PR_TERM_ZH} #${l.linked_pr_id}`}
                              </Link>
                            </div>
                          )}
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

// ---------------------------------------------------------------
// 進度時間軸：申請 → 核可 → 出貨 → 收貨
// 出貨/收貨時間只有轉貨單有（restock 表沒這兩個時間戳），
// 完成度取 restock.status 與 transfer.status 的較高者。
// ---------------------------------------------------------------
type StepState = "done" | "current" | "todo" | "reject" | "cancel";
type Step = { key: string; label: string; at: string | null; state: StepState; note?: string };

function ProgressTimeline({ hd }: { hd: RestockRow }) {
  const st = hd.status;

  // 終端狀態：拒絕 / 取消 → 申請 + 終端節點
  if (st === "rejected" || st === "cancelled") {
    const steps: Step[] = [
      { key: "requested", label: "申請", at: hd.requested_at, state: "done" },
      st === "rejected"
        ? { key: "terminal", label: "已拒絕", at: hd.rejected_at, state: "reject", note: hd.rejected_reason ?? undefined }
        : hd.stockout_at
          ? { key: "terminal", label: "⛔ 斷貨取消", at: hd.stockout_at, state: "reject", note: "採購斷貨，供應商無法供貨" }
          : { key: "terminal", label: "已取消", at: null, state: "cancel" },
    ];
    return <Timeline steps={steps} />;
  }

  // reached level = max(restock, transfer)
  const restockLevel =
    st === "received" ? 3 : st === "shipped" ? 2 : st === "approved_transfer" || st === "approved_pr" ? 1 : 0;
  const ts = hd.transfer_status;
  const transferLevel = ts === "received" || ts === "closed" ? 3 : ts === "shipped" ? 2 : ts === "confirmed" ? 1 : 0;
  const reached = Math.max(restockLevel, transferLevel);
  const stateOf = (level: number): StepState => (level <= reached ? "done" : level === reached + 1 ? "current" : "todo");

  // 核可方式：派庫存 / 採購 / 兩者
  const approveNote =
    hd.linked_transfer_id != null && hd.linked_pr_id != null
      ? "派庫存 + 採購"
      : hd.linked_transfer_id != null
        ? "派庫存"
        : hd.linked_pr_id != null
          ? "採購"
          : undefined;

  const steps: Step[] = [
    { key: "requested", label: "申請", at: hd.requested_at, state: "done" },
    { key: "approved", label: "核可", at: hd.approved_at, state: stateOf(1), note: approveNote },
    { key: "shipped", label: "出貨", at: hd.transfer_shipped_at, state: stateOf(2) },
    { key: "received", label: "收貨", at: hd.transfer_received_at, state: stateOf(3) },
  ];
  return <Timeline steps={steps} />;
}

function Timeline({ steps }: { steps: Step[] }) {
  return (
    <div className="rounded-md border border-zinc-200 p-4 dark:border-zinc-800">
      <div className="mb-3 text-xs font-medium uppercase tracking-wide text-zinc-500">進度</div>
      <ol>
        {steps.map((s, i) => {
          const last = i === steps.length - 1;
          return (
            <li key={s.key} className="flex gap-3">
              <div className="flex flex-col items-center">
                <span className={dotCls(s.state)} />
                {!last && (
                  <span
                    className={`w-px flex-1 ${s.state === "done" ? "bg-emerald-400 dark:bg-emerald-600" : "bg-zinc-200 dark:bg-zinc-700"}`}
                  />
                )}
              </div>
              <div className={last ? "pb-0" : "pb-5"}>
                <div className="flex flex-wrap items-baseline gap-x-2">
                  <span className={labelCls(s.state)}>{s.label}</span>
                  <span className="text-xs text-zinc-400">
                    {s.at ? new Date(s.at).toLocaleString("zh-TW") : s.state === "current" ? "目前" : ""}
                  </span>
                </div>
                {s.note && <div className="mt-0.5 text-xs text-zinc-500">{s.note}</div>}
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

function dotCls(state: StepState): string {
  const base = "mt-1 h-2.5 w-2.5 shrink-0 rounded-full ring-4 ring-white dark:ring-zinc-900 ";
  switch (state) {
    case "done":
      return base + "bg-emerald-500";
    case "current":
      return base + "bg-blue-500 ring-blue-100 dark:ring-blue-950";
    case "reject":
      return base + "bg-red-500";
    case "cancel":
      return base + "bg-zinc-400";
    default:
      return base + "bg-zinc-300 dark:bg-zinc-600";
  }
}

function labelCls(state: StepState): string {
  switch (state) {
    case "current":
      return "text-sm font-semibold text-blue-700 dark:text-blue-300";
    case "todo":
      return "text-sm text-zinc-400";
    case "reject":
      return "text-sm font-semibold text-red-600 dark:text-red-400";
    case "cancel":
      return "text-sm font-medium text-zinc-500";
    default:
      return "text-sm font-medium text-zinc-900 dark:text-zinc-100";
  }
}
