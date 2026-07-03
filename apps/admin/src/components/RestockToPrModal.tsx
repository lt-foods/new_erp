"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { PR_TERM_ZH } from "@/lib/prStatus";

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
};

/**
 * 補貨申請「下訂單」品相選擇 Modal：
 * 勾選要開請購單的品相（明細），可分次為不同品相各開一張 PR。
 * 已開單的品相鎖定顯示其 PR 連結。
 */
export default function RestockToPrModal({
  open,
  restockId,
  onClose,
  onDone,
}: {
  open: boolean;
  restockId: number | null;
  onClose: () => void;
  /** 建單成功後呼叫（呼叫端 reload 列表） */
  onDone: () => void;
}) {
  // 以 restockId 為 key 存載入結果：換單/關閉不需同步 reset state（react-hooks/set-state-in-effect）
  const [loaded, setLoaded] = useState<{ restockId: number; lines: Line[] } | null>(null);
  const [checked, setChecked] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  const lines = open && restockId != null && loaded?.restockId === restockId ? loaded.lines : null;

  useEffect(() => {
    if (!open || restockId == null) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error } = await sb
        .from("restock_request_lines")
        .select("id, sku_id, qty, unit_price, linked_pr_id, purchase_requests(pr_no), skus(sku_code, variant_name, products(name))")
        .eq("request_id", restockId)
        .order("id");
      if (cancelled) return;
      if (error) {
        setErr(error.message);
        setLoaded({ restockId, lines: [] });
        return;
      }
      type ApiL = {
        id: number;
        sku_id: number;
        qty: number;
        unit_price: number;
        linked_pr_id: number | null;
        purchase_requests: { pr_no?: string } | { pr_no?: string }[] | null;
        skus:
          | { sku_code: string; variant_name: string | null; products: { name?: string } | { name?: string }[] | null }
          | Array<{ sku_code: string; variant_name: string | null; products: { name?: string } | { name?: string }[] | null }>
          | null;
      };
      const rows: Line[] = ((data ?? []) as unknown as ApiL[]).map((row) => {
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
          linked_pr_id: row.linked_pr_id,
          linked_pr_no: prObj?.pr_no ?? null,
        };
      });
      setErr(null);
      setLoaded({ restockId, lines: rows });
      // 預設全選尚未開單的品相
      setChecked(new Set(rows.filter((l) => l.linked_pr_id === null).map((l) => l.id)));
    })();
    return () => {
      cancelled = true;
    };
  }, [open, restockId, reload]);

  const openable = useMemo(() => (lines ?? []).filter((l) => l.linked_pr_id === null), [lines]);
  const selectedTotal = useMemo(
    () => (lines ?? []).filter((l) => checked.has(l.id)).reduce((acc, l) => acc + l.qty * l.unit_price, 0),
    [lines, checked]
  );

  function toggle(id: number) {
    setChecked((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function submit() {
    if (restockId == null || checked.size === 0) return;
    setBusy(true);
    setErr(null);
    try {
      const { error } = await getSupabase().rpc("rpc_approve_restock_lines_to_pr", {
        p_request_id: restockId,
        p_line_ids: Array.from(checked),
      });
      if (error) throw error;
      onDone();
      // 還有品相沒開單 → 留在 modal 續開下一張；全開完 → 關閉
      if (checked.size < openable.length) {
        setReload((t) => t + 1);
      } else {
        onClose();
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`📝 開${PR_TERM_ZH} — 補貨申請 #${restockId ?? ""}`} maxWidth="max-w-2xl">
      <div className="space-y-3">
        <p className="text-sm text-zinc-500">
          勾選要下訂的品相：勾選的品項會建成一張新的{PR_TERM_ZH}；可分次為不同品相各開一張。
        </p>

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                <th className="w-8 px-3 py-2" />
                <th className="px-3 py-2">SKU</th>
                <th className="px-3 py-2">品名 / 品相</th>
                <th className="px-3 py-2 text-right">數量</th>
                <th className="px-3 py-2 text-right">小計</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {lines === null ? (
                <tr><td colSpan={5} className="p-4 text-center text-zinc-500">載入中…</td></tr>
              ) : lines.length === 0 ? (
                <tr><td colSpan={5} className="p-4 text-center text-zinc-500">無明細</td></tr>
              ) : (
                lines.map((l) => {
                  const ordered = l.linked_pr_id !== null;
                  return (
                    <tr key={l.id} className={ordered ? "opacity-60" : "cursor-pointer"} onClick={() => !ordered && toggle(l.id)}>
                      <td className="px-3 py-2">
                        {ordered ? (
                          <span title="已開單">✅</span>
                        ) : (
                          <input
                            type="checkbox"
                            checked={checked.has(l.id)}
                            onChange={() => toggle(l.id)}
                            onClick={(e) => e.stopPropagation()}
                          />
                        )}
                      </td>
                      <td className="px-3 py-2 font-mono text-xs">{l.sku_code}</td>
                      <td className="px-3 py-2 text-xs">
                        {l.sku_name || "—"}
                        {l.variant_name && <span className="ml-1 text-zinc-500">/ {l.variant_name}</span>}
                        {ordered && (
                          <span className="ml-2">
                            →{" "}
                            <Link
                              href={`/purchase/requests/edit?id=${l.linked_pr_id}`}
                              className="font-mono text-blue-600 hover:underline dark:text-blue-400"
                              onClick={(e) => e.stopPropagation()}
                            >
                              {l.linked_pr_no ?? `${PR_TERM_ZH} #${l.linked_pr_id}`}
                            </Link>
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right font-mono">{l.qty}</td>
                      <td className="px-3 py-2 text-right font-mono">${(l.qty * l.unit_price).toFixed(0)}</td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>

        <div className="flex items-center justify-between">
          <span className="text-xs text-zinc-500">
            已選 {checked.size} / {openable.length} 個未開單品相 · 小計 ${selectedTotal.toFixed(0)}
          </span>
          <div className="flex gap-2">
            <SpinButton onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">
              取消
            </SpinButton>
            <SpinButton
              onClick={submit}
              disabled={busy || checked.size === 0}
              className="rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
            >
              {busy ? "建立中…" : `為勾選品相開一張${PR_TERM_ZH}`}
            </SpinButton>
          </div>
        </div>
      </div>
    </Modal>
  );
}
