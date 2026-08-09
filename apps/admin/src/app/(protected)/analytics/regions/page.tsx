"use client";

// 地區偏好 —— 「哪一區的人特別愛買什麼」
//
// 為什麼全部用人數比例：見 lib/regionPreference.ts 與 20260809000030 的檔頭。
// 這一頁只做三件事：亮點清單（直接給答案）→ 矩陣（自己找）→ 下鑽（看是哪些商品）。

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import {
  cellColor, cellValue, fmtMetric, liftWord,
  DAY_OPTIONS, DEFAULT_MIN_BUYERS, HIGHLIGHT_MIN_BUYERS, HIGHLIGHT_MIN_PEN, MIN_CELL_BUYERS, METRIC_LABEL,
  type Metric, type RegionMatrix, type RegionProducts,
} from "@/lib/regionPreference";

const METRICS: Metric[] = ["lift_adj", "lift", "pen"];

export default function RegionPreferencePage() {
  const [days, setDays] = useState(90);
  const [metric, setMetric] = useState<Metric>("lift_adj");
  const [minBuyers, setMinBuyers] = useState(DEFAULT_MIN_BUYERS);
  const [group, setGroup] = useState<string>("全部");
  const [data, setData] = useState<RegionMatrix | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sel, setSel] = useState<{ storeId: number | null; tagId: number | null } | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase()
        .rpc("rpc_region_tag_matrix", { p_days: days });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as RegionMatrix);
    })();
    return () => { cancelled = true; };
  }, [days]);

  const stores = useMemo(
    () => (data?.stores ?? []).filter((s) => s.buyers >= minBuyers),
    [data, minBuyers],
  );
  const smallStores = useMemo(
    () => (data?.stores ?? []).filter((s) => s.buyers < minBuyers),
    [data, minBuyers],
  );
  const groups = useMemo(() => {
    const g: string[] = [];
    for (const t of data?.tags ?? []) if (!g.includes(t.group)) g.push(t.group);
    return g;
  }, [data]);
  const tags = useMemo(
    () => (data?.tags ?? []).filter((t) => group === "全部" || t.group === group),
    [data, group],
  );

  const cellMap = useMemo(() => {
    const m = new Map<string, (typeof data extends null ? never : RegionMatrix)["cells"][number]>();
    for (const c of data?.cells ?? []) m.set(`${c.store_id}:${c.tag_id}`, c);
    return m;
  }, [data]);

  const maxPen = useMemo(() => {
    let mx = 0;
    for (const c of data?.cells ?? []) if (c.pen > mx) mx = c.pen;
    return mx;
  }, [data]);

  // 亮點：夠多人買（滲透率門檻）+ 樣本夠（人數門檻）之下，校正偏好指數最高的組合
  const highlights = useMemo(() => {
    const storeOk = new Map(stores.map((s) => [s.id, s]));
    const tagById = new Map((data?.tags ?? []).map((t) => [t.id, t]));
    return (data?.cells ?? [])
      .filter((c) => storeOk.has(c.store_id) && tagById.has(c.tag_id))
      .filter((c) => c.pen >= HIGHLIGHT_MIN_PEN && c.buyers >= HIGHLIGHT_MIN_BUYERS && c.lift_adj != null)
      .sort((a, b) => (b.lift_adj ?? 0) - (a.lift_adj ?? 0))
      .slice(0, 12)
      .map((c) => ({ c, store: storeOk.get(c.store_id)!, tag: tagById.get(c.tag_id)! }));
  }, [data, stores]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">地區偏好</h1>
          <p className="text-sm text-zinc-500">
            近 {days} 天 · 全店 {data?.total_buyers?.toLocaleString("zh-TW") ?? "…"} 位下單會員 ·
            一律以「買過的人數比例」計算，不受門市大小影響
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Seg
            options={DAY_OPTIONS.map((d) => ({ key: String(d), label: `${d} 天` }))}
            value={String(days)} onChange={(v) => setDays(Number(v))}
          />
          <Seg
            options={METRICS.map((m) => ({ key: m, label: METRIC_LABEL[m] }))}
            value={metric} onChange={(v) => setMetric(v as Metric)}
          />
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <p className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs leading-relaxed text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
        <b>怎麼看</b>：滲透率＝這家店有多少比例的客人買過該類別；偏好指數＝滲透率 ÷ 全店平均，
        1.00 表示跟大盤一樣、1.30 表示這一區比平均多 30% 的人買。
        <b>校正</b>版本再除掉「這家店本來就什麼都買比較多」的效應（客單品類數高的店會在原始指數上洗版），
        找地區特色請看校正值。一個商品可以同時屬於多個標籤，所以各標籤的滲透率不會加總成 100%。
      </p>

      {/* ── 亮點 ── */}
      <section>
        <h2 className="mb-2 text-sm font-semibold">各區最突出的偏好</h2>
        {highlights.length === 0 ? (
          <p className="text-sm text-zinc-500">{loading ? "載入中…" : "這段期間沒有足夠樣本"}</p>
        ) : (
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {highlights.map(({ c, store, tag }) => (
              <button
                key={`${c.store_id}:${c.tag_id}`}
                type="button"
                onClick={() => setSel({ storeId: c.store_id, tagId: c.tag_id })}
                className="rounded-md border border-zinc-200 bg-white p-3 text-left transition hover:shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
              >
                <div className="flex items-baseline justify-between gap-2">
                  <span className="text-sm font-semibold">{store.name}</span>
                  <span className="rounded bg-red-100 px-1.5 py-0.5 text-[11px] font-medium text-red-700 dark:bg-red-950 dark:text-red-300">
                    ×{(c.lift_adj ?? 0).toFixed(2)}
                  </span>
                </div>
                <div className="mt-0.5 text-sm">
                  {liftWord(c.lift_adj)}<b className="mx-1">{tag.name}</b>
                </div>
                <div className="mt-1 text-[11px] text-zinc-500">
                  {c.buyers} 人買過 · 滲透 {Math.round(c.pen * 100)}%（大盤 {Math.round(tag.base * 100)}%）
                </div>
              </button>
            ))}
          </div>
        )}
      </section>

      {/* ── 矩陣 ── */}
      <section>
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-sm font-semibold">門市 × 標籤 矩陣</h2>
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <label className="flex items-center gap-1.5">
              <span className="text-zinc-500">標籤群組</span>
              <select
                value={group} onChange={(e) => setGroup(e.target.value)}
                className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
              >
                <option value="全部">全部</option>
                {groups.map((g) => <option key={g} value={g}>{g}</option>)}
              </select>
            </label>
            <label className="flex items-center gap-1.5">
              <span className="text-zinc-500">最少買家數</span>
              <input
                type="number" min={1} step={10} value={minBuyers}
                onChange={(e) => setMinBuyers(Math.max(1, Number(e.target.value) || 1))}
                className="w-20 rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
              />
            </label>
          </div>
        </div>

        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full border-collapse text-xs">
            <thead>
              <tr className="bg-zinc-50 dark:bg-zinc-900">
                <th className="sticky left-0 z-10 border-b border-r border-zinc-200 bg-zinc-50 px-2 py-2 text-left font-medium dark:border-zinc-800 dark:bg-zinc-900">
                  門市
                </th>
                {tags.map((t) => (
                  <th
                    key={t.id}
                    title={`${t.name}（${t.group}）· 全店 ${t.buyers} 人買過、滲透 ${Math.round(t.base * 100)}%`}
                    className="border-b border-zinc-200 px-1.5 py-2 text-center font-medium dark:border-zinc-800"
                  >
                    <div className="whitespace-nowrap">{t.name}</div>
                    <div className="font-normal text-[10px] text-zinc-400">{Math.round(t.base * 100)}%</div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {stores.map((s) => (
                <tr key={s.id} className="hover:bg-zinc-50/60 dark:hover:bg-zinc-800/40">
                  <th className="sticky left-0 z-10 whitespace-nowrap border-b border-r border-zinc-200 bg-white px-2 py-1.5 text-left font-medium dark:border-zinc-800 dark:bg-zinc-900">
                    <button
                      type="button"
                      onClick={() => setSel({ storeId: s.id, tagId: null })}
                      className="hover:underline"
                    >
                      {s.name}
                    </button>
                    <div className="font-normal text-[10px] text-zinc-400">
                      {s.buyers} 人
                      {s.breadth != null && ` · 廣度 ${s.breadth.toFixed(2)}`}
                    </div>
                  </th>
                  {tags.map((t) => {
                    const c = cellMap.get(`${s.id}:${t.id}`);
                    const v = c ? cellValue(c, metric) : null;
                    const weak = !c || c.buyers < MIN_CELL_BUYERS;
                    return (
                      <td
                        key={t.id}
                        onClick={() => c && setSel({ storeId: s.id, tagId: t.id })}
                        title={c
                          ? `${s.name} × ${t.name}\n${c.buyers} 人買過（該店 ${s.buyers} 人）\n滲透 ${(c.pen * 100).toFixed(1)}% / 大盤 ${(t.base * 100).toFixed(1)}%\n原始 ${c.lift?.toFixed(2) ?? "—"} · 校正 ${c.lift_adj?.toFixed(2) ?? "—"}`
                          : "這段期間沒有人買"}
                        style={{ background: weak ? undefined : cellColor(v, metric, maxPen) }}
                        className={`cursor-pointer border-b border-zinc-100 px-1.5 py-1.5 text-center tabular-nums dark:border-zinc-800/60 ${
                          weak ? "text-zinc-300 dark:text-zinc-600" : ""
                        }`}
                      >
                        {c ? fmtMetric(v, metric) : "·"}
                      </td>
                    );
                  })}
                </tr>
              ))}
              {stores.length === 0 && (
                <tr>
                  <td colSpan={tags.length + 1} className="p-6 text-center text-zinc-500">
                    {loading ? "載入中…" : "沒有達到最少買家數的門市"}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <p className="mt-1.5 text-[11px] text-zinc-500">
          灰字＝該格買過的人不到 {MIN_CELL_BUYERS} 位，比例不可靠。點格子看是哪些商品。
          {smallStores.length > 0 && (
            <> 樣本不足未列入：{smallStores.map((s) => `${s.name}(${s.buyers})`).join("、")}</>
          )}
        </p>
      </section>

      {sel && data && (
        <DrillDown
          days={days}
          storeId={sel.storeId}
          tagId={sel.tagId}
          storeName={data.stores.find((s) => s.id === sel.storeId)?.name ?? "全店"}
          tagName={data.tags.find((t) => t.id === sel.tagId)?.name ?? null}
          onClose={() => setSel(null)}
        />
      )}
    </div>
  );
}

function DrillDown({
  days, storeId, tagId, storeName, tagName, onClose,
}: {
  days: number;
  storeId: number | null;
  tagId: number | null;
  storeName: string;
  tagName: string | null;
  onClose: () => void;
}) {
  const [data, setData] = useState<RegionProducts | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data: rows, error: err } = await getSupabase().rpc("rpc_region_tag_products", {
      p_store_id: storeId, p_tag_id: tagId, p_days: days, p_limit: 20,
    });
    setLoading(false);
    if (err) { setError(translateRpcError(err)); return; }
    setError(null);
    setData(rows as RegionProducts);
  }, [storeId, tagId, days]);

  useEffect(() => { load(); }, [load]);

  return (
    <section className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
        <div>
          <h2 className="text-sm font-semibold">
            {storeName}{tagName ? ` · ${tagName}` : ""} 的偏好商品
          </h2>
          <p className="text-xs text-zinc-500">
            依「校正偏好指數」排序 —— 這家店買的人比例，比全店平均高多少倍
            {data && ` · 該店 ${data.store_buyers} 位下單會員`}
          </p>
        </div>
        <button type="button" onClick={onClose} className="text-xs text-blue-600 hover:underline dark:text-blue-400">
          關閉
        </button>
      </div>

      {error && <div className="px-4 py-2 text-sm text-red-600 dark:text-red-400">{error}</div>}

      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>商品</Th>
              <Th className="text-right">買過人數</Th>
              <Th className="text-right">本店滲透</Th>
              <Th className="text-right">大盤滲透</Th>
              <Th className="text-right">偏好指數</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {loading ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : (data?.products.length ?? 0) === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">這段期間沒有足夠樣本（買家數需 ≥ 3）</td></tr>
            ) : data!.products.map((p) => (
              <tr key={p.id}>
                <td className="px-3 py-2">
                  <div className="max-w-md truncate" title={p.name}>{p.name}</div>
                  {p.tags.length > 0 && (
                    <div className="mt-0.5 flex flex-wrap gap-1">
                      {p.tags.slice(0, 5).map((t) => (
                        <span key={t} className="rounded bg-zinc-100 px-1 py-0.5 text-[10px] text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
                          {t}
                        </span>
                      ))}
                    </div>
                  )}
                </td>
                <td className="px-3 py-2 text-right tabular-nums">{p.buyers}</td>
                <td className="px-3 py-2 text-right tabular-nums">{p.pen == null ? "—" : `${(p.pen * 100).toFixed(1)}%`}</td>
                <td className="px-3 py-2 text-right tabular-nums text-zinc-500">{p.base == null ? "—" : `${(p.base * 100).toFixed(1)}%`}</td>
                <td className="px-3 py-2 text-right tabular-nums font-medium">
                  {p.lift_adj == null ? "—" : `×${p.lift_adj.toFixed(2)}`}
                  <div className="text-[10px] font-normal text-zinc-400">原始 {p.lift?.toFixed(2) ?? "—"}</div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="border-t border-zinc-200 px-4 py-2 text-[11px] text-zinc-500 dark:border-zinc-800">
        商品分類是用商品名稱自動標的，標錯或漏標請到
        <Link href="/products" className="mx-1 text-blue-600 hover:underline dark:text-blue-400">商品</Link>
        頁調整。
      </div>
    </section>
  );
}

function Seg({
  options, value, onChange,
}: {
  options: { key: string; label: string }[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="inline-flex overflow-hidden rounded-md border border-zinc-300 dark:border-zinc-700">
      {options.map((o) => (
        <button
          key={o.key}
          type="button"
          onClick={() => onChange(o.key)}
          className={`px-2.5 py-1 text-xs transition ${
            o.key === value
              ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
              : "bg-white text-zinc-600 hover:bg-zinc-50 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
