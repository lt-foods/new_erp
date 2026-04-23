"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Row = {
  id: number;
  sku_id: number;
  sku_code: string;
  sku_name: string;
  unit_price: number;
  cap_qty: number | null;
  sort_order: number;
  notes: string | null;
};

type SkuOption = { id: number; sku_code: string; name: string };

export function CampaignItemsTable({ campaignId }: { campaignId: number }) {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [skuQuery, setSkuQuery] = useState("");
  const [skuResults, setSkuResults] = useState<SkuOption[]>([]);
  const [adding, setAdding] = useState<{ sku: SkuOption; price: string; cap: string } | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = async () => {
    const { data, error: err } = await getSupabase()
      .from("campaign_items")
      .select("id, sku_id, unit_price, cap_qty, sort_order, notes, skus!inner(id, sku_code, name)")
      .eq("campaign_id", campaignId)
      .order("sort_order");
    if (err) { setError(err.message); return; }
    setRows(
      (data as unknown as Array<{
        id: number; sku_id: number; unit_price: number; cap_qty: number | null;
        sort_order: number; notes: string | null;
        skus: { id: number; sku_code: string; name: string };
      }>).map((r) => ({
        id: r.id, sku_id: r.sku_id, sku_code: r.skus.sku_code, sku_name: r.skus.name,
        unit_price: Number(r.unit_price), cap_qty: r.cap_qty != null ? Number(r.cap_qty) : null,
        sort_order: r.sort_order, notes: r.notes,
      }))
    );
  };

  useEffect(() => { reload(); }, [campaignId]);

  useEffect(() => {
    if (!skuQuery.trim()) { setSkuResults([]); return; }
    const t = setTimeout(async () => {
      const safe = skuQuery.replace(/[%,()]/g, " ").trim();
      const { data } = await getSupabase()
        .from("skus").select("id, sku_code, name")
        .or(`sku_code.ilike.%${safe}%,name.ilike.%${safe}%`)
        .limit(10);
      setSkuResults((data as SkuOption[]) ?? []);
    }, 250);
    return () => clearTimeout(t);
  }, [skuQuery]);

  async function addItem() {
    if (!adding) return;
    const price = Number(adding.price);
    if (!(price >= 0)) { setError("單價需 ≥ 0"); return; }
    try {
      const { error: err } = await getSupabase().rpc("rpc_upsert_campaign_item", {
        p_id: null,
        p_campaign_id: campaignId,
        p_sku_id: adding.sku.id,
        p_unit_price: price,
        p_cap_qty: adding.cap ? Number(adding.cap) : null,
        p_sort_order: (rows?.length ?? 0) + 1,
        p_notes: null,
      });
      if (err) throw err;
      setAdding(null); setSkuQuery(""); setSkuResults([]); setError(null);
      await reload();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }

  async function updatePrice(id: number, price: number) {
    const r = rows?.find((x) => x.id === id); if (!r) return;
    const { error: err } = await getSupabase().rpc("rpc_upsert_campaign_item", {
      p_id: id, p_campaign_id: campaignId, p_sku_id: r.sku_id, p_unit_price: price,
      p_cap_qty: r.cap_qty, p_sort_order: r.sort_order, p_notes: r.notes,
    });
    if (err) setError(err.message); else await reload();
  }

  async function deleteItem(id: number) {
    if (!confirm("確定刪除這項商品？")) return;
    const { error: err } = await getSupabase().rpc("rpc_delete_campaign_item", { p_id: id });
    if (err) setError(err.message); else await reload();
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">商品明細</h2>
        <span className="text-xs text-zinc-500">{rows?.length ?? 0} 項</span>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>SKU</Th><Th>名稱</Th><Th className="text-right">單價</Th><Th className="text-right">量上限</Th><Th>{""}</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={5} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">尚無商品，加一個吧</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id}>
                <Td className="font-mono">{r.sku_code}</Td>
                <Td>{r.sku_name}</Td>
                <Td className="text-right">
                  <input
                    type="number" step="0.0001" defaultValue={r.unit_price}
                    onBlur={(e) => { const n = Number(e.target.value); if (n !== r.unit_price) updatePrice(r.id, n); }}
                    className="w-24 rounded-md border border-zinc-300 px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                  />
                </Td>
                <Td className="text-right text-xs text-zinc-500">{r.cap_qty ?? "—"}</Td>
                <Td>
                  <button onClick={() => deleteItem(r.id)} className="text-xs text-red-600 hover:underline dark:text-red-400">刪除</button>
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="rounded-md border border-dashed border-zinc-300 p-3 dark:border-zinc-700">
        <div className="flex flex-wrap items-end gap-2">
          <div className="flex-1">
            <label className="text-xs text-zinc-500">搜尋 SKU</label>
            <input
              value={skuQuery}
              onChange={(e) => { setSkuQuery(e.target.value); setAdding(null); }}
              placeholder="SKU 編號 / 名稱"
              className="block w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </div>
        </div>
        {skuResults.length > 0 && !adding && (
          <ul className="mt-2 divide-y divide-zinc-200 rounded-md border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
            {skuResults.map((s) => (
              <li key={s.id}>
                <button
                  type="button"
                  onClick={() => setAdding({ sku: s, price: "", cap: "" })}
                  className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800"
                >
                  <span className="font-mono">{s.sku_code}</span>
                  <span className="text-zinc-600 dark:text-zinc-400">{s.name}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {adding && (
          <div className="mt-2 flex flex-wrap items-end gap-2 border-t border-zinc-200 pt-2 dark:border-zinc-800">
            <div className="text-sm">
              <div className="text-xs text-zinc-500">已選 SKU</div>
              <div className="font-mono">{adding.sku.sku_code}</div>
              <div className="text-xs text-zinc-600 dark:text-zinc-400">{adding.sku.name}</div>
            </div>
            <label className="text-sm">
              <div className="text-xs text-zinc-500">單價</div>
              <input type="number" step="0.0001" value={adding.price} onChange={(e) => setAdding({ ...adding, price: e.target.value })}
                className="w-28 rounded-md border border-zinc-300 px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800" />
            </label>
            <label className="text-sm">
              <div className="text-xs text-zinc-500">量上限</div>
              <input type="number" step="0.001" value={adding.cap} onChange={(e) => setAdding({ ...adding, cap: e.target.value })}
                className="w-28 rounded-md border border-zinc-300 px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800" />
            </label>
            <button type="button" onClick={addItem} className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white dark:bg-zinc-50 dark:text-zinc-900">加入</button>
            <button type="button" onClick={() => setAdding(null)} className="rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700">取消</button>
          </div>
        )}
      </div>
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-2 ${className}`}>{children}</td>;
}
