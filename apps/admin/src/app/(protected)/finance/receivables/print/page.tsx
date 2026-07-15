"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { useRole, canSeeCost } from "@/lib/role";

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
  unit_cost: number;
  line_amount: number;
  unit_branch_price: number;
  branch_amount: number;
  received_at: string;
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
  description: string | null;
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

        const [{ data: storeData }, { data: itemRows }, { data: tenantData }] = await Promise.all([
          sb.from("stores").select("id, code, name").eq("id", sd.store_id).maybeSingle(),
          sb.from("store_monthly_settlement_items")
            .select("id, transfer_id, sku_id, qty_received, unit_cost, line_amount, unit_branch_price, branch_amount, received_at, entry_type, description")
            .eq("settlement_id", settlementId)
            .order("entry_type")
            .order("received_at"),
          sb.from("tenants").select("name").limit(1),
        ]);
        if (cancelled) return;
        if (storeData) setStore(storeData as Store);
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
  const totalCost = items.reduce((s, it) => s + Number(it.line_amount), 0);
  const totalBranch = items.reduce((s, it) => s + Number(it.branch_amount ?? 0), 0);
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
              {items.map((it, i) => {
                const tx = transfers.get(it.transfer_id);
                const sku = skus.get(it.sku_id);
                const isFree = it.description != null; // 自由轉貨行：估價入帳、無單價
                return (
                  <tr key={it.id}>
                    <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                    <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{new Date(it.received_at).toLocaleDateString("zh-TW")}</td>
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
                          {isFree ? "—" : `$${Number(it.unit_cost).toFixed(2)}`}
                        </td>
                        <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${Number(it.line_amount) < 0 ? "text-amber-600" : ""}`}>
                          ${Number(it.line_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
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
                      ${totalCost.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
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

          {/* 說明 */}
          <div className="mt-3 text-[10px] text-zinc-500">
            ※ 類型說明：HQ 進貨 = 總倉直接出貨給本店；空中轉入 = 別店空中轉來（加應付）；空中轉出 = 空中轉去別店（減應付）；
            自由轉入／轉出 = 店間自由轉貨（轉貨時申報金額入帳）；退貨沖回 = 退貨回總倉（減應付）。
            {internal && (
              <>
                <br />
                ※ 價格口徑：成本單價 = 出貨當下成本；分店單價 = 收貨當下生效之分店價。應付金額以分店價口徑計，成本口徑供總倉毛利參考。
              </>
            )}
          </div>

          {/* 簽收區 */}
          <div className="mt-8 grid grid-cols-2 gap-8 text-sm">
            <div>
              <div className="text-xs text-zinc-500">付款方確認 / 日期</div>
              <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
                簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
              </div>
            </div>
            <div>
              <div className="text-xs text-zinc-500">總部確認 / 日期</div>
              <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
                簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
              </div>
            </div>
          </div>

          <div className="mt-6 text-[10px] text-zinc-500">
            ※ 收到請逐項點收、若數量或金額不符請於簽收前註明。
          </div>
        </div>
      </div>
    </>
  );
}
