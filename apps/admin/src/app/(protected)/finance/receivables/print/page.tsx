"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SettlementStatementSheet, { SettlementPrintStyles, SettlementStatementAlerts } from "@/components/SettlementStatementSheet";
import { useRole, canSeeCost } from "@/lib/role";
import { fmtStatementMoney } from "@/lib/settlementPrintRows";
import {
  loadSingleStatementCore,
  loadSingleStatementNames,
  statementPaper,
  statementPrintBlockReason,
  type Adjustment,
  type Receivable,
  type Settlement,
  type SettlementItem,
  type Sku,
  type Store,
} from "@/lib/settlementPrintLoad";

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
        const core = await loadSingleStatementCore(sb, settlementId);
        if (cancelled) return;
        setSettlement(core.settlement);
        setStore(core.store);
        setAdjustments(core.adjustments);
        setItems(core.items);
        if (core.tenantName) setTenantName(core.tenantName);

        const names = await loadSingleStatementNames(sb, core.items, core.settlement);
        if (cancelled) return;
        if (names.skus) setSkus(names.skus);
        if (names.receivable) setReceivable(names.receivable);
        setNamesFailed([...(core.tenantFailed ? ["公司名稱"] : []), ...names.failed]);
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
  // 讀完明細的自我核對＋紙上三個整數（貨款 X印＝應付 Z印 − 調整 Y印，紙上等式一定成立）。
  const paper = statementPaper(settlement, items, adjustments);
  const printBlockedReason = statementPrintBlockReason(paper, namesFailed);
  const internal = view === "internal" && costAllowed;

  return (
    <>
      <SettlementPrintStyles />

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

        <SettlementStatementAlerts paper={paper} namesFailed={namesFailed} />

        {/* 對帳單內容 */}
        <SettlementStatementSheet
          settlement={settlement}
          store={store}
          items={items}
          adjustments={adjustments}
          skus={skus}
          tenantName={tenantName}
          receivable={receivable}
          internal={internal}
        />
      </div>
    </>
  );
}
