"use client";

// 廠商評分 —— 這個廠商的貨是不是都很慢到總倉？慢的那幾家，客人取消是不是比較多？
// 資料：rpc_supplier_scorecard / rpc_supplier_scorecard_detail（20261101000030）。
// 定義（送出 = sent_at，到總倉 = 第一張收貨單）寫在 migration 檔頭，這頁只畫。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ChartCard, Seg, num } from "@/components/ChartKit";

type Bucket = { bucket: string; pos: number; orders: number; cancelled: number };
type Month = { mon: string; pos: number; med_days: number | null; over14: number };
type Supplier = {
  id: number; name: string; pos: number; received: number;
  med_days: number | null; p90_days: number | null; over14: number; stockouts: number;
  orders: number; cancelled: number; med_days_30d: number | null;
};
type Scorecard = {
  days: number;
  summary: { pos: number; received: number; p25: number | null; med_days: number | null; p75: number | null; p90: number | null; over14: number; stockouts: number; orders: number; cancelled: number };
  buckets: Bucket[];
  months: Month[];
  suppliers: Supplier[];
};
type DetailRow = {
  id: number; po_no: string; status: string; sent: string; first_rcpt: string | null; days: number | null;
  stockout: boolean; orders: number; cancelled: number; campaigns: string | null;
};

type SortKey = "orders" | "med_days" | "over14_rate" | "stockout_rate" | "cancel_rate";

const rate = (a: number, b: number) => (b > 0 ? a / b : null);
const pct1 = (v: number | null) => (v == null ? "—" : `${(v * 100).toFixed(1)}%`);
const days1 = (v: number | null | undefined) => (v == null ? "—" : `${Number(v).toFixed(1)} 天`);
const fmtDate = (s: string | null) => (s ? new Date(s).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" }) : "—");

export default function SupplierScorecardPage() {
  const [days, setDays] = useState(150);
  const [data, setData] = useState<Scorecard | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sortKey, setSortKey] = useState<SortKey>("cancel_rate");
  const [minPos, setMinPos] = useState(5);
  const [open, setOpen] = useState<Supplier | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const { data: rows, error: err } = await getSupabase().rpc("rpc_supplier_scorecard", { p_days: days });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as Scorecard);
    })();
    return () => { cancelled = true; };
  }, [days]);

  const s = data?.summary;
  const overallCancel = s ? rate(s.cancelled, s.orders) : null;

  const suppliers = useMemo(() => {
    const list = (data?.suppliers ?? []).filter((x) => x.pos >= minPos);
    const key = (x: Supplier): number => {
      switch (sortKey) {
        case "orders": return x.orders;
        case "med_days": return x.med_days ?? -1;
        case "over14_rate": return rate(x.over14, x.received) ?? -1;
        case "stockout_rate": return rate(x.stockouts, x.pos) ?? -1;
        case "cancel_rate": return rate(x.cancelled, x.orders) ?? -1;
      }
    };
    return list.sort((a, b) => key(b) - key(a) || b.orders - a.orders);
  }, [data, sortKey, minPos]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">廠商評分</h1>
        <p className="text-sm text-zinc-500">
          採購送出到總倉收貨要幾天、斷貨多不多，以及這些貨的訂單客人取消了多少。慢又常斷貨的廠商，就是客訴來源。
        </p>
      </header>

      {error && <div className="text-sm text-red-600 dark:text-red-400">{error}</div>}

      {/* 總覽 */}
      <ChartCard
        title="整體"
        subtitle="採購送出 → 總倉第一次收貨（只算已收過的單；斷貨單沒收貨，只進斷貨率）"
        actions={
          <Seg
            options={[90, 150, 365].map((d) => ({ key: String(d), label: `${d} 天` }))}
            value={String(days)} onChange={(v) => setDays(Number(v))}
          />
        }
      >
        {s && (
          <div className={`grid gap-3 sm:grid-cols-3 lg:grid-cols-6 ${loading ? "opacity-50" : ""}`}>
            <Stat label="採購單" value={num(s.pos)} sub={`已收 ${num(s.received)}`} />
            <Stat label="中位天數" value={days1(s.med_days)} sub={`P25 ${days1(s.p25)}・P75 ${days1(s.p75)}`} />
            <Stat label="最慢一成" value={days1(s.p90)} sub="P90" />
            <Stat label="超過 14 天" value={pct1(rate(s.over14, s.received))} sub={`${num(s.over14)} 張`} />
            <Stat label="斷貨率" value={pct1(rate(s.stockouts, s.pos))} sub={`${num(s.stockouts)} 張`} />
            <Stat label="連動訂單取消率" value={pct1(overallCancel)} sub={`${num(s.cancelled)} / ${num(s.orders)}`} />
          </div>
        )}

        <div className="mt-4 grid gap-4 md:grid-cols-2">
          {/* 天數 → 取消率 */}
          <div>
            <div className="mb-1 text-xs font-semibold text-zinc-500">到總倉越慢，客人取消越多</div>
            <table className="min-w-full text-xs">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="px-2 py-1.5 text-left font-medium text-zinc-500">到總倉</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">採購單</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">連動訂單</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">取消率</th>
                </tr>
              </thead>
              <tbody>
                {(data?.buckets ?? []).map((b) => {
                  const r = rate(b.cancelled, b.orders);
                  const hot = overallCancel != null && r != null && r > overallCancel * 1.5;
                  return (
                    <tr key={b.bucket} className="border-t border-zinc-100 dark:border-zinc-800">
                      <td className="px-2 py-1.5">{b.bucket}</td>
                      <td className="px-2 py-1.5 text-right tabular-nums">{num(b.pos)}</td>
                      <td className="px-2 py-1.5 text-right tabular-nums">{num(b.orders)}</td>
                      <td className={`px-2 py-1.5 text-right tabular-nums ${hot ? "font-semibold text-red-600 dark:text-red-400" : ""}`}>{pct1(r)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* 逐月 */}
          <div>
            <div className="mb-1 text-xs font-semibold text-zinc-500">逐月（有沒有在變好）</div>
            <table className="min-w-full text-xs">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="px-2 py-1.5 text-left font-medium text-zinc-500">月份</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">已收單</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">中位天數</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">超過 14 天</th>
                </tr>
              </thead>
              <tbody>
                {(data?.months ?? []).map((m) => (
                  <tr key={m.mon} className="border-t border-zinc-100 dark:border-zinc-800">
                    <td className="px-2 py-1.5">{m.mon.slice(0, 7)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{num(m.pos)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{days1(m.med_days)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{pct1(rate(m.over14, m.pos))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </ChartCard>

      {/* 廠商表 */}
      <ChartCard
        title="各廠商"
        subtitle="點廠商名看那家每一張採購單。紅字 = 比整體差一截（天數 > 14、超過 14 天比例 > 50%、斷貨 > 15%、取消率 > 整體 1.5 倍）"
        actions={
          <>
            <Seg
              options={[
                { key: "cancel_rate", label: "取消率" },
                { key: "med_days", label: "天數" },
                { key: "over14_rate", label: ">14 天" },
                { key: "stockout_rate", label: "斷貨率" },
                { key: "orders", label: "訂單量" },
              ]}
              value={sortKey} onChange={(v) => setSortKey(v as SortKey)}
            />
            <Seg
              options={[1, 5, 15].map((n) => ({ key: String(n), label: `≥${n} 張` }))}
              value={String(minPos)} onChange={(v) => setMinPos(Number(v))}
            />
          </>
        }
        footer="連動訂單 = 該採購單對應的團購訂單（經請購單的來源團）。只算採購單，店家自己進貨、現貨直配不在這裡。"
      >
        <div className="overflow-x-auto">
          <table className={`min-w-full text-xs ${loading ? "opacity-50" : ""}`}>
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">廠商</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">採購單</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">中位天數</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">近 30 天</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">最慢一成</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">超過 14 天</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">斷貨率</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">連動訂單</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">取消率</th>
              </tr>
            </thead>
            <tbody>
              {suppliers.map((x) => {
                const over14 = rate(x.over14, x.received);
                const stock = rate(x.stockouts, x.pos);
                const cancel = rate(x.cancelled, x.orders);
                const bad = (cond: boolean) => (cond ? "font-semibold text-red-600 dark:text-red-400" : "");
                return (
                  <tr key={x.id} className="border-t border-zinc-100 dark:border-zinc-800">
                    <td className="px-2 py-1.5">
                      <button type="button" className="text-blue-600 hover:underline dark:text-blue-400" onClick={() => setOpen(x)}>
                        {x.name}
                      </button>
                    </td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{num(x.pos)}</td>
                    <td className={`px-2 py-1.5 text-right tabular-nums ${bad((x.med_days ?? 0) > 14)}`}>{days1(x.med_days)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">{days1(x.med_days_30d)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{days1(x.p90_days)}</td>
                    <td className={`px-2 py-1.5 text-right tabular-nums ${bad((over14 ?? 0) > 0.5)}`}>{pct1(over14)}</td>
                    <td className={`px-2 py-1.5 text-right tabular-nums ${bad((stock ?? 0) > 0.15)}`}>{pct1(stock)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{num(x.orders)}</td>
                    <td className={`px-2 py-1.5 text-right tabular-nums ${bad(overallCancel != null && (cancel ?? 0) > overallCancel * 1.5)}`}>{pct1(cancel)}</td>
                  </tr>
                );
              })}
              {!loading && suppliers.length === 0 && (
                <tr><td colSpan={9} className="px-2 py-4 text-center text-zinc-400">這段期間沒有符合條件的廠商</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </ChartCard>

      {open && <DetailModal supplier={open} days={days} onClose={() => setOpen(null)} />}
    </div>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded border border-zinc-200 p-2 dark:border-zinc-800">
      <div className="text-[11px] text-zinc-500">{label}</div>
      <div className="text-lg font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-[11px] text-zinc-400">{sub}</div>}
    </div>
  );
}

function DetailModal({ supplier, days, onClose }: { supplier: Supplier; days: number; onClose: () => void }) {
  const [rows, setRows] = useState<DetailRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: err } = await getSupabase()
        .rpc("rpc_supplier_scorecard_detail", { p_supplier_id: supplier.id, p_days: days });
      if (cancelled) return;
      if (err) { setError(translateRpcError(err)); return; }
      setRows((data ?? []) as DetailRow[]);
    })();
    return () => { cancelled = true; };
  }, [supplier.id, days]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="max-h-[85vh] w-full max-w-4xl overflow-auto rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-3 flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold">{supplier.name}</h2>
            <p className="text-xs text-zinc-500">
              近 {days} 天 {num(supplier.pos)} 張採購單・中位 {days1(supplier.med_days)}・最慢一成 {days1(supplier.p90_days)}・
              斷貨 {num(supplier.stockouts)} 張・連動訂單取消 {num(supplier.cancelled)} / {num(supplier.orders)}
            </p>
          </div>
          <button type="button" className="text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200" onClick={onClose}>關閉</button>
        </div>
        {error && <div className="text-sm text-red-600 dark:text-red-400">{error}</div>}
        {!rows && !error && <div className="text-sm text-zinc-400">讀取中…</div>}
        {rows && (
          <table className="min-w-full text-xs">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">採購單</th>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">送出</th>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">到總倉</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">天數</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">訂單</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">取消</th>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">團</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-t border-zinc-100 dark:border-zinc-800">
                  <td className="px-2 py-1.5">
                    <Link href={`/purchase/orders/edit?id=${r.id}`} className="text-blue-600 hover:underline dark:text-blue-400">{r.po_no}</Link>
                    {r.stockout && <span className="ml-1 rounded bg-red-100 px-1 text-[10px] text-red-700 dark:bg-red-900/40 dark:text-red-300">斷貨</span>}
                  </td>
                  <td className="px-2 py-1.5">{fmtDate(r.sent)}</td>
                  <td className="px-2 py-1.5">{fmtDate(r.first_rcpt)}</td>
                  <td className={`px-2 py-1.5 text-right tabular-nums ${(r.days ?? 0) > 14 ? "font-semibold text-red-600 dark:text-red-400" : ""}`}>{days1(r.days)}</td>
                  <td className="px-2 py-1.5 text-right tabular-nums">{num(r.orders)}</td>
                  <td className="px-2 py-1.5 text-right tabular-nums">{num(r.cancelled)}</td>
                  <td className="max-w-[280px] truncate px-2 py-1.5 text-zinc-500" title={r.campaigns ?? ""}>{r.campaigns ?? "—"}</td>
                </tr>
              ))}
              {rows.length === 0 && <tr><td colSpan={7} className="px-2 py-4 text-center text-zinc-400">沒有資料</td></tr>}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
