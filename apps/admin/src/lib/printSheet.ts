// 列印用的共用樣式（A4 橫式矩陣表）＋ 匯出 CSV 的工具。
//
// 由來：`picking/print-pick-list` 已經有一套跑很久的列印樣式，撿貨草稿的列印頁需要同一套
// 外觀（樓下看到的紙要長得一樣）。但**不去改那一頁** ——
// 那頁的 `?skus=` 路徑是 PR #744 的驗收項，紅線寫明不得破壞；
// 把樣式抽成這支共用模組、只給新頁使用，那條紅線就變成「結構上不可能違反」
// （新頁與舊頁零共用程式碼），而不是靠測試去證明沒弄壞。
// 舊頁之後要不要改用這支，是獨立的一件事，本次不動。

/** A4 橫式 + 隱藏 .no-print + 矩陣表格。`.pick-table` 等 class 名稱與既有列印頁一致。 */
export const PRINT_SHEET_CSS = `
  @media print {
    @page { size: A4 landscape; margin: 8mm; }
    .no-print { display: none !important; }
    body { background: white !important; }
    .pick-table { font-size: 10px; }
    /* 一列不要被切到跨頁 —— 樓下對著紙撿貨，斷行等於漏撿 */
    .pick-table tr { break-inside: avoid; }
    .pick-table thead { display: table-header-group; }
  }
  .pick-table { border-collapse: collapse; width: 100%; font-size: 12px; }
  .pick-table th, .pick-table td {
    border: 1px solid #cbd5e1;
    padding: 4px 6px;
    text-align: center;
  }
  .pick-table thead { background: #f1f5f9; }
  .pick-table .sku-cell { text-align: left; }
  .pick-table .num-cell { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .pick-table .frozen-col { background: #fef3c7; font-weight: 600; }
  .pick-table .store-col { background: #ffffff; }
  .pick-table tbody tr:nth-child(even) td.store-col { background: #f8fafc; }
  .pick-table tbody tr:nth-child(even) td.sku-cell { background: #f8fafc; }
  .pick-table .zero { color: #cbd5e1; }
  /* 異常欄位／列（已停用、已刪除、無法確認、商品查不到）— 紙本也要看得出來 */
  .pick-table .odd-col { background: #fffbeb; }
  .pick-table tbody tr:nth-child(even) td.odd-col { background: #fef3c7; }
  .pick-table .note { display: block; font-size: 9px; font-weight: 400; color: #b45309; }
`;

// ============================================================
// 匯出 CSV（老闆要能丟給別人 / 存檔）
// ============================================================

/**
 * ⚠️ **一定要加 UTF-8 BOM**：沒有 BOM 的話 Excel 在中文 Windows 上
 * 會用 ANSI(Big5) 解讀，中文全變亂碼。這是本公司踩過的老坑。
 */
export const UTF8_BOM = "\uFEFF";

/**
 * ⭐ Excel 專屬的兩種破壞，**在 RFC4180 跳脫之前**先處理（阿審 #752 P1-3）：
 *   1. 公式注入：`=` `+` `-` `@`（以及 tab / CR）開頭的字串，Excel 會當公式執行
 *   2. 自動轉型：長純數字→科學記號、前導零被吃掉、`6/24` 樣式→日期
 * ⚠️ 這是**老闆自己要留存的檔案**，品號被 Excel 改掉等於檔案作廢，而且他不會馬上發現。
 * 作法：前面加一個單引號（Excel 讀進去視為「強制文字」，不會顯示那個引號）。
 * ⛔ 只套在文字欄位；數量欄要維持數字，否則沒辦法在 Excel 裡加總。
 */
export function excelSafeText(v: string | number | null | undefined): string {
  const s = v === null || v === undefined ? "" : String(v);
  if (!s) return s;
  // 公式注入（含 tab / CR 開頭 —— 那兩個也會讓 Excel 進入公式解析）
  if (/^[=+\-@\t\r]/.test(s)) return `'${s}`;
  // 前導零（品號很常見，例如 0123 會被吃成 123）
  if (/^0\d/.test(s)) return `'${s}`;
  // 長純數字 → 科學記號
  if (/^\d{12,}$/.test(s)) return `'${s}`;
  // 日期樣式（6/24、2026-08-17…）
  if (/^\d{1,4}\s*[-/]\s*\d{1,2}(\s*[-/]\s*\d{1,4})?$/.test(s)) return `'${s}`;
  return s;
}

/** RFC4180：含逗號 / 引號 / 換行就要用雙引號包住，內部的引號變兩個 */
export function csvCell(v: string | number | null | undefined): string {
  const s = v === null || v === undefined ? "" : String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function toCsv(rows: (string | number | null | undefined)[][]): string {
  // 用 CRLF：Excel 對 CRLF 最保險
  return UTF8_BOM + rows.map((r) => r.map(csvCell).join(",")).join("\r\n") + "\r\n";
}

/** 檔名帶草稿名 + 日期。去掉檔名不能用的字元，避免下載失敗 */
export function csvFileName(draftName: string, iso: string): string {
  const safe = (draftName || "撿貨草稿")
    .replace(/[\\/:*?"<>|]/g, "_") // Windows 不合法字元（含反斜線）
    .replace(/[\u0000-\u001f]/g, "_") // 控制字元
    .trim()
    .slice(0, 60)
    .replace(/[.\s]+$/, ""); // Windows 檔名不可以用「.」或空白結尾
  return `撿貨草稿_${safe || "撿貨草稿"}_${iso.slice(0, 10)}.csv`;
}
