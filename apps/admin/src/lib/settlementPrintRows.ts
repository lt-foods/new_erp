// 月結對帳單列印（finance/receivables/print）「要印哪幾行」的純函式（不碰 React、不碰資料庫），單獨測試：
//   node --test apps/admin/src/lib/settlementPrintRows.test.mjs
//
// 版面規則（老闆 2026-10-07 裁示：一日一行、精簡頁數）：
//   - 店到店四種（空中轉入／出、自由轉入／出）照舊一筆一行，排最前面。
//   - HQ 進貨按台北日期一天一行；退貨沖回也一天一行，排在 HQ 進貨之後。
//   - 金額用原始小數加總、只在畫面顯示時取整數。欄位是 NUMERIC(18,4)／數量 NUMERIC(18,3)，
//     先換成整數萬分位（數量千分位）再加，避免 0.1+0.2 這種浮點誤差讓 .5 的金額取整時差 1 元。
//   - 成本是 null 的行不當 0 加：併日那行另外記「幾項未提供成本」。
//
// 資料來源是月結當下凍結的 store_monthly_settlement_items（列印頁已經載入的那些列），
// ⛔ 不要改用 rpc_store_inbound_daily_summary —— 那支是即時重算，不是月結當時的帳。
// ⚠ received_at 欄位存的是「這筆帳成立的時間」，不一定是收貨時間：
//   HQ 進貨＝總倉派車當下、退貨沖回＝總倉收到退貨當下（產生月結的函式最新版 20260907030000），日期照它切。

export type SettlementEntryType = "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";

type Num = number | string;

/** 列印頁讀進來的月結明細（只列這裡用得到的欄位；PostgREST 的 numeric 可能是字串，一律 Number() 再算） */
export type SettlementPrintItem = {
  id: number;
  transfer_id: number;
  qty_received: Num;
  line_amount: Num | null;
  branch_amount: Num | null;
  received_at: string;
  entry_type: SettlementEntryType;
};

/** 店到店（或任何不併日的類型）：照舊一筆一行，原樣帶著那一列 */
export type SettlementLineRow<T> = { kind: "line"; key: string; date: string; item: T };

/** HQ 進貨／退貨沖回：同一個台北日期併成一行 */
export type SettlementDayRow = {
  kind: "day";
  key: string;
  /** 台北日期 YYYY-MM-DD */
  date: string;
  entryType: "hq_inbound" | "return_out";
  /** 當天出現過的調撥單（不重複，照明細出現順序） */
  transferIds: number[];
  /** 共幾項＝當天明細行數（同「店家每日進貨」頁的品項數，一行算一項） */
  lineCount: number;
  qty: number;
  /** 分店小計合計（原始小數，顯示時才取整） */
  branchAmount: number;
  /** 成本小計合計：只加有成本的行 */
  costAmount: number;
  /** 成本是 null 的行數；> 0 時畫面要標「含未提供成本」，等於 lineCount 時整格就是「未提供成本」 */
  costMissingCount: number;
};

export type SettlementPrintRow<T> = SettlementLineRow<T> | SettlementDayRow;

const STORE_TO_STORE_ORDER: readonly string[] = ["air_in", "air_out", "free_in", "free_out"];
const DAILY_TYPES: readonly SettlementDayRow["entryType"][] = ["hq_inbound", "return_out"];

const MONEY_SCALE = 10_000; // NUMERIC(18,4)
const QTY_SCALE = 1_000; // NUMERIC(18,3)

function toUnits(v: Num | null | undefined, scale: number): number {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? Math.round(n * scale) : 0;
}

/** 成本缺不缺：判斷方式同列印頁 fmtAmount（null／undefined／空字串／不是數字＝未提供成本） */
function costMissing(v: Num | null | undefined): boolean {
  if (v === null || v === undefined || v === "") return true;
  return !Number.isFinite(Number(v));
}

/** 金額精確加總（萬分位整數相加），回傳原始小數 */
export function sumMoney(values: readonly (Num | null | undefined)[]): number {
  let units = 0;
  for (const v of values) units += toUnits(v, MONEY_SCALE);
  return units / MONEY_SCALE;
}

// 台北日期寫法同「店家每日進貨」頁 transfers/settlement/daily/page.tsx 的 taipeiParts()；不看瀏覽器所在時區
const TAIPEI_DATE = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Taipei",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** ISO 時間 → 台北日期 YYYY-MM-DD；解析不了回 "" */
export function taipeiDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : TAIPEI_DATE.format(d);
}

/** "2026-09-03" → "2026/9/3"（跟原本 toLocaleDateString("zh-TW") 印出來的樣子一致） */
export function fmtPrintDate(date: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  return m ? `${m[1]}/${Number(m[2])}/${Number(m[3])}` : "—";
}

/** 最上面那句等式用的金額：$1,234／－$500（負數把全形減號放在 $ 前面），只在這裡取整數 */
export function fmtStatementMoney(v: number): string {
  const n = Number.isFinite(v) ? v : 0;
  const s = Math.abs(n).toLocaleString("zh-TW", { maximumFractionDigits: 0 });
  return n < 0 && s !== "0" ? `－$${s}` : `$${s}`;
}

/** 整張明細的合計（合計列與最上面「貨款總金額」用） */
export function summarizeSettlementItems(items: readonly SettlementPrintItem[]): {
  lineCount: number;
  branchAmount: number;
  costAmount: number;
  costMissingCount: number;
} {
  let branch = 0;
  let cost = 0;
  let missing = 0;
  for (const it of items) {
    branch += toUnits(it.branch_amount, MONEY_SCALE);
    if (costMissing(it.line_amount)) missing += 1;
    else cost += toUnits(it.line_amount, MONEY_SCALE);
  }
  return {
    lineCount: items.length,
    branchAmount: branch / MONEY_SCALE,
    costAmount: cost / MONEY_SCALE,
    costMissingCount: missing,
  };
}

type DayAcc = {
  date: string;
  entryType: SettlementDayRow["entryType"];
  transferIds: number[];
  lineCount: number;
  qtyUnits: number;
  branchUnits: number;
  costUnits: number;
  costMissingCount: number;
};

/**
 * 月結明細 → 要印的列：
 *   店到店四種逐筆（依 空中轉入→空中轉出→自由轉入→自由轉出、再依時間）排最前，
 *   接著 HQ 進貨每天一行、最後退貨沖回每天一行（日期由舊到新）。
 * 不認得的類型（以後新增的）照逐筆印在店到店後面，不會被吞掉 —— 合計才對得上。
 */
export function buildSettlementPrintRows<T extends SettlementPrintItem>(
  items: readonly T[],
): SettlementPrintRow<T>[] {
  const lines: { item: T; date: string; rank: number; time: number }[] = [];
  const days = new Map<string, DayAcc>();

  for (const item of items) {
    const date = taipeiDate(item.received_at);
    const dailyType = DAILY_TYPES.find((t) => t === item.entry_type);
    if (!dailyType) {
      const rank = STORE_TO_STORE_ORDER.indexOf(item.entry_type);
      const time = new Date(item.received_at).getTime();
      lines.push({
        item,
        date,
        rank: rank >= 0 ? rank : STORE_TO_STORE_ORDER.length,
        time: Number.isNaN(time) ? 0 : time,
      });
      continue;
    }
    const key = `${dailyType}|${date}`;
    let acc = days.get(key);
    if (!acc) {
      acc = {
        date,
        entryType: dailyType,
        transferIds: [],
        lineCount: 0,
        qtyUnits: 0,
        branchUnits: 0,
        costUnits: 0,
        costMissingCount: 0,
      };
      days.set(key, acc);
    }
    if (!acc.transferIds.includes(item.transfer_id)) acc.transferIds.push(item.transfer_id);
    acc.lineCount += 1;
    acc.qtyUnits += toUnits(item.qty_received, QTY_SCALE);
    acc.branchUnits += toUnits(item.branch_amount, MONEY_SCALE);
    if (costMissing(item.line_amount)) acc.costMissingCount += 1;
    else acc.costUnits += toUnits(item.line_amount, MONEY_SCALE);
  }

  lines.sort((a, b) => a.rank - b.rank || a.time - b.time || a.item.id - b.item.id);

  const dayRows: SettlementDayRow[] = Array.from(days.values())
    .sort(
      (a, b) =>
        DAILY_TYPES.indexOf(a.entryType) - DAILY_TYPES.indexOf(b.entryType) ||
        (a.date < b.date ? -1 : a.date > b.date ? 1 : 0),
    )
    .map((d) => ({
      kind: "day",
      key: `day-${d.entryType}-${d.date}`,
      date: d.date,
      entryType: d.entryType,
      transferIds: d.transferIds,
      lineCount: d.lineCount,
      qty: d.qtyUnits / QTY_SCALE,
      branchAmount: d.branchUnits / MONEY_SCALE,
      costAmount: d.costUnits / MONEY_SCALE,
      costMissingCount: d.costMissingCount,
    }));

  return [
    ...lines.map((l): SettlementLineRow<T> => ({ kind: "line", key: `line-${l.item.id}`, date: l.date, item: l.item })),
    ...dayRows,
  ];
}
