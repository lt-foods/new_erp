"use client";

// 一張月結對帳單（紙上內容），單張列印頁（finance/receivables/print）與一次列印頁（transfers/settlement/print-batch）共用。
// batchMarks 只有一次列印才打開：內部版標示、表頭每頁重複的店名列。單張頁畫面不受影響。

import { memo } from "react";
import {
  buildSettlementPrintRows,
  fmtPrintDate,
  fmtStatementMoney,
  summarizeSettlementItems,
  type SettlementEntryType,
  type StatementTotals,
} from "@/lib/settlementPrintRows";
import { statementPaper, type StatementData } from "@/lib/settlementPrintLoad";

const ENTRY_TYPE_LABEL: Record<SettlementEntryType, string> = {
  hq_inbound: "HQ 進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};

// 不認得的類型（以後新增的）印原始代號，不留白 —— 店家至少看得出那一行是什麼帳
function entryTypeLabel(t: string): string {
  return ENTRY_TYPE_LABEL[t as SettlementEntryType] ?? t;
}

// 金額一律走 fmtStatementMoney（負數 －$N），全頁同一種寫法
function fmtCost(v: unknown): string {
  if (v === null || v === undefined || v === "") return "未提供成本";
  const n = Number(v);
  return Number.isFinite(n) ? fmtStatementMoney(n, 2) : "未提供成本";
}

function fmtAmount(v: unknown): string {
  if (v === null || v === undefined || v === "") return "未提供成本";
  const n = Number(v);
  return Number.isFinite(n) ? fmtStatementMoney(n) : "未提供成本";
}

// 併日那行／合計列的成本小計：有缺成本的行要看得出來，不讓 null 默默當 0 加（全缺＝整格「未提供成本」）
function costSumCell(amount: number, missing: number, count: number) {
  if (count > 0 && missing === count) return "未提供成本";
  return (
    <>
      {fmtAmount(amount)}
      {missing > 0 && <div className="whitespace-normal text-[10px] text-amber-700">含 {missing} 項未提供成本</div>}
    </>
  );
}

/** 列印樣式（整頁放一份） */
export function SettlementPrintStyles() {
  return (
    <style jsx global>{`
      @media print {
        @page { size: A4; margin: 10mm; }
        .no-print { display: none !important; }
        .sheet { page-break-after: always; }
        .sheet:last-child { page-break-after: auto; }
        body { background: white !important; }
        .stmt-table { font-size: 10px; }
        .stmt-table th, .stmt-table td { padding: 2px 4px; }
        .stmt-table thead { display: table-header-group; }
        .stmt-table tr { break-inside: avoid; }
      }
    `}</style>
  );
}

/** 紅黃警示（⛔ 不加 no-print —— 就算有人用瀏覽器硬印，紙上也帶著這行，不會被當成正常的對帳單） */
export function SettlementStatementAlerts({ paper, namesFailed }: { paper: StatementTotals; namesFailed: readonly string[] | null }) {
  return (
    <>
      {/* 金額自我核對沒過：紅字擋在最上面 */}
      {!paper.ok && (
        <div role="alert" className="mx-auto mt-3 max-w-[210mm] rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">
          明細合計與系統應付總倉不一致（差 {fmtStatementMoney(Math.abs(paper.diff), 2)}），請先到月結明細頁重算後再列印
        </div>
      )}

      {/* 單號／品名載入失敗：黃字提醒 */}
      {(namesFailed?.length ?? 0) > 0 && (
        <div role="alert" className="mx-auto mt-3 max-w-[210mm] rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800">
          部分單號／品名載入失敗，請重新整理後再印
          <span className="ml-2 text-xs font-normal text-amber-700">（{namesFailed?.join("、")}）</span>
        </div>
      )}
    </>
  );
}

type Props = StatementData & {
  /** 內部版：加列成本單價/成本小計與口徑差額（總部毛利），總部對帳用。呼叫端要先確認帳號能看成本。 */
  internal: boolean;
  /** 一次列印才打開：內部版標示上紙＋表頭每頁重複店名、月份（散掉也分得出是哪家） */
  batchMarks?: boolean;
};

function SettlementStatementSheetImpl({ settlement, store, items, adjustments, skus, tenantName, receivable, internal, batchMarks = false }: Props) {
  const monthLabel = settlement.settlement_month?.slice(0, 7);
  const totals = summarizeSettlementItems(items);
  const paper = statementPaper(settlement, items, adjustments);
  // 店到店逐筆排最前；HQ 進貨、退貨沖回各按台北日期一天一行（老闆 2026-10-07）
  const rows = buildSettlementPrintRows(items);
  const today = new Date().toLocaleDateString("zh-TW");
  const repeatedHeader = batchMarks ? (
    <>
      {store.name}（{store.code}）／{monthLabel}
      {internal && "・內部版"}
    </>
  ) : null;

  return (
    <div className="sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:border-0 print:p-0">
      {batchMarks && internal && (
        <div data-batch-only className="mb-3 border-2 border-red-700 px-3 py-1.5 text-center text-sm font-bold text-red-700">
          內部版・含成本・不可給店家
        </div>
      )}

      {/* 表頭 */}
      <div className="mb-4 flex items-start justify-between border-b-2 border-zinc-900 pb-3">
        <div>
          <div className="text-xl font-bold">月結對帳單</div>
          {tenantName && (
            <div className="mt-0.5 text-xs text-zinc-500">{tenantName}</div>
          )}
        </div>
        <div className="text-right text-sm">
          <div>結算月份：<span className="font-mono font-semibold">{monthLabel}</span></div>
          {receivable && (
            <div className="mt-0.5 text-xs text-zinc-600">
              應收單號：<span className="font-mono">{receivable.receivable_no}</span>
            </div>
          )}
          <div className="mt-0.5 text-xs text-zinc-500">列印日：{today}</div>
        </div>
      </div>

      {/* 分店資訊 + 合計 */}
      <div className="mb-4 grid grid-cols-2 gap-4 text-sm">
        <div>
          <div className="text-xs text-zinc-500">付款方（分店）</div>
          <div className="text-lg font-semibold">
            {store.name}
            <span className="ml-2 font-mono text-sm text-zinc-500">({store.code})</span>
          </div>
        </div>
        <div className="text-right">
          <div className="text-xs text-zinc-500">應付總倉金額{internal && "（分店價口徑）"}</div>
          <div className="text-lg font-semibold text-rose-600">
            {fmtStatementMoney(paper.payable)}
          </div>
          {internal && (
            <div className="mt-0.5 text-xs text-zinc-600">
              成本口徑：<span className="font-mono font-semibold">{fmtStatementMoney(Number(settlement.cost_amount ?? 0))}</span>
              <span className="ml-2">總部毛利：<span className="font-mono font-semibold">{fmtStatementMoney(Number(settlement.branch_amount ?? 0) - Number(settlement.cost_amount ?? 0))}</span></span>
            </div>
          )}
          {receivable && (
            <div className="mt-0.5 text-xs text-zinc-500">到期日：{receivable.due_date}</div>
          )}
        </div>
      </div>

      {/* 金額總覽：貨款＋調整＝應付總倉（每張都印；應付總倉讀月結表頭，產生月結時就是 分店價合計＋有效調整）。
          三個數都是整數、而且貨款＝應付−調整，紙上算式一定對得起來（見 statementTotals） */}
      <div className="mb-3 border border-zinc-900 px-3 py-2 text-right text-sm font-semibold">
        貨款總金額 <span className="font-mono">{fmtStatementMoney(paper.goods)}</span>
        <span className="mx-1">＋</span>調整 <span className="font-mono">{fmtStatementMoney(paper.adjustment)}</span>
        <span className="mx-1">＝</span>應付總倉{" "}
        <span className="font-mono text-rose-600">{fmtStatementMoney(paper.payable)}</span>
      </div>

      {/* 商品明細表（2026-10-07 老闆指示刪掉「調撥單」欄：長單號把品名擠成好幾行、表格還超出右邊；
          表頭一律不換行，「數量」這種短欄位才不會被擠成兩行） */}
      <table className="stmt-table w-full border-collapse text-xs">
        <thead>
          {batchMarks && (
            <tr data-batch-only className="hidden print:table-row">
              <th colSpan={internal ? 10 : 8} className="border border-zinc-400 px-2 py-1 text-left whitespace-nowrap">{repeatedHeader}</th>
            </tr>
          )}
          <tr className="border-b-2 border-zinc-900">
            <th className="border border-zinc-400 px-2 py-1.5 text-left whitespace-nowrap">#</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left whitespace-nowrap">日期</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left whitespace-nowrap">類型</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left whitespace-nowrap">商品編號</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left whitespace-nowrap">品名</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-right whitespace-nowrap">數量</th>
            {internal && (
              <>
                <th className="border border-zinc-400 px-2 py-1.5 text-right whitespace-nowrap">成本單價</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-right whitespace-nowrap">成本小計</th>
              </>
            )}
            <th className="border border-zinc-400 px-2 py-1.5 text-right whitespace-nowrap">{internal ? "分店單價" : "單價"}</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-right whitespace-nowrap">{internal ? "分店小計" : "小計"}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => {
            if (row.kind === "day") {
              // HQ 進貨／退貨沖回：一天一行（單價、商品編號不適用，顯示「—」）
              return (
                <tr key={row.key}>
                  <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                  <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{fmtPrintDate(row.date)}</td>
                  <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{entryTypeLabel(row.entryType)}</td>
                  <td className="border border-zinc-400 px-2 py-1 font-mono whitespace-nowrap">—</td>
                  <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">共 {row.lineCount} 項</td>
                  <td className="border border-zinc-400 px-2 py-1 text-right font-mono">{row.qty.toLocaleString()}</td>
                  {internal && (
                    <>
                      <td className="border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap">—</td>
                      <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${row.costAmount < 0 ? "text-amber-600" : ""}`}>
                        {costSumCell(row.costAmount, row.costMissingCount, row.lineCount)}
                      </td>
                    </>
                  )}
                  <td className="border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap">—</td>
                  <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${row.branchAmount < 0 ? "text-amber-600" : ""}`}>
                    {fmtStatementMoney(row.branchAmount)}
                  </td>
                </tr>
              );
            }
            // 店到店（空中／自由轉入轉出）：照舊一筆一行
            const it = row.item;
            const sku = skus.get(it.sku_id);
            const isFree = it.description != null; // 自由轉貨行：估價入帳、無單價
            return (
              <tr key={row.key}>
                <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{fmtPrintDate(row.date)}</td>
                <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{entryTypeLabel(it.entry_type)}</td>
                <td className="border border-zinc-400 px-2 py-1 font-mono whitespace-nowrap">{sku?.sku_code ?? "—"}</td>
                <td className="border border-zinc-400 px-2 py-1">
                  {it.description ? (
                    <span>{it.description}</span>
                  ) : (
                    <>
                      {sku?.product_name ?? "—"}
                      {sku?.variant_name && <span className="ml-1 text-zinc-500">/ {sku.variant_name}</span>}
                    </>
                  )}
                </td>
                <td className="border border-zinc-400 px-2 py-1 text-right font-mono">{Number(it.qty_received).toLocaleString()}</td>
                {internal && (
                  <>
                    <td className="border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap">
                      {isFree ? "—" : fmtCost(it.unit_cost)}
                    </td>
                    <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${Number(it.line_amount) < 0 ? "text-amber-600" : ""}`}>
                      {fmtAmount(it.line_amount)}
                    </td>
                  </>
                )}
                <td className="border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap">
                  {isFree ? "—" : fmtStatementMoney(Number(it.unit_branch_price ?? 0), 2)}
                </td>
                <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${Number(it.branch_amount ?? 0) < 0 ? "text-amber-600" : ""}`}>
                  {fmtStatementMoney(Number(it.branch_amount ?? 0))}
                </td>
              </tr>
            );
          })}
          {/* 合計列 */}
          <tr className="bg-zinc-100 font-semibold">
            <td colSpan={6} className="border border-zinc-400 px-2 py-1.5 text-right">合計</td>
            {internal && (
              <>
                <td className="border border-zinc-400 px-2 py-1.5"></td>
                <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap">
                  {costSumCell(totals.costAmount, totals.costMissingCount, totals.lineCount)}
                </td>
              </>
            )}
            <td className="border border-zinc-400 px-2 py-1.5"></td>
            {/* 跟最上列「貨款總金額」同一個數（X印），紙上兩處一致 */}
            <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap text-rose-600">
              {fmtStatementMoney(paper.goods)}
            </td>
          </tr>
        </tbody>
      </table>

      {/* 金額調整（明細以外的加減項＋原因） */}
      {adjustments.length > 0 && (
        <>
          <div className="mt-4 mb-1 text-xs font-semibold">金額調整</div>
          <table className="stmt-table w-full border-collapse text-xs">
            <thead>
              {batchMarks && (
                <tr data-batch-only className="hidden print:table-row">
                  <th colSpan={4} className="border border-zinc-400 px-2 py-1 text-left whitespace-nowrap">{repeatedHeader}</th>
                </tr>
              )}
              <tr className="border-b-2 border-zinc-900">
                <th className="border border-zinc-400 px-2 py-1.5 text-left">#</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">日期</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">原因</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-right">金額</th>
              </tr>
            </thead>
            <tbody>
              {adjustments.map((a, i) => (
                <tr key={a.id}>
                  <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                  <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{new Date(a.created_at).toLocaleDateString("zh-TW")}</td>
                  <td className="border border-zinc-400 px-2 py-1">{a.reason}</td>
                  <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${Number(a.amount) < 0 ? "text-emerald-700" : ""}`}>
                    {/* 單筆調整照原樣：有小數就印兩位小數，不在這裡取整 */}
                    {Number(a.amount) > 0 && "＋"}
                    {fmtStatementMoney(Number(a.amount), Number.isInteger(Number(a.amount)) ? 0 : 2)}
                  </td>
                </tr>
              ))}
              <tr className="bg-zinc-100 font-semibold">
                <td colSpan={3} className="border border-zinc-400 px-2 py-1.5 text-right">調整合計</td>
                {/* 跟最上列「調整」同一個數（Y印） */}
                <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap">
                  {paper.adjustment > 0 && "＋"}
                  {fmtStatementMoney(paper.adjustment)}
                </td>
              </tr>
            </tbody>
          </table>
          {/* 「商品合計＋調整＝應付金額」那句已搬到最上面每張都印，這裡不重複 */}
        </>
      )}
      {/* ⛔ 這裡原本有「※ 類型說明」、付款方／總部簽名區、「※ 收到請逐項點收…」三段，
          2026-10-07 老闆指示通通刪掉（精簡頁數）。三段都是純靜態版面，拿掉不影響任何一格數字。
          ⛔ 上面的金額調整表要留著 —— 店家要看得到每筆加減的原因，不是被刪的那三段。 */}
    </div>
  );
}

// 一次列印同一頁有很多家：進度更新時，已經讀好的家不重算
const SettlementStatementSheet = memo(SettlementStatementSheetImpl);
export default SettlementStatementSheet;
