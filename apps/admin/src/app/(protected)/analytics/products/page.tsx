"use client";

// 商品分析 —— 兩張圖：標籤滲透率趨勢、斷貨率。
// 客人面的在 /analytics/members，地區面的在 /analytics/regions。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ChartCard, Seg, money, num, pct, useMeasuredWidth } from "@/components/ChartKit";

type TagTrend = {
  weeks: { wk: string; buyers: number }[];
  tags: { id: number; name: string; group: string; buyers: number }[];
  cells: { wk: string; tag_id: number; buyers: number; pen: number }[];
};
type Stockout = {
  days: number; items: number; stockouts: number; lost_amount: number;
  by_week: { wk: string; items: number; stockouts: number; rate: number }[];
  by_store: { store_id: number; name: string; items: number; stockouts: number; rate: number }[];
  top_products: { id: number; name: string; items: number; stockouts: number; rate: number; lost_amount: number }[];
};

export default function ProductAnalyticsPage() {
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">商品分析</h1>
        <p className="text-sm text-zinc-500">哪些品類在長、哪些在退，以及哪些商品常常開了團卻拿不到貨</p>
      </header>
      <TagTrendCard />
      <StockoutCard />
    </div>
  );
}

// ────────────────────────────── 標籤滲透率趨勢 ──────────────────────────────

// 折線用的顏色（最多同時看 6 條，再多就看不出誰是誰）
const LINE_COLORS = ["#ef4444", "#3b82f6", "#10b981", "#f59e0b", "#8b5cf6", "#ec4899"];
const MAX_LINES = 6;

function TagTrendCard() {
  const [weeks, setWeeks] = useState(12);
  const [data, setData] = useState<TagTrend | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sel, setSel] = useState<number[]>([]);
  const [wrapRef, width] = useMeasuredWidth<HTMLDivElement>();

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase()
        .rpc("rpc_tag_penetration_trend", { p_weeks: weeks });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      const d = rows as TagTrend;
      setData(d);
      // 預設看買家數最多的 5 個標籤
      setSel((cur) => (cur.length ? cur : d.tags.slice(0, 5).map((t) => t.id)));
    })();
    return () => { cancelled = true; };
  }, [weeks]);

  const wks = useMemo(() => (data?.weeks ?? []).map((w) => w.wk), [data]);
  const byTag = useMemo(() => {
    const m = new Map<number, Map<string, number>>();
    for (const c of data?.cells ?? []) {
      if (!m.has(c.tag_id)) m.set(c.tag_id, new Map());
      m.get(c.tag_id)!.set(c.wk, c.pen);
    }
    return m;
  }, [data]);

  // 成長/衰退：拿最後 3 週的平均比前 3 週
  const movers = useMemo(() => {
    if (wks.length < 6) return [];
    const early = wks.slice(0, 3), late = wks.slice(-3);
    const avg = (m: Map<string, number> | undefined, ks: string[]) =>
      ks.reduce((a, k) => a + (m?.get(k) ?? 0), 0) / ks.length;
    return (data?.tags ?? [])
      .filter((t) => t.buyers >= 50)
      .map((t) => {
        const a = avg(byTag.get(t.id), early), b = avg(byTag.get(t.id), late);
        return { tag: t, from: a, to: b, delta: a > 0 ? b / a - 1 : 0 };
      })
      .sort((x, y) => y.delta - x.delta);
  }, [data, byTag, wks]);

  const H = 200;
  const W = Math.max(width, 1);
  const PAD_L = 34, PAD_B = 22, PAD_T = 8, PAD_R = 8;
  const maxPen = useMemo(() => {
    let mx = 0;
    for (const id of sel) for (const w of wks) mx = Math.max(mx, byTag.get(id)?.get(w) ?? 0);
    return Math.max(mx, 0.05);
  }, [sel, wks, byTag]);

  const x = (i: number) => PAD_L + (wks.length > 1 ? (i / (wks.length - 1)) * (W - PAD_L - PAD_R) : 0);
  const y = (v: number) => PAD_T + (1 - v / maxPen) * (H - PAD_T - PAD_B);

  return (
    <ChartCard
      title="標籤滲透率趨勢"
      subtitle="每一週有多少比例的下單客人買了該類別 —— 看品類在長還是在退"
      actions={
        <Seg
          options={[8, 12, 20].map((w) => ({ key: String(w), label: `${w} 週` }))}
          value={String(weeks)} onChange={(v) => setWeeks(Number(v))}
        />
      }
      footer="一個商品可以有多個標籤，各標籤的滲透率不會加總成 100%，所以不畫堆疊圖。最近一週通常還沒跑完，尾巴下彎屬正常。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}

      <div ref={wrapRef}>
        {wks.length > 0 && (
          <svg width={W} height={H} className={loading ? "opacity-50" : ""}>
            {[0, 0.25, 0.5, 0.75, 1].map((g) => (
              <g key={g}>
                <line x1={PAD_L} x2={W - PAD_R} y1={y(maxPen * g)} y2={y(maxPen * g)}
                      className="stroke-zinc-200 dark:stroke-zinc-800" strokeWidth="1" />
                <text x={PAD_L - 4} y={y(maxPen * g) + 3} textAnchor="end" className="fill-zinc-400 text-[10px]">
                  {Math.round(maxPen * g * 100)}%
                </text>
              </g>
            ))}
            {wks.map((w, i) => (
              i % Math.ceil(wks.length / 8) === 0 ? (
                <text key={w} x={x(i)} y={H - 6} textAnchor="middle" className="fill-zinc-400 text-[10px]">
                  {w.slice(5)}
                </text>
              ) : null
            ))}
            {sel.map((id, si) => {
              const m = byTag.get(id);
              const pts = wks.map((w, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(m?.get(w) ?? 0).toFixed(1)}`).join(" ");
              return (
                <g key={id}>
                  <path d={pts} fill="none" stroke={LINE_COLORS[si % LINE_COLORS.length]} strokeWidth="2" />
                  {wks.map((w, i) => (
                    <circle key={w} cx={x(i)} cy={y(m?.get(w) ?? 0)} r="2.5"
                            fill={LINE_COLORS[si % LINE_COLORS.length]}>
                      <title>{`${data?.tags.find((t) => t.id === id)?.name} ${w.slice(5)}：${pct(m?.get(w) ?? 0, 1)}`}</title>
                    </circle>
                  ))}
                </g>
              );
            })}
          </svg>
        )}
      </div>

      {/* 標籤選擇 */}
      <div className="mt-2 flex flex-wrap gap-1">
        {(data?.tags ?? []).map((t) => {
          const i = sel.indexOf(t.id);
          const on = i >= 0;
          return (
            <button
              key={t.id}
              type="button"
              onClick={() => setSel((cur) =>
                cur.includes(t.id) ? cur.filter((x) => x !== t.id)
                                   : cur.length >= MAX_LINES ? cur : [...cur, t.id])}
              disabled={!on && sel.length >= MAX_LINES}
              className={`rounded px-1.5 py-0.5 text-[11px] transition ${
                on ? "text-white" : "bg-zinc-100 text-zinc-600 hover:bg-zinc-200 disabled:opacity-40 dark:bg-zinc-800 dark:text-zinc-300"
              }`}
              style={on ? { background: LINE_COLORS[i % LINE_COLORS.length] } : undefined}
            >
              {t.name}
            </button>
          );
        })}
        <span className="ml-1 self-center text-[10px] text-zinc-400">最多同時 {MAX_LINES} 條</span>
      </div>

      {/* 成長 / 衰退 */}
      {movers.length > 0 && (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <MoverList title="成長最多" rows={movers.slice(0, 5)} tone="up" />
          <MoverList title="衰退最多" rows={movers.slice(-5).reverse()} tone="down" />
        </div>
      )}
    </ChartCard>
  );
}

function MoverList({
  title, rows, tone,
}: {
  title: string;
  rows: { tag: { id: number; name: string }; from: number; to: number; delta: number }[];
  tone: "up" | "down";
}) {
  return (
    <div>
      <div className="mb-1 text-xs font-semibold text-zinc-500">{title}（前 3 週 → 後 3 週）</div>
      <ul className="space-y-0.5 text-xs">
        {rows.map((m) => (
          <li key={m.tag.id} className="flex items-baseline justify-between gap-2">
            <span className="truncate">{m.tag.name}</span>
            <span className="shrink-0 tabular-nums text-zinc-500">
              {pct(m.from, 1)} → {pct(m.to, 1)}
              <span className={`ml-1.5 font-medium ${tone === "up" ? "text-red-600 dark:text-red-400" : "text-blue-600 dark:text-blue-400"}`}>
                {m.delta >= 0 ? "+" : ""}{Math.round(m.delta * 100)}%
              </span>
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ────────────────────────────── 斷貨率 ──────────────────────────────

function StockoutCard() {
  const [days, setDays] = useState(90);
  const [data, setData] = useState<Stockout | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase().rpc("rpc_stockout_analysis", { p_days: days });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as Stockout);
    })();
    return () => { cancelled = true; };
  }, [days]);

  const maxRate = Math.max(0.01, ...(data?.by_week ?? []).map((w) => w.rate));

  return (
    <ChartCard
      title="斷貨率"
      subtitle={
        data
          ? `近 ${days} 天 ${num(data.items)} 個品項中有 ${num(data.stockouts)} 個斷貨（${pct(data.stockouts / Math.max(data.items, 1), 2)}）· 少收 ${money(data.lost_amount)}`
          : "載入中…"
      }
      actions={
        <Seg
          options={[30, 90, 180].map((d) => ({ key: String(d), label: `${d} 天` }))}
          value={String(days)} onChange={(v) => setDays(Number(v))}
        />
      }
      footer="斷貨＝品項被標記 stockout_at（開了團但拿不到貨）。少收金額是那些品項的原始金額，是實際飛掉的營收，也是客人失望的次數。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}

      <div className="grid gap-4 lg:grid-cols-2">
        {/* 逐週趨勢 */}
        <div>
          <div className="mb-1.5 text-xs font-semibold text-zinc-500">逐週斷貨率</div>
          <ul className={`space-y-1 ${loading ? "opacity-50" : ""}`}>
            {(data?.by_week ?? []).map((w) => (
              <li key={w.wk} className="flex items-center gap-2 text-xs">
                <span className="w-12 shrink-0 text-zinc-500">{w.wk.slice(5)}</span>
                <span className="h-3 flex-1 overflow-hidden rounded bg-zinc-100 dark:bg-zinc-800">
                  <span className="block h-full rounded bg-amber-500" style={{ width: `${(w.rate / maxRate) * 100}%` }} />
                </span>
                <span className="w-24 shrink-0 text-right tabular-nums text-zinc-500">
                  {pct(w.rate, 1)}（{num(w.stockouts)}）
                </span>
              </li>
            ))}
          </ul>
        </div>

        {/* 各店 */}
        <div>
          <div className="mb-1.5 text-xs font-semibold text-zinc-500">各店斷貨率</div>
          <ul className="max-h-56 space-y-1 overflow-y-auto text-xs">
            {(data?.by_store ?? []).map((s) => (
              <li key={s.store_id} className="flex items-center gap-2">
                <span className="w-16 shrink-0 truncate text-right" title={s.name}>{s.name}</span>
                <span className="h-3 flex-1 overflow-hidden rounded bg-zinc-100 dark:bg-zinc-800">
                  <span className="block h-full rounded bg-amber-500"
                        style={{ width: `${Math.min(100, (s.rate / Math.max(0.01, maxRate)) * 100)}%` }} />
                </span>
                <span className="w-20 shrink-0 text-right tabular-nums text-zinc-500">
                  {pct(s.rate, 1)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      </div>

      {/* 常常拿不到貨的商品 */}
      <div className="mt-4">
        <div className="mb-1.5 text-xs font-semibold text-zinc-500">
          斷貨率最高的商品（該期間至少被訂 20 次才列入）
        </div>
        <div className="overflow-x-auto rounded border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full text-xs">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">商品</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">被訂</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">斷貨</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">斷貨率</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">少收</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {(data?.top_products ?? []).map((p) => (
                <tr key={p.id}>
                  <td className="max-w-sm truncate px-2 py-1.5" title={p.name}>{p.name}</td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">{num(p.items)}</td>
                  <td className="px-2 py-1.5 text-right tabular-nums">{num(p.stockouts)}</td>
                  <td className={`px-2 py-1.5 text-right tabular-nums font-medium ${p.rate >= 0.5 ? "text-red-600 dark:text-red-400" : ""}`}>
                    {pct(p.rate, 0)}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">{money(p.lost_amount)}</td>
                </tr>
              ))}
              {(data?.top_products.length ?? 0) === 0 && (
                <tr><td colSpan={5} className="p-4 text-center text-zinc-500">{loading ? "載入中…" : "這段期間沒有斷貨"}</td></tr>
              )}
            </tbody>
          </table>
        </div>
        <p className="mt-1.5 text-[11px] text-zinc-500">
          斷貨率 100% 的商品代表「每一次訂了都拿不到」—— 那不是缺貨，是這個品項根本不該再開團，
          去 <Link href="/products" className="text-blue-600 hover:underline dark:text-blue-400">商品</Link> 頁下架或換供應商。
        </p>
      </div>
    </ChartCard>
  );
}
