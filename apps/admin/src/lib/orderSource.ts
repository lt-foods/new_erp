// ============================================================
// 顧客訂單品項來源 (customer_order_items.source) 中央定義
//
// Single source of truth — 「這張單是 App 下單還是小幫手代客」的判斷與 label
// 都從這裡 import。
//
// source 是「品項層級」欄位（customer_order_items.source）：
//   - 'pwa'    → 顧客在會員 App（PWA / 外部瀏覽器）自助下單  ＝ App
//   - 'liff'   → 顧客在 LINE 內（LIFF 商城）自助下單          ＝ 商城
//   - 'manual' → 小幫手在後台代客 key 單                      ＝ 小幫手
//   其餘為系統/特殊流程產生（非人工通路）。
//
// pwa / liff 的判斷在會員端做（apps/member/src/lib/clientChannel.ts），
// 由 place_member_order 帶上來；liff-api 只收白名單值，沒帶就退回 'liff'。
// ⚠ 2026-08-08 之前的自助訂單一律是 'liff'（當時沒記執行環境，不回填），
//   所以那段期間的「App」= 0 是預期結果，不是壞掉。
//
// 同一張訂單因為 UNIQUE(tenant, campaign, channel, member) 會合併，
// 顧客 App 自助 + 小幫手在 closed 緩衝期補加可能落在同一張單，
// 故需 summarizeOrderSource() 推導「整單來源」並處理「混合」。
//
// 新增 source 時：
//   1. 加到 ORDER_ITEM_SOURCES tuple + ORDER_SOURCE_META
//   2. 同步 supabase migration 的 CHECK constraint
//      （現行：20260808000020_order_item_source_pwa.sql）
//   3. 若屬「人工下單通路」，加進 SOURCE_TREND_SERIES（訂單頁折線圖 KPI）
// ============================================================

export const ORDER_ITEM_SOURCES = [
  "pwa",
  "liff",
  "manual",
  "screenshot_parse",
  "csv",
  "rollover",
  "store_internal",
  "aid_transfer",
  "walk_in",
] as const;

export type OrderItemSource = (typeof ORDER_ITEM_SOURCES)[number];

export type SourceMeta = {
  /** 完整中文 label（明細頁 / tooltip） */
  label: string;
  /** 精簡 label（列表 badge） */
  short: string;
  icon: string;
  /** Tailwind badge 配色 */
  cls: string;
};

export const ORDER_SOURCE_META: Record<OrderItemSource, SourceMeta> = {
  pwa:              { label: "App 下單",  short: "App",    icon: "📱", cls: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300" },
  liff:             { label: "商城下單",  short: "商城",   icon: "🛍️", cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" },
  manual:           { label: "小幫手",   short: "小幫手", icon: "🧑‍💼", cls: "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-300" },
  screenshot_parse: { label: "截圖解析", short: "截圖",   icon: "🖼️", cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300" },
  csv:              { label: "CSV 匯入", short: "CSV",    icon: "📄", cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300" },
  rollover:         { label: "缺貨遞轉", short: "遞轉",   icon: "↪️", cls: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300" },
  store_internal:   { label: "店長叫貨", short: "店叫",   icon: "🏬", cls: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300" },
  aid_transfer:     { label: "互助轉手", short: "互助",   icon: "🤝", cls: "bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300" },
  walk_in:          { label: "現場銷售", short: "現場",   icon: "🛒", cls: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300" },
};

// 訂單頁「下單來源」折線圖 KPI 的線 —— 只放「人是怎麼下這張單的」三個通路，
// 系統流程（遞轉/互助/匯入…）不畫線，它們不是通路消長的一部分。
// ⚠ walk_in（現場銷售）刻意不放：那是臨櫃結帳，不是線上通路，
//   混進來會讓「App / 商城 / 小幫手」的消長圖說謊。
// color 直接寫死 rgb：SVG stroke 吃不到 Tailwind class，且深/淺色模式共用同一組
// （這三個色相在兩種底色上都夠對比）。順序＝圖例順序。
export const SOURCE_TREND_SERIES: { source: OrderItemSource; label: string; color: string }[] = [
  { source: "pwa",    label: "App",    color: "rgb(59 130 246)" },  // blue-500（blue-600 在深色底上太暗）
  { source: "liff",   label: "商城",   color: "rgb(5 150 105)" },   // emerald-600
  { source: "manual", label: "小幫手", color: "rgb(124 58 237)" },  // violet-600
];

const MIXED_META: SourceMeta = {
  label: "混合來源",
  short: "混合",
  icon: "🔀",
  cls: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
};

const UNKNOWN_META: SourceMeta = {
  label: "—",
  short: "—",
  icon: "",
  cls: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
};

/** 單一品項 source → 標籤 meta；未知值 fallback 成原字串。 */
export function itemSourceMeta(source: string | null | undefined): SourceMeta {
  if (!source) return UNKNOWN_META;
  return ORDER_SOURCE_META[source as OrderItemSource] ?? { ...UNKNOWN_META, label: source, short: source };
}

export type OrderSourceSummary = SourceMeta & {
  kind: "single" | "mixed" | "none";
  /** 各別來源 meta（依首次出現順序）；混合時給細分顯示用。 */
  parts: SourceMeta[];
};

/**
 * 由一張訂單所有品項的 source 推導「整單來源」。
 *   - 全部同一來源 → 該來源標籤（kind: "single"）
 *   - 多種來源     → 「混合」，label 列出各別來源（e.g.「App + 小幫手」）
 *   - 無品項       → kind: "none"
 */
export function summarizeOrderSource(sources: (string | null | undefined)[]): OrderSourceSummary {
  const distinct: string[] = [];
  for (const s of sources) {
    if (!s) continue;
    if (!distinct.includes(s)) distinct.push(s);
  }
  if (distinct.length === 0) return { ...UNKNOWN_META, kind: "none", parts: [] };
  if (distinct.length === 1) {
    const meta = itemSourceMeta(distinct[0]);
    return { ...meta, kind: "single", parts: [meta] };
  }
  const parts = distinct.map(itemSourceMeta);
  return { ...MIXED_META, label: parts.map((p) => p.short).join(" + "), kind: "mixed", parts };
}
