"use client";

// 撿貨清單列印 — SKU × 店家 矩陣，給現場撿貨用
// 列 = SKU；前幾欄 = 訂購/已到/已撿/可分配；之後是各店家需求數量。
// 開啟方式：從 /wms/picking 點「📄 列印撿貨清單」開新分頁。
// data source: 與派貨工作台同 v_picking_demand_by_po。

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { getTenantName } from "@/lib/tenant";

type DemandRow = {
  po_id: number;
  po_no: string;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_ordered: number;
  gr_qty: number;
  store_id: number | null;
  store_code: string | null;
  store_name: string | null;
  demand_qty: number;
  wave_qty: number;
  shipped_qty: number;
  // per (po, sku) 跨 store 已撿真值（與 RPC 守衛對齊）。
  // 同 (po, sku) 各 row 共享同值；NULL fallback 給未套 migration 環境。
  po_sku_already_wave?: number | null;
};

type StoreInfo = { store_id: number; store_code: string | null; store_name: string };
type SkuRow = {
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  totalOrdered: number;
  totalGr: number;
  totalAlreadyWave: number;
  totalAvailable: number;
  storeDemand: Map<number, number>;
  storeWave: Map<number, number>;  // 每店「已撿」量（wave_qty）
};

export default function PrintPickListPage() {
  const [demand, setDemand] = useState<DemandRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tenantName, setTenantName] = useState("");
  const [printedAt] = useState(() => new Date());

  useEffect(() => {
    setTenantName(getTenantName());
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb.from("v_picking_demand_by_po").select("*");
        if (cancelled) return;
        if (e) { setError(e.message); return; }
        setDemand((data ?? []) as DemandRow[]);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const { skuRows, stores } = useMemo(() => {
    const empty = { skuRows: [] as SkuRow[], stores: [] as StoreInfo[] };
    if (!demand) return empty;
    const skuMap = new Map<number, SkuRow>();
    const storeMap = new Map<number, StoreInfo>();
    const poSkuSeen = new Set<string>();
    for (const r of demand) {
      if (r.store_id == null) continue;
      if (!storeMap.has(r.store_id)) {
        storeMap.set(r.store_id, {
          store_id: r.store_id,
          store_code: r.store_code,
          store_name: r.store_name ?? `#${r.store_id}`,
        });
      }
      let s = skuMap.get(r.sku_id);
      if (!s) {
        s = {
          sku_id: r.sku_id,
          sku_code: r.sku_code,
          sku_label: r.sku_label,
          totalOrdered: 0,
          totalGr: 0,
          totalAlreadyWave: 0,
          totalAvailable: 0,
          storeDemand: new Map(),
          storeWave: new Map(),
        };
        skuMap.set(r.sku_id, s);
      }
      const poSkuKey = `${r.po_id}:${r.sku_id}`;
      if (!poSkuSeen.has(poSkuKey)) {
        poSkuSeen.add(poSkuKey);
        s.totalOrdered += Number(r.qty_ordered);
        s.totalGr += Number(r.gr_qty);
        // 用 view 新欄位 po_sku_already_wave：per (po, sku) 跨 store 真值，
        // 與 RPC 守衛 SUM(pwi) 對齊。fallback 給未套 migration 的本地環境（會偏低）。
        s.totalAlreadyWave += Number(r.po_sku_already_wave ?? 0);
      }
      s.storeDemand.set(r.store_id, (s.storeDemand.get(r.store_id) ?? 0) + Number(r.demand_qty));
      s.storeWave.set(r.store_id, (s.storeWave.get(r.store_id) ?? 0) + Number(r.wave_qty));
    }
    for (const s of skuMap.values()) {
      s.totalAvailable = Math.max(0, s.totalGr - s.totalAlreadyWave);
    }
    const stores = Array.from(storeMap.values()).sort((a, b) =>
      (a.store_code ?? "").localeCompare(b.store_code ?? "")
    );
    const skuRows = Array.from(skuMap.values())
      // 隱藏「已到貨且全部撿完」的 SKU
      .filter((s) => !(s.totalGr > 0 && s.totalAvailable === 0))
      .sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? ""));
    return { skuRows, stores };
  }, [demand]);

  return (
    <>
      <style>{`
        @media print {
          @page {
            size: A4 landscape;
            margin: 8mm;
          }
          .no-print { display: none !important; }
          body { background: white !important; }
          .pick-table { font-size: 10px; }
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
        .pick-table .frozen-col {
          background: #fef3c7;
          font-weight: 600;
        }
        .pick-table .store-col { background: #ffffff; }
        .pick-table tbody tr:nth-child(even) td.store-col { background: #f8fafc; }
        .pick-table tbody tr:nth-child(even) td.sku-cell { background: #f8fafc; }
        .pick-table .zero { color: #cbd5e1; }
        .pick-table .picked-tag {
          display: block;
          font-size: 10px;
          color: #047857;  /* green-700 — 已撿 */
        }
        .pick-table .picked-partial { color: #b45309; }  /* amber-700 — 部分撿 */
        .pick-table .picked-zero { color: #b91c1c; }     /* red-700 — 還沒撿 */
      `}</style>

      <div className="bg-white text-zinc-900 print:bg-white">
        {/* 控制列（列印時隱藏）*/}
        <div className="no-print sticky top-0 z-20 flex flex-wrap items-center gap-3 border-b border-zinc-200 bg-zinc-50 p-3 print:hidden">
          <h1 className="text-base font-semibold">📄 撿貨清單列印</h1>
          <span className="text-sm text-zinc-500">
            {demand === null
              ? "載入中…"
              : skuRows.length === 0
                ? "（無資料）"
                : `${skuRows.length} 個 SKU × ${stores.length} 間分店`}
          </span>
          <SpinButton
            onClick={() => window.print()}
            disabled={skuRows.length === 0}
            className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            🖨️ 列印
          </SpinButton>
        </div>

        {error && (
          <div className="no-print m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {error}
          </div>
        )}

        {skuRows.length === 0 && demand !== null && (
          <div className="no-print p-6 text-center text-sm text-zinc-500">
            目前沒有待撿項目。
          </div>
        )}

        {skuRows.length > 0 && (
          <div className="mx-auto p-4 print:p-0">
            <div className="mb-3 flex items-end justify-between border-b-2 border-zinc-900 pb-2">
              <div>
                <div className="text-xl font-bold">撿貨清單</div>
                {tenantName && <div className="mt-0.5 text-xs text-zinc-500">{tenantName}</div>}
              </div>
              <div className="text-right text-xs text-zinc-600">
                <div>列印時間：{printedAt.toLocaleString("zh-TW")}</div>
                <div>共 {skuRows.length} 個 SKU、{stores.length} 間分店</div>
              </div>
            </div>

            <table className="pick-table">
              <thead>
                <tr>
                  <th rowSpan={2} className="sku-cell">SKU</th>
                  <th rowSpan={2} className="sku-cell">品名 / 規格</th>
                  <th colSpan={4}>HQ 統計</th>
                  <th colSpan={stores.length}>各店家需求</th>
                </tr>
                <tr>
                  <th className="frozen-col">訂購</th>
                  <th className="frozen-col">已到</th>
                  <th className="frozen-col">已撿</th>
                  <th className="frozen-col">可分配</th>
                  {stores.map((s) => (
                    <th key={s.store_id} className="store-col">
                      <div className="font-mono text-[10px] text-zinc-500">{s.store_code ?? "—"}</div>
                      <div>{s.store_name}</div>
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {skuRows.map((s) => (
                  <tr key={s.sku_id}>
                    <td className="sku-cell num-cell">{s.sku_code ?? `#${s.sku_id}`}</td>
                    <td className="sku-cell">{s.sku_label}</td>
                    <td className="frozen-col num-cell">{s.totalOrdered}</td>
                    <td className="frozen-col num-cell">{s.totalGr}</td>
                    <td className="frozen-col num-cell">{s.totalAlreadyWave}</td>
                    <td className="frozen-col num-cell">{s.totalAvailable}</td>
                    {stores.map((store) => {
                      const q = s.storeDemand.get(store.store_id) ?? 0;
                      const picked = s.storeWave.get(store.store_id) ?? 0;
                      if (q === 0 && picked === 0) {
                        return (
                          <td key={store.store_id} className="store-col num-cell zero">·</td>
                        );
                      }
                      // 已撿 tag 樣式：足量綠色 / 部分黃色 / 還沒撿紅色
                      const tagCls =
                        picked === 0 ? "picked-tag picked-zero" :
                        picked >= q ? "picked-tag" :
                        "picked-tag picked-partial";
                      const tagText =
                        picked === 0 ? "撿 0" :
                        picked >= q ? `✓ 撿 ${picked}` :
                        `撿 ${picked}`;
                      return (
                        <td key={store.store_id} className="store-col num-cell">
                          {q || "—"}
                          {q > 0 && <span className={tagCls}>{tagText}</span>}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={2} className="sku-cell text-right text-xs text-zinc-500">合計</td>
                  <td className="frozen-col num-cell">{skuRows.reduce((a, s) => a + s.totalOrdered, 0)}</td>
                  <td className="frozen-col num-cell">{skuRows.reduce((a, s) => a + s.totalGr, 0)}</td>
                  <td className="frozen-col num-cell">{skuRows.reduce((a, s) => a + s.totalAlreadyWave, 0)}</td>
                  <td className="frozen-col num-cell">{skuRows.reduce((a, s) => a + s.totalAvailable, 0)}</td>
                  {stores.map((store) => {
                    const sum = skuRows.reduce((a, s) => a + (s.storeDemand.get(store.store_id) ?? 0), 0);
                    const sumPicked = skuRows.reduce((a, s) => a + (s.storeWave.get(store.store_id) ?? 0), 0);
                    return (
                      <td key={store.store_id} className={`store-col num-cell ${sum === 0 && sumPicked === 0 ? "zero" : ""}`}>
                        {sum === 0 && sumPicked === 0 ? "·" : sum}
                        {sum > 0 && (
                          <span className={`picked-tag ${sumPicked === 0 ? "picked-zero" : sumPicked >= sum ? "" : "picked-partial"}`}>
                            {sumPicked === 0 ? "撿 0" : sumPicked >= sum ? `✓ 撿 ${sumPicked}` : `撿 ${sumPicked}`}
                          </span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              </tfoot>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
