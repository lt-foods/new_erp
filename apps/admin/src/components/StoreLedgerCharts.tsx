"use client";

import { useMemo, useState } from "react";
import { ChartCard, Seg, useMeasuredWidth } from "@/components/ChartKit";
import { money, num, type LedgerPeriod, type LedgerPeriodDay } from "@/lib/storeLedger";

// 記帳本的兩張圖：每日收支（時間軸）＋ 分類排行。
// 沿用 ChartKit 的 useMeasuredWidth / ChartCard / Seg，畫法跟 /analytics 那幾頁一樣
// 都是量出寬度後手寫 inline SVG（不引圖表套件）。
//
// 配色：綠＝收入、紅＝支出（跟頁面其他地方的徽章語意一致），但**深淺是算出來的**，
// 不是順手抄 emerald-600 / rose-600 —— 那組在紅綠色盲下的 ΔE 只有 5.8，等於兩根
// 一樣的柱子。改用下面這兩組（dataviz validator 全過）：
//   亮色：收入 #047857 / 支出 #fb7185（deutan ΔE 10.6）
//   暗色：收入 #059669 / 支出 #f43f5e（deutan ΔE 8.3；暗色的亮度帶比較窄，要另外挑）
// 而且「收入在上、支出在下」本身就是第二層編碼 —— 就算完全看不出顏色，位置也分得出來。

const INCOME_FILL = "fill-[#047857] dark:fill-[#059669]";
const EXPENSE_FILL = "fill-[#fb7185] dark:fill-[#f43f5e]";
const INCOME_DOT = "bg-[#047857] dark:bg-[#059669]";
const EXPENSE_DOT = "bg-[#fb7185] dark:bg-[#f43f5e]";

/** 軸標用的短金額：1.2萬 / 3,500（軸上塞不下完整數字） */
function axisMoney(v: number): string {
  const a = Math.abs(v);
  if (a >= 10000) return `${(v / 10000).toFixed(a >= 100000 ? 0 : 1)}萬`;
  return Math.round(v).toLocaleString("zh-TW");
}

/** 只留月/日（2026-09-22 → 9/22） */
function mmdd(ymd: string): string {
  const [, m, d] = ymd.split("-");
  return `${Number(m)}/${Number(d)}`;
}

/**
 * 每日收支長條圖。
 * 「收支」：收入朝上、支出朝下，中間一條零線 —— 一眼看得出哪天花得比收得多。
 * 「營業額」：只畫取貨營業額（跟收支差一個量級，混在同一張圖裡支出會被壓成一條線，
 *   所以是切換不是疊加 —— 不做雙 Y 軸）。
 */
export function LedgerDailyChart({
  days,
  onPickDay,
}: {
  days: LedgerPeriodDay[];
  onPickDay?: (ymd: string) => void;
}) {
  const [mode, setMode] = useState<"flow" | "sales">("flow");
  const [wrapRef, width] = useMeasuredWidth<HTMLDivElement>();

  // 日期由舊到新（RPC 回的是新到舊）
  const rows = useMemo(() => [...days].reverse(), [days]);

  const H = 210;
  const W = Math.max(width, 1);
  const PAD_L = 46, PAD_R = 8, PAD_T = 10, PAD_B = 22;
  const plotW = Math.max(W - PAD_L - PAD_R, 1);
  const plotH = H - PAD_T - PAD_B;

  const { maxUp, maxDown } = useMemo(() => {
    let up = 0, down = 0;
    for (const d of rows) {
      if (mode === "sales") up = Math.max(up, num(d.sales_total));
      else {
        up = Math.max(up, num(d.income_all));
        down = Math.max(down, num(d.expense_all));
      }
    }
    return { maxUp: up, maxDown: down };
  }, [rows, mode]);

  const span = Math.max(maxUp + maxDown, 1);
  const yZero = PAD_T + (maxUp / span) * plotH;
  const h = (v: number) => (Math.abs(v) / span) * plotH;

  const step = plotW / Math.max(rows.length, 1);
  const barW = Math.max(Math.min(step - 2, 22), 2);
  const xOf = (i: number) => PAD_L + step * i + (step - barW) / 2;
  // 標籤太密會疊在一起：算出每幾根標一次
  const labelEvery = Math.max(1, Math.ceil(rows.length / Math.max(Math.floor(plotW / 44), 1)));

  return (
    <ChartCard
      title={mode === "sales" ? "每日取貨營業額" : "每日收支"}
      subtitle={
        mode === "sales"
          ? "這段期間每天實際取走的貨（＝日結報表那個數字）"
          : "上面是記進來的收入，下面是支出 —— 柱子往下長得比較多的那天就是花錢的日子"
      }
      actions={
        <Seg
          options={[
            { key: "flow", label: "收支" },
            { key: "sales", label: "營業額" },
          ]}
          value={mode}
          onChange={(v) => setMode(v as "flow" | "sales")}
        />
      }
      footer={
        mode === "sales"
          ? "營業額跟店裡的收支差一個量級，混在同一張圖會把支出壓平，所以做成切換而不是疊圖。"
          : "點一根柱子可以跳到那天的帳。數字對照看下面的每日表。"
      }
    >
      <div ref={wrapRef}>
        {rows.length === 0 ? (
          <div className="p-6 text-center text-sm text-zinc-500">這段期間沒有資料。</div>
        ) : (
          <svg width={W} height={H} role="img" aria-label={mode === "sales" ? "每日取貨營業額長條圖" : "每日收支長條圖"}>
            {/* 上下界與零線 */}
            {(mode === "sales" ? [maxUp, 0] : [maxUp, 0, -maxDown]).map((v) => {
              const y = yZero - (v >= 0 ? h(v) : -h(v));
              return (
                <g key={v}>
                  <line
                    x1={PAD_L} x2={W - PAD_R} y1={y} y2={y}
                    className={v === 0 ? "stroke-zinc-300 dark:stroke-zinc-600" : "stroke-zinc-200 dark:stroke-zinc-800"}
                    strokeWidth="1"
                  />
                  <text x={PAD_L - 5} y={y + 3} textAnchor="end" className="fill-zinc-400 text-[10px]">
                    {v === 0 ? "0" : axisMoney(v)}
                  </text>
                </g>
              );
            })}

            {rows.map((d, i) => {
              const x = xOf(i);
              const income = mode === "sales" ? num(d.sales_total) : num(d.income_all);
              const expense = mode === "sales" ? 0 : num(d.expense_all);
              const tip =
                mode === "sales"
                  ? `${d.ymd}　營業額 ${money(d.sales_total)}（現金 ${money(d.sales_cash)}${num(d.sales_noncash) > 0 ? `・非現金 ${money(d.sales_noncash)}` : ""}）`
                  : `${d.ymd}　收入 ${money(d.income_all)}　支出 ${money(d.expense_all)}${d.closed ? "　已關帳" : ""}`;
              return (
                <g
                  key={d.ymd}
                  className={onPickDay ? "cursor-pointer" : undefined}
                  onClick={onPickDay ? () => onPickDay(d.ymd) : undefined}
                >
                  <title>{tip}</title>
                  {/* 整欄的透明感應區，柱子再細也點得到 */}
                  <rect x={PAD_L + step * i} y={PAD_T} width={step} height={plotH} fill="transparent" />
                  {income > 0 && (
                    <rect
                      x={x} y={yZero - h(income)} width={barW} height={Math.max(h(income), 1)}
                      rx={Math.min(3, barW / 2)} className={INCOME_FILL}
                    />
                  )}
                  {expense > 0 && (
                    <rect
                      x={x} y={yZero} width={barW} height={Math.max(h(expense), 1)}
                      rx={Math.min(3, barW / 2)} className={EXPENSE_FILL}
                    />
                  )}
                  {i % labelEvery === 0 && (
                    <text x={x + barW / 2} y={H - 6} textAnchor="middle" className="fill-zinc-400 text-[10px]">
                      {mmdd(d.ymd)}
                    </text>
                  )}
                </g>
              );
            })}
          </svg>
        )}
      </div>

      {mode === "flow" && (
        <div className="mt-1 flex items-center gap-4 text-[11px] text-zinc-500">
          <span className="flex items-center gap-1.5">
            <span className={`inline-block h-2.5 w-2.5 rounded-sm ${INCOME_DOT}`} />收入（往上）
          </span>
          <span className="flex items-center gap-1.5">
            <span className={`inline-block h-2.5 w-2.5 rounded-sm ${EXPENSE_DOT}`} />支出（往下）
          </span>
        </div>
      )}
    </ChartCard>
  );
}

/** 分類排行：哪個科目花最多／收最多。橫條比長度，最直觀。 */
export function LedgerCategoryChart({ rows }: { rows: LedgerPeriod["by_category"] }) {
  const [kind, setKind] = useState<"expense" | "income">("expense");

  const bars = useMemo(() => {
    const mine = rows
      .filter((r) => r.kind === kind)
      .map((r) => ({ name: r.name, amount: num(r.amount), cash: num(r.cash), cnt: num(r.cnt) }))
      .sort((a, b) => b.amount - a.amount);
    if (mine.length <= 9) return mine;
    const head = mine.slice(0, 8);
    const tail = mine.slice(8);
    return [
      ...head,
      {
        name: `其他 ${tail.length} 個科目`,
        amount: tail.reduce((a, b) => a + b.amount, 0),
        cash: tail.reduce((a, b) => a + b.cash, 0),
        cnt: tail.reduce((a, b) => a + b.cnt, 0),
      },
    ];
  }, [rows, kind]);

  const max = Math.max(...bars.map((b) => b.amount), 1);
  const total = bars.reduce((a, b) => a + b.amount, 0);

  return (
    <ChartCard
      title={kind === "expense" ? "支出都花在哪" : "收入從哪來"}
      subtitle={`這段期間共 ${money(total)}`}
      actions={
        <Seg
          options={[
            { key: "expense", label: "支出" },
            { key: "income", label: "收入" },
          ]}
          value={kind}
          onChange={(v) => setKind(v as "expense" | "income")}
        />
      }
      footer="長度＝金額。取貨營業額不在這張圖裡（那是賣貨的錢，不是記進帳本的收入）。"
    >
      {bars.length === 0 ? (
        <div className="p-6 text-center text-sm text-zinc-500">
          這段期間沒有{kind === "expense" ? "支出" : "收入"}紀錄。
        </div>
      ) : (
        <div className="flex flex-col gap-1.5">
          {bars.map((b) => (
            <div key={b.name} className="flex items-center gap-2 text-xs" title={`${b.name}　${money(b.amount)}　${b.cnt} 筆`}>
              <span className="w-24 shrink-0 truncate text-zinc-600 dark:text-zinc-300">{b.name}</span>
              <span className="h-4 min-w-0 flex-1 rounded-sm bg-zinc-100 dark:bg-zinc-800">
                <span
                  className={`block h-4 rounded-sm ${kind === "expense" ? "bg-[#fb7185] dark:bg-[#f43f5e]" : "bg-[#047857] dark:bg-[#059669]"}`}
                  style={{ width: `${Math.max((b.amount / max) * 100, 1.5)}%` }}
                />
              </span>
              <span className="w-20 shrink-0 text-right font-mono text-zinc-700 dark:text-zinc-200">{money(b.amount)}</span>
              <span className="w-10 shrink-0 text-right text-[10px] text-zinc-400">{b.cnt} 筆</span>
            </div>
          ))}
        </div>
      )}
    </ChartCard>
  );
}
