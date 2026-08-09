"use client";

// 開團早期訊號 —— 放在開團頁最上面。
//
// 為什麼這張比「開團前的熱銷比」有用：實測開團後 6/12/24 小時的累積訂單，
// 對最終總量的相關係數是 0.64 / 0.75 / 0.81；開團前的屬性預測只有 0.36。
// 首日訂單佔全團 48%，所以第一天沒救起來基本上就定案了 → 這張圖的價值是
// 「今晚就知道哪一團要補推」。
//
// 推估方法見 rpc_campaign_pace：用歷史團建「第 h 小時通常累積了幾成」的中位數
// 曲線，再把進行中的團套上去。不是模型，是同儕比較。

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ChartCard, Seg, num, useMeasuredWidth } from "@/components/ChartKit";

type Pace = {
  median_total: number;
  hist_campaigns: number;
  curve: { h: number; share: number; n: number }[];
  campaigns: {
    id: number; name: string; campaign_no: string; status: string;
    t0: string; elapsed_h: number; orders_now: number;
    med_share: number | null; projected: number | null; vs_median: number | null;
  }[];
};

const DAY_OPTIONS = [3, 7, 14];
// 低於這個倍數就是冷團（相對歷史團的最終訂單中位數）
const COLD = 0.6;
const HOT = 1.5;
// 開團超過這個時數就別列進「要補推」了 —— 首日就佔全團 48%，
// 一個已經開 164 小時、只有 1 單的團不是待辦事項，是已經結束的事實。
const ACTIONABLE_H = 48;

export default function CampaignPacePanel() {
  const [days, setDays] = useState(7);
  const [data, setData] = useState<Pace | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [wrapRef, width] = useMeasuredWidth<HTMLDivElement>();

  const load = useCallback(async () => {
    setLoading(true);
    const { data: rows, error: err } = await getSupabase()
      .rpc("rpc_campaign_pace", { p_days: days, p_hist_days: 90 });
    setLoading(false);
    if (err) { setError(translateRpcError(err)); return; }
    setError(null);
    setData(rows as Pace);
  }, [days]);

  useEffect(() => { load(); }, [load]);

  // 只把「還在爬」的團排進待辦：超過 7 天的團基本上定案了，列出來只是雜訊
  const live = useMemo(
    () => (data?.campaigns ?? []).filter((c) => c.elapsed_h <= 168),
    [data],
  );
  const coldAll = useMemo(
    () => live.filter((c) => c.vs_median != null && c.vs_median < COLD),
    [live],
  );
  // 還來得及補推的排前面，且照「剩下的時間」排序（開越久越沒得救）
  const cold = useMemo(
    () => coldAll.filter((c) => c.elapsed_h <= ACTIONABLE_H)
                 .sort((a, b) => a.elapsed_h - b.elapsed_h),
    [coldAll],
  );
  const coldStale = coldAll.length - cold.length;
  const hot = useMemo(
    () => live.filter((c) => c.vs_median != null && c.vs_median >= HOT)
              .sort((a, b) => (b.vs_median ?? 0) - (a.vs_median ?? 0)),
    [live],
  );

  // 基準曲線：前 72 小時就看得出形狀，畫到 72 小時即可
  const curve = useMemo(() => (data?.curve ?? []).filter((p) => p.h <= 72), [data]);
  const H = 120;
  const W = Math.max(width, 1);
  const path = useMemo(() => {
    if (curve.length === 0 || W <= 1) return "";
    const maxH = 72;
    return curve
      .map((p, i) => {
        const x = 8 + (p.h / maxH) * (W - 16);
        const y = H - 12 - p.share * (H - 24);
        return `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`;
      })
      .join(" ");
  }, [curve, W]);

  const markers = [6, 12, 24, 48];

  return (
    <ChartCard
      title="開團速度（早期訊號）"
      subtitle={
        data
          ? `近 ${days} 天開始的 ${live.length} 團 · 歷史中位數 ${num(data.median_total)} 單／團（取樣 ${num(data.hist_campaigns)} 團）`
          : "載入中…"
      }
      actions={
        <Seg
          options={DAY_OPTIONS.map((d) => ({ key: String(d), label: `${d} 天` }))}
          value={String(days)}
          onChange={(v) => setDays(Number(v))}
        />
      }
      footer="推估方式：拿歷史團「第 h 小時通常已累積最終幾成」的中位數，回推目前這一團的最終量。開團起點取該團第一張訂單的時間。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}

      {/* 基準曲線 */}
      <div ref={wrapRef} className="mb-3">
        {curve.length > 0 && (
          <svg width={W} height={H} className={loading ? "opacity-50" : ""}>
            {[0.25, 0.5, 0.75, 1].map((g) => (
              <line
                key={g} x1={8} x2={W - 8}
                y1={H - 12 - g * (H - 24)} y2={H - 12 - g * (H - 24)}
                className="stroke-zinc-200 dark:stroke-zinc-800" strokeWidth="1"
              />
            ))}
            {markers.map((m) => {
              const x = 8 + (m / 72) * (W - 16);
              const p = curve.find((c) => c.h === m);
              return (
                <g key={m}>
                  <line x1={x} x2={x} y1={8} y2={H - 12} className="stroke-zinc-200 dark:stroke-zinc-800" strokeDasharray="2 2" />
                  <text x={x} y={H - 2} textAnchor="middle" className="fill-zinc-400 text-[10px]">{m}h</text>
                  {p && (
                    <text x={x + 3} y={H - 16 - p.share * (H - 24)} className="fill-zinc-500 text-[10px]">
                      {Math.round(p.share * 100)}%
                    </text>
                  )}
                </g>
              );
            })}
            <path d={path} fill="none" className="stroke-blue-500" strokeWidth="2" />
          </svg>
        )}
        <p className="text-[11px] text-zinc-500">
          基準曲線：開團後第 N 小時，一般團已經累積了最終訂單數的幾成。
        </p>
      </div>

      {/* 該補推的冷團 / 表現超標的熱團 */}
      <div className="grid gap-3 lg:grid-cols-2">
        <PaceList
          title={`要補推的冷團（${cold.length}）· 開團 ${ACTIONABLE_H} 小時內`}
          tone="cold"
          rows={cold}
          empty={`${ACTIONABLE_H} 小時內開的團都沒有明顯落後`}
          medianTotal={data?.median_total ?? 0}
          note={coldStale > 0
            ? `另有 ${coldStale} 團已開超過 ${ACTIONABLE_H} 小時且落後，基本上定案了，沒列進待辦`
            : undefined}
        />
        <PaceList
          title={`跑很快的團（${hot.length}）`}
          tone="hot"
          rows={hot}
          empty="目前沒有特別突出的團"
          medianTotal={data?.median_total ?? 0}
        />
      </div>
    </ChartCard>
  );
}

function PaceList({
  title, tone, rows, empty, medianTotal, note,
}: {
  title: string;
  tone: "cold" | "hot";
  rows: Pace["campaigns"];
  empty: string;
  medianTotal: number;
  note?: string;
}) {
  return (
    <div>
      <div className="mb-1 text-xs font-semibold text-zinc-500">{title}</div>
      {rows.length === 0 ? (
        <p className="py-3 text-center text-xs text-zinc-400">{empty}</p>
      ) : (
        <ul className="space-y-1">
          {rows.slice(0, 8).map((c) => (
            <li key={c.id}>
              <Link
                href={`/campaigns?id=${c.id}`}
                className="flex items-baseline justify-between gap-2 rounded border border-zinc-200 px-2 py-1.5 text-xs transition hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
              >
                <span className="min-w-0 flex-1 truncate" title={c.name}>{c.name}</span>
                <span className="shrink-0 tabular-nums text-zinc-500">
                  開團 {c.elapsed_h}h · 目前 {num(c.orders_now)} 單
                </span>
                <span
                  className={`shrink-0 rounded px-1.5 py-0.5 font-medium tabular-nums ${
                    tone === "cold"
                      ? "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300"
                      : "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"
                  }`}
                  title={`推估最終 ${num(c.projected)} 單，歷史中位數 ${num(medianTotal)} 單`}
                >
                  預估 {num(c.projected)}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
      {note && <p className="mt-1 text-[11px] text-zinc-400">{note}</p>}
    </div>
  );
}
