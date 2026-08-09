// 地區（門市）偏好分析的共用型別與換算。
//
// 資料來源：rpc_region_tag_matrix / rpc_region_tag_products（20260809000030）。
// 口徑一律是「人數比例」不是金額 —— 中和店活躍會員 563 人、湖口店 84 人，
// 看絕對值永遠是中和贏，問不出小店的偏好。
// 三個指標的意思見 SQL 檔頭；這裡只負責前端怎麼顯示。

export type RegionStore = {
  id: number;
  code: string;
  name: string;
  is_active: boolean;
  address: string | null;
  buyers: number;
  /** 該店所有標籤的 Σ實際 ÷ Σ期望；>1 = 這家店本來就什麼都買比較多 */
  breadth: number | null;
};

export type RegionTag = {
  id: number;
  code: string;
  name: string;
  group: string;
  buyers: number;
  /** 全店滲透率 */
  base: number;
};

export type RegionCell = {
  store_id: number;
  tag_id: number;
  buyers: number;
  pen: number;
  lift: number | null;
  /** lift ÷ 該店廣度：扣掉「這家店什麼都買比較多」之後的偏好 */
  lift_adj: number | null;
};

export type RegionMatrix = {
  days: number;
  since: string;
  total_buyers: number;
  stores: RegionStore[];
  tags: RegionTag[];
  cells: RegionCell[];
};

export type RegionProduct = {
  id: number;
  name: string;
  buyers: number;
  qty: number;
  amount: number;
  pen: number | null;
  base: number | null;
  lift: number | null;
  lift_adj: number | null;
  tags: string[];
};

export type RegionProducts = {
  store_buyers: number;
  total_buyers: number;
  breadth: number | null;
  products: RegionProduct[];
};

export type Metric = "lift_adj" | "lift" | "pen";

export const METRIC_LABEL: Record<Metric, string> = {
  lift_adj: "偏好指數（校正）",
  lift: "偏好指數（原始）",
  pen: "滲透率",
};

export const DAY_OPTIONS = [30, 90, 180];

/** 門市買家數低於此值的，樣本太小、比例會亂跳，預設不進矩陣 */
export const DEFAULT_MIN_BUYERS = 50;
/** 一個格子至少要這麼多人，數字才值得看（低於此值矩陣裡以灰字呈現） */
export const MIN_CELL_BUYERS = 8;
/**
 * 「亮點」清單另外用較高的門檻：8 人的格子指數可以衝到 2.1，但那是雜訊
 * （實測 90 天：素食 11 人 ×2.12、童趣玩具 14 人 ×1.76 會把真正的發現擠掉）。
 */
export const HIGHLIGHT_MIN_BUYERS = 15;
/** 「亮點」清單的滲透率門檻：指數再高，只有 2% 的人買也沒有經營意義 */
export const HIGHLIGHT_MIN_PEN = 0.1;

export function cellValue(c: RegionCell, metric: Metric): number | null {
  if (metric === "pen") return c.pen;
  return metric === "lift" ? c.lift : c.lift_adj;
}

export function fmtMetric(v: number | null, metric: Metric): string {
  if (v == null) return "—";
  return metric === "pen" ? `${Math.round(v * 100)}%` : v.toFixed(2);
}

/**
 * 格子底色。
 * 偏好指數是「跟大盤比」，所以用雙向色階（紅=偏好、藍=冷淡）；
 * 滲透率是單向的量，用單向紅色深淺。
 */
export function cellColor(v: number | null, metric: Metric, maxPen: number): string {
  if (v == null) return "transparent";
  if (metric === "pen") {
    const t = maxPen > 0 ? Math.min(1, v / maxPen) : 0;
    return `rgba(239,68,68,${(0.06 + 0.5 * t).toFixed(3)})`;
  }
  const d = v - 1;
  if (Math.abs(d) < 0.05) return "transparent";
  const t = Math.min(1, Math.abs(d) / 0.5);
  return d > 0
    ? `rgba(239,68,68,${(0.08 + 0.52 * t).toFixed(3)})`
    : `rgba(59,130,246,${(0.08 + 0.42 * t).toFixed(3)})`;
}

/** 指數 → 白話。老闆看的是這一行，不是 1.34 這個數字。 */
export function liftWord(v: number | null): string {
  if (v == null) return "—";
  if (v >= 1.3) return "特別愛";
  if (v >= 1.15) return "偏愛";
  if (v > 0.85) return "跟大盤差不多";
  if (v > 0.7) return "偏冷";
  return "很冷";
}
