"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { useRole, canSeeCost } from "@/lib/role";
import { fetchAllRows } from "@/lib/fetchAllRows";
import {
  buildSettlementPrintRows,
  fetchInBatches,
  fmtPrintDate,
  fmtStatementMoney,
  statementTotals,
  sumMoney,
  summarizeSettlementItems,
  type SettlementEntryType,
} from "@/lib/settlementPrintRows";

type Settlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  cost_amount: number;
  branch_amount: number;
  transfer_count: number;
  item_count: number;
  status: string;
  generated_receivable_id: number | null;
};

type SettlementItem = {
  id: number;
  transfer_id: number;
  sku_id: number;
  qty_received: number;
  unit_cost: number | null;
  line_amount: number | null;
  unit_branch_price: number;
  branch_amount: number;
  received_at: string;
  /** 認得的見 SettlementEntryType；以後新增的類型照樣印（類型欄退回原始代號） */
  entry_type: string;
  description: string | null;
};

type Adjustment = {
  id: number;
  amount: number;
  reason: string;
  created_at: string;
};

type Store = { id: number; code: string; name: string };
type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };
type Receivable = { id: number; receivable_no: string; due_date: string; status: string };

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

// .in("id", …) 一批最多幾個 id：太多會撞網址長度上限（PostgREST 走 GET）
const IN_BATCH = 200;

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

// 分店版（預設）：給店家的對帳單，只列分店價，不露總倉成本。
// 內部版：加列成本單價/成本小計與口徑差額（總部毛利），總部對帳用。
type PrintView = "store" | "internal";

export default function PrintSettlementPage() {
  const role = useRole();
  // 分店帳號只能看分店版（不含成本）
  const costAllowed = canSeeCost(role);
  const [settlementId, setSettlementId] = useState<number | null>(null);
  const [view, setView] = useState<PrintView>("store");
  const [settlement, setSettlement] = useState<Settlement | null>(null);
  const [store, setStore] = useState<Store | null>(null);
  const [items, setItems] = useState<SettlementItem[]>([]);
  const [adjustments, setAdjustments] = useState<Adjustment[]>([]);
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [tenantName, setTenantName] = useState("");
  const [receivable, setReceivable] = useState<Receivable | null>(null);
  // 單號／品名類（商品編號／品名、公司名、應收單號）載入結果：null＝還在載；[]＝全部載到；有值＝哪幾樣載入失敗
  const [namesFailed, setNamesFailed] = useState<string[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // 從 query 抓 settlement_id + view
  useEffect(() => {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    const id = params.get("settlement_id");
    if (id) setSettlementId(Number(id));
    if (params.get("view") === "internal") setView("internal");
  }, []);

  useEffect(() => {
    if (!settlementId) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: s, error: e1 } = await sb
          .from("store_monthly_settlements")
          .select("id, settlement_month, store_id, payable_amount, cost_amount, branch_amount, transfer_count, item_count, status, generated_receivable_id")
          .eq("id", settlementId)
          .maybeSingle();
        if (e1) throw new Error(e1.message);
        if (!s) throw new Error("找不到此月結算");
        if (cancelled) return;
        const sd = s as Settlement;
        setSettlement(sd);

        const [storeRes, itemRows, tenantRes, adjRes] = await Promise.all([
          sb.from("stores").select("id, code, name").eq("id", sd.store_id).maybeSingle(),
          // 明細一張月結常破千列（HQ 派車每張單的每個品項一列），PostgREST 單次最多回 1000 列、
          // 超過會靜默截斷 → 一定要走 fetchAllRows 分頁讀完。排序加 id 給分頁一個穩定的順序。
          fetchAllRows<SettlementItem>(() =>
            sb.from("store_monthly_settlement_items")
              .select("id, transfer_id, sku_id, qty_received, unit_cost, line_amount, unit_branch_price, branch_amount, received_at, entry_type, description")
              .eq("settlement_id", settlementId)
              .order("entry_type")
              .order("received_at")
              .order("id"),
          ),
          sb.from("tenants").select("name").limit(1),
          sb.from("store_settlement_adjustments")
            .select("id, amount, reason, created_at")
            .eq("store_id", sd.store_id)
            .eq("settlement_month", sd.settlement_month)
            .eq("status", "active")
            .order("created_at"),
        ]);
        if (cancelled) return;
        // 分店、金額調整查失敗 → 跟明細失敗一樣整頁錯誤、不給印。
        // 調整不能當成 0：正負剛好互抵時金額核對擋不住，紙看起來正常、調整表卻整段消失。
        if (storeRes.error) throw new Error(`分店資料載入失敗：${storeRes.error.message}`);
        if (!storeRes.data) throw new Error("找不到此月結算的分店");
        if (adjRes.error) throw new Error(`金額調整載入失敗：${adjRes.error.message}`);
        setStore(storeRes.data as Store);
        setAdjustments((adjRes.data ?? []) as Adjustment[]);
        const itList = itemRows;
        setItems(itList);

        // 以下是單號／品名類（公司名、商品編號／品名、應收單號）：查失敗不影響金額，
        // 但紙上會變「—」，所以不整頁擋，改成黃字提醒＋停用列印（載入完成前也不給印）。
        const failed: string[] = [];
        if (tenantRes.error) failed.push("公司名稱");
        else {
          const t = (tenantRes.data as { name: string }[] | null)?.[0];
          if (t?.name) setTenantName(t.name);
        }

        // sku 名稱：id 可能上百上千個，切 IN_BATCH 一批查，每一批都檢查錯誤（fetchInBatches）。
        // 紙上不印調撥單號（2026-10-07 老闆指示整欄刪掉），所以不查 transfers —— 免得一個用不到的查詢失敗還擋列印。
        const skuIds = Array.from(new Set(itList.map((i) => i.sku_id)));
        const [skRes] = await Promise.allSettled([
          fetchInBatches<Sku>(skuIds, IN_BATCH, (ids) =>
            sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", ids),
          ),
        ]);
        if (cancelled) return;
        if (skRes.status === "fulfilled") setSkus(new Map(skRes.value.map((x) => [x.id, x])));
        else failed.push("商品編號／品名");

        // 如果有對應 store_receivable 也載入
        if (sd.generated_receivable_id) {
          const { data: r, error: rErr } = await sb
            .from("store_receivables")
            .select("id, receivable_no, due_date, status")
            .eq("id", sd.generated_receivable_id)
            .maybeSingle();
          if (cancelled) return;
          if (rErr) failed.push("應收單號");
          else if (r) setReceivable(r as Receivable);
        }
        setNamesFailed(failed);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [settlementId]);

  if (!settlementId) {
    return <div className="p-6 text-sm text-zinc-500">缺少 settlement_id 參數。</div>;
  }
  if (error) {
    return (
      <div className="m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
        {error}
      </div>
    );
  }
  if (!settlement || !store) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }

  const monthLabel = settlement.settlement_month?.slice(0, 7);
  // 金額一律用原始小數精確加總，只在顯示時取整（見 lib/settlementPrintRows.ts）
  const totals = summarizeSettlementItems(items);
  const totalBranch = totals.branchAmount;
  const adjTotal = sumMoney(adjustments.map((a) => a.amount));
  // 讀完明細的自我核對＋紙上三個整數（貨款 X印＝應付 Z印 − 調整 Y印，紙上等式一定成立）。
  // 核對沒過（明細沒讀完整、月結表頭過期）就擋下列印，不印出等式對不上的紙。
  const paper = statementTotals(totalBranch, adjTotal, settlement.payable_amount);
  const namesBroken = (namesFailed?.length ?? 0) > 0;
  // 不給印的原因（依序）：金額核對沒過 → 單號／品名載入失敗 → 單號／品名還在載入
  const printBlockedReason = !paper.ok
    ? "明細合計與系統應付總倉不一致，請先重算月結"
    : namesBroken
      ? "部分單號／品名載入失敗，請重新整理後再印"
      : namesFailed === null
        ? "單號／品名載入中…"
        : undefined;
  // 店到店逐筆排最前；HQ 進貨、退貨沖回各按台北日期一天一行（老闆 2026-10-07）
  const rows = buildSettlementPrintRows(items);
  const today = new Date().toLocaleDateString("zh-TW");
  const internal = view === "internal" && costAllowed;

  return (
    <>
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

      <div className="bg-white text-zinc-900 print:bg-white">
        {/* 控制列（列印時隱藏）*/}
        <div className="no-print sticky top-0 z-20 flex flex-wrap items-center gap-3 border-b border-zinc-200 bg-zinc-50 p-3">
          <h1 className="text-base font-semibold">月結對帳單列印</h1>
          <span className="text-sm text-zinc-500">
            {store.name} / {monthLabel} / 應付總倉 {fmtStatementMoney(paper.payable)}
          </span>
          {costAllowed && (
            <div className="flex overflow-hidden rounded-md border border-zinc-300 text-sm">
              <SpinButton
                onClick={() => setView("store")}
                className={`px-3 py-1.5 ${!internal ? "bg-zinc-900 font-semibold text-white" : "bg-white text-zinc-600 hover:bg-zinc-100"}`}
              >
                分店版（給店家）
              </SpinButton>
              <SpinButton
                onClick={() => setView("internal")}
                className={`px-3 py-1.5 ${internal ? "bg-zinc-900 font-semibold text-white" : "bg-white text-zinc-600 hover:bg-zinc-100"}`}
              >
                內部版（含成本）
              </SpinButton>
            </div>
          )}
          <SpinButton
            onClick={() => window.print()}
            disabled={printBlockedReason !== undefined}
            title={printBlockedReason}
            className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-400"
          >
            🖨️ 列印
          </SpinButton>
        </div>

        {/* 金額自我核對沒過：紅字擋在最上面（不加 no-print —— 就算有人用瀏覽器硬印，紙上也帶著這行警告） */}
        {!paper.ok && (
          <div role="alert" className="mx-auto mt-3 max-w-[210mm] rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">
            明細合計與系統應付總倉不一致（差 {fmtStatementMoney(Math.abs(paper.diff), 2)}），請先到月結明細頁重算後再列印
          </div>
        )}

        {/* 單號／品名載入失敗：黃字提醒（同上不加 no-print —— 硬印出來的紙也帶著這行，不會被當成正常的對帳單） */}
        {namesBroken && (
          <div role="alert" className="mx-auto mt-3 max-w-[210mm] rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800">
            部分單號／品名載入失敗，請重新整理後再印
            <span className="ml-2 text-xs font-normal text-amber-700">（{namesFailed?.join("、")}）</span>
          </div>
        )}

        {/* 對帳單內容 */}
        <div className="sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:border-0 print:p-0">
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
      </div>
    </>
  );
}
