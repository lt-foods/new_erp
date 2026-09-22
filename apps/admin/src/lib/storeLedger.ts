// 門市記帳本（/finance/daily 的「記帳本」分頁）共用型別與小工具。
// 資料來源：supabase/migrations/20260922030000（表）＋ 20260922030010（RPC）。
//
// ⚠ 付款方式的值要跟 DB 的 CHECK 一致（cash / transfer / credit_card / line_pay / other）；
//   多加一個值要同時改 store_ledger_entries 的 CHECK，不然按下去會被 DB 打回來。

export type LedgerKind = "income" | "expense";

export const PAY_METHODS = ["cash", "transfer", "credit_card", "line_pay", "other"] as const;
export type PayMethod = (typeof PAY_METHODS)[number];

const PAY_LABELS: Record<string, string> = {
  cash: "現金",
  transfer: "轉帳",
  credit_card: "刷卡",
  line_pay: "LINE Pay",
  other: "其他",
};

export function payMethodLabel(m: string | null | undefined): string {
  return PAY_LABELS[m ?? ""] ?? m ?? "—";
}

export type LedgerCategory = {
  id: number;
  store_id: number | null;
  kind: LedgerKind;
  name: string;
  affects_profit: boolean;
  is_system: boolean;
  sort_order: number;
  is_active?: boolean;
  used_count?: number;
};

export type LedgerEntry = {
  id: number;
  entry_date: string;
  direction: LedgerKind;
  category_id: number | null;
  category_name: string;
  affects_profit: boolean;
  amount: number;
  payment_method: string;
  counterparty: string | null;
  note: string | null;
  receipt_no: string | null;
  created_at: string;
  created_by: string | null;
  voided_at: string | null;
  void_reason: string | null;
  voided_by?: string | null;
};

export type LedgerClosing = {
  id: number;
  closing_date: string;
  status: "closed" | "reopened";
  opening_cash: number;
  sales_total: number;
  sales_cash: number;
  sales_noncash: number;
  income_cash: number;
  income_noncash: number;
  expense_cash: number;
  expense_noncash: number;
  expected_cash: number;
  counted_cash: number;
  diff_cash: number;
  note: string | null;
  closed_at: string;
  reopened_at: string | null;
  reopen_reason: string | null;
};

export type LedgerDay = {
  store: { id: number; code: string; name: string };
  date: string;
  today: string;
  is_hq: boolean;
  sales: {
    total: number;
    cash: number;
    noncash: number;
    orders: number;
    qty: number;
    store_campaign: number;
  };
  totals: {
    entries: number;
    income_cash: number;
    income_noncash: number;
    expense_cash: number;
    expense_noncash: number;
    income_profit: number;
    expense_profit: number;
  };
  opening_cash: number;
  suggested_opening_cash: number;
  expected_cash: number;
  profit: number;
  prev_closing: { closing_date: string; counted_cash: number } | null;
  closing: LedgerClosing | null;
  entries: LedgerEntry[];
  categories: LedgerCategory[];
};

export type LedgerPeriodDay = {
  ymd: string;
  sales_total: number;
  sales_cash: number;
  sales_noncash: number;
  income_all: number;
  income_cash: number;
  income_profit: number;
  expense_all: number;
  expense_cash: number;
  expense_profit: number;
  entries: number;
  closed: boolean;
  counted_cash: number | null;
  expected_cash: number | null;
  diff_cash: number | null;
};

export type LedgerPeriod = {
  store: { id: number; code: string; name: string };
  date_from: string;
  date_to: string;
  days: LedgerPeriodDay[];
  by_category: {
    kind: LedgerKind;
    category_id: number | null;
    name: string;
    affects_profit: boolean;
    amount: number;
    cash: number;
    cnt: number;
  }[];
  totals: {
    sales_total: number;
    sales_cash: number;
    sales_noncash: number;
    income_all: number;
    income_cash: number;
    income_profit: number;
    expense_all: number;
    expense_cash: number;
    expense_profit: number;
    entries: number;
    closed_days: number;
    diff_cash: number;
    profit: number;
  };
};

/** RPC 回的是 numeric（supabase-js 會給 string 或 number），一律轉成數字，NaN 當 0 */
export function num(v: unknown): number {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
}

/** 金額顯示：整數不補小數，有角有分才顯示兩位 */
export function money(v: unknown): string {
  const n = Math.round(num(v) * 100) / 100;
  const sign = n < 0 ? "-" : "";
  return `${sign}$${Math.abs(n).toLocaleString("zh-TW", { maximumFractionDigits: 2 })}`;
}

/** 本地（瀏覽器）日期 → YYYY-MM-DD。與 /finance/daily 同一套，不要用 toISOString（會差 8 小時） */
export function localYmd(d = new Date()): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${dd}`;
}

export function addDays(ymd: string, n: number): string {
  const d = new Date(`${ymd}T12:00:00`);
  d.setDate(d.getDate() + n);
  return localYmd(d);
}

/** 匯出 CSV（含 BOM，Excel 開中文不亂碼）。與 /analytics/members 同一套寫法 */
export function downloadCsv(filename: string, rows: (string | number)[][]) {
  const csv = rows
    .map((r) => r.map((v) => `"${String(v ?? "").replace(/"/g, '""')}"`).join(","))
    .join("\n");
  const url = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
