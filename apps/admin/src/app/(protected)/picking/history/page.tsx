"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Wave = {
  id: number;
  wave_code: string;
  wave_date: string;
  status: string;
  store_count: number;
  item_count: number;
  total_qty: number;
  note: string | null;
  created_at: string;
};

type WaveItem = {
  id: number;
  sku_id: number;
  store_id: number;
  qty: number;
  picked_qty: number | null;
  generated_transfer_id: number | null;
};

type Store = { id: number; name: string };
type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  picking: "撿貨中",
  picked: "撿貨完成",
  shipped: "已派貨",
  cancelled: "已取消",
};

const STATUS_COLOR: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  picking: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  picked: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  shipped: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

export default function PickingHistoryPage() {
  const [waves, setWaves] = useState<Wave[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Wave | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("picking_waves")
          .select("id, wave_code, wave_date, status, store_count, item_count, total_qty, note, created_at")
          .order("created_at", { ascending: false })
          .limit(50);
        if (e) throw new Error(e.message);
        if (!cancelled) {
          setWaves(((data as Wave[] | null) ?? []).map((r) => ({ ...r, total_qty: Number(r.total_qty) })));
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">撿貨歷史</h1>
          <p className="text-sm text-zinc-500">
            {waves === null ? "載入中…" : `共 ${waves.length} 張撿貨單`}
          </p>
        </div>
        <a
          href="/picking/workstation"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          + 至撿貨工作站
        </a>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>撿貨單號</Th>
              <Th>配送日</Th>
              <Th>狀態</Th>
              <Th className="text-right">分店</Th>
              <Th className="text-right">SKU</Th>
              <Th className="text-right">總量</Th>
              <Th>備註</Th>
              <Th>建立</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {waves !== null && waves.length === 0 && (
              <tr>
                <td colSpan={9} className="p-6 text-center text-sm text-zinc-500">
                  尚無撿貨單，請至「撿貨工作站」建立。
                </td>
              </tr>
            )}
            {waves?.map((w) => (
              <tr key={w.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <td className="px-3 py-2 font-mono">{w.wave_code}</td>
                <td className="px-3 py-2">{w.wave_date}</td>
                <td className="px-3 py-2">
                  <span
                    className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[w.status] ?? ""}`}
                  >
                    {STATUS_LABEL[w.status] ?? w.status}
                  </span>
                </td>
                <td className="px-3 py-2 text-right font-mono">{w.store_count}</td>
                <td className="px-3 py-2 text-right font-mono">{w.item_count}</td>
                <td className="px-3 py-2 text-right font-mono">{w.total_qty}</td>
                <td className="px-3 py-2 text-xs text-zinc-500">{w.note ?? "—"}</td>
                <td className="px-3 py-2 text-xs text-zinc-500">
                  {new Date(w.created_at).toLocaleString("zh-TW")}
                </td>
                <td className="px-3 py-2 text-right">
                  {(w.status === "draft" || w.status === "picking" || w.status === "picked") && (
                    <button
                      onClick={() => setEditing(w)}
                      className="rounded-md bg-amber-500 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-600"
                    >
                      修正數量
                    </button>
                  )}
                  {w.status === "shipped" && (
                    <span className="text-xs text-emerald-600 dark:text-emerald-400">✓ 已派貨</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {editing && (
        <PickModal
          wave={editing}
          onClose={() => setEditing(null)}
          onSubmitted={() => {
            setEditing(null);
            setReloadTick((t) => t + 1);
          }}
        />
      )}
    </div>
  );
}

function PickModal({
  wave,
  onClose,
  onSubmitted,
}: {
  wave: Wave;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [items, setItems] = useState<WaveItem[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [skus, setSkus] = useState<Sku[]>([]);
  const [edits, setEdits] = useState<Map<number, string>>(new Map()); // wave_item_id -> new picked_qty string
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [shipping, setShipping] = useState(false);
  const [hqLocId, setHqLocId] = useState<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: itemsData, error: e1 } = await sb
          .from("picking_wave_items")
          .select("id, sku_id, store_id, qty, picked_qty, generated_transfer_id")
          .eq("wave_id", wave.id);
        if (e1) throw new Error(e1.message);
        if (cancelled) return;
        const arr = ((itemsData as WaveItem[] | null) ?? []).map((r) => ({
          ...r,
          qty: Number(r.qty),
          picked_qty: r.picked_qty === null ? null : Number(r.picked_qty),
        }));
        setItems(arr);

        const skuIds = Array.from(new Set(arr.map((r) => r.sku_id)));
        const storeIds = Array.from(new Set(arr.map((r) => r.store_id)));

        if (skuIds.length) {
          const { data: skuData } = await sb
            .from("skus")
            .select("id, sku_code, product_name, variant_name")
            .in("id", skuIds);
          if (!cancelled) setSkus((skuData as Sku[] | null) ?? []);
        }
        if (storeIds.length) {
          const { data: storeData } = await sb
            .from("stores")
            .select("id, name")
            .in("id", storeIds)
            .order("id");
          if (!cancelled) setStores((storeData as Store[] | null) ?? []);
        }

        // 找一個 central_warehouse location 當 HQ
        const { data: loc } = await sb
          .from("locations")
          .select("id")
          .eq("type", "central_warehouse")
          .eq("is_active", true)
          .limit(1);
        if (!cancelled) setHqLocId(((loc as { id: number }[] | null) ?? [])[0]?.id ?? null);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [wave.id]);

  const matrix: Map<number, Map<number, WaveItem>> = useMemo(() => {
    const m = new Map<number, Map<number, WaveItem>>();
    for (const it of items ?? []) {
      if (!m.has(it.sku_id)) m.set(it.sku_id, new Map());
      m.get(it.sku_id)!.set(it.store_id, it);
    }
    return m;
  }, [items]);

  const skuList = useMemo(
    () => skus.sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? "")),
    [skus],
  );

  function setEdit(itemId: number, val: string) {
    setEdits((cur) => {
      const next = new Map(cur);
      next.set(itemId, val);
      return next;
    });
  }

  async function saveEdits() {
    if (edits.size === 0) {
      onSubmitted();
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      for (const [itemId, val] of edits) {
        const newQty = Number(val);
        if (Number.isNaN(newQty) || newQty < 0) continue;
        const { error: e } = await sb.rpc("rpc_update_picked_qty", {
          p_wave_item_id: itemId,
          p_new_qty: newQty,
          p_operator: operator,
          p_note: "manual fix in /picking/history",
        });
        if (e) throw new Error(`item ${itemId}: ${e.message}`);
      }
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function ship() {
    if (!hqLocId) {
      setError("找不到總倉 location");
      return;
    }
    if (wave.status !== "picked") {
      setError(`撿貨單狀態為 ${wave.status}，需是 picked 才能派貨。請先確認修正完成。`);
      return;
    }
    if (!confirm(`確認派貨？將為 ${wave.store_count} 間分店產生 transfer 並從總倉出庫。`)) return;
    setShipping(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const { error: e } = await sb.rpc("generate_transfer_from_wave", {
        p_wave_id: wave.id,
        p_hq_location_id: hqLocId,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      alert(`派貨完成！${wave.store_count} 張 transfer 已建立`);
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setShipping(false);
    }
  }

  async function confirmAsPicked() {
    if (wave.status === "picked") return;
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { error: e } = await sb
        .from("picking_waves")
        .update({ status: "picked", updated_at: new Date().toISOString() })
        .eq("id", wave.id);
      if (e) throw new Error(e.message);
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="flex max-h-[90vh] w-full max-w-[90vw] flex-col overflow-hidden rounded-md bg-white shadow-xl dark:bg-zinc-900">
        <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
          <div>
            <h2 className="font-semibold">
              修正數量：<span className="font-mono">{wave.wave_code}</span>{" "}
              <span className="text-xs text-zinc-500">
                · 配送日 {wave.wave_date} · 狀態 {STATUS_LABEL[wave.status] ?? wave.status}
              </span>
            </h2>
          </div>
          <div className="flex gap-2">
            <button
              onClick={saveEdits}
              disabled={submitting}
              className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {submitting ? "儲存中…" : `儲存修正 (${edits.size})`}
            </button>
            {wave.status !== "picked" && wave.status !== "shipped" && (
              <button
                onClick={confirmAsPicked}
                disabled={submitting}
                className="rounded-md bg-blue-500 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-600 disabled:opacity-50"
              >
                ✅ 確認修正完成
              </button>
            )}
            {wave.status === "picked" && (
              <button
                onClick={ship}
                disabled={shipping}
                className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
              >
                {shipping ? "派貨中…" : "🚚 派貨出倉"}
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

        {error && (
          <div className="border-b border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="overflow-auto p-3">
          {items === null ? (
            <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
          ) : (
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="sticky left-0 z-10 bg-zinc-50 px-3 py-2 text-left text-xs uppercase text-zinc-500 dark:bg-zinc-900">
                    品名
                  </th>
                  {stores.map((s) => (
                    <th
                      key={s.id}
                      className="px-2 py-2 text-right text-xs uppercase text-zinc-500"
                    >
                      {s.name}
                    </th>
                  ))}
                  <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">合計</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {skuList.map((sku) => {
                  const row = matrix.get(sku.id);
                  const total = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    if (!it) return s;
                    const edit = edits.get(it.id);
                    const v = edit !== undefined ? Number(edit) : (it.picked_qty ?? it.qty);
                    return s + (Number.isNaN(v) ? 0 : v);
                  }, 0);
                  return (
                    <tr key={sku.id}>
                      <td className="sticky left-0 bg-white px-3 py-2 dark:bg-zinc-900">
                        <div className="font-medium">{sku.product_name ?? "—"}</div>
                        <div className="text-xs text-zinc-500">
                          {sku.sku_code}{sku.variant_name ? ` / ${sku.variant_name}` : ""}
                        </div>
                      </td>
                      {stores.map((st) => {
                        const it = row?.get(st.id);
                        if (!it) return <td key={st.id} className="px-2 py-2 text-right text-zinc-300">·</td>;
                        const edit = edits.get(it.id);
                        const cur = edit !== undefined ? edit : String(it.picked_qty ?? it.qty);
                        const isEdited = edit !== undefined;
                        const isShippedItem = it.generated_transfer_id !== null;
                        return (
                          <td key={st.id} className="px-1 py-1 text-right">
                            <div className="flex flex-col">
                              <input
                                inputMode="decimal"
                                disabled={isShippedItem || wave.status === "shipped"}
                                value={cur}
                                onChange={(e) => setEdit(it.id, e.target.value)}
                                className={`w-14 rounded-md border px-1 py-0.5 text-right font-mono text-sm ${isEdited ? "border-amber-400 bg-amber-50 dark:bg-amber-950" : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"} disabled:bg-zinc-100 disabled:opacity-60 dark:disabled:bg-zinc-800`}
                              />
                              <div className="text-[10px] text-zinc-400">
                                應 {it.qty}
                              </div>
                            </div>
                          </td>
                        );
                      })}
                      <td className="px-3 py-2 text-right font-mono font-semibold">{total}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th
      className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}
    >
      {children}
    </th>
  );
}
