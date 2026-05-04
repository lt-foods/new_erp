"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";

type OrderRow = {
  id: number;
  order_no: string;
  status: string;
  pickup_store_id: number | null;
  nickname_snapshot: string | null;
  notes: string | null;
  order_kind: string | null;
  created_at: string;
  customer_order_items: { qty: number; unit_price: number }[];
};

type Store = { id: number; code: string; name: string };

const STATUS_LABEL: Record<string, string> = {
  pending: "待確認",
  confirmed: "已確認",
  reserved: "已備貨",
  partially_ready: "部分備貨",
  partially_completed: "部分完成",
  shipping: "出貨中",
  ready: "可取貨",
  completed: "已完成",
  cancelled: "已取消",
  expired: "已逾期",
  transferred_out: "已轉出",
};

const STATUS_BADGE: Record<string, string> = {
  pending: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  reserved: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  partially_ready: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  partially_completed: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  shipping: "bg-cyan-100 text-cyan-800 dark:bg-cyan-950 dark:text-cyan-300",
  ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  transferred_out: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
};

export function CampaignOrdersPanel({ campaignId }: { campaignId: number }) {
  const [rows, setRows] = useState<OrderRow[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [storeFilter, setStoreFilter] = useState<string>("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const [ordersRes, storesRes] = await Promise.all([
          sb
            .from("customer_orders")
            .select(
              "id, order_no, status, pickup_store_id, nickname_snapshot, notes, order_kind, created_at, customer_order_items(qty, unit_price)",
            )
            .eq("campaign_id", campaignId)
            .order("created_at", { ascending: false }),
          sb.from("stores").select("id, code, name").eq("is_active", true).order("code"),
        ]);
        if (cancelled) return;
        if (ordersRes.error) throw ordersRes.error;
        if (storesRes.error) throw storesRes.error;
        setRows((ordersRes.data ?? []) as OrderRow[]);
        setStores((storesRes.data ?? []) as Store[]);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [campaignId]);

  const storeCount = useMemo(() => {
    const m = new Map<number, number>();
    for (const r of rows ?? []) {
      if (r.pickup_store_id) m.set(r.pickup_store_id, (m.get(r.pickup_store_id) ?? 0) + 1);
    }
    return m;
  }, [rows]);

  const filtered = useMemo(() => {
    if (!rows) return [];
    return storeFilter
      ? rows.filter((r) => r.pickup_store_id === Number(storeFilter))
      : rows;
  }, [rows, storeFilter]);

  const totals = useMemo(() => {
    let qty = 0;
    let amount = 0;
    let normalCount = 0;
    let offsetCount = 0;
    for (const r of filtered) {
      const isOffset = r.order_kind === "offset";
      if (isOffset) offsetCount++;
      else if (r.status !== "cancelled" && r.status !== "expired") normalCount++;
      for (const it of r.customer_order_items ?? []) {
        const q = Number(it.qty);
        if (!Number.isFinite(q)) continue;
        if (r.status === "cancelled" || r.status === "expired") continue;
        qty += q;
        amount += q * Number(it.unit_price);
      }
    }
    return { qty, amount, normalCount, offsetCount };
  }, [filtered]);

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">
          本團訂單{rows ? ` (${filtered.length} / ${rows.length})` : "…"}
        </h3>
        <div className="flex items-center gap-2">
          <select
            value={storeFilter}
            onChange={(e) => setStoreFilter(e.target.value)}
            className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部門市{rows ? ` (${rows.length})` : ""}</option>
            {stores.map((s) => {
              const n = storeCount.get(s.id) ?? 0;
              if (n === 0 && !storeFilter) return null;
              return (
                <option key={s.id} value={s.id}>
                  {s.name} ({n})
                </option>
              );
            })}
          </select>
          <Link
            href={`/orders?campaignIds=${campaignId}`}
            className="text-xs text-blue-600 hover:underline dark:text-blue-400"
          >
            完整訂單頁 →
          </Link>
        </div>
      </div>

      {error && (
        <div className="rounded border border-red-300 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          載入失敗：{error}
        </div>
      )}

      {!rows && !error && (
        <p className="text-xs text-zinc-500">載入中…</p>
      )}

      {rows && filtered.length === 0 && (
        <p className="rounded border border-zinc-200 bg-zinc-50 p-4 text-center text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          {storeFilter ? "此門市暫無訂單" : "本團尚無訂單"}
        </p>
      )}

      {rows && filtered.length > 0 && (
        <>
          <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
            <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="px-3 py-1.5 text-left font-medium uppercase tracking-wide text-zinc-500">訂單號</th>
                  <th className="px-3 py-1.5 text-left font-medium uppercase tracking-wide text-zinc-500">會員</th>
                  <th className="px-3 py-1.5 text-left font-medium uppercase tracking-wide text-zinc-500">門市</th>
                  <th className="px-3 py-1.5 text-left font-medium uppercase tracking-wide text-zinc-500">狀態</th>
                  <th className="px-3 py-1.5 text-right font-medium uppercase tracking-wide text-zinc-500">數量</th>
                  <th className="px-3 py-1.5 text-right font-medium uppercase tracking-wide text-zinc-500">金額</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {filtered.map((r) => {
                  const store = stores.find((s) => s.id === r.pickup_store_id);
                  const items = r.customer_order_items ?? [];
                  const qty = items.reduce((s, i) => s + Number(i.qty || 0), 0);
                  const amt = items.reduce((s, i) => s + Number(i.qty || 0) * Number(i.unit_price || 0), 0);
                  const isOffset = r.order_kind === "offset";
                  const isCancelled = r.status === "cancelled" || r.status === "expired";
                  return (
                    <tr
                      key={r.id}
                      className={`${isOffset ? "bg-red-50/40 dark:bg-red-950/20" : ""} ${isCancelled ? "opacity-50" : ""} hover:bg-zinc-50 dark:hover:bg-zinc-900`}
                    >
                      <td className="px-3 py-1.5 font-mono">
                        {r.order_no}
                        {isOffset && (
                          <span className="ml-1.5 rounded bg-red-200 px-1 py-0.5 text-[10px] font-medium text-red-800 dark:bg-red-900 dark:text-red-300">
                            抵減
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-1.5">{r.nickname_snapshot ?? "—"}</td>
                      <td className="px-3 py-1.5 text-zinc-600 dark:text-zinc-400">{store?.name ?? "—"}</td>
                      <td className="px-3 py-1.5">
                        <span className={`inline-block rounded px-1.5 py-0.5 ${STATUS_BADGE[r.status] ?? STATUS_BADGE.pending}`}>
                          {STATUS_LABEL[r.status] ?? r.status}
                        </span>
                      </td>
                      <td className={`px-3 py-1.5 text-right font-mono tabular-nums ${isOffset ? "text-red-700 dark:text-red-300" : ""}`}>
                        {isOffset ? `−${Math.abs(qty)}` : qty}
                      </td>
                      <td className={`px-3 py-1.5 text-right font-mono tabular-nums ${isOffset ? "text-red-700 dark:text-red-300" : ""}`}>
                        {isOffset ? `−$${Math.abs(amt).toLocaleString()}` : `$${amt.toLocaleString()}`}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <td colSpan={3} className="px-3 py-1.5 text-right text-zinc-500">
                    {storeFilter ? "本店小計" : "全店小計"}
                  </td>
                  <td className="px-3 py-1.5 text-zinc-500">
                    {totals.normalCount} 筆{totals.offsetCount > 0 && ` + ${totals.offsetCount} 抵減`}
                  </td>
                  <td className="px-3 py-1.5 text-right font-mono tabular-nums font-semibold">
                    {totals.qty}
                  </td>
                  <td className="px-3 py-1.5 text-right font-mono tabular-nums font-semibold">
                    ${totals.amount.toLocaleString()}
                  </td>
                </tr>
              </tfoot>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
