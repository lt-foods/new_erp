"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type WaveItem = {
  id: number;
  wave_id: number;
  sku_id: number;
  store_id: number;
  qty: number;
  picked_qty: number | null;
};

type WaveRow = {
  id: number;
  wave_code: string;
  wave_date: string;
  status: string;
};

type StoreRow = { id: number; code: string | null; name: string };
type SkuRow = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

type StoreSheet = {
  store: StoreRow;
  rows: {
    sku: SkuRow;
    qty: number;
    pickedQty: number;
    waveCodes: string[];
  }[];
  totalPicked: number;
};

export default function PrintSignPage() {
  const [date, setDate] = useState("");
  const [waves, setWaves] = useState<WaveRow[] | null>(null);
  const [items, setItems] = useState<WaveItem[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [skus, setSkus] = useState<SkuRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [tenantName, setTenantName] = useState("");

  // 從 query 抓 date
  useEffect(() => {
    if (typeof window === "undefined") return;
    const d = new URLSearchParams(window.location.search).get("date");
    if (d) setDate(d);
    else setDate(new Date().toLocaleDateString("sv-SE"));
  }, []);

  useEffect(() => {
    if (!date) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: waveRows, error: e1 } = await sb
          .from("picking_waves")
          .select("id, wave_code, wave_date, status")
          .eq("wave_date", date)
          .neq("status", "cancelled")
          .order("created_at", { ascending: true });
        if (e1) throw new Error(e1.message);
        const list = (waveRows as WaveRow[] | null) ?? [];
        if (cancelled) return;
        setWaves(list);
        if (list.length === 0) {
          setItems([]);
          setStores([]);
          setSkus([]);
          return;
        }

        const ids = list.map((w) => w.id);
        const { data: itemRows, error: e2 } = await sb
          .from("picking_wave_items")
          .select("id, wave_id, sku_id, store_id, qty, picked_qty")
          .in("wave_id", ids);
        if (e2) throw new Error(e2.message);
        const its = ((itemRows as WaveItem[] | null) ?? []).map((r) => ({
          ...r,
          qty: Number(r.qty),
          picked_qty: r.picked_qty == null ? null : Number(r.picked_qty),
        }));
        if (cancelled) return;
        setItems(its);

        const storeIds = Array.from(new Set(its.map((r) => r.store_id)));
        const skuIds = Array.from(new Set(its.map((r) => r.sku_id)));
        const [ss, sk] = await Promise.all([
          storeIds.length
            ? sb.from("stores").select("id, code, name").in("id", storeIds).order("code")
            : Promise.resolve({ data: [] as StoreRow[] }),
          skuIds.length
            ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds)
            : Promise.resolve({ data: [] as SkuRow[] }),
        ]);
        if (!cancelled) {
          setStores((ss.data as StoreRow[]) ?? []);
          setSkus((sk.data as SkuRow[]) ?? []);
        }

        const { data: tenantData } = await sb.from("tenants").select("name").limit(1);
        if (!cancelled) {
          const t = (tenantData as { name: string }[] | null)?.[0];
          if (t?.name) setTenantName(t.name);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [date]);

  const sheets: StoreSheet[] = useMemo(() => {
    if (!waves || items.length === 0) return [];
    const skuMap = new Map(skus.map((s) => [s.id, s]));
    const waveCodeMap = new Map(waves.map((w) => [w.id, w.wave_code]));

    // (store_id) -> (sku_id) -> { qty, picked_qty, waveCodes Set }
    const byStore = new Map<
      number,
      Map<number, { qty: number; pickedQty: number; waveCodes: Set<string> }>
    >();
    for (const it of items) {
      if (!byStore.has(it.store_id)) byStore.set(it.store_id, new Map());
      const skuMap2 = byStore.get(it.store_id)!;
      const cur = skuMap2.get(it.sku_id) ?? {
        qty: 0,
        pickedQty: 0,
        waveCodes: new Set<string>(),
      };
      cur.qty += it.qty;
      cur.pickedQty += Number(it.picked_qty ?? 0);
      const wc = waveCodeMap.get(it.wave_id);
      if (wc) cur.waveCodes.add(wc);
      skuMap2.set(it.sku_id, cur);
    }

    const result: StoreSheet[] = [];
    for (const store of stores) {
      const skuRows = byStore.get(store.id);
      if (!skuRows || skuRows.size === 0) continue;
      const rows = Array.from(skuRows.entries())
        .map(([skuId, v]) => ({
          sku: skuMap.get(skuId) ?? { id: skuId, sku_code: null, product_name: null, variant_name: null },
          qty: v.qty,
          pickedQty: v.pickedQty,
          waveCodes: Array.from(v.waveCodes).sort(),
        }))
        .sort((a, b) => (a.sku.sku_code ?? "").localeCompare(b.sku.sku_code ?? ""))
        .filter((r) => r.pickedQty > 0); // 0 數量不列（短缺到 0 那店家就沒貨）
      if (rows.length === 0) continue;
      const totalPicked = rows.reduce((s, r) => s + r.pickedQty, 0);
      result.push({ store, rows, totalPicked });
    }
    return result;
  }, [waves, items, stores, skus]);

  if (!date) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }

  return (
    <>
      <style jsx global>{`
        @media print {
          @page {
            size: A4;
            margin: 12mm;
          }
          .no-print {
            display: none !important;
          }
          .sheet {
            page-break-after: always;
          }
          .sheet:last-child {
            page-break-after: auto;
          }
          body {
            background: white !important;
          }
        }
      `}</style>

      <div className="bg-white text-zinc-900 print:bg-white">
        {/* 控制列（列印時隱藏）*/}
        <div className="no-print sticky top-0 z-20 flex flex-wrap items-center gap-3 border-b border-zinc-200 bg-zinc-50 p-3 print:hidden">
          <h1 className="text-base font-semibold">分店簽收單列印</h1>
          <label className="flex items-center gap-2 text-sm">
            <span>配送日</span>
            <input
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm"
            />
          </label>
          <span className="text-sm text-zinc-500">
            {waves === null
              ? "載入中…"
              : sheets.length === 0
              ? "（無資料）"
              : `${sheets.length} 間分店、${waves.length} 張撿貨單`}
          </span>
          <button
            onClick={() => window.print()}
            disabled={sheets.length === 0}
            className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            🖨️ 列印
          </button>
        </div>

        {error && (
          <div className="no-print m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {error}
          </div>
        )}

        {/* 簽收單內容 */}
        {sheets.length === 0 && waves !== null && (
          <div className="no-print p-6 text-center text-sm text-zinc-500">
            此日無已派貨資料 — 請選擇有撿貨單的配送日。
          </div>
        )}
        {sheets.map((sheet) => (
          <div
            key={sheet.store.id}
            className="sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:border-0 print:p-0"
          >
            {/* 表頭 */}
            <div className="mb-4 flex items-start justify-between border-b-2 border-zinc-900 pb-2">
              <div>
                <div className="text-xl font-bold">分店簽收單</div>
                {tenantName && (
                  <div className="mt-0.5 text-xs text-zinc-500">{tenantName}</div>
                )}
              </div>
              <div className="text-right text-sm">
                <div>
                  配送日：<span className="font-mono font-semibold">{date}</span>
                </div>
                <div className="mt-0.5 text-xs text-zinc-600">
                  撿貨單號：
                  <span className="font-mono">
                    {Array.from(new Set(sheet.rows.flatMap((r) => r.waveCodes))).join("、")}
                  </span>
                </div>
              </div>
            </div>

            {/* 分店資訊 */}
            <div className="mb-4 flex justify-between text-sm">
              <div>
                <div className="text-xs text-zinc-500">收貨分店</div>
                <div className="text-lg font-semibold">
                  {sheet.store.name}
                  {sheet.store.code && (
                    <span className="ml-2 font-mono text-sm text-zinc-500">
                      ({sheet.store.code})
                    </span>
                  )}
                </div>
              </div>
              <div className="text-right">
                <div className="text-xs text-zinc-500">合計</div>
                <div className="text-lg font-semibold">{sheet.totalPicked} 件</div>
              </div>
            </div>

            {/* 商品表 */}
            <table className="w-full border-collapse text-sm">
              <thead>
                <tr className="border-b-2 border-zinc-900">
                  <th className="border border-zinc-400 px-2 py-1.5 text-left text-xs">#</th>
                  <th className="border border-zinc-400 px-2 py-1.5 text-left text-xs">商品編號</th>
                  <th className="border border-zinc-400 px-2 py-1.5 text-left text-xs">品名</th>
                  <th className="border border-zinc-400 px-2 py-1.5 text-right text-xs">數量</th>
                  <th className="border border-zinc-400 px-2 py-1.5 text-center text-xs">收貨確認</th>
                </tr>
              </thead>
              <tbody>
                {sheet.rows.map((r, i) => (
                  <tr key={r.sku.id}>
                    <td className="border border-zinc-400 px-2 py-1.5 text-xs">{i + 1}</td>
                    <td className="border border-zinc-400 px-2 py-1.5 font-mono text-xs">
                      {r.sku.sku_code ?? "—"}
                    </td>
                    <td className="border border-zinc-400 px-2 py-1.5">
                      {r.sku.product_name ?? "—"}
                      {r.sku.variant_name && (
                        <span className="ml-1 text-xs text-zinc-500">/ {r.sku.variant_name}</span>
                      )}
                    </td>
                    <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono">
                      {r.pickedQty}
                    </td>
                    <td className="border border-zinc-400 px-2 py-1.5 text-center">
                      <span className="text-zinc-300">□</span>
                    </td>
                  </tr>
                ))}
                {/* 補空行讓表格美觀 */}
                {Array.from({ length: Math.max(0, 5 - sheet.rows.length) }).map((_, i) => (
                  <tr key={`empty-${i}`}>
                    <td className="border border-zinc-400 px-2 py-3"></td>
                    <td className="border border-zinc-400 px-2 py-3"></td>
                    <td className="border border-zinc-400 px-2 py-3"></td>
                    <td className="border border-zinc-400 px-2 py-3"></td>
                    <td className="border border-zinc-400 px-2 py-3"></td>
                  </tr>
                ))}
                {/* 合計列 */}
                <tr className="bg-zinc-100 font-semibold">
                  <td colSpan={3} className="border border-zinc-400 px-2 py-1.5 text-right">
                    合計
                  </td>
                  <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono">
                    {sheet.totalPicked}
                  </td>
                  <td className="border border-zinc-400 px-2 py-1.5"></td>
                </tr>
              </tbody>
            </table>

            {/* 簽名區 */}
            <div className="mt-8 grid grid-cols-2 gap-8 text-sm">
              <div>
                <div className="text-xs text-zinc-500">收貨人簽名 / 日期</div>
                <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
                  簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
                </div>
              </div>
              <div>
                <div className="text-xs text-zinc-500">送貨人</div>
                <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
                  簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
                </div>
              </div>
            </div>

            <div className="mt-6 text-[10px] text-zinc-500">
              ※ 收到請逐項點收，數量不符請於收貨人簽名旁註明短少 / 多到項目與數量。
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
