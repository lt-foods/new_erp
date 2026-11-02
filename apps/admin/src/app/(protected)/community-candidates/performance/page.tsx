"use client";

// 推薦成效 —— 推薦系統 ⑧ 回寫 + ⑨ 評估（20261101000180）。
// 每週一回測 3～4 週前第一次開、已結束的團（backtest），以及真的從候選池排程出去的團
// 預估 vs 實際（live）。排名相關 ρ 低於 0.5 就該換模型版本。
// 定義寫在 migration 檔頭，這頁只畫。

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import ConfidenceChevrons, { confidenceTextColor, PredictRange } from "@/components/ConfidenceChevrons";

type EvalRun = {
  id: number;
  kind: "backtest" | "live" | "daily";
  model_version: string;
  window_from: string | null;
  window_to: string | null;
  n: number;
  rho: number | null;
  mae: number | null;
  median_ae: number | null;
  top_bottom_ratio: number | null;
  zero_rate: number | null;
  ratio_median: number | null;
  coverage: number | null;
  accept_rate: number | null;
  details: { slates?: { accepted: number; skipped: number; expired: number } } | null;
  run_at: string;
};

type Outcome = {
  candidate_id: number;
  predicted: number | null;
  low: number | null;
  high: number | null;
  confidence: "high" | "mid" | "low" | null;
  slate_status: string | null;
  /** manual = 人工排；reco = 週曆系統預選排入；reco_explore = 新嘗試名額（20261101000240） */
  source: "manual" | "reco" | "reco_explore" | null;
  start_date: string | null;
  buyers_24h: number | null;
  buyers_7d: number | null;
  buyers_final: number | null;
  settled: boolean;
  candidate: { product_name_hint: string | null } | null;
};

const SOURCE_LABEL = { manual: "人工排", reco: "系統推薦", reco_explore: "系統推薦・新嘗試" } as const;

/** 人工排 vs 系統推薦：近 30 天開的總倉團，依來源（rpc_reco_source_compare，20261101000250） */
type SourceCompare = {
  source: "manual" | "reco" | "reco_explore";
  campaigns: number;
  settled: number;
  avg_buyers: number | null;
  median_buyers: number | null;
  avg_predicted: number | null;
  beat_rate: number | null;
  avg_24h: number | null;
};
const pct = (v: number | null) => (v == null ? "—" : `${(Number(v) * 100).toFixed(0)}%`);
const n1 = (v: number | null) => (v == null ? "—" : Number(v).toLocaleString("zh-TW", { maximumFractionDigits: 1 }));
const md = (s: string | null) => (s ? `${Number(s.slice(5, 7))}/${Number(s.slice(8, 10))}` : "—");

/** ρ 燈號：≥0.6 綠、0.5～0.6 黃、<0.5 紅（該換模型） */
function RhoLight({ rho }: { rho: number | null }) {
  if (rho == null) return <span className="text-zinc-400">—</span>;
  const v = Number(rho);
  const cls = v >= 0.6
    ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300"
    : v >= 0.5
      ? "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300"
      : "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300";
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ${cls}`}>{v.toFixed(2)}</span>;
}

export default function RecoPerformancePage() {
  const [runs, setRuns] = useState<EvalRun[] | null>(null);
  const [outcomes, setOutcomes] = useState<Outcome[]>([]);
  const [compare, setCompare] = useState<SourceCompare[]>([]);
  const [error, setError] = useState<string | null>(null);

  const reload = async () => {
    const sb = getSupabase();
    const [r, o, c] = await Promise.all([
      sb.from("reco_eval_runs").select("*").order("run_at", { ascending: false }).limit(60),
      sb.from("reco_outcomes")
        .select("candidate_id, predicted, low, high, confidence, slate_status, source, start_date, buyers_24h, buyers_7d, buyers_final, settled, candidate:community_product_candidates(product_name_hint)")
        .order("scheduled_at", { ascending: false, nullsFirst: false })
        .limit(1000),
      sb.rpc("rpc_reco_source_compare", { p_days: 30 }),
    ]);
    if (r.error || o.error) setError((r.error ?? o.error)?.message ?? null);
    else setError(null);
    setRuns((r.data as EvalRun[]) ?? []);
    setOutcomes(((o.data as unknown) as Outcome[]) ?? []);
    setCompare((c.data as SourceCompare[]) ?? []);
  };

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    reload();
  }, []);

  // 回測：每個週窗只留最新一次
  const backtests = Object.values(
    (runs ?? []).filter((x) => x.kind === "backtest").reduce<Record<string, EvalRun>>((acc, x) => {
      const k = `${x.window_from}~${x.window_to}`;
      if (!acc[k] || acc[k].run_at < x.run_at) acc[k] = x;
      return acc;
    }, {}),
  ).sort((a, b) => String(b.window_from).localeCompare(String(a.window_from)));
  const latestBt = backtests[0] ?? null;
  // 每日回測（昨天關團的團）：最近 14 天
  const dailies = (runs ?? []).filter((x) => x.kind === "daily")
    .sort((a, b) => String(b.window_from).localeCompare(String(a.window_from))).slice(0, 14);
  const live = (runs ?? []).find((x) => x.kind === "live") ?? null;
  const sl = live?.details?.slates;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">推薦成效</h1>
          <p className="mt-0.5 text-sm text-zinc-500">
            預估準不準：每週一回測 3～4 週前第一次開、已結束的團；以及從候選池排出去的團實際賣了幾位
          </p>
        </div>
        <div className="flex gap-2">
          <SpinButton onClick={() => reload()}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900">
            重新整理
          </SpinButton>
          <Link href="/community-candidates/calendar"
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900">
            週曆
          </Link>
        </div>
      </header>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}

      {runs === null ? (
        <div className="text-sm text-zinc-400">載入中…</div>
      ) : (
        <>
          {/* 摘要 */}
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <div className="rounded-lg border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
              <div className="text-xs text-zinc-500">最近一週回測 排名相關</div>
              <div className="mt-1 flex items-center gap-2 text-2xl font-semibold"><RhoLight rho={latestBt?.rho ?? null} /></div>
              <div className="mt-1 text-[11px] text-zinc-400">
                {latestBt ? `${md(latestBt.window_from)}～${md(latestBt.window_to)}・${latestBt.n} 團` : "還沒有回測"}・低於 0.5 要換模型
              </div>
            </div>
            <div className="rounded-lg border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
              <div className="text-xs text-zinc-500">預估前 20% vs 後 20%</div>
              <div className="mt-1 text-2xl font-semibold">{latestBt?.top_bottom_ratio != null ? `${n1(latestBt.top_bottom_ratio)} 倍` : "—"}</div>
              <div className="mt-1 text-[11px] text-zinc-400">實際買家數的倍數，越大代表排前面的真的比較會賣</div>
            </div>
            <div className="rounded-lg border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
              <div className="text-xs text-zinc-500">落在預估區間內</div>
              <div className="mt-1 text-2xl font-semibold">{pct(latestBt?.coverage ?? null)}</div>
              <div className="mt-1 text-[11px] text-zinc-400">誤差中位數 {latestBt?.median_ae != null ? `${n1(latestBt.median_ae)} 位` : "—"}</div>
            </div>
            <div className="rounded-lg border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
              <div className="text-xs text-zinc-500">近 7 天系統預選採納率</div>
              <div className="mt-1 text-2xl font-semibold">{pct(live?.accept_rate ?? null)}</div>
              <div className="mt-1 text-[11px] text-zinc-400">
                {sl ? `排入 ${sl.accepted}・略過 ${sl.skipped}・過期 ${sl.expired}` : "還沒有預選被處理"}
              </div>
            </div>
          </div>

          {/* 人工排 vs 系統推薦 */}
          <section className="rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 px-4 py-2.5 text-sm dark:border-zinc-800">
              <span className="font-medium">人工排 vs 系統推薦</span>
              <span className="text-xs text-zinc-500">近 30 天開的總倉團（不是從系統預選排入的都算人工排）；買家數只算已到貨結束的，預估是開團前算的</span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full whitespace-nowrap text-sm">
                <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
                  <tr>
                    <th className="px-3 py-2 text-left font-medium">來源</th>
                    <th className="px-3 py-2 text-right font-medium">開團</th>
                    <th className="px-3 py-2 text-right font-medium">已結束</th>
                    <th className="px-3 py-2 text-right font-medium">平均買家</th>
                    <th className="px-3 py-2 text-right font-medium">買家中位數</th>
                    <th className="px-3 py-2 text-right font-medium">平均預估</th>
                    <th className="px-3 py-2 text-right font-medium">賣贏預估</th>
                    <th className="px-3 py-2 text-right font-medium">開團 24 小時平均</th>
                  </tr>
                </thead>
                <tbody>
                  {(["manual", "reco", "reco_explore"] as const).map((src) => {
                    const c = compare.find((x) => x.source === src);
                    return (
                      <tr key={src} className="border-t border-zinc-100 dark:border-zinc-800">
                        <td className="px-3 py-2">{SOURCE_LABEL[src]}</td>
                        <td className="px-3 py-2 text-right">{c?.campaigns ?? 0}</td>
                        <td className="px-3 py-2 text-right">{c?.settled ?? 0}</td>
                        <td className="px-3 py-2 text-right font-semibold">{c?.avg_buyers != null ? `${n1(c.avg_buyers)} 位` : "—"}</td>
                        <td className="px-3 py-2 text-right">{c?.median_buyers != null ? `${n1(c.median_buyers)} 位` : "—"}</td>
                        <td className="px-3 py-2 text-right">{c?.avg_predicted != null ? `${n1(c.avg_predicted)} 位` : "—"}</td>
                        <td className="px-3 py-2 text-right" title="實際買家 ≥ 開團前預估的比例">{pct(c?.beat_rate ?? null)}</td>
                        <td className="px-3 py-2 text-right">{c?.avg_24h != null ? `${n1(c.avg_24h)} 位` : "—"}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </section>

          {/* 每日回測 */}
          <section className="rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 px-4 py-2.5 text-sm dark:border-zinc-800">
              <span className="font-medium">每日回測（昨天關團的團）</span>
              <span className="text-xs text-zinc-500">每天 23:53 跑；比的是關團時的買家數，第一次開的商品才算</span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full whitespace-nowrap text-sm">
                <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
                  <tr>
                    <th className="px-3 py-2 text-left font-medium">關團日</th>
                    <th className="px-3 py-2 text-right font-medium">團數</th>
                    <th className="px-3 py-2 text-right font-medium">排名相關</th>
                    <th className="px-3 py-2 text-right font-medium">誤差中位數</th>
                    <th className="px-3 py-2 text-right font-medium">落在區間</th>
                    <th className="px-3 py-2 text-right font-medium">實際÷預估</th>
                  </tr>
                </thead>
                <tbody>
                  {dailies.length === 0 ? (
                    <tr><td colSpan={6} className="px-3 py-6 text-center text-zinc-400">還沒有每日回測</td></tr>
                  ) : dailies.map((b) => (
                    <tr key={b.id} className="border-t border-zinc-100 dark:border-zinc-800">
                      <td className="px-3 py-2">{md(b.window_from)}</td>
                      <td className="px-3 py-2 text-right">{b.n}</td>
                      <td className="px-3 py-2 text-right">
                        {b.n < 10 ? <span className="text-xs text-zinc-400">團太少</span> : <RhoLight rho={b.rho} />}
                      </td>
                      <td className="px-3 py-2 text-right">{b.n && b.median_ae != null ? `${n1(b.median_ae)} 位` : "—"}</td>
                      <td className="px-3 py-2 text-right">{b.n ? pct(b.coverage) : "—"}</td>
                      <td className="px-3 py-2 text-right">{b.n ? n1(b.ratio_median) : "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          {/* 每週回測 */}
          <section className="rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <div className="border-b border-zinc-200 px-4 py-2.5 text-sm font-medium dark:border-zinc-800">每週回測（3～4 週前開、已到貨結束的團）</div>
            <div className="overflow-x-auto">
              <table className="w-full whitespace-nowrap text-sm">
                <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
                  <tr>
                    <th className="px-3 py-2 text-left font-medium">開團週</th>
                    <th className="px-3 py-2 text-right font-medium">團數</th>
                    <th className="px-3 py-2 text-right font-medium">排名相關</th>
                    <th className="px-3 py-2 text-right font-medium">誤差中位數</th>
                    <th className="px-3 py-2 text-right font-medium">前/後 20% 倍數</th>
                    <th className="px-3 py-2 text-right font-medium">落在區間</th>
                    <th className="px-3 py-2 text-right font-medium">實際÷預估</th>
                    <th className="px-3 py-2 text-right font-medium">0 買家</th>
                  </tr>
                </thead>
                <tbody>
                  {backtests.length === 0 ? (
                    <tr><td colSpan={8} className="px-3 py-6 text-center text-zinc-400">還沒有回測</td></tr>
                  ) : backtests.map((b) => (
                    <tr key={b.id} className="border-t border-zinc-100 dark:border-zinc-800">
                      <td className="px-3 py-2">{md(b.window_from)}～{md(b.window_to)}</td>
                      <td className="px-3 py-2 text-right">{b.n}</td>
                      <td className="px-3 py-2 text-right"><RhoLight rho={b.rho} /></td>
                      <td className="px-3 py-2 text-right">{b.median_ae != null ? `${n1(b.median_ae)} 位` : "—"}</td>
                      <td className="px-3 py-2 text-right">{b.top_bottom_ratio != null ? `${n1(b.top_bottom_ratio)} 倍` : "—"}</td>
                      <td className="px-3 py-2 text-right">{pct(b.coverage)}</td>
                      <td className="px-3 py-2 text-right" title="1 = 不偏高也不偏低">{n1(b.ratio_median)}</td>
                      <td className="px-3 py-2 text-right">{pct(b.zero_rate)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          {/* 實際排出去的 */}
          <section className="rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 px-4 py-2.5 text-sm dark:border-zinc-800">
              <span className="font-medium">從候選池排出去的團</span>
              <span className="text-xs text-zinc-500">
                上線實績（已結束）{live?.n ? `${live.n} 團・排名相關 ${live.rho != null ? Number(live.rho).toFixed(2) : "—"}` : "還沒有已結束的團"}
              </span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full whitespace-nowrap text-sm">
                <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
                  <tr>
                    <th className="px-3 py-2 text-left font-medium">商品</th>
                    <th className="px-3 py-2 text-left font-medium">來源</th>
                    <th className="px-3 py-2 text-right font-medium">預估</th>
                    <th className="px-3 py-2 text-left font-medium">開團</th>
                    <th className="px-3 py-2 text-right font-medium">24 小時</th>
                    <th className="px-3 py-2 text-right font-medium">7 天</th>
                    <th className="px-3 py-2 text-right font-medium">最終</th>
                  </tr>
                </thead>
                <tbody>
                  {outcomes.length === 0 ? (
                    <tr><td colSpan={7} className="px-3 py-6 text-center text-zinc-400">還沒有帶預估的候選被排程（11/1 起才有預估）</td></tr>
                  ) : outcomes.map((o) => (
                    <tr key={o.candidate_id} className="border-t border-zinc-100 dark:border-zinc-800">
                      <td className="max-w-xs px-3 py-2">
                        <Link href={`/community-candidates?highlight=${o.candidate_id}`} className="line-clamp-1 hover:underline">
                          {o.candidate?.product_name_hint ?? `候選 #${o.candidate_id}`}
                        </Link>
                      </td>
                      <td className="px-3 py-2">
                        {o.source === "reco" || o.source === "reco_explore"
                          ? <span className="rounded bg-violet-50 px-1.5 py-0.5 text-[11px] text-violet-700 dark:bg-violet-950/40 dark:text-violet-300">{SOURCE_LABEL[o.source]}</span>
                          : <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">人工排</span>}
                      </td>
                      <td className="px-3 py-2 text-right">
                        {o.predicted == null ? <span className="text-zinc-400">—</span> : (
                          <>
                            <ConfidenceChevrons level={o.confidence} className="mr-1 align-middle" />
                            <span className={`font-semibold ${confidenceTextColor(o.confidence)}`}>{o.predicted}</span>
                            <span className="ml-1.5 align-middle"><PredictRange low={o.low} high={o.high} value={o.predicted} level={o.confidence} /></span>
                          </>
                        )}
                      </td>
                      <td className="px-3 py-2">{o.start_date ? md(o.start_date) : <span className="text-zinc-400">還沒開</span>}</td>
                      <td className="px-3 py-2 text-right">{o.buyers_24h ?? "—"}</td>
                      <td className="px-3 py-2 text-right">{o.buyers_7d ?? "—"}</td>
                      <td className="px-3 py-2 text-right">
                        {o.buyers_final ?? "—"}
                        {o.start_date && !o.settled && <span className="ml-1 text-[10px] text-amber-600">未結束</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}
    </div>
  );
}
