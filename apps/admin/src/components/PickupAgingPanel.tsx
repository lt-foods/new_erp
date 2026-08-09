"use client";

// 未取貨貨齡 —— 放在取貨頁最上面。
//
// 刻意預設收合、只留一行摘要：取貨頁是櫃檯掃單用的操作台，一進來就被一張大圖
// 擋住會很煩。但那個數字必須看得到 —— 線上 16,507 張「可取貨」還沒被取走，
// 其中 3,604 張放超過 30 天、最久 66 天，貨佔空間、錢收不到、客人早忘了。

import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { num, pct } from "@/components/ChartKit";

type Bucket = { bucket: string; orders: number };
type StoreRow = {
  store_id: number; name: string; total: number; over_30: number;
  by_bucket: Record<string, number>;
};
type OldRow = {
  id: number; order_no: string; store: string | null; nickname: string | null;
  age_days: number; deadline: string | null;
};
type Aging = {
  total: number; over_30: number; oldest_days: number;
  buckets: Bucket[]; stores: StoreRow[]; oldest: OldRow[];
};

// 由新到舊；顏色也照這個順序由淺到深，一眼看得出哪一段是老貨
const BUCKETS = ["0-3", "4-7", "8-14", "15-30", "31+"] as const;
const BUCKET_LABEL: Record<string, string> = {
  "0-3": "0–3 天", "4-7": "4–7 天", "8-14": "8–14 天", "15-30": "15–30 天", "31+": "31 天以上",
};
const BUCKET_COLOR: Record<string, string> = {
  "0-3": "bg-emerald-300 dark:bg-emerald-700",
  "4-7": "bg-lime-300 dark:bg-lime-700",
  "8-14": "bg-amber-300 dark:bg-amber-600",
  "15-30": "bg-orange-400 dark:bg-orange-600",
  "31+": "bg-red-500 dark:bg-red-600",
};

export default function PickupAgingPanel({ storeId }: { storeId?: number | null }) {
  const [open, setOpen] = useState(false);
  const [data, setData] = useState<Aging | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    const { data: rows, error: err } = await getSupabase()
      .rpc("rpc_pickup_aging", { p_store_id: storeId ?? null });
    setLoading(false);
    if (err) { setError(translateRpcError(err)); return; }
    setError(null);
    setData(rows as Aging);
  }, [storeId]);

  useEffect(() => { load(); }, [load]);

  const maxStore = Math.max(1, ...(data?.stores ?? []).map((s) => s.total));

  return (
    <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full flex-wrap items-center justify-between gap-2 px-4 py-2.5 text-left"
      >
        <span className="text-sm">
          <span className="font-semibold">未取貨</span>
          <span className="mx-1.5 text-zinc-500">·</span>
          {loading && !data ? (
            <span className="text-zinc-500">載入中…</span>
          ) : (
            <>
              共 <b>{num(data?.total)}</b> 張
              {(data?.over_30 ?? 0) > 0 && (
                <>
                  ，其中{" "}
                  <b className="text-red-600 dark:text-red-400">{num(data?.over_30)} 張放超過 30 天</b>
                  <span className="text-zinc-500">（最久 {data?.oldest_days} 天）</span>
                </>
              )}
            </>
          )}
        </span>
        <span className="text-xs text-blue-600 dark:text-blue-400">{open ? "收合" : "展開貨齡明細"} {open ? "▲" : "▼"}</span>
      </button>

      {error && <div className="px-4 pb-2 text-xs text-red-600 dark:text-red-400">{error}</div>}

      {open && data && (
        <div className="space-y-4 border-t border-zinc-200 p-4 dark:border-zinc-800">
          {/* 全體分桶 */}
          <div>
            <div className="mb-1.5 text-xs font-semibold text-zinc-500">放置天數分佈</div>
            <div className="flex h-6 w-full overflow-hidden rounded">
              {BUCKETS.map((b) => {
                const n = data.buckets.find((x) => x.bucket === b)?.orders ?? 0;
                const w = data.total > 0 ? (n / data.total) * 100 : 0;
                if (w <= 0) return null;
                return (
                  <div
                    key={b}
                    className={BUCKET_COLOR[b]}
                    style={{ width: `${w}%` }}
                    title={`${BUCKET_LABEL[b]}：${num(n)} 張（${pct(n / data.total, 1)}）`}
                  />
                );
              })}
            </div>
            <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-zinc-500">
              {BUCKETS.map((b) => {
                const n = data.buckets.find((x) => x.bucket === b)?.orders ?? 0;
                return (
                  <span key={b} className="flex items-center gap-1">
                    <span className={`inline-block h-2.5 w-2.5 rounded-sm ${BUCKET_COLOR[b]}`} />
                    {BUCKET_LABEL[b]} {num(n)}
                  </span>
                );
              })}
            </div>
          </div>

          {/* 各店堆疊柱狀（橫的，店名比較好讀） */}
          {data.stores.length > 1 && (
            <div>
              <div className="mb-1.5 text-xs font-semibold text-zinc-500">各店（依 30 天以上的張數排序）</div>
              <ul className="space-y-1">
                {data.stores.map((s) => (
                  <li key={s.store_id} className="flex items-center gap-2 text-xs">
                    <span className="w-16 shrink-0 truncate text-right" title={s.name}>{s.name}</span>
                    <span className="flex h-4 flex-1 overflow-hidden rounded" style={{ maxWidth: `${(s.total / maxStore) * 100}%` }}>
                      {BUCKETS.map((b) => {
                        const n = s.by_bucket?.[b] ?? 0;
                        if (!n) return null;
                        return (
                          <span
                            key={b}
                            className={BUCKET_COLOR[b]}
                            style={{ width: `${(n / s.total) * 100}%` }}
                            title={`${s.name} ${BUCKET_LABEL[b]}：${num(n)} 張`}
                          />
                        );
                      })}
                    </span>
                    <span className="w-24 shrink-0 tabular-nums text-zinc-500">
                      {num(s.total)} 張
                      {s.over_30 > 0 && <span className="ml-1 text-red-600 dark:text-red-400">/{num(s.over_30)}</span>}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {/* 該打電話的名單 */}
          <div>
            <div className="mb-1.5 text-xs font-semibold text-zinc-500">
              放最久的 {data.oldest.length} 張（建議優先聯絡）
            </div>
            <div className="max-h-64 overflow-y-auto rounded border border-zinc-200 dark:border-zinc-800">
              <table className="min-w-full text-xs">
                <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {data.oldest.map((o) => (
                    <tr key={o.id}>
                      <td className="px-2 py-1.5 font-mono text-[11px] text-zinc-500">{o.order_no}</td>
                      <td className="px-2 py-1.5">{o.store ?? "—"}</td>
                      <td className="max-w-56 truncate px-2 py-1.5" title={o.nickname ?? ""}>{o.nickname ?? "—"}</td>
                      <td className="px-2 py-1.5 text-right tabular-nums font-medium text-red-600 dark:text-red-400">
                        {o.age_days} 天
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <p className="text-[11px] text-zinc-500">
            只算「貨已到店在等人」的訂單（可取貨 / 部分取貨）；還沒到貨的不列入，催也沒用。
            貨齡自到貨日起算。
          </p>
        </div>
      )}
    </div>
  );
}
