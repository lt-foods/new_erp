"use client";

// 會員分析 —— 三張圖：新客留存三角、RFM 分群、下單時段熱力圖。
// 三張都是「客人的行為」，放同一頁；商品面的在 /analytics/products。

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ChartCard, DOW_LABEL, Seg, heatRed, money, num, pct } from "@/components/ChartKit";

type Cohorts = {
  weeks: number;
  cohorts: { cohort: string; size: number; cells: { offset: number; members: number; pct: number }[] }[];
};
type Rfm = {
  days: number; members: number; amount: number;
  segments: { segment: string; members: number; avg_r: number; avg_f: number; avg_m: number; amount: number }[];
  grid: { r: number; f: number; members: number; amount: number }[];
};
type RfmList = {
  segment: string; total: number;
  members: { id: number; member_no: string; name: string | null; phone: string | null;
             store: string | null; r_days: number; orders: number; amount: number; has_line: boolean }[];
};
type Heatmap = {
  days: number; total: number; max: number;
  cells: { dow: number; h: number; orders: number; members: number }[];
  top: { dow: number; h: number; orders: number }[];
};

// 每一群該做什麼 —— 分群不寫行動建議就只是一張好看的圖
const SEGMENT_NOTE: Record<string, string> = {
  "冠軍": "最近買、買最多。新品優先給他們試，別亂發折扣",
  "忠實": "買很多但最近淡了一點，適合提醒與新品通知",
  "新客潛力": "剛來、次數還少，第二單決定他會不會留下",
  "需喚回": "以前是大戶，最近不見了 —— 最該打的一群",
  "沉睡": "很久沒買、次數也少，用低成本的群發就好",
  "一般": "沒有明顯特徵",
};
const SEGMENT_COLOR: Record<string, string> = {
  "冠軍": "bg-red-500", "忠實": "bg-orange-400", "新客潛力": "bg-emerald-400",
  "需喚回": "bg-amber-500", "沉睡": "bg-zinc-400", "一般": "bg-blue-300",
};

export default function MemberAnalyticsPage() {
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">會員分析</h1>
        <p className="text-sm text-zinc-500">
          新客留得住嗎、哪一群客人值得經營、什麼時間推播最有效
        </p>
      </header>
      <CohortCard />
      <RfmCard />
      <HeatmapCard />
    </div>
  );
}

// ────────────────────────────── 留存三角 ──────────────────────────────

function CohortCard() {
  const [weeks, setWeeks] = useState(12);
  const [data, setData] = useState<Cohorts | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase().rpc("rpc_member_cohorts", { p_weeks: weeks });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as Cohorts);
    })();
    return () => { cancelled = true; };
  }, [weeks]);

  const maxOffset = useMemo(() => {
    let mx = 0;
    for (const c of data?.cohorts ?? []) for (const x of c.cells) if (x.offset > mx) mx = x.offset;
    return Math.min(mx, 16);
  }, [data]);

  return (
    <ChartCard
      title="新客留存三角"
      subtitle="每一週第一次下單的客人，之後第 N 週還有多少比例回來買"
      actions={
        <Seg
          options={[8, 12, 20].map((w) => ({ key: String(w), label: `${w} 週` }))}
          value={String(weeks)} onChange={(v) => setWeeks(Number(v))}
        />
      }
      footer="第 0 週固定是 100%（那一週本來就下了第一單）。橫著看是同一批客人隨時間的流失，直著看是不同批客人在同一個「入會後第 N 週」的表現。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}
      <div className="overflow-x-auto">
        <table className="min-w-full border-collapse text-xs">
          <thead>
            <tr className="bg-zinc-50 dark:bg-zinc-900">
              <th className="sticky left-0 z-10 border-b border-r border-zinc-200 bg-zinc-50 px-2 py-2 text-left font-medium dark:border-zinc-800 dark:bg-zinc-900">
                首購週
              </th>
              <th className="border-b border-zinc-200 px-2 py-2 text-right font-medium dark:border-zinc-800">人數</th>
              {Array.from({ length: maxOffset + 1 }, (_, i) => (
                <th key={i} className="border-b border-zinc-200 px-1.5 py-2 text-center font-medium dark:border-zinc-800">
                  W{i}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {(data?.cohorts ?? []).map((c) => (
              <tr key={c.cohort}>
                <th className="sticky left-0 z-10 whitespace-nowrap border-b border-r border-zinc-200 bg-white px-2 py-1.5 text-left font-medium dark:border-zinc-800 dark:bg-zinc-900">
                  {c.cohort.slice(5)}
                </th>
                <td className="border-b border-zinc-100 px-2 py-1.5 text-right tabular-nums text-zinc-500 dark:border-zinc-800/60">
                  {num(c.size)}
                </td>
                {Array.from({ length: maxOffset + 1 }, (_, i) => {
                  const cell = c.cells.find((x) => x.offset === i);
                  return (
                    <td
                      key={i}
                      style={{ background: cell ? heatRed(cell.pct) : undefined }}
                      title={cell ? `${c.cohort} 第 ${i} 週：${num(cell.members)} 人（${pct(cell.pct, 1)}）` : ""}
                      className="border-b border-zinc-100 px-1.5 py-1.5 text-center tabular-nums dark:border-zinc-800/60"
                    >
                      {cell ? pct(cell.pct) : ""}
                    </td>
                  );
                })}
              </tr>
            ))}
            {(data?.cohorts.length ?? 0) === 0 && (
              <tr><td colSpan={maxOffset + 3} className="p-6 text-center text-zinc-500">{loading ? "載入中…" : "沒有資料"}</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </ChartCard>
  );
}

// ────────────────────────────── RFM ──────────────────────────────

function RfmCard() {
  const [days, setDays] = useState(90);
  const [data, setData] = useState<Rfm | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [picked, setPicked] = useState<string | null>(null);
  const [list, setList] = useState<RfmList | null>(null);
  const [listLoading, setListLoading] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase().rpc("rpc_member_rfm", { p_days: days });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as Rfm);
    })();
    return () => { cancelled = true; };
  }, [days]);

  const openList = useCallback(async (segment: string) => {
    setPicked(segment);
    setListLoading(true);
    setList(null);
    const { data: rows, error: err } = await getSupabase()
      .rpc("rpc_member_rfm_list", { p_segment: segment, p_days: days, p_limit: 500 });
    setListLoading(false);
    if (!err) setList(rows as RfmList);
  }, [days]);

  const maxCell = useMemo(() => Math.max(1, ...(data?.grid ?? []).map((g) => g.members)), [data]);

  function exportCsv() {
    if (!list) return;
    const head = ["會員編號", "姓名", "電話", "門市", "距今天數", "訂單數", "金額", "已綁LINE"];
    const body = list.members.map((m) => [
      m.member_no, m.name ?? "", m.phone ?? "", m.store ?? "",
      m.r_days, m.orders, Math.round(m.amount), m.has_line ? "是" : "否",
    ]);
    const csv = [head, ...body].map((r) => r.map((v) => `"${String(v).replace(/"/g, '""')}"`).join(",")).join("\n");
    const url = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `RFM-${list.segment}-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  return (
    <ChartCard
      title="會員 RFM 分群"
      subtitle={
        data
          ? `近 ${days} 天有下單的 ${num(data.members)} 位會員 · 合計 ${money(data.amount)}`
          : "載入中…"
      }
      actions={
        <Seg
          options={[30, 90, 180].map((d) => ({ key: String(d), label: `${d} 天` }))}
          value={String(days)} onChange={(v) => setDays(Number(v))}
        />
      }
      footer="R=最近一次下單距今天數、F=訂單數、M=金額，三個都取五分位（R 反轉，越近分數越高）。點一群可以看名單並匯出 CSV。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_260px]">
        {/* 分群清單 */}
        <div>
          <ul className="space-y-1.5">
            {(data?.segments ?? []).map((s) => (
              <li key={s.segment}>
                <button
                  type="button"
                  onClick={() => openList(s.segment)}
                  className={`w-full rounded-md border px-3 py-2 text-left transition ${
                    picked === s.segment
                      ? "border-zinc-400 bg-zinc-50 dark:border-zinc-600 dark:bg-zinc-800"
                      : "border-zinc-200 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
                  }`}
                >
                  <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <span className="flex items-center gap-1.5 text-sm font-semibold">
                      <span className={`inline-block h-2.5 w-2.5 rounded-full ${SEGMENT_COLOR[s.segment] ?? "bg-zinc-400"}`} />
                      {s.segment}
                    </span>
                    <span className="text-xs tabular-nums text-zinc-500">
                      {num(s.members)} 人（{pct(data ? s.members / data.members : 0)}）· {money(s.amount)}
                    </span>
                  </div>
                  <div className="mt-0.5 flex flex-wrap gap-x-3 text-[11px] text-zinc-500">
                    <span>平均 {s.avg_r} 天前買過</span>
                    <span>{s.avg_f} 單</span>
                    <span>{money(s.avg_m)}</span>
                  </div>
                  <div className="mt-0.5 text-[11px] text-zinc-400">{SEGMENT_NOTE[s.segment]}</div>
                </button>
              </li>
            ))}
            {(data?.segments.length ?? 0) === 0 && (
              <li className="py-6 text-center text-sm text-zinc-500">{loading ? "載入中…" : "沒有資料"}</li>
            )}
          </ul>
        </div>

        {/* R×F 網格 */}
        <div>
          <div className="mb-1 text-xs font-semibold text-zinc-500">R × F 分佈</div>
          <table className="w-full border-collapse text-[11px]">
            <thead>
              <tr>
                <th className="p-1 text-right font-normal text-zinc-400">F↓ R→</th>
                {[1, 2, 3, 4, 5].map((r) => <th key={r} className="p-1 font-normal text-zinc-400">{r}</th>)}
              </tr>
            </thead>
            <tbody>
              {[5, 4, 3, 2, 1].map((f) => (
                <tr key={f}>
                  <th className="p-1 text-right font-normal text-zinc-400">{f}</th>
                  {[1, 2, 3, 4, 5].map((r) => {
                    const g = (data?.grid ?? []).find((x) => x.r === r && x.f === f);
                    return (
                      <td
                        key={r}
                        style={{ background: g ? heatRed(g.members / maxCell) : undefined }}
                        title={g ? `R${r} F${f}：${num(g.members)} 人 · ${money(g.amount)}` : ""}
                        className="border border-zinc-100 p-1 text-center tabular-nums dark:border-zinc-800"
                      >
                        {g ? num(g.members) : ""}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-1 text-[10px] text-zinc-400">右上角＝最近又常買；左下角＝很久沒來又買很少</p>
        </div>
      </div>

      {/* 名單 */}
      {picked && (
        <div className="mt-4 rounded-md border border-zinc-200 dark:border-zinc-800">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 px-3 py-2 dark:border-zinc-800">
            <span className="text-sm font-semibold">
              {picked} 名單
              {list && <span className="ml-2 text-xs font-normal text-zinc-500">
                共 {num(list.total)} 人，顯示前 {list.members.length} 位（依金額）
              </span>}
            </span>
            <div className="flex items-center gap-2">
              <button
                type="button" onClick={exportCsv} disabled={!list || list.members.length === 0}
                className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                匯出 CSV
              </button>
              <button type="button" onClick={() => { setPicked(null); setList(null); }}
                      className="text-xs text-blue-600 hover:underline dark:text-blue-400">
                關閉
              </button>
            </div>
          </div>
          <div className="max-h-72 overflow-y-auto">
            <table className="min-w-full text-xs">
              <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="px-2 py-1.5 text-left font-medium text-zinc-500">會員</th>
                  <th className="px-2 py-1.5 text-left font-medium text-zinc-500">門市</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">距今</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">訂單</th>
                  <th className="px-2 py-1.5 text-right font-medium text-zinc-500">金額</th>
                  <th className="px-2 py-1.5 text-center font-medium text-zinc-500">LINE</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                {listLoading ? (
                  <tr><td colSpan={6} className="p-4 text-center text-zinc-500">載入中…</td></tr>
                ) : (list?.members ?? []).map((m) => (
                  <tr key={m.id}>
                    <td className="px-2 py-1.5">
                      <span className="font-mono text-[11px] text-zinc-500">{m.member_no}</span>
                      {m.name && <span className="ml-1.5">{m.name}</span>}
                    </td>
                    <td className="px-2 py-1.5 text-zinc-500">{m.store ?? "—"}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{m.r_days} 天</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{m.orders}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{money(m.amount)}</td>
                    <td className="px-2 py-1.5 text-center">{m.has_line ? "✅" : "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </ChartCard>
  );
}

// ────────────────────────────── 時段熱力圖 ──────────────────────────────

function HeatmapCard() {
  const [days, setDays] = useState(90);
  const [data, setData] = useState<Heatmap | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase()
        .rpc("rpc_order_hour_heatmap", { p_days: days, p_store_id: null });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as Heatmap);
    })();
    return () => { cancelled = true; };
  }, [days]);

  const cellMap = useMemo(() => {
    const m = new Map<string, Heatmap["cells"][number]>();
    for (const c of data?.cells ?? []) m.set(`${c.dow}:${c.h}`, c);
    return m;
  }, [data]);

  const best = data?.top?.[0];

  return (
    <ChartCard
      title="下單時段熱力圖"
      subtitle={
        data
          ? `近 ${days} 天 ${num(data.total)} 張訂單${best ? ` · 最熱：週${DOW_LABEL[best.dow]} ${best.h}:00（${num(best.orders)} 張）` : ""}`
          : "載入中…"
      }
      actions={
        <Seg
          options={[30, 90, 180].map((d) => ({ key: String(d), label: `${d} 天` }))}
          value={String(days)} onChange={(v) => setDays(Number(v))}
        />
      }
      footer="用途：決定 LINE 推播時間。推播要落在客人「正在滑手機」的時段，不是後台方便發的時段。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}
      <div className="overflow-x-auto">
        <table className={`border-collapse text-[10px] ${loading ? "opacity-50" : ""}`}>
          <thead>
            <tr>
              <th className="px-1 py-0.5" />
              {Array.from({ length: 24 }, (_, h) => (
                <th key={h} className="px-0.5 py-0.5 text-center font-normal text-zinc-400">
                  {h % 3 === 0 ? h : ""}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {[1, 2, 3, 4, 5, 6, 0].map((dow) => (
              <tr key={dow}>
                <th className="whitespace-nowrap px-1.5 py-0.5 text-right font-medium text-zinc-500">
                  週{DOW_LABEL[dow]}
                </th>
                {Array.from({ length: 24 }, (_, h) => {
                  const c = cellMap.get(`${dow}:${h}`);
                  // sqrt：線性色階下最熱那格 1,147 張會把其餘全部壓成白色
                  const t = c && data?.max ? Math.sqrt(c.orders / data.max) : 0;
                  return (
                    <td
                      key={h}
                      style={{ background: heatRed(t) }}
                      title={`週${DOW_LABEL[dow]} ${h}:00–${h + 1}:00｜${num(c?.orders ?? 0)} 張 · ${num(c?.members ?? 0)} 人`}
                      className="h-5 w-5 min-w-5 border border-white dark:border-zinc-900"
                    />
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {(data?.top?.length ?? 0) > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5 text-[11px]">
          <span className="text-zinc-500">建議推播時段：</span>
          {data!.top.slice(0, 5).map((t) => (
            <span key={`${t.dow}:${t.h}`} className="rounded bg-red-100 px-1.5 py-0.5 text-red-700 dark:bg-red-950 dark:text-red-300">
              週{DOW_LABEL[t.dow]} {t.h}:00
            </span>
          ))}
        </div>
      )}
    </ChartCard>
  );
}
