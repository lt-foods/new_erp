"use client";

import { Fragment, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

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
  expected_total: number;
  actual_total: number;
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
  const [filterDate, setFilterDate] = useState<string>("");
  const [autoOpenWaveId, setAutoOpenWaveId] = useState<number | null>(() => {
    if (typeof window === "undefined") return null;
    const id = new URLSearchParams(window.location.search).get("wave");
    return id ? Number(id) : null;
  });

  useEffect(() => {
    if (autoOpenWaveId === null || waves === null) return;
    const target = waves.find((w) => w.id === autoOpenWaveId);
    if (target) {
      setEditing(target);
      setAutoOpenWaveId(null);
    }
  }, [waves, autoOpenWaveId]);

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
        const waveRows = (data as Omit<Wave, "expected_total" | "actual_total">[] | null) ?? [];
        const ids = waveRows.map((w) => w.id);
        const totals = new Map<number, { expected: number; actual: number; itemCount: number }>();
        if (ids.length > 0) {
          const { data: itemRows } = await sb
            .from("picking_wave_items")
            .select("wave_id, qty, picked_qty")
            .in("wave_id", ids);
          for (const r of (itemRows as { wave_id: number; qty: number; picked_qty: number | null }[] | null) ?? []) {
            const cur = totals.get(r.wave_id) ?? { expected: 0, actual: 0, itemCount: 0 };
            cur.expected += Number(r.qty);
            cur.actual += Number(r.picked_qty ?? r.qty);
            cur.itemCount += 1;
            totals.set(r.wave_id, cur);
          }
        }
        if (!cancelled) {
          setWaves(
            waveRows.map((r) => {
              const t = totals.get(r.id);
              return {
                ...r,
                total_qty: Number(r.total_qty),
                expected_total: t?.expected ?? 0,
                actual_total: t?.actual ?? 0,
                item_count: t?.itemCount ?? r.item_count,
              };
            }),
          );
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(translateRpcError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadTick]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">撿貨歷史</h1>
          <p className="text-sm text-zinc-500">
            {waves === null
              ? "載入中…"
              : filterDate
                ? `共 ${waves.filter((w) => w.wave_date === filterDate).length} 張（配送日 ${filterDate}）／ ${waves.length} 張`
                : `共 ${waves.length} 張撿貨單`}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <label className="flex items-center gap-1 text-xs text-zinc-600 dark:text-zinc-300">
            <span>配送日</span>
            <input
              type="date"
              value={filterDate}
              onChange={(e) => setFilterDate(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
            {filterDate && (
              <button
                onClick={() => setFilterDate("")}
                className="ml-1 text-xs text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100"
                title="清除"
              >
                ✕
              </button>
            )}
          </label>
          <Link
            href={filterDate ? `/picking/print-sign?date=${filterDate}` : "#"}
            target="_blank"
            onClick={(e) => {
              if (!filterDate) {
                e.preventDefault();
                alert("請先選配送日");
              }
            }}
            className={`rounded-md border px-3 py-1.5 text-sm ${
              filterDate
                ? "border-blue-300 bg-blue-50 text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                : "cursor-not-allowed border-zinc-200 bg-zinc-100 text-zinc-400 dark:border-zinc-800 dark:bg-zinc-800 dark:text-zinc-600"
            }`}
          >
            📄 列印分店簽收單
          </Link>
          <Link
            href="/picking/workstation"
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            + 至撿貨工作站
          </Link>
        </div>
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
              <Th>作業時間</Th>
              <Th>撿貨單號</Th>
              <Th>摘要</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {waves !== null && waves.length === 0 && (
              <tr>
                <td colSpan={4} className="p-6 text-center text-sm text-zinc-500">
                  尚無撿貨單，請至「撿貨工作站」建立。
                </td>
              </tr>
            )}
            {waves !== null && waves.length > 0 && filterDate && waves.filter((w) => w.wave_date === filterDate).length === 0 && (
              <tr>
                <td colSpan={4} className="p-6 text-center text-sm text-zinc-500">
                  此配送日無撿貨單。
                </td>
              </tr>
            )}
            {waves?.filter((w) => !filterDate || w.wave_date === filterDate).map((w) => {
              const diff = w.actual_total - w.expected_total;
              const diffEl =
                diff === 0 ? (
                  <span className="ml-2 font-medium text-emerald-600 dark:text-emerald-400">✓ 正確</span>
                ) : diff > 0 ? (
                  <span className="ml-2 font-medium text-purple-600 dark:text-purple-400">(+{diff})</span>
                ) : (
                  <span className="ml-2 font-medium text-red-600 dark:text-red-400">({diff})</span>
                );
              return (
              <tr key={w.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <td className="px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">
                  <div>{new Date(w.created_at).toLocaleString("zh-TW")}</div>
                  <div className="mt-1 flex items-center gap-1 text-zinc-500">
                    <span>📅 配送：</span>
                    {w.status === "shipped" || w.status === "cancelled" ? (
                      <span>{w.wave_date}</span>
                    ) : (
                      <input
                        type="date"
                        value={w.wave_date}
                        onChange={async (e) => {
                          const newDate = e.target.value;
                          if (!newDate || newDate === w.wave_date) return;
                          try {
                            const sb = getSupabase();
                            const { data: userRes } = await sb.auth.getUser();
                            const operator = userRes?.user?.id;
                            if (!operator) throw new Error("未登入");
                            const { error: er } = await sb.rpc("rpc_update_wave_date", {
                              p_wave_id: w.id,
                              p_new_date: newDate,
                              p_operator: operator,
                            });
                            if (er) throw new Error(er.message);
                            setReloadTick((t) => t + 1);
                          } catch (err) {
                            alert(`配送日更新失敗：${translateRpcError(err)}`);
                          }
                        }}
                        className="rounded border border-zinc-300 bg-white px-1 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    )}
                  </div>
                </td>
                <td className="px-3 py-2">
                  <div className="font-mono text-sm">{w.wave_code}</div>
                  <span
                    className={`mt-1 inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[w.status] ?? ""}`}
                  >
                    {STATUS_LABEL[w.status] ?? w.status}
                  </span>
                  {w.note && <div className="mt-1 text-[11px] text-zinc-500">{w.note}</div>}
                </td>
                <td className="px-3 py-2 text-sm">
                  <span className="text-zinc-600 dark:text-zinc-300">{w.item_count} 品項</span>
                  <span className="mx-2 text-zinc-300">|</span>
                  <span className="text-zinc-600 dark:text-zinc-300">應發 <span className="font-mono font-semibold">{w.expected_total}</span></span>
                  <span className="mx-2 text-zinc-300">|</span>
                  <span className="text-zinc-600 dark:text-zinc-300">實分 <span className="font-mono font-semibold">{w.actual_total}</span></span>
                  {diffEl}
                </td>
                <td className="px-3 py-2 text-right">
                  <div className="flex items-center justify-end gap-2">
                    {(w.status === "draft" || w.status === "picking" || w.status === "picked") && (
                      <button
                        onClick={() => setEditing(w)}
                        className="rounded-md bg-amber-500 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-600"
                      >
                        修正數量
                      </button>
                    )}
                    {w.status === "shipped" && (
                      <button
                        onClick={() => setEditing(w)}
                        className="rounded-md border border-emerald-300 px-3 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-50 dark:border-emerald-700 dark:text-emerald-400 dark:hover:bg-emerald-950"
                      >
                        ✓ 已派貨 · 看明細
                      </button>
                    )}
                    {w.status !== "shipped" && (
                      <button
                        onClick={async () => {
                          if (!confirm(`確認刪除撿貨單 ${w.wave_code}？此操作無法復原。`)) return;
                          try {
                            const sb = getSupabase();
                            const { data: userRes } = await sb.auth.getUser();
                            const operator = userRes?.user?.id;
                            if (!operator) throw new Error("未登入");
                            const { error: e } = await sb.rpc("rpc_delete_picking_wave", {
                              p_wave_id: w.id,
                              p_operator: operator,
                            });
                            if (e) throw new Error(e.message);
                            alert("已刪除");
                            setReloadTick((t) => t + 1);
                          } catch (err) {
                            alert(`刪除失敗: ${translateRpcError(err)}`);
                          }
                        }}
                        className="rounded-md bg-red-500 px-3 py-1 text-xs font-semibold text-white hover:bg-red-600"
                      >
                        刪除
                      </button>
                    )}
                  </div>
                </td>
              </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {editing && (
        <PickModal
          wave={editing}
          onClose={() => { setEditing(null); setReloadTick((t) => t + 1); }}
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
  const [effectiveStatus, setEffectiveStatus] = useState<string>(wave.status);

  const shortageCount = useMemo(() => {
    if (!items) return 0;
    let n = 0;
    for (const it of items) {
      const e = edits.get(it.id);
      const v = e !== undefined ? Number(e) : Number(it.picked_qty ?? it.qty);
      if (!Number.isNaN(v) && v < Number(it.qty)) n += 1;
    }
    return n;
  }, [items, edits]);

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
        if (!cancelled) setError(translateRpcError(e));
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
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function ship() {
    if (!hqLocId) {
      setError("找不到總倉 location，請確認倉庫設定");
      return;
    }
    if (effectiveStatus !== "picked") {
      setError(`撿貨單狀態為「${effectiveStatus}」，需先確認撿貨完成才能派貨`);
      return;
    }

    // 檢查是否所有品項 picked_qty = 0
    const allZero = items != null && items.length > 0 && items.every((it) => {
      const e = edits.get(it.id);
      const v = e !== undefined ? Number(e) : Number(it.picked_qty ?? it.qty);
      return !Number.isNaN(v) && v === 0;
    });
    if (allZero) {
      setError("所有品項撿貨數量均為 0，請先在上方輸入實際撿貨量再派貨");
      return;
    }

    const shortMsg = shortageCount > 0
      ? `\n\n⚠ 有 ${shortageCount} 行短缺（撿到的數量少於應撿量），派貨後該店家會拿不到應有量。是否仍要繼續？`
      : "";
    if (!confirm(`確認派貨？將為 ${wave.store_count} 間分店產生 transfer 並從總倉出庫。${shortMsg}`)) return;
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
      setError(translateRpcError(e));
    } finally {
      setShipping(false);
    }
  }

  async function confirmAsPicked() {
    if (effectiveStatus === "picked") return;
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");
      const { error: e } = await sb.rpc("rpc_confirm_picked", {
        p_wave_id: wave.id,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      setEffectiveStatus("picked");
    } catch (e) {
      setError(translateRpcError(e));
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
                · 配送日 {wave.wave_date} · 狀態 {STATUS_LABEL[effectiveStatus] ?? effectiveStatus}
              </span>
              {shortageCount > 0 && (
                <span className="ml-2 inline-block rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                  ⚠ {shortageCount} 行短缺（可派貨，部分店家拿不到應有量）
                </span>
              )}
            </h2>
          </div>
          <div className="flex gap-2">
            {effectiveStatus !== "shipped" && (
              <button
                onClick={saveEdits}
                disabled={submitting}
                className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
              >
                {submitting ? "儲存中…" : `儲存修正 (${edits.size})`}
              </button>
            )}
            {effectiveStatus !== "picked" && effectiveStatus !== "shipped" && (
              <button
                onClick={confirmAsPicked}
                disabled={submitting}
                className="rounded-md bg-blue-500 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-600 disabled:opacity-50"
              >
                ✅ 確認修正完成
              </button>
            )}
            {effectiveStatus === "picked" && (
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
                  <th className="px-2 py-2 text-left text-xs uppercase text-zinc-500">項目</th>
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
              <tbody className="divide-y-2 divide-zinc-300 dark:divide-zinc-700">
                {skuList.map((sku) => {
                  const row = matrix.get(sku.id);
                  const expectedTotal = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    return it ? s + Number(it.qty) : s;
                  }, 0);
                  const actualTotal = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    if (!it) return s;
                    const edit = edits.get(it.id);
                    const v = edit !== undefined ? Number(edit) : Number(it.picked_qty ?? it.qty);
                    return s + (Number.isNaN(v) ? 0 : v);
                  }, 0);
                  const totalDiff = actualTotal - expectedTotal;
                  let skuShortStores = 0;
                  let skuShortQty = 0;
                  if (row) {
                    for (const st of stores) {
                      const it = row.get(st.id);
                      if (!it) continue;
                      const e = edits.get(it.id);
                      const v = Number(e !== undefined ? e : (it.picked_qty ?? it.qty));
                      if (!Number.isNaN(v) && v < Number(it.qty)) {
                        skuShortStores += 1;
                        skuShortQty += Number(it.qty) - v;
                      }
                    }
                  }
                  const skuHasShortage = skuShortStores > 0;
                  return (
                    <Fragment key={sku.id}>
                      {/* 應發 */}
                      <tr className={skuHasShortage ? "bg-red-50/60 dark:bg-red-950/20" : "bg-zinc-50/50 dark:bg-zinc-900/50"}>
                        <td
                          rowSpan={3}
                          className={`sticky left-0 px-3 py-2 align-top ${skuHasShortage ? "bg-red-50 dark:bg-red-950/30" : "bg-white dark:bg-zinc-900"}`}
                        >
                          <div className="font-medium">{sku.product_name ?? "—"}</div>
                          <div className="text-xs text-zinc-500">
                            {sku.sku_code}{sku.variant_name ? ` / ${sku.variant_name}` : ""}
                          </div>
                          {skuHasShortage && (
                            <div className="mt-1 inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-medium text-red-700 dark:bg-red-950 dark:text-red-300">
                              ⚠ 短缺 {skuShortStores} 店 / {skuShortQty} 件
                            </div>
                          )}
                        </td>
                        <td className="px-2 py-1 text-xs text-zinc-500">應發</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          return (
                            <td key={st.id} className="px-2 py-1 text-right font-mono text-zinc-500">
                              {it ? Number(it.qty) : <span className="text-zinc-300">·</span>}
                            </td>
                          );
                        })}
                        <td className="px-3 py-1 text-right font-mono text-zinc-600">{expectedTotal}</td>
                      </tr>

                      {/* 實分 */}
                      <tr>
                        <td className="px-2 py-1 text-xs font-semibold">實分</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          if (!it) return <td key={st.id} className="px-2 py-1 text-right text-zinc-300">·</td>;
                          const edit = edits.get(it.id);
                          const cur = edit !== undefined ? edit : String(it.picked_qty ?? it.qty);
                          const curNum = Number(cur);
                          const expNum = Number(it.qty);
                          const isShort = !Number.isNaN(curNum) && curNum < expNum;
                          const isOver = !Number.isNaN(curNum) && curNum > expNum;
                          const isEdited = edit !== undefined;
                          const isShippedItem = it.generated_transfer_id !== null;
                          const inputCls = isShort
                            ? "border-red-400 bg-red-50 text-red-700 dark:border-red-700 dark:bg-red-950 dark:text-red-300"
                            : isOver
                            ? "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-700 dark:bg-purple-950 dark:text-purple-300"
                            : isEdited
                            ? "border-amber-400 bg-amber-50 dark:bg-amber-950"
                            : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800";
                          return (
                            <td
                              key={st.id}
                              className={`px-1 py-1 text-right ${isShort ? "bg-red-50/50 dark:bg-red-950/20" : ""}`}
                            >
                              <input
                                inputMode="decimal"
                                disabled={isShippedItem || effectiveStatus === "shipped"}
                                value={cur}
                                onChange={(e) => setEdit(it.id, e.target.value)}
                                className={`w-14 rounded-md border px-1 py-0.5 text-right font-mono text-sm font-semibold ${inputCls} disabled:opacity-60`}
                              />
                            </td>
                          );
                        })}
                        <td className={`px-3 py-1 text-right font-mono font-semibold ${
                          totalDiff < 0
                            ? "text-red-700 dark:text-red-300"
                            : totalDiff > 0
                            ? "text-purple-700 dark:text-purple-300"
                            : ""
                        }`}>
                          {actualTotal}
                        </td>
                      </tr>

                      {/* 狀態 */}
                      <tr className={skuHasShortage ? "bg-red-50/60 dark:bg-red-950/20" : "bg-zinc-50/50 dark:bg-zinc-900/50"}>
                        <td className="px-2 py-1 text-xs text-zinc-500">狀態</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          if (!it) return <td key={st.id} className="px-2 py-1 text-right text-zinc-300">—</td>;
                          const edit = edits.get(it.id);
                          const cur = Number(edit !== undefined ? edit : (it.picked_qty ?? it.qty));
                          const diff = !Number.isNaN(cur) ? cur - Number(it.qty) : 0;
                          if (diff === 0) {
                            return <td key={st.id} className="px-2 py-1 text-right text-xs text-zinc-400">—</td>;
                          }
                          if (diff > 0) {
                            return (
                              <td key={st.id} className="px-2 py-1 text-right">
                                <span className="inline-block rounded bg-purple-100 px-1.5 py-0.5 text-[10px] font-semibold text-purple-700 dark:bg-purple-950 dark:text-purple-300">
                                  +{diff} 超賣
                                </span>
                              </td>
                            );
                          }
                          return (
                            <td key={st.id} className="bg-red-50/50 px-2 py-1 text-right dark:bg-red-950/20">
                              <span className="inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-semibold text-red-700 dark:bg-red-950 dark:text-red-300">
                                {diff} 短缺
                              </span>
                            </td>
                          );
                        })}
                        <td className={`px-3 py-1 text-right font-mono text-xs font-semibold ${
                          totalDiff === 0
                            ? "text-emerald-600 dark:text-emerald-400"
                            : totalDiff > 0
                            ? "text-purple-600 dark:text-purple-400"
                            : "text-red-600 dark:text-red-400"
                        }`}>
                          {totalDiff === 0 ? "✓" : (totalDiff > 0 ? `+${totalDiff}` : `${totalDiff}`)}
                        </td>
                      </tr>
                    </Fragment>
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
