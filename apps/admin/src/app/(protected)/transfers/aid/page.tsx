"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";

type OrderStatus =
  | "pending" | "confirmed" | "reserved" | "shipping" | "ready" | "partially_ready"
  | "partially_completed" | "completed" | "expired" | "cancelled" | "transferred_out";

type AidItem = {
  id: number;
  qty: number;
  source: string;
  sku: { id: number; sku_code: string; product_name: string; variant_name: string | null } | null;
};

type AidOrder = {
  id: number;
  order_no: string;
  status: OrderStatus;
  is_air_transfer: boolean | null;
  pickup_store_id: number | null;
  campaign_id: number | null;
  transferred_from_order_id: number | null;
  updated_at: string;
  created_at: string;
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
  items: AidItem[];
};

type SourceOrder = {
  id: number;
  order_no: string;
  pickup_store_id: number | null;
  store: { id: number; name: string } | null;
};

const STATUS_LABEL: Record<OrderStatus, string> = {
  pending: "待確認", confirmed: "已確認", reserved: "已保留", shipping: "派貨中",
  ready: "可取貨", partially_ready: "部分可取", partially_completed: "部分取貨",
  completed: "已完成", expired: "逾期", cancelled: "已取消",
  transferred_out: "已轉出",
};

const STATUS_COLOR: Record<OrderStatus, string> = {
  pending: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  reserved: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  shipping: "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300",
  ready: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
  partially_ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  partially_completed: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300",
  completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
  expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  transferred_out: "bg-zinc-300 text-zinc-700 line-through dark:bg-zinc-700 dark:text-zinc-400",
};

const PAGE_SIZE = 50;

export default function TransfersAidListPage() {
  const [rows, setRows] = useState<AidOrder[] | null>(null);
  const [sources, setSources] = useState<Map<number, SourceOrder>>(new Map());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [modeFilter, setModeFilter] = useState<"all" | "air" | "via_warehouse">("all");
  const [statusFilter, setStatusFilter] = useState<string>("");
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);

  const [detailId, setDetailId] = useState<number | null>(null);
  const [detailNo, setDetailNo] = useState<string>("");

  useEffect(() => { setPage(1); }, [modeFilter, statusFilter]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        // INNER JOIN customer_order_items 過濾 source='aid_transfer'
        let q = sb
          .from("customer_orders")
          .select(
            `id, order_no, status, is_air_transfer, pickup_store_id, campaign_id,
             transferred_from_order_id, updated_at, created_at,
             campaign:group_buy_campaigns(id, campaign_no, name),
             store:stores!customer_orders_pickup_store_id_fkey(id, name),
             items:customer_order_items!inner(id, qty, source,
               sku:skus(id, sku_code, product_name, variant_name))`,
            { count: "exact" },
          )
          .eq("items.source", "aid_transfer")
          .order("updated_at", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (modeFilter === "air") q = q.eq("is_air_transfer", true);
        else if (modeFilter === "via_warehouse") q = q.eq("is_air_transfer", false);
        if (statusFilter) q = q.eq("status", statusFilter);

        const { data, count, error: e } = await q;
        if (cancelled) return;
        if (e) { setError(e.message); setRows([]); return; }
        setError(null);
        const list = (data ?? []) as unknown as AidOrder[];
        setRows(list);
        setTotal(count ?? 0);

        // 撈 source orders（transferred_from_order_id）一次撈完
        const srcIds = Array.from(
          new Set(list.map((r) => r.transferred_from_order_id).filter((x): x is number => x != null)),
        );
        if (srcIds.length > 0) {
          const { data: srcs } = await sb
            .from("customer_orders")
            .select("id, order_no, pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(id, name)")
            .in("id", srcIds);
          const m = new Map<number, SourceOrder>();
          for (const s of (srcs ?? []) as unknown as SourceOrder[]) m.set(s.id, s);
          if (!cancelled) setSources(m);
        } else {
          if (!cancelled) setSources(new Map());
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [modeFilter, statusFilter, page]);

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">互助轉移單（總倉檢視）</h1>
          <p className="text-sm text-zinc-500">
            {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
            <span className="ml-2 text-xs text-zinc-400">— 來自互助交流板的訂單轉移；經總倉者需走收/出貨流程</span>
          </p>
        </div>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        <select value={modeFilter} onChange={(e) => setModeFilter(e.target.value as typeof modeFilter)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="all">全部模式</option>
          <option value="air">空中轉（店對店直送）</option>
          <option value="via_warehouse">經總倉中轉</option>
        </select>
        <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>訂單號</Th>
              <Th>開團</Th>
              <Th>模式</Th>
              <Th>來源店 → 目的店</Th>
              <Th>SKU / 數量</Th>
              <Th>狀態</Th>
              <Th className="text-right">更新</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={7} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={7} className="p-6 text-center text-zinc-500">尚無互助轉移單。</td></tr>
            ) : rows.map((r) => {
              const src = r.transferred_from_order_id ? sources.get(r.transferred_from_order_id) : null;
              const aidItems = r.items.filter((it) => it.source === "aid_transfer");
              const totalQty = aidItems.reduce((sum, it) => sum + Number(it.qty), 0);
              return (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono">
                    <button
                      onClick={() => { setDetailId(r.id); setDetailNo(r.order_no); }}
                      className="hover:underline"
                    >
                      {r.order_no}
                    </button>
                  </Td>
                  <Td className="text-xs">
                    {r.campaign ? (
                      <>
                        <span className="font-mono">{r.campaign.campaign_no}</span>
                        <span className="ml-1 text-zinc-500">{r.campaign.name}</span>
                      </>
                    ) : "—"}
                  </Td>
                  <Td>
                    {r.is_air_transfer ? (
                      <span className="inline-block rounded bg-sky-100 px-2 py-0.5 text-xs text-sky-800 dark:bg-sky-950 dark:text-sky-300">
                        ✈️ 空中轉
                      </span>
                    ) : (
                      <span className="inline-block rounded bg-violet-100 px-2 py-0.5 text-xs text-violet-800 dark:bg-violet-950 dark:text-violet-300">
                        🏬 經總倉
                      </span>
                    )}
                  </Td>
                  <Td className="text-xs">
                    {src ? (
                      <>
                        <span className="text-zinc-600 dark:text-zinc-300">{src.store?.name ?? "—"}</span>
                        <span className="ml-1 font-mono text-zinc-400">({src.order_no})</span>
                      </>
                    ) : "—"}
                    <span className="mx-1 text-zinc-400">→</span>
                    <span className="text-zinc-600 dark:text-zinc-300">{r.store?.name ?? "—"}</span>
                  </Td>
                  <Td className="text-xs">
                    {aidItems.length === 0 ? "—" : (
                      <ul className="space-y-0.5">
                        {aidItems.map((it) => (
                          <li key={it.id}>
                            <span className="text-zinc-700 dark:text-zinc-200">
                              {it.sku?.product_name ?? "—"}
                              {it.sku?.variant_name && <span className="text-zinc-500"> · {it.sku.variant_name}</span>}
                            </span>
                            <span className="ml-2 font-mono text-zinc-500">×{Number(it.qty)}</span>
                          </li>
                        ))}
                        {aidItems.length > 1 && (
                          <li className="text-zinc-400">合計 {totalQty}</li>
                        )}
                      </ul>
                    )}
                  </Td>
                  <Td>
                    <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[r.status]}`}>
                      {STATUS_LABEL[r.status]}
                    </span>
                  </Td>
                  <Td className="text-right text-xs text-zinc-500">
                    {new Date(r.updated_at).toLocaleString("zh-TW")}
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <Modal
        open={detailId !== null}
        onClose={() => setDetailId(null)}
        title={`訂單明細 ${detailNo}`}
        maxWidth="max-w-4xl"
      >
        {detailId !== null && (
          <OrderDetail
            orderId={detailId}
            onNavigate={(id, no) => { setDetailId(id); setDetailNo(no); }}
          />
        )}
      </Modal>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return <button onClick={onClick} disabled={disabled} className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800">{children}</button>;
}
