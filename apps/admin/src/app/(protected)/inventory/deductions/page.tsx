"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";

// 庫存減抵單：待補貨（少發配貨沒配到）的訂單品項，改用「店內現貨」直接交貨結案。
// 流程：帳上沒現貨 → 先到「庫存總覽」依商品新增庫存 → 回來勾品項開單。
// 開單當下扣店倉庫存、品項標已取貨、訂單結案（與到店取貨同一套帳）。
// 見 20260805000170_inventory_deduction_notes.sql。

type StoreRow = { id: number; name: string; location_id: number | null };

type BackorderItem = {
  item_id: number;
  order_id: number;
  order_no: string;
  customer: string | null;
  campaign_id: number;
  campaign_name: string | null;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty: number;
  backorder_at: string;
  ordered_at: string;
  store_on_hand: number;
};

type NoteLine = { order_no: string; customer: string | null; qty: number };
type Note = {
  id: number;
  note_no: string;
  qty: number;
  reason: string | null;
  created_at: string;
  store_id: number;
  store_name: string;
  campaign_id: number;
  campaign_name: string | null;
  sku_code: string | null;
  sku_label: string;
  lines: NoteLine[];
};

// (campaign, sku) 一組 = 一張減抵單
type Group = {
  key: string;
  campaignId: number;
  skuId: number;
  skuCode: string | null;
  skuLabel: string;
  campaignName: string | null;
  storeOnHand: number;
  items: BackorderItem[];
};

export default function InventoryDeductionsPage() {
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [storeId, setStoreId] = useState<string>("");
  const [items, setItems] = useState<BackorderItem[] | null>(null);
  const [notes, setNotes] = useState<Note[] | null>(null);
  // item_id → 本次要交貨的數量（0 = 不交）
  const [give, setGive] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const branchStoreId = useUserBranchStoreId(stores);
  useEffect(() => {
    if (branchStoreId != null && storeId !== String(branchStoreId)) {
      setStoreId(String(branchStoreId));
    }
  }, [branchStoreId, storeId]);
  useDefaultStoreFromUser(stores, storeId, setStoreId);

  useEffect(() => {
    (async () => {
      const { data } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .eq("is_active", true)
        .order("name");
      setStores((data as StoreRow[]) ?? []);
    })();
  }, []);

  const load = useCallback(async () => {
    const sb = getSupabase();
    const sid = storeId ? Number(storeId) : null;
    const [bi, nl] = await Promise.all([
      sid != null
        ? sb.rpc("rpc_get_backorder_items_for_store", { p_store_id: sid })
        : Promise.resolve({ data: [], error: null }),
      sb.rpc("rpc_list_inventory_deduction_notes", { p_store_id: sid, p_limit: 50 }),
    ]);
    if (bi.error) throw new Error(bi.error.message);
    if (nl.error) throw new Error(nl.error.message);
    const list = ((bi.data ?? []) as BackorderItem[]).map((r) => ({
      ...r,
      qty: Number(r.qty),
      store_on_hand: Number(r.store_on_hand),
    }));
    setItems(list);
    setNotes(((nl.data ?? []) as Note[]).map((n) => ({ ...n, qty: Number(n.qty) })));
    // 預設全不勾（0）— 店家自己決定哪些要用現貨交
    setGive(new Map(list.map((r) => [r.item_id, 0])));
  }, [storeId]);

  useEffect(() => {
    let cancelled = false;
    setItems(null);
    (async () => {
      try {
        await load();
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [load]);

  const groups = useMemo(() => {
    const map = new Map<string, Group>();
    for (const it of items ?? []) {
      const key = `${it.campaign_id}-${it.sku_id}`;
      let g = map.get(key);
      if (!g) {
        g = {
          key,
          campaignId: it.campaign_id,
          skuId: it.sku_id,
          skuCode: it.sku_code,
          skuLabel: it.sku_label,
          campaignName: it.campaign_name,
          storeOnHand: it.store_on_hand,
          items: [],
        };
        map.set(key, g);
      }
      g.items.push(it);
    }
    return Array.from(map.values()).sort((a, b) => a.skuLabel.localeCompare(b.skuLabel));
  }, [items]);

  function setItemGive(id: number, v: number, max: number) {
    const q = Number.isFinite(v) ? Math.max(0, Math.min(Math.floor(v), max)) : 0;
    setGive((cur) => new Map(cur).set(id, q));
  }

  function groupTotal(g: Group) {
    return g.items.reduce((s, r) => s + (give.get(r.item_id) ?? 0), 0);
  }

  // 對一組 (團, 品項) 開減抵單交貨
  async function createNote(g: Group) {
    const allocations: Record<string, number> = {};
    for (const r of g.items) {
      const q = give.get(r.item_id) ?? 0;
      if (q > 0) allocations[String(r.item_id)] = q;
    }
    const total = Object.values(allocations).reduce((s, q) => s + q, 0);
    if (total <= 0) return;
    if (
      !confirm(
        `「${g.skuLabel}」用店內現貨交貨 ${total} 件（${Object.keys(allocations).length} 筆訂單）？\n\n` +
          `會立刻扣店內庫存、品項標成已取貨、訂單結案 — 跟客人到店取貨同一套帳。\n` +
          `店倉帳上可用現貨：${g.storeOnHand} 件。開錯只能走退貨流程沖回，請確認。`,
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_create_inventory_deduction", {
        p_store_id: Number(storeId),
        p_campaign_id: g.campaignId,
        p_sku_id: g.skuId,
        p_allocations: allocations,
        p_reason: null,
        p_operator: operator,
        p_transfer_id: null,
      });
      if (e) throw new Error(translateRpcError(e));
      const note = (res ?? {}) as { note_no?: string; qty?: number; orders?: number };
      alert(
        `✅ 減抵單 ${note.note_no ?? ""} 完成：交貨 ${note.qty ?? total} 件、` +
          `${note.orders ?? "?"} 張訂單結案。`,
      );
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const branchLocked = branchStoreId != null;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">🏬 庫存減抵單</h1>
          <p className="text-sm text-zinc-500">
            待補貨的訂單改用店內現貨直接交貨結案。帳上沒現貨請先到
            <Link href="/inventory" className="mx-1 text-blue-600 underline dark:text-blue-400">
              庫存總覽
            </Link>
            依商品新增庫存。
          </p>
        </div>
        {branchLocked ? (
          <div className="rounded-md border border-zinc-300 bg-zinc-50 px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
            🏬 {stores.find((s) => s.id === branchStoreId)?.name ?? `#${branchStoreId}`}
            <span className="ml-2 text-xs text-zinc-500">(僅本店)</span>
          </div>
        ) : (
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 選分店 —</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        )}
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {!storeId && (
        <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          請先選擇分店，才會列出該店的待補貨品項。
        </div>
      )}

      {storeId && items === null && !error && (
        <div className="flex items-center justify-center gap-2 py-8 text-sm text-zinc-500">
          <Spinner size={16} /> 載入待補貨品項…
        </div>
      )}

      {storeId && items !== null && groups.length === 0 && (
        <div className="rounded-md border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          這家店目前沒有待補貨的品項 🎉
        </div>
      )}

      {groups.map((g) => {
        const total = groupTotal(g);
        const exceed = total > g.storeOnHand;
        return (
          <section
            key={g.key}
            className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
          >
            <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-zinc-200 bg-zinc-50 px-3 py-2.5 dark:border-zinc-800 dark:bg-zinc-900/60">
              <div className="min-w-0 flex-1">
                <div className="font-semibold text-zinc-900 dark:text-zinc-100">
                  {g.skuCode && (
                    <span className="mr-1.5 font-mono text-xs text-zinc-400">{g.skuCode}</span>
                  )}
                  {g.skuLabel}
                </div>
                <div className="mt-0.5 text-xs text-zinc-500">
                  {g.campaignName && <span className="mr-2">🛒 {g.campaignName}</span>}
                  待補貨 {g.items.reduce((s, r) => s + r.qty, 0)} 件 · 店倉帳上可用{" "}
                  <b className={g.storeOnHand > 0 ? "text-emerald-700 dark:text-emerald-400" : "text-rose-600 dark:text-rose-400"}>
                    {g.storeOnHand}
                  </b>{" "}
                  件
                </div>
              </div>
              <SpinButton
                onClick={() => createNote(g)}
                disabled={busy || total <= 0 || exceed}
                className="shrink-0 rounded-md bg-violet-600 px-4 py-2 text-sm font-semibold text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
                title="把勾選的待補貨品項用店內現貨直接交貨結案（會扣店庫存）"
              >
                用現貨交貨{total > 0 ? `（${total} 件）` : ""}
              </SpinButton>
            </div>
            {exceed && (
              <div className="border-b border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-300">
                ⚠ 帳上現貨只有 {g.storeOnHand} 件、不夠交 {total} 件 — 請先到
                <Link href="/inventory" target="_blank" className="mx-1 underline">
                  庫存總覽
                </Link>
                對這個商品「新增庫存」把現貨入帳。
              </div>
            )}
            <table className="w-full min-w-[560px] text-sm">
              <thead>
                <tr className="border-b border-zinc-200 bg-white text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                  <th className="w-28 px-3 py-2 text-left font-medium">交貨數量</th>
                  <th className="px-3 py-2 text-left font-medium">訂單編號</th>
                  <th className="px-3 py-2 text-left font-medium">顧客</th>
                  <th className="px-3 py-2 text-left font-medium">下單時間</th>
                  <th className="px-3 py-2 text-right font-medium">待補</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {g.items.map((r) => {
                  const q = give.get(r.item_id) ?? 0;
                  return (
                    <tr key={r.item_id} className={q > 0 ? "bg-violet-50/50 dark:bg-violet-950/20" : ""}>
                      <td className="px-3 py-2">
                        <div className="flex items-center gap-1.5">
                          <input
                            type="checkbox"
                            checked={q > 0}
                            onChange={(e) => setItemGive(r.item_id, e.target.checked ? r.qty : 0, r.qty)}
                            className="cursor-pointer"
                          />
                          <input
                            type="number"
                            min={0}
                            max={r.qty}
                            value={q}
                            onChange={(e) => setItemGive(r.item_id, Number(e.target.value), r.qty)}
                            className="w-14 rounded-md border border-zinc-300 px-1.5 py-1 text-right text-sm tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                          />
                          <span className="text-[10px] text-zinc-400">/ {r.qty}</span>
                        </div>
                      </td>
                      <td className="px-3 py-2 font-mono text-xs">{r.order_no}</td>
                      <td className="max-w-[220px] truncate px-3 py-2" title={r.customer ?? ""}>
                        {r.customer || "—"}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-500">
                        {new Date(r.ordered_at).toLocaleString("zh-TW", {
                          dateStyle: "short",
                          timeStyle: "short",
                        })}
                      </td>
                      <td className="px-3 py-2 text-right font-semibold tabular-nums">{r.qty}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </section>
        );
      })}

      {/* 歷史減抵單 */}
      {notes !== null && notes.length > 0 && (
        <section className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <div className="border-b border-zinc-200 bg-zinc-50 px-3 py-2.5 text-sm font-semibold dark:border-zinc-800 dark:bg-zinc-900/60">
            📜 歷史減抵單（近 {notes.length} 張）
          </div>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead>
                <tr className="border-b border-zinc-200 bg-white text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                  <th className="px-3 py-2 text-left font-medium">單號</th>
                  <th className="px-3 py-2 text-left font-medium">時間</th>
                  <th className="px-3 py-2 text-left font-medium">分店</th>
                  <th className="px-3 py-2 text-left font-medium">商品</th>
                  <th className="px-3 py-2 text-right font-medium">數量</th>
                  <th className="px-3 py-2 text-left font-medium">交貨對象</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {notes.map((n) => (
                  <tr key={n.id}>
                    <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-violet-700 dark:text-violet-400">
                      {n.note_no}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-500">
                      {new Date(n.created_at).toLocaleString("zh-TW", {
                        dateStyle: "short",
                        timeStyle: "short",
                      })}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-xs">{n.store_name}</td>
                    <td className="px-3 py-2">
                      {n.sku_code && (
                        <span className="mr-1.5 font-mono text-[10px] text-zinc-400">{n.sku_code}</span>
                      )}
                      {n.sku_label}
                    </td>
                    <td className="px-3 py-2 text-right font-semibold tabular-nums">{n.qty}</td>
                    <td className="px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">
                      {n.lines.map((l, i) => (
                        <div key={i}>
                          <span className="font-mono">{l.order_no}</span>
                          {l.customer ? ` ${l.customer}` : ""} × {l.qty}
                        </div>
                      ))}
                      {n.reason && <div className="text-zinc-400">{n.reason}</div>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}
