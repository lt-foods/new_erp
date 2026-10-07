"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { useRole, canSeeCost } from "@/lib/role";
import {
  buildSettlementPrintRows,
  fmtPrintDate,
  fmtStatementMoney,
  sumMoney,
  summarizeSettlementItems,
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
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
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
type Transfer = { id: number; transfer_no: string };
type Receivable = { id: number; receivable_no: string; due_date: string; status: string };

const ENTRY_TYPE_LABEL: Record<SettlementItem["entry_type"], string> = {
  hq_inbound: "HQ 進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};

function fmtCost(v: unknown): string {
  if (v === null || v === undefined || v === "") return "未提供成本";
  const n = Number(v);
  return Number.isFinite(n) ? `$${n.toFixed(2)}` : "未提供成本";
}

function fmtAmount(v: unknown): string {
  if (v === null || v === undefined || v === "") return "未提供成本";
  const n = Number(v);
  return Number.isFinite(n) ? `$${n.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}` : "未提供成本";
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
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [tenantName, setTenantName] = useState("");
  const [receivable, setReceivable] = useState<Receivable | null>(null);
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

        const [{ data: storeData }, { data: itemRows }, { data: tenantData }, { data: adjData }] = await Promise.all([
          sb.from("stores").select("id, code, name").eq("id", sd.store_id).maybeSingle(),
          sb.from("store_monthly_settlement_items")
            .select("id, transfer_id, sku_id, qty_received, unit_cost, line_amount, unit_branch_price, branch_amount, received_at, entry_type, description")
            .eq("settlement_id", settlementId)
            .order("entry_type")
            .order("received_at"),
          sb.from("tenants").select("name").limit(1),
          sb.from("store_settlement_adjustments")
            .select("id, amount, reason, created_at")
            .eq("store_id", sd.store_id)
            .eq("settlement_month", sd.settlement_month)
            .eq("status", "active")
            .order("created_at"),
        ]);
        if (cancelled) return;
        if (storeData) setStore(storeData as Store);
        setAdjustments((adjData ?? []) as Adjustment[]);
        const itList = (itemRows ?? []) as SettlementItem[];
        setItems(itList);
        const t = (tenantData as { name: string }[] | null)?.[0];
        if (t?.name) setTenantName(t.name);

        // 載入 transfer + sku 名稱
        const txIds = Array.from(new Set(itList.map((i) => i.transfer_id)));
        const skuIds = Array.from(new Set(itList.map((i) => i.sku_id)));
        const [{ data: tx }, { data: sk }] = await Promise.all([
          txIds.length ? sb.from("transfers").select("id, transfer_no").in("id", txIds) : Promise.resolve({ data: [] as Transfer[] }),
          skuIds.length ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds) : Promise.resolve({ data: [] as Sku[] }),
        ]);
        if (cancelled) return;
        const tm = new Map<number, Transfer>();
        for (const x of (tx ?? []) as Transfer[]) tm.set(x.id, x);
        setTransfers(tm);
        const skMap = new Map<number, Sku>();
        for (const x of (sk ?? []) as Sku[]) skMap.set(x.id, x);
        setSkus(skMap);

        // 如果有對應 store_receivable 也載入
        if (sd.generated_receivable_id) {
          const { data: r } = await sb
            .from("store_receivables")
            .select("id, receivable_no, due_date, status")
            .eq("id", sd.generated_receivable_id)
            .maybeSingle();
          if (!cancelled && r) setReceivable(r as Receivable);
        }
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
            {store.name} / {monthLabel} / 應付總倉 ${Number(settlement.payable_amount).toLocaleString()}
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
            className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700"
          >
            🖨️ 列印
          </SpinButton>
        </div>

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
                ${Number(settlement.payable_amount).toLocaleString()}
              </div>
              {internal && (
                <div className="mt-0.5 text-xs text-zinc-600">
                  成本口徑：<span className="font-mono font-semibold">${Number(settlement.cost_amount ?? 0).toLocaleString()}</span>
                  <span className="ml-2">總部毛利：<span className="font-mono font-semibold">${(Number(settlement.branch_amount ?? 0) - Number(settlement.cost_amount ?? 0)).toLocaleString()}</span></span>
                </div>
              )}
              {receivable && (
                <div className="mt-0.5 text-xs text-zinc-500">到期日：{receivable.due_date}</div>
              )}
            </div>
          </div>

          {/* 金額總覽：貨款＋調整＝應付總倉（每張都印；應付總倉讀月結表頭，產生月結時就是 分店價合計＋有效調整） */}
          <div className="mb-3 border border-zinc-900 px-3 py-2 text-right text-sm font-semibold">
            貨款總金額 <span className="font-mono">{fmtStatementMoney(totalBranch)}</span>
            <span className="mx-1">＋</span>調整 <span className="font-mono">{fmtStatementMoney(adjTotal)}</span>
            <span className="mx-1">＝</span>應付總倉{" "}
            <span className="font-mono text-rose-600">{fmtStatementMoney(Number(settlement.payable_amount))}</span>
          </div>

          {/* 商品明細表 */}
          <table className="stmt-table w-full border-collapse text-xs">
            <thead>
              <tr className="border-b-2 border-zinc-900">
                <th className="border border-zinc-400 px-2 py-1.5 text-left">#</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">日期</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">類型</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">調撥單</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">商品編號</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-left">品名</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-right">數量</th>
                {internal && (
                  <>
                    <th className="border border-zinc-400 px-2 py-1.5 text-right">成本單價</th>
                    <th className="border border-zinc-400 px-2 py-1.5 text-right">成本小計</th>
                  </>
                )}
                <th className="border border-zinc-400 px-2 py-1.5 text-right">{internal ? "分店單價" : "單價"}</th>
                <th className="border border-zinc-400 px-2 py-1.5 text-right">{internal ? "分店小計" : "小計"}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row, i) => {
                if (row.kind === "day") {
                  // HQ 進貨／退貨沖回：一天一行（單價、商品編號不適用，顯示「—」）
                  const txLabel =
                    row.transferIds.length === 1
                      ? (transfers.get(row.transferIds[0])?.transfer_no ?? `#${row.transferIds[0]}`)
                      : `${row.transferIds.length} 張`;
                  return (
                    <tr key={row.key}>
                      <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                      <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{fmtPrintDate(row.date)}</td>
                      <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{ENTRY_TYPE_LABEL[row.entryType]}</td>
                      <td className="border border-zinc-400 px-2 py-1 font-mono whitespace-nowrap">{txLabel}</td>
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
                        ${row.branchAmount.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                      </td>
                    </tr>
                  );
                }
                // 店到店（空中／自由轉入轉出）：照舊一筆一行
                const it = row.item;
                const tx = transfers.get(it.transfer_id);
                const sku = skus.get(it.sku_id);
                const isFree = it.description != null; // 自由轉貨行：估價入帳、無單價
                return (
                  <tr key={row.key}>
                    <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                    <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{fmtPrintDate(row.date)}</td>
                    <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{ENTRY_TYPE_LABEL[it.entry_type]}</td>
                    <td className="border border-zinc-400 px-2 py-1 font-mono whitespace-nowrap">{tx?.transfer_no ?? `#${it.transfer_id}`}</td>
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
                      {isFree ? "—" : `$${Number(it.unit_branch_price ?? 0).toFixed(2)}`}
                    </td>
                    <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${Number(it.branch_amount ?? 0) < 0 ? "text-amber-600" : ""}`}>
                      ${Number(it.branch_amount ?? 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                    </td>
                  </tr>
                );
              })}
              {/* 合計列 */}
              <tr className="bg-zinc-100 font-semibold">
                <td colSpan={7} className="border border-zinc-400 px-2 py-1.5 text-right">合計</td>
                {internal && (
                  <>
                    <td className="border border-zinc-400 px-2 py-1.5"></td>
                    <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap">
                      {costSumCell(totals.costAmount, totals.costMissingCount, totals.lineCount)}
                    </td>
                  </>
                )}
                <td className="border border-zinc-400 px-2 py-1.5"></td>
                <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap text-rose-600">
                  ${totalBranch.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
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
                        {Number(a.amount) < 0 ? "−" : "+"}${Math.abs(Number(a.amount)).toLocaleString("zh-TW")}
                      </td>
                    </tr>
                  ))}
                  <tr className="bg-zinc-100 font-semibold">
                    <td colSpan={3} className="border border-zinc-400 px-2 py-1.5 text-right">調整合計</td>
                    <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap">
                      {adjTotal < 0 ? "−" : "+"}${Math.abs(adjTotal).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
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
