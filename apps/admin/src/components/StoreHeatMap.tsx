"use client";

// 首頁「門市熱賣地圖」
//
// 資料來源：rpc_store_product_heat（20260809000010）。口徑（排除 cancelled /
// expired / transferred_out）在 SQL 裡，前端只負責畫，不要在這裡另外加總或過濾，
// 否則會跟 /orders 的數字對不起來。
//
// 為什麼是自繪 SVG 而不是 Leaflet：全部門市都在北台灣 0.5° 見方的範圍內，需要的
// 只是「相對位置 + 熱度」，不需要街道底圖；換 tile 供應商 / CSP / 額外相依都省了。
// 投影：等距圓柱 + cos(中心緯度) 修正經度，單一縮放比例套 x/y ⇒ 圖上距離等比，
// 右下角的比例尺才有意義（範圍小到不需要 Web Mercator）。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { Seg, useMeasuredWidth } from "@/components/ChartKit";

type TopProduct = { id: number; name: string; orders: number; qty: number; amount: number };
type HeatStore = {
  id: number;
  code: string;
  name: string;
  is_active: boolean;
  address: string | null;
  lat: number | null;
  lng: number | null;
  orders: number;
  members: number;
  qty: number;
  amount: number;
  top: TopProduct[];
};
type ByStore = { store_id: number; orders: number; qty: number; amount: number };
type HeatProduct = {
  id: number;
  name: string;
  orders: number;
  store_count: number;
  qty: number;
  amount: number;
  by_store: ByStore[];
};
type Heat = {
  days: number;
  since: string;
  totals: { orders: number; members: number; qty: number; amount: number };
  stores: HeatStore[];
  products: HeatProduct[];
};

type Metric = "amount" | "qty" | "orders";

const METRICS: { key: Metric; label: string; fmt: (v: number) => string }[] = [
  { key: "amount", label: "金額", fmt: (v) => `$${Math.round(v).toLocaleString("zh-TW")}` },
  { key: "qty", label: "件數", fmt: (v) => `${Math.round(v).toLocaleString("zh-TW")} 件` },
  { key: "orders", label: "訂單", fmt: (v) => `${Math.round(v).toLocaleString("zh-TW")} 單` },
];
const DAY_OPTIONS = [7, 30, 90];

const MAP_H = 380;       // 畫布高度上限；實際高度依資料的長寬比縮（見 naturalHeight）
const MAP_H_MIN = 240;
const PAD = 28;          // 投影邊界留白（px）；泡泡半徑最大 26，留白要蓋得住
const R_MIN = 5;
const R_MAX = 26;

export default function StoreHeatMap({ focusStoreId }: { focusStoreId?: number | null }) {
  const [days, setDays] = useState(30);
  const [metric, setMetric] = useState<Metric>("amount");
  const [data, setData] = useState<Heat | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  // 選了門市 → 看這家店賣什麼；選了商品 → 看這個商品在哪些店賣得好。兩者互斥。
  const [storeSel, setStoreSel] = useState<number | null>(null);
  const [productSel, setProductSel] = useState<number | null>(null);
  const [hover, setHover] = useState<number | null>(null);
  const [wrapRef, width] = useMeasuredWidth<HTMLDivElement>();

  // 頁首選了單一門市時，地圖預設就聚焦那家（店長只看得到自己店的資料，
  // 不先選起來的話右側面板會是空的）
  useEffect(() => {
    setStoreSel(focusStoreId ?? null);
    setProductSel(null);
  }, [focusStoreId]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      const { data: rows, error: err } = await getSupabase().rpc("rpc_store_product_heat", {
        p_days: days,
        p_top: 8,
        p_products: 12,
      });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as Heat);
    })();
    return () => { cancelled = true; };
  }, [days]);

  const fmt = METRICS.find((m) => m.key === metric)!.fmt;
  // 每次 render 都新建 [] 的話，下面幾個 useMemo 的依賴永遠在變
  const stores = useMemo(() => data?.stores ?? [], [data]);
  const product = productSel != null ? data?.products.find((p) => p.id === productSel) ?? null : null;

  // 商品模式：泡泡值換成「該商品在這家店的量」，沒賣的店就是 0
  const valueOf = useMemo(() => {
    if (product) {
      const byStore = new Map(product.by_store.map((b) => [b.store_id, b]));
      return (s: HeatStore) => byStore.get(s.id)?.[metric] ?? 0;
    }
    return (s: HeatStore) => s[metric];
  }, [product, metric]);

  // 已停用又整段期間都沒銷售的店＝純雜訊（線上有 3 家早期試營運店），
  // 讓它們留在圖上只會多幾顆灰點，還會把投影範圍撐大
  const shown = useMemo(() => stores.filter((s) => s.is_active || s.amount > 0), [stores]);
  const plotted = shown.filter((s) => s.lat != null && s.lng != null);
  const unplotted = shown.filter((s) => s.lat == null || s.lng == null);
  // 沒座標又本期有銷售的店最需要被補上，排前面
  const unplottedRanked = [...unplotted].sort((a, b) => b.amount - a.amount);

  // 先算出這個寬度下「剛好裝下所有點」的高度，畫布就用它 —— 固定高度的話，
  // 窄螢幕（手機）會在地圖上下各留一段空白
  const mapH = useMemo(() => naturalHeight(plotted, width), [plotted, width]);
  const layout = useMemo(() => projectStores(plotted, width, mapH), [plotted, width, mapH]);
  const maxVal = Math.max(1, ...plotted.map(valueOf));

  const ranked = useMemo(
    () => shown.map((s) => ({ s, v: valueOf(s) })).sort((a, b) => b.v - a.v),
    [shown, valueOf],
  );

  const selected = storeSel != null ? stores.find((s) => s.id === storeSel) ?? null : null;

  return (
    <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
        <div>
          <h2 className="text-sm font-semibold">門市熱賣地圖</h2>
          <p className="text-xs text-zinc-500">
            近 {days} 天下單（不含取消／逾期／轉出）
            {data && ` · 全店 ${METRICS.find((m) => m.key === metric)!.fmt(data.totals[metric])}`}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Seg
            options={DAY_OPTIONS.map((d) => ({ key: String(d), label: `${d} 天` }))}
            value={String(days)}
            onChange={(v) => setDays(Number(v))}
          />
          <Seg
            options={METRICS.map((m) => ({ key: m.key, label: m.label }))}
            value={metric}
            onChange={(v) => setMetric(v as Metric)}
          />
        </div>
      </div>

      {error && (
        <div className="border-b border-red-200 bg-red-50 px-4 py-2 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="grid gap-0 lg:grid-cols-[minmax(0,1fr)_320px]">
        {/* ── 地圖 ── */}
        <div className="border-b border-zinc-200 p-3 dark:border-zinc-800 lg:border-b-0 lg:border-r">
          <div ref={wrapRef} className="relative w-full">
            {plotted.length === 0 ? (
              <div className="flex h-[240px] items-center justify-center px-6 text-center text-sm text-zinc-500">
                {loading ? "載入中…" : (
                  <span>
                    還沒有任何門市設定經緯度。<br />
                    到 <Link href="/stores" className="text-blue-600 hover:underline dark:text-blue-400">門市</Link> 頁編輯門市、填入「緯度 / 經度」後就會出現在這張圖上。
                  </span>
                )}
              </div>
            ) : (
              <svg
                width={Math.max(width, 1)}
                height={mapH}
                className={loading ? "opacity-50 transition-opacity" : "transition-opacity"}
                onClick={() => { setStoreSel(null); }}
              >
                {/* 底圖：等距網格，只為了給眼睛一個尺度參考，不是行政區界。
                    只鋪在資料的外接框（sheet）上 —— 全幅鋪滿的話，門市擠在一角、
                    其餘半張圖都是空格線，看起來像沒載完 */}
                <defs>
                  <pattern id="heatgrid" width="40" height="40" patternUnits="userSpaceOnUse">
                    <path d="M40 0 L0 0 0 40" fill="none" className="stroke-zinc-200 dark:stroke-zinc-800" strokeWidth="1" />
                  </pattern>
                </defs>
                <rect
                  x={layout.sheet.x} y={layout.sheet.y}
                  width={layout.sheet.w} height={layout.sheet.h}
                  rx="6"
                  fill="url(#heatgrid)"
                  className="stroke-zinc-200 dark:stroke-zinc-800"
                  strokeWidth="1"
                />

                {/* 縣市名（同縣市門市的重心）— 淡淡的方位參考 */}
                {layout.cityLabels.map((c) => (
                  <text
                    key={c.name}
                    x={c.x}
                    y={c.y}
                    textAnchor="middle"
                    className="fill-zinc-300 text-[15px] font-semibold dark:fill-zinc-700"
                  >
                    {c.name}
                  </text>
                ))}

                {/* 泡泡：面積 ∝ 值（半徑走 sqrt），顏色深淺同步，小圖也看得出高低 */}
                {layout.points.map((pt) => {
                  const s = pt.store;
                  const v = valueOf(s);
                  const t = v > 0 ? Math.sqrt(v / maxVal) : 0;
                  const r = v > 0 ? R_MIN + (R_MAX - R_MIN) * t : 3;
                  const active = storeSel === s.id || hover === s.id;
                  return (
                    <g
                      key={s.id}
                      className="cursor-pointer"
                      onMouseEnter={() => setHover(s.id)}
                      onMouseLeave={() => setHover((h) => (h === s.id ? null : h))}
                      onClick={(e) => {
                        e.stopPropagation();
                        setStoreSel((cur) => (cur === s.id ? null : s.id));
                      }}
                    >
                      <circle
                        cx={pt.x}
                        cy={pt.y}
                        r={r}
                        fill={v > 0 ? `rgba(239,68,68,${(0.15 + 0.5 * t).toFixed(3)})` : "rgba(161,161,170,0.25)"}
                        stroke={v > 0 ? "rgb(239,68,68)" : "rgb(161,161,170)"}
                        strokeWidth={active ? 2.5 : 1}
                      />
                      {active && (
                        <circle cx={pt.x} cy={pt.y} r={r + 4} fill="none" stroke="rgb(239,68,68)" strokeWidth="1" strokeDasharray="3 2" />
                      )}
                    </g>
                  );
                })}

                {/* 標籤：貪心避讓，位置都被占走就不標（滑過泡泡仍看得到 tooltip） */}
                {layout.labels.map((l) => (
                  <text
                    key={l.id}
                    x={l.x}
                    y={l.y}
                    textAnchor={l.anchor}
                    strokeWidth="3"
                    style={{ paintOrder: "stroke" }}
                    className="pointer-events-none fill-zinc-700 stroke-white text-[11px] dark:fill-zinc-200 dark:stroke-zinc-900"
                  >
                    {l.text}
                  </text>
                ))}

                {/* 比例尺 */}
                {layout.scaleBar && (
                  <g transform={`translate(${layout.sheet.x + layout.sheet.w - layout.scaleBar.px - 12}, ${layout.sheet.y + layout.sheet.h - 12})`}>
                    <line x1="0" y1="0" x2={layout.scaleBar.px} y2="0" className="stroke-zinc-400 dark:stroke-zinc-500" strokeWidth="2" />
                    <line x1="0" y1="-4" x2="0" y2="4" className="stroke-zinc-400 dark:stroke-zinc-500" strokeWidth="2" />
                    <line x1={layout.scaleBar.px} y1="-4" x2={layout.scaleBar.px} y2="4" className="stroke-zinc-400 dark:stroke-zinc-500" strokeWidth="2" />
                    <text x={layout.scaleBar.px / 2} y="-7" textAnchor="middle" className="fill-zinc-500 text-[10px]">
                      {layout.scaleBar.km} 公里
                    </text>
                  </g>
                )}
              </svg>
            )}

            {/* hover 卡片：跟著泡泡走，不用等點擊就看得到主力商品 */}
            {(() => {
              const pt = layout.points.find((p) => p.store.id === hover);
              if (!pt) return null;
              const s = pt.store;
              const v = valueOf(s);
              const flip = pt.x > Math.max(width, 1) / 2;
              return (
                <div
                  className="pointer-events-none absolute z-10 w-52 rounded-md border border-zinc-200 bg-white/95 p-2 text-xs shadow-lg dark:border-zinc-700 dark:bg-zinc-800/95"
                  style={{ left: flip ? undefined : pt.x + 14, right: flip ? Math.max(width, 1) - pt.x + 14 : undefined, top: Math.min(pt.y, Math.max(mapH - 110, 8)) }}
                >
                  <div className="font-semibold">{s.name}</div>
                  <div className="mt-0.5 text-zinc-500">
                    {product ? `${product.name}：` : ""}{fmt(v)}
                  </div>
                  {!product && s.top.length > 0 && (
                    <div className="mt-1 border-t border-zinc-100 pt-1 dark:border-zinc-700">
                      <div className="text-[10px] text-zinc-400">主力商品</div>
                      {s.top.slice(0, 3).map((p) => (
                        <div key={p.id} className="truncate">{p.name}</div>
                      ))}
                    </div>
                  )}
                </div>
              );
            })()}
          </div>

          {unplottedRanked.length > 0 && (
            <div className="mt-2 flex flex-wrap items-center gap-1.5 text-[11px] text-zinc-500">
              <span>尚未設定座標（不在圖上）：</span>
              {unplottedRanked.slice(0, 8).map((s) => (
                <span key={s.id} className="rounded bg-zinc-100 px-1.5 py-0.5 dark:bg-zinc-800">
                  {s.name}
                  {s.amount > 0 && <span className="ml-1 text-zinc-400">{fmt(valueOf(s))}</span>}
                </span>
              ))}
              {unplottedRanked.length > 8 && <span>等 {unplottedRanked.length} 家</span>}
              <Link href="/stores" className="text-blue-600 hover:underline dark:text-blue-400">去設定 →</Link>
            </div>
          )}
        </div>

        {/* ── 右側面板 ── */}
        <div className="flex max-h-[430px] flex-col overflow-y-auto p-3">
          {product ? (
            <ProductPanel
              product={product}
              stores={stores}
              metric={metric}
              fmt={fmt}
              onBack={() => setProductSel(null)}
              onPickStore={(id) => { setProductSel(null); setStoreSel(id); }}
            />
          ) : selected ? (
            <StorePanel
              store={selected}
              metric={metric}
              fmt={fmt}
              onBack={() => setStoreSel(null)}
              onPickProduct={(id) => { setStoreSel(null); setProductSel(id); }}
            />
          ) : (
            <OverviewPanel
              products={data?.products ?? []}
              ranked={ranked}
              metric={metric}
              fmt={fmt}
              loading={loading}
              onPickProduct={setProductSel}
              onPickStore={setStoreSel}
            />
          )}
        </div>
      </div>
    </div>
  );
}

// ────────────────────────────── 面板 ──────────────────────────────

function OverviewPanel({
  products, ranked, metric, fmt, loading, onPickProduct, onPickStore,
}: {
  products: HeatProduct[];
  ranked: { s: HeatStore; v: number }[];
  metric: Metric;
  fmt: (v: number) => string;
  loading: boolean;
  onPickProduct: (id: number) => void;
  onPickStore: (id: number) => void;
}) {
  const maxP = Math.max(1, ...products.map((p) => p[metric]));
  const maxS = Math.max(1, ...ranked.map((r) => r.v));
  return (
    <>
      <PanelTitle>全店熱賣商品</PanelTitle>
      {products.length === 0 ? (
        <p className="py-4 text-center text-xs text-zinc-500">{loading ? "載入中…" : "這段期間沒有銷售"}</p>
      ) : (
        <ul className="space-y-1">
          {products.map((p, i) => (
            <BarRow
              key={p.id}
              rank={i + 1}
              label={p.name}
              value={fmt(p[metric])}
              ratio={p[metric] / maxP}
              sub={`${p.store_count} 家店有賣`}
              onClick={() => onPickProduct(p.id)}
            />
          ))}
        </ul>
      )}

      <PanelTitle className="mt-4">門市排行</PanelTitle>
      <ul className="space-y-1">
        {ranked.slice(0, 10).map((r, i) => (
          <BarRow
            key={r.s.id}
            rank={i + 1}
            label={r.s.name}
            value={fmt(r.v)}
            ratio={r.v / maxS}
            sub={r.s.top[0]?.name}
            onClick={() => onPickStore(r.s.id)}
          />
        ))}
      </ul>
    </>
  );
}

function StorePanel({
  store, metric, fmt, onBack, onPickProduct,
}: {
  store: HeatStore;
  metric: Metric;
  fmt: (v: number) => string;
  onBack: () => void;
  onPickProduct: (id: number) => void;
}) {
  const max = Math.max(1, ...store.top.map((p) => p[metric]));
  return (
    <>
      <div className="mb-1 flex items-start justify-between gap-2">
        <div>
          <div className="text-sm font-semibold">{store.name}</div>
          <div className="text-[11px] text-zinc-500">{store.address ?? store.code}</div>
        </div>
        <button type="button" onClick={onBack} className="text-xs text-blue-600 hover:underline dark:text-blue-400">
          返回
        </button>
      </div>
      <div className="mb-2 grid grid-cols-3 gap-1 text-center">
        <MiniStat label="金額" value={`$${Math.round(store.amount).toLocaleString("zh-TW")}`} />
        <MiniStat label="訂單" value={store.orders.toLocaleString("zh-TW")} />
        <MiniStat label="會員" value={store.members.toLocaleString("zh-TW")} />
      </div>
      <PanelTitle>這家店賣最好的商品</PanelTitle>
      {store.top.length === 0 ? (
        <p className="py-4 text-center text-xs text-zinc-500">這段期間沒有銷售</p>
      ) : (
        <ul className="space-y-1">
          {store.top.map((p, i) => (
            <BarRow
              key={p.id}
              rank={i + 1}
              label={p.name}
              value={fmt(p[metric])}
              ratio={p[metric] / max}
              sub={`${p.orders} 單`}
              onClick={() => onPickProduct(p.id)}
            />
          ))}
        </ul>
      )}
      <p className="mt-2 text-[11px] text-zinc-400">點商品可看它在各店的分佈</p>
    </>
  );
}

function ProductPanel({
  product, stores, metric, fmt, onBack, onPickStore,
}: {
  product: HeatProduct;
  stores: HeatStore[];
  metric: Metric;
  fmt: (v: number) => string;
  onBack: () => void;
  onPickStore: (id: number) => void;
}) {
  const nameOf = new Map(stores.map((s) => [s.id, s.name]));
  const rows = [...product.by_store].sort((a, b) => b[metric] - a[metric]);
  const max = Math.max(1, ...rows.map((r) => r[metric]));
  return (
    <>
      <div className="mb-1 flex items-start justify-between gap-2">
        <div>
          <div className="text-sm font-semibold">{product.name}</div>
          <div className="text-[11px] text-zinc-500">
            全店 {fmt(product[metric])} · {product.store_count} 家店有賣
          </div>
        </div>
        <button type="button" onClick={onBack} className="shrink-0 text-xs text-blue-600 hover:underline dark:text-blue-400">
          返回
        </button>
      </div>
      <PanelTitle>哪些店賣得好</PanelTitle>
      <ul className="space-y-1">
        {rows.map((r, i) => (
          <BarRow
            key={r.store_id}
            rank={i + 1}
            label={nameOf.get(r.store_id) ?? `#${r.store_id}`}
            value={fmt(r[metric])}
            ratio={r[metric] / max}
            sub={`${r.orders} 單`}
            onClick={() => onPickStore(r.store_id)}
          />
        ))}
      </ul>
    </>
  );
}

// ────────────────────────────── 小元件 ──────────────────────────────

function PanelTitle({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <div className={`mb-1 text-xs font-semibold text-zinc-500 ${className}`}>{children}</div>;
}

function MiniStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded border border-zinc-200 px-1 py-1 dark:border-zinc-800">
      <div className="text-[10px] text-zinc-500">{label}</div>
      <div className="truncate text-xs font-semibold">{value}</div>
    </div>
  );
}

function BarRow({
  rank, label, value, ratio, sub, onClick,
}: {
  rank: number;
  label: string;
  value: string;
  ratio: number;
  sub?: string;
  onClick?: () => void;
}) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        className="w-full rounded px-1 py-1 text-left transition hover:bg-zinc-50 dark:hover:bg-zinc-800"
      >
        <div className="flex items-baseline gap-1.5 text-xs">
          <span className="w-4 shrink-0 text-right text-[10px] text-zinc-400">{rank}</span>
          <span className="min-w-0 flex-1 truncate" title={label}>{label}</span>
          <span className="shrink-0 font-mono text-[11px] text-zinc-600 dark:text-zinc-300">{value}</span>
        </div>
        <div className="ml-5 mt-0.5 h-1.5 overflow-hidden rounded bg-zinc-100 dark:bg-zinc-800">
          <div
            className="h-full rounded bg-red-400/70 dark:bg-red-500/60"
            style={{ width: `${Math.max(2, Math.min(100, ratio * 100))}%` }}
          />
        </div>
        {sub && <div className="ml-5 truncate text-[10px] text-zinc-400">{sub}</div>}
      </button>
    </li>
  );
}

// ────────────────────────────── 投影 ──────────────────────────────

type Point = { store: HeatStore; x: number; y: number };
type LabelBox = { id: number; text: string; x: number; y: number; anchor: "start" | "middle" | "end" };

const KM_PER_DEG_LAT = 110.574;
const SCALE_STEPS_KM = [1, 2, 5, 10, 20, 50, 100];

// 這批座標在給定寬度下的「自然高度」＝ 依資料長寬比等比縮放後需要的高度，
// 夾在 [MAP_H_MIN, MAP_H]。寬螢幕會撞到上限（改由高度決定縮放，左右留白），
// 窄螢幕則剛好貼齊，不會上下留一段空白。
function naturalHeight(stores: HeatStore[], width: number) {
  if (stores.length === 0 || width <= 0) return MAP_H_MIN;
  const lats = stores.map((s) => Number(s.lat));
  const lngs = stores.map((s) => Number(s.lng));
  const latMid = (Math.min(...lats) + Math.max(...lats)) / 2;
  const kx = Math.cos((latMid * Math.PI) / 180);
  const spanX = (Math.max(...lngs) - Math.min(...lngs)) * kx;
  const spanY = Math.max(...lats) - Math.min(...lats);
  if (spanX <= 0) return MAP_H;
  const usableW = Math.max(width - 2 * PAD, 1);
  return Math.round(Math.min(MAP_H, Math.max(MAP_H_MIN, (spanY / spanX) * usableW + 2 * PAD)));
}

function projectStores(stores: HeatStore[], width: number, height: number) {
  const empty = {
    points: [] as Point[],
    labels: [] as LabelBox[],
    cityLabels: [] as { name: string; x: number; y: number }[],
    scaleBar: null as null | { px: number; km: number },
    sheet: { x: 0, y: 0, w: Math.max(width, 1), h: height },
  };
  if (stores.length === 0 || width <= 0) return empty;

  const lats = stores.map((s) => Number(s.lat));
  const lngs = stores.map((s) => Number(s.lng));
  const latMid = (Math.min(...lats) + Math.max(...lats)) / 2;
  const kx = Math.cos((latMid * Math.PI) / 180); // 經度 1° 在此緯度的實際寬度比

  // 投影到「等比座標」（單位＝緯度度數），再單一比例縮放進畫布
  const ux = lngs.map((v) => v * kx);
  const uy = lats.map((v) => -v); // 螢幕 y 往下 = 緯度往南
  const spanX = Math.max(...ux) - Math.min(...ux);
  const spanY = Math.max(...uy) - Math.min(...uy);
  const usableW = Math.max(width - 2 * PAD, 1);
  const usableH = Math.max(height - 2 * PAD, 1);
  // 只有一家店（span=0）時 scale 會變 Infinity，退回一個固定值並置中
  const scale = spanX <= 0 && spanY <= 0
    ? 1
    : Math.min(spanX > 0 ? usableW / spanX : Infinity, spanY > 0 ? usableH / spanY : Infinity);
  const offX = PAD + (usableW - spanX * scale) / 2 - Math.min(...ux) * scale;
  const offY = PAD + (usableH - spanY * scale) / 2 - Math.min(...uy) * scale;

  const points: Point[] = stores.map((s, i) => ({
    store: s,
    x: ux[i] * scale + offX,
    y: uy[i] * scale + offY,
  }));

  // 縣市標：地址前 3 字（臺北市 / 新北市 / 桃園市…）當分組鍵，取該組重心
  const byCity = new Map<string, Point[]>();
  for (const p of points) {
    const city = (p.store.address ?? "").slice(0, 3);
    if (!/^[一-龥]{3}$/.test(city)) continue;
    const arr = byCity.get(city) ?? [];
    arr.push(p);
    byCity.set(city, arr);
  }
  const cityLabels = [...byCity.entries()]
    .filter(([, ps]) => ps.length >= 2)
    .map(([name, ps]) => ({
      name,
      x: ps.reduce((a, p) => a + p.x, 0) / ps.length,
      y: ps.reduce((a, p) => a + p.y, 0) / ps.length,
    }));

  // 資料的外接框（含留白）＝ 底圖那張「地圖紙」。網格與比例尺只畫在裡面。
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const sheet = {
    x: Math.max(0, Math.min(...xs) - PAD),
    y: Math.max(0, Math.min(...ys) - PAD),
    w: Math.min(width, Math.max(...xs) + PAD) - Math.max(0, Math.min(...xs) - PAD),
    h: Math.min(height, Math.max(...ys) + PAD) - Math.max(0, Math.min(...ys) - PAD),
  };

  // 標籤避讓：大店（金額高）先卡位。障礙物含「別家店的泡泡」—— 只避讓其他標籤的話
  // 標籤會壓在圓上，密集區（雙北）整片看不清。四個候選位置都撞到就退回下方硬標
  // （大店先跑，被壓到的是小店，且泡泡本身仍可 hover 看名字）。
  const maxAmount = Math.max(1, ...points.map((p) => p.store.amount));
  const obstacles: { x1: number; y1: number; x2: number; y2: number }[] = points.map((p) => {
    const t = p.store.amount > 0 ? Math.sqrt(p.store.amount / maxAmount) : 0;
    const r = p.store.amount > 0 ? R_MIN + (R_MAX - R_MIN) * t : 3;
    return { x1: p.x - r, y1: p.y - r, x2: p.x + r, y2: p.y + r };
  });
  const labels: LabelBox[] = [];
  const order = [...points].sort((a, b) => b.store.amount - a.store.amount);
  const hits = (box: { x1: number; y1: number; x2: number; y2: number }) =>
    obstacles.some((b) => !(box.x2 < b.x1 || box.x1 > b.x2 || box.y2 < b.y1 || box.y1 > b.y2));
  for (const p of order) {
    const text = p.store.name;
    const w = text.length * 11 + 4;
    const t = p.store.amount > 0 ? Math.sqrt(p.store.amount / maxAmount) : 0;
    const r = p.store.amount > 0 ? R_MIN + (R_MAX - R_MIN) * t : 3;
    const candidates: LabelBox[] = [
      { id: p.store.id, text, x: p.x, y: p.y + r + 12, anchor: "middle" },
      { id: p.store.id, text, x: p.x, y: p.y - r - 5, anchor: "middle" },
      { id: p.store.id, text, x: p.x + r + 4, y: p.y + 4, anchor: "start" },
      { id: p.store.id, text, x: p.x - r - 4, y: p.y + 4, anchor: "end" },
      { id: p.store.id, text, x: p.x + r * 0.8 + 4, y: p.y + r + 12, anchor: "start" },
      { id: p.store.id, text, x: p.x - r * 0.8 - 4, y: p.y - r - 5, anchor: "end" },
    ];
    const box = (c: LabelBox) => {
      const x1 = c.anchor === "start" ? c.x : c.anchor === "end" ? c.x - w : c.x - w / 2;
      return { x1, y1: c.y - 11, x2: x1 + w, y2: c.y + 3 };
    };
    const fits = candidates.find((c) => {
      const b = box(c);
      return b.x1 >= 2 && b.x2 <= width - 2 && b.y1 >= 2 && b.y2 <= height - 2 && !hits(b);
    });
    if (!fits) continue; // 六個位置都被占走就不標（大店先跑，被犧牲的一定是小店）
    obstacles.push(box(fits));
    labels.push(fits);
  }

  // 比例尺：取「不超過 1/5 圖寬」的最大整數公里，寧可短一點也不要長到跨半張圖
  const pxPerKm = scale / KM_PER_DEG_LAT;
  const targetKm = sheet.w / 5 / pxPerKm;
  const km = [...SCALE_STEPS_KM].reverse().find((s) => s <= targetKm) ?? SCALE_STEPS_KM[0];
  const scaleBar = Number.isFinite(pxPerKm) && pxPerKm > 0 ? { px: Math.round(km * pxPerKm), km } : null;

  return { points, labels, cityLabels, scaleBar, sheet };
}
