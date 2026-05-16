"use client";

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";

type STHead = {
  id: number;
  stocktake_no: string;
  location_id: number;
  type: string;
  status: string;
  notes: string | null;
};
type STItem = {
  id: number;
  sku_id: number;
  system_qty: number;
  counted_qty: number | null;
  diff_qty: number | null;
  adjustment_movement_id: number | null;
};
type Sku = { id: number; sku_code: string; product_name: string | null; variant_name: string | null };

const TYPE_LABEL: Record<string, string> = { full: "全盤", partial: "部分", cycle: "循環" };
const STATUS_LABEL: Record<string, string> = {
  draft: "草稿", counting: "盤點中", review: "覆核中", adjusted: "已調整", cancelled: "已取消",
};

export default function StocktakeSessionPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <SessionInner />
    </Suspense>
  );
}

function SessionInner() {
  const sp = useSearchParams();
  const id = Number(sp.get("id"));
  const [head, setHead] = useState<STHead | null>(null);
  const [items, setItems] = useState<STItem[] | null>(null);
  const [skuMap, setSkuMap] = useState<Map<number, Sku>>(new Map());
  const [locName, setLocName] = useState<string>("");
  const [counts, setCounts] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);
  const [tick, setTick] = useState(0);

  const load = useCallback(async () => {
    if (!id) { setNotFound(true); return; }
    const sb = getSupabase();
    const { data: h } = await sb.from("stocktakes")
      .select("id, stocktake_no, location_id, type, status, notes").eq("id", id).maybeSingle();
    if (!h) { setNotFound(true); return; }
    setHead(h as STHead);
    const { data: locRow } = await sb.from("locations").select("name").eq("id", (h as STHead).location_id).maybeSingle();
    const { data: stRow } = await sb.from("stores").select("name").eq("location_id", (h as STHead).location_id).maybeSingle();
    setLocName((stRow as { name?: string } | null)?.name ?? (locRow as { name?: string } | null)?.name ?? `#${(h as STHead).location_id}`);
    const { data: its } = await sb.from("stocktake_items")
      .select("id, sku_id, system_qty, counted_qty, diff_qty, adjustment_movement_id")
      .eq("stocktake_id", id).order("id");
    const list = ((its as STItem[]) ?? []).map((x) => ({
      ...x,
      system_qty: Number(x.system_qty),
      counted_qty: x.counted_qty == null ? null : Number(x.counted_qty),
      diff_qty: x.diff_qty == null ? null : Number(x.diff_qty),
    }));
    setItems(list);
    const init: Record<number, string> = {};
    for (const it of list) if (it.counted_qty != null) init[it.id] = String(it.counted_qty);
    setCounts(init);
    const ids = Array.from(new Set(list.map((x) => x.sku_id)));
    if (ids.length) {
      const { data: sk } = await sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", ids);
      const m = new Map<number, Sku>();
      for (const s of (sk as Sku[]) ?? []) m.set(s.id, s);
      setSkuMap(m);
    }
  }, [id]);

  useEffect(() => { load(); }, [load, tick]);

  const editable = head?.status === "draft" || head?.status === "counting";
  const reviewable = head?.status === "review";
  const terminal = head?.status === "adjusted" || head?.status === "cancelled";

  const diffNow = useMemo(() => {
    const m: Record<number, number | null> = {};
    for (const it of items ?? []) {
      const raw = counts[it.id];
      m[it.id] = raw === undefined || raw === "" ? it.diff_qty : Number(raw) - it.system_qty;
    }
    return m;
  }, [items, counts]);

  async function call(fn: string, extra: Record<string, unknown> = {}) {
    setBusy(true); setError(null);
    try {
      const { error: e } = await getSupabase().rpc(fn, { p_stocktake_id: id, ...extra });
      if (e) throw e;
      setTick((n) => n + 1);
    } catch (e) { setError(translateRpcError(e)); } finally { setBusy(false); }
  }

  async function saveCounts() {
    const lines = (items ?? [])
      .filter((it) => counts[it.id] !== undefined && counts[it.id] !== "")
      .map((it) => ({ item_id: it.id, counted_qty: Number(counts[it.id]) }));
    if (lines.length === 0) { setError("請至少輸入一筆盤點數量"); return; }
    await call("rpc_save_stocktake_counts", { p_counts: lines });
  }

  if (notFound) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-sm text-zinc-500">
        <p>找不到此盤點單（可能不存在或無權限）。</p>
        <Link href="/inventory/stocktake" className="text-blue-600 hover:underline dark:text-blue-400">← 回盤點列表</Link>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">
            盤點 {head?.stocktake_no ?? "…"}
            {head && <span className="ml-2 text-sm font-normal text-zinc-500">{locName} · {TYPE_LABEL[head.type] ?? head.type} · {STATUS_LABEL[head.status] ?? head.status}</span>}
          </h1>
          <Link href="/inventory/stocktake" className="text-sm text-blue-600 hover:underline dark:text-blue-400">← 盤點列表</Link>
        </div>
        <div className="flex flex-wrap gap-2">
          {editable && (
            <>
              <SpinButton onClick={saveCounts} disabled={busy}
                className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800">
                儲存盤點數
              </SpinButton>
              <SpinButton onClick={() => call("rpc_submit_stocktake")} disabled={busy}
                className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">
                提交覆核
              </SpinButton>
            </>
          )}
          {reviewable && (
            <SpinButton
              onClick={() => { if (confirm("套用調整？將依差異產生庫存異動、不可復原。")) call("rpc_apply_stocktake"); }}
              disabled={busy}
              className="rounded-md bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-700">
              套用調整
            </SpinButton>
          )}
          {!terminal && head && (
            <SpinButton
              onClick={() => { const r = prompt("取消盤點原因（選填）"); if (r !== null) call("rpc_cancel_stocktake", { p_reason: r || null }); }}
              disabled={busy}
              className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700">
              取消盤點
            </SpinButton>
          )}
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}
      {head?.status === "adjusted" && (
        <div className="rounded-md border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
          已套用調整，庫存已依差異更新（唯讀）。
        </div>
      )}

      <Table>
        <THead>
          <Th>商品 / SKU</Th>
          <Th align="right">系統量</Th>
          <Th align="right">盤點量</Th>
          <Th align="right">差異</Th>
          <Th align="right">調整異動</Th>
        </THead>
        <TBody>
          {items === null ? (
            <LoadingRow colSpan={5} />
          ) : items.length === 0 ? (
            <EmptyRow colSpan={5}>此盤點單無品項。</EmptyRow>
          ) : (
            items.map((it) => {
              const s = skuMap.get(it.sku_id);
              const d = diffNow[it.id];
              return (
                <Tr key={it.id}>
                  <Td>
                    <div className="font-medium text-zinc-900 dark:text-zinc-100">
                      {s?.product_name ?? "—"}{s?.variant_name ? <span className="ml-1 text-zinc-500">/ {s.variant_name}</span> : null}
                    </div>
                    <div className="font-mono text-xs text-zinc-500">{s?.sku_code ?? `sku#${it.sku_id}`}</div>
                  </Td>
                  <Td align="right" className="font-mono">{it.system_qty}</Td>
                  <Td align="right">
                    {editable ? (
                      <input type="number" min="0" step="1"
                        value={counts[it.id] ?? ""}
                        onChange={(e) => setCounts((m) => ({ ...m, [it.id]: e.target.value }))}
                        className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800" />
                    ) : (
                      <span className="font-mono">{it.counted_qty ?? "—"}</span>
                    )}
                  </Td>
                  <Td align="right" className={`font-mono ${d == null ? "text-zinc-400" : d > 0 ? "text-emerald-600 dark:text-emerald-400" : d < 0 ? "text-red-600 dark:text-red-400" : "text-zinc-500"}`}>
                    {d == null ? "—" : d > 0 ? `+${d}` : d}
                  </Td>
                  <Td align="right" className="font-mono text-xs text-zinc-500">
                    {it.adjustment_movement_id ? `#${it.adjustment_movement_id}` : "—"}
                  </Td>
                </Tr>
              );
            })
          )}
        </TBody>
      </Table>
    </div>
  );
}
