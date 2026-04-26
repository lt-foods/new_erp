"use client";

import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";

export type Transfer = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  shipped_at: string | null;
  received_at: string | null;
  notes: string | null;
};

export type Wave = {
  id: number;
  wave_code: string;
  wave_date: string;
  created_at: string;
};

type TransferItem = {
  id: number;
  transfer_id: number;
  sku_id: number;
  qty_requested: number;
  qty_shipped: number;
  qty_received: number;
};

type Sku = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

export const TRANSFER_TYPE_LABEL: Record<string, string> = {
  hq_to_store: "總倉配送",
  store_to_store: "店轉店",
  return_to_hq: "退回龍潭",
};

export function parseWaveId(transferNo: string): number | null {
  const m = /^WAVE-(\d+)-S\d+$/.exec(transferNo);
  return m ? Number(m[1]) : null;
}

export function TransferReceiveModal({
  transfer,
  srcName,
  dstName,
  wave,
  onClose,
  onSubmitted,
}: {
  transfer: Transfer;
  srcName: string;
  dstName: string;
  wave: Wave | null;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [items, setItems] = useState<TransferItem[] | null>(null);
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [edits, setEdits] = useState<Map<number, string>>(new Map());
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const readOnly = transfer.status !== "shipped";

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: itemRows, error: e } = await sb
          .from("transfer_items")
          .select("id, transfer_id, sku_id, qty_requested, qty_shipped, qty_received")
          .eq("transfer_id", transfer.id)
          .order("id");
        if (e) throw new Error(e.message);
        const list = ((itemRows as TransferItem[] | null) ?? []).map((r) => ({
          ...r,
          qty_requested: Number(r.qty_requested),
          qty_shipped: Number(r.qty_shipped),
          qty_received: Number(r.qty_received),
        }));
        if (cancelled) return;
        setItems(list);

        const skuIds = Array.from(new Set(list.map((r) => r.sku_id)));
        if (skuIds.length > 0) {
          const { data: skuRows } = await sb
            .from("skus")
            .select("id, sku_code, product_name, variant_name")
            .in("id", skuIds);
          const m = new Map<number, Sku>();
          for (const s of (skuRows as Sku[] | null) ?? []) m.set(s.id, s);
          if (!cancelled) setSkus(m);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [transfer.id]);

  const totalShipped = useMemo(
    () => (items ?? []).reduce((s, r) => s + r.qty_shipped, 0),
    [items],
  );
  const totalReceived = useMemo(() => {
    if (!items) return 0;
    return items.reduce((s, r) => {
      if (readOnly) return s + r.qty_received;
      const e = edits.get(r.id);
      const v = e !== undefined ? Number(e) : r.qty_shipped;
      return s + (Number.isNaN(v) ? 0 : v);
    }, 0);
  }, [items, edits, readOnly]);
  const variance = totalReceived - totalShipped;

  function setQty(itemId: number, val: string) {
    setEdits((cur) => {
      const next = new Map(cur);
      next.set(itemId, val);
      return next;
    });
  }

  async function submit() {
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const lines: Array<{ transfer_item_id: number; qty_received: number }> = [];
      for (const it of items ?? []) {
        const e = edits.get(it.id);
        if (e === undefined) continue;
        const v = Number(e);
        if (Number.isNaN(v) || v < 0) {
          throw new Error(`item ${it.id}: 數量無效`);
        }
        if (v > it.qty_shipped) {
          throw new Error(`item ${it.id}: 收貨量不可大於出貨量 ${it.qty_shipped}`);
        }
        if (v !== it.qty_shipped) {
          lines.push({ transfer_item_id: it.id, qty_received: v });
        }
      }

      const { data, error: e } = await sb.rpc("rpc_receive_transfer", {
        p_transfer_id: transfer.id,
        p_lines: lines.length === 0 ? null : lines,
        p_operator: operator,
        p_notes: note.trim() === "" ? null : note.trim(),
      });
      if (e) throw new Error(e.message);

      const r = data as
        | {
            transfer_id: number;
            items_received: number;
            total_qty_received: number;
            total_variance: number;
          }
        | null;
      const varNote =
        r && Number(r.total_variance) < 0
          ? `\n⚠ 短收 ${Math.abs(Number(r.total_variance))}`
          : "";
      alert(
        `收貨完成：${r?.items_received ?? 0} 行，實收合計 ${r?.total_qty_received ?? 0}${varNote}`,
      );
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="flex max-h-[90vh] w-full max-w-3xl flex-col overflow-hidden rounded-md bg-white shadow-xl dark:bg-zinc-900">
        <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
          <div>
            <h2 className="font-semibold">
              收貨：<span className="font-mono">{transfer.transfer_no}</span>
            </h2>
            <div className="mt-0.5 text-xs text-zinc-500">
              {srcName} → {dstName} ·{" "}
              {TRANSFER_TYPE_LABEL[transfer.transfer_type] ?? transfer.transfer_type}
              {wave && (
                <>
                  {" · 來自撿貨單 "}
                  <span className="font-mono">{wave.wave_code}</span>
                </>
              )}
            </div>
          </div>
          <div className="flex gap-2">
            {readOnly ? (
              <span className="self-center rounded bg-emerald-100 px-2 py-1 text-xs text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                ✓ 已收貨
              </span>
            ) : (
              <button
                onClick={submit}
                disabled={submitting || !items}
                className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
              >
                {submitting ? "送出中…" : "確認收貨"}
              </button>
            )}
            <button
              onClick={onClose}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              關閉
            </button>
          </div>
        </div>

        <Timeline transfer={transfer} wave={wave} />

        {error && (
          <div className="border-b border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="overflow-auto p-3">
          {items === null ? (
            <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
          ) : (
            <Fragment>
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <th className="px-3 py-2 text-left text-xs uppercase text-zinc-500">商品</th>
                    <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">出貨</th>
                    <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">實收</th>
                    <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">差異</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {items.map((it) => {
                    const sku = skus.get(it.sku_id);
                    const editVal = edits.get(it.id);
                    const cur = readOnly
                      ? String(it.qty_received)
                      : editVal !== undefined
                      ? editVal
                      : String(it.qty_shipped);
                    const numCur = Number(cur);
                    const diff = !Number.isNaN(numCur) ? numCur - it.qty_shipped : 0;
                    const overflowing = !readOnly && numCur > it.qty_shipped;
                    return (
                      <tr key={it.id}>
                        <td className="px-3 py-2">
                          <div className="font-medium">{sku?.product_name ?? "—"}</div>
                          <div className="text-xs text-zinc-500">
                            {sku?.sku_code}
                            {sku?.variant_name ? ` / ${sku.variant_name}` : ""}
                          </div>
                        </td>
                        <td className="px-3 py-2 text-right font-mono text-zinc-600 dark:text-zinc-300">
                          {it.qty_shipped}
                        </td>
                        <td className="px-3 py-2 text-right">
                          <input
                            inputMode="decimal"
                            value={cur}
                            disabled={readOnly}
                            onChange={(e) => setQty(it.id, e.target.value)}
                            className={`w-20 rounded-md border px-2 py-0.5 text-right font-mono text-sm font-semibold ${
                              overflowing
                                ? "border-red-400 bg-red-50 dark:bg-red-950"
                                : editVal !== undefined
                                ? "border-amber-400 bg-amber-50 dark:bg-amber-950"
                                : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
                            } disabled:bg-zinc-100 disabled:opacity-70 dark:disabled:bg-zinc-800`}
                          />
                        </td>
                        <td
                          className={`px-3 py-2 text-right font-mono text-xs ${
                            diff === 0
                              ? "text-zinc-400"
                              : diff < 0
                              ? "text-red-600 dark:text-red-400"
                              : "text-purple-600 dark:text-purple-400"
                          }`}
                        >
                          {diff === 0 ? "—" : diff > 0 ? `+${diff}` : `${diff}`}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
                <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <td className="px-3 py-2 text-right text-xs font-semibold text-zinc-500">合計</td>
                    <td className="px-3 py-2 text-right font-mono font-semibold">{totalShipped}</td>
                    <td className="px-3 py-2 text-right font-mono font-semibold">{totalReceived}</td>
                    <td
                      className={`px-3 py-2 text-right font-mono text-xs font-semibold ${
                        variance === 0
                          ? "text-emerald-600 dark:text-emerald-400"
                          : variance < 0
                          ? "text-red-600 dark:text-red-400"
                          : "text-purple-600 dark:text-purple-400"
                      }`}
                    >
                      {variance === 0 ? "✓" : variance > 0 ? `+${variance}` : `${variance}`}
                    </td>
                  </tr>
                </tfoot>
              </table>

              {!readOnly && (
                <div className="mt-4">
                  <label className="block text-xs text-zinc-500">備註（短收 / 異常說明）</label>
                  <textarea
                    value={note}
                    onChange={(e) => setNote(e.target.value)}
                    rows={2}
                    className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                    placeholder="例：途中破損 2 件"
                  />
                </div>
              )}
              {readOnly && transfer.notes && (
                <div className="mt-4 rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-950 dark:text-zinc-300">
                  <div className="mb-1 text-zinc-500">備註</div>
                  <div className="whitespace-pre-line">{transfer.notes}</div>
                </div>
              )}
            </Fragment>
          )}
        </div>
      </div>
    </div>
  );
}

function Timeline({ transfer, wave }: { transfer: Transfer; wave: Wave | null }) {
  const steps: Array<{ label: string; ts: string | null; done: boolean }> = [
    { label: "撿貨單建立", ts: wave?.created_at ?? null, done: !!wave },
    { label: "派貨出倉", ts: transfer.shipped_at, done: !!transfer.shipped_at },
    { label: "收貨", ts: transfer.received_at, done: transfer.status === "received" },
  ];
  return (
    <div className="border-b border-zinc-200 bg-zinc-50 px-4 py-3 dark:border-zinc-800 dark:bg-zinc-950">
      <ol className="flex items-center gap-1 overflow-x-auto text-xs">
        {steps.map((s, i) => (
          <Fragment key={s.label}>
            <li className="flex min-w-0 items-center gap-2">
              <span
                className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold ${
                  s.done
                    ? "bg-emerald-600 text-white"
                    : "bg-zinc-300 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                }`}
              >
                {s.done ? "✓" : i + 1}
              </span>
              <div className="min-w-0">
                <div className={s.done ? "font-medium" : "text-zinc-500"}>{s.label}</div>
                {s.ts && (
                  <div className="text-[10px] text-zinc-500">
                    {new Date(s.ts).toLocaleString("zh-TW")}
                  </div>
                )}
              </div>
            </li>
            {i < steps.length - 1 && (
              <li
                aria-hidden
                className={`h-[1px] flex-1 ${
                  steps[i + 1].done ? "bg-emerald-400" : "bg-zinc-300 dark:bg-zinc-700"
                }`}
              />
            )}
          </Fragment>
        ))}
      </ol>
    </div>
  );
}
