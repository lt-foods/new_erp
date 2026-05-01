"use client";

// 撿貨工作站 v2.1 — PO / 分店 雙視角
// - 「依 PO」：每張 PO 一個 section、含 SKU × store 矩陣（建單）
// - 「依分店」：每家店一個 section、含 PO × SKU 列表（純檢視、不建單）

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";

type DemandRow = {
  po_id: number;
  po_no: string;
  supplier_id: number;
  po_item_id: number;
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
};

type Supplier = { id: number; code: string; name: string };
type AllocKey = string; // `${po_id}:${sku_id}:${store_id}`
type ViewMode = "by_po" | "by_store";

function defaultWaveDate() {
  const d = new Date();
  d.setDate(d.getDate() + 2);
  return d.toLocaleDateString("sv-SE");
}

export default function PickingWorkstationPage() {
  const router = useRouter();
  const [demand, setDemand] = useState<DemandRow[] | null>(null);
  const [suppliers, setSuppliers] = useState<Map<number, Supplier>>(new Map());
  const [waveDate, setWaveDate] = useState(defaultWaveDate());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>("by_po");

  const [allocs, setAllocs] = useState<Map<AllocKey, number>>(new Map());
  const [submittingPoId, setSubmittingPoId] = useState<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        const [{ data: dRows, error: e1 }, { data: supRows }] = await Promise.all([
          sb.from("v_picking_demand_by_po").select("*"),
          sb.from("suppliers").select("id, code, name"),
        ]);
        if (cancelled) return;
        if (e1) { setError(e1.message); return; }
        setError(null);
        setDemand((dRows ?? []) as DemandRow[]);
        const sm = new Map<number, Supplier>();
        for (const s of (supRows ?? []) as Supplier[]) sm.set(s.id, s);
        setSuppliers(sm);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // 預設分配 = max(0, demand - wave - shipped)
  useEffect(() => {
    if (!demand) return;
    setAllocs((prev) => {
      const next = new Map(prev);
      for (const r of demand) {
        if (r.store_id === null) continue;
        const key: AllocKey = `${r.po_id}:${r.sku_id}:${r.store_id}`;
        if (!next.has(key)) {
          const remaining = Math.max(0, Number(r.demand_qty) - Number(r.wave_qty) - Number(r.shipped_qty));
          next.set(key, remaining);
        }
      }
      return next;
    });
  }, [demand]);

  // ===== 分組（PO 維度）=====
  type PoSection = {
    poId: number;
    poNo: string;
    supplierId: number;
    skus: { sku_id: number; sku_code: string | null; sku_label: string; gr_qty: number; po_item_id: number }[];
    stores: { store_id: number; store_code: string | null; store_name: string }[];
    cell: Map<string, DemandRow>;
  };

  const poSections: PoSection[] = useMemo(() => {
    if (!demand) return [];
    const groupedByPo = new Map<number, DemandRow[]>();
    for (const r of demand) {
      if (r.store_id === null) continue;
      if (!groupedByPo.has(r.po_id)) groupedByPo.set(r.po_id, []);
      groupedByPo.get(r.po_id)!.push(r);
    }
    const sections: PoSection[] = [];
    for (const [poId, rows] of groupedByPo.entries()) {
      const skuMap = new Map<number, PoSection["skus"][number]>();
      const storeMap = new Map<number, PoSection["stores"][number]>();
      const cell = new Map<string, DemandRow>();
      for (const r of rows) {
        if (!skuMap.has(r.sku_id)) {
          skuMap.set(r.sku_id, {
            sku_id: r.sku_id, sku_code: r.sku_code,
            sku_label: r.sku_label, gr_qty: Number(r.gr_qty),
            po_item_id: r.po_item_id,
          });
        }
        if (r.store_id !== null && !storeMap.has(r.store_id)) {
          storeMap.set(r.store_id, {
            store_id: r.store_id, store_code: r.store_code, store_name: r.store_name ?? `#${r.store_id}`,
          });
        }
        cell.set(`${r.sku_id}:${r.store_id}`, r);
      }
      sections.push({
        poId,
        poNo: rows[0].po_no,
        supplierId: rows[0].supplier_id,
        skus: Array.from(skuMap.values()).sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? "")),
        stores: Array.from(storeMap.values()).sort((a, b) => (a.store_code ?? "").localeCompare(b.store_code ?? "")),
        cell,
      });
    }
    return sections.sort((a, b) => a.poNo.localeCompare(b.poNo));
  }, [demand]);

  // ===== 分組（分店維度）=====
  type StoreSection = {
    storeId: number;
    storeCode: string | null;
    storeName: string;
    rows: DemandRow[];  // 含多個 (po, sku) 組合
  };

  const storeSections: StoreSection[] = useMemo(() => {
    if (!demand) return [];
    const grouped = new Map<number, StoreSection>();
    for (const r of demand) {
      if (r.store_id === null) continue;
      if (!grouped.has(r.store_id)) {
        grouped.set(r.store_id, {
          storeId: r.store_id,
          storeCode: r.store_code,
          storeName: r.store_name ?? `#${r.store_id}`,
          rows: [],
        });
      }
      grouped.get(r.store_id)!.rows.push(r);
    }
    return Array.from(grouped.values()).sort((a, b) => (a.storeCode ?? "").localeCompare(b.storeCode ?? ""));
  }, [demand]);

  // ===== Allocation Helpers =====
  function setAlloc(poId: number, skuId: number, storeId: number, qty: number) {
    const key: AllocKey = `${poId}:${skuId}:${storeId}`;
    setAllocs((prev) => {
      const next = new Map(prev);
      next.set(key, Math.max(0, qty));
      return next;
    });
  }
  function getAlloc(poId: number, skuId: number, storeId: number): number {
    return allocs.get(`${poId}:${skuId}:${storeId}`) ?? 0;
  }
  function getSkuAllocTotal(section: PoSection, skuId: number): number {
    let sum = 0;
    for (const st of section.stores) sum += getAlloc(section.poId, skuId, st.store_id);
    return sum;
  }
  function getSkuRemaining(section: PoSection, skuId: number): number {
    const skuRow = section.skus.find((s) => s.sku_id === skuId);
    if (!skuRow) return 0;
    let waveSum = 0, shippedSum = 0;
    for (const st of section.stores) {
      const cell = section.cell.get(`${skuId}:${st.store_id}`);
      if (cell) {
        waveSum += Number(cell.wave_qty);
        shippedSum += Number(cell.shipped_qty);
      }
    }
    return Math.max(0, skuRow.gr_qty - waveSum - shippedSum);
  }

  async function submitWave(section: PoSection) {
    setSubmittingPoId(section.poId);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const allocations: Array<{ sku_id: number; store_id: number; qty: number }> = [];
      for (const sku of section.skus) {
        for (const st of section.stores) {
          const qty = getAlloc(section.poId, sku.sku_id, st.store_id);
          if (qty > 0) allocations.push({ sku_id: sku.sku_id, store_id: st.store_id, qty });
        }
      }
      if (allocations.length === 0) throw new Error("沒有任何分配 — 請先填數量");

      const { data, error: e } = await sb.rpc("rpc_create_wave_from_po", {
        p_po_id: section.poId, p_wave_date: waveDate,
        p_allocations: allocations, p_operator: operator,
      });
      if (e) throw new Error(e.message);

      const r = data as { wave_id: number; wave_code: string };
      alert(`✅ 已建立撿貨單 ${r.wave_code}（${allocations.length} 筆分配）`);
      router.push(`/picking/history?wave=${r.wave_id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmittingPoId(null);
    }
  }

  // ============================================================
  // 渲染
  // ============================================================
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">批次撿貨工作站</h1>
          <p className="text-sm text-zinc-500">
            按 PO 為單位撿貨。建單後到撿貨歷史派貨。
          </p>
        </div>
        <Link
          href="/picking/history"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          撿貨歷史 →
        </Link>
      </header>

      {/* Tab 切換 */}
      <div className="border-b border-zinc-200 dark:border-zinc-800">
        <nav className="-mb-px flex gap-4">
          <TabBtn active={viewMode === "by_po"} onClick={() => setViewMode("by_po")}>
            📦 依 PO（建單）
          </TabBtn>
          <TabBtn active={viewMode === "by_store"} onClick={() => setViewMode("by_store")}>
            🏬 依分店（檢視）
          </TabBtn>
        </nav>
      </div>

      <div className="flex flex-wrap items-end gap-3 rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">配送日</span>
          <DatePicker
            value={waveDate}
            onChange={setWaveDate}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
          />
        </label>
        <span className="text-xs text-zinc-500">
          {loading ? "載入中…"
            : viewMode === "by_po"
              ? `${poSections.length} 張未派完 PO`
              : `${storeSections.length} 間分店有待撿貨`}
        </span>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      {demand === null ? (
        <div className="text-center text-sm text-zinc-500">載入中…</div>
      ) : viewMode === "by_po" ? (
        // ============= PO 視角（建單）=============
        poSections.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
            沒有待撿貨的 PO（所有已進貨的都已派完）。
          </div>
        ) : poSections.map((section) => {
          const supplier = suppliers.get(section.supplierId);
          return (
            <section
              key={section.poId}
              className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
            >
              <header className="flex items-center justify-between gap-3 border-b border-zinc-200 px-3 py-2 dark:border-zinc-800">
                <div>
                  <h2 className="font-mono text-sm font-semibold">{section.poNo}</h2>
                  <p className="text-[11px] text-zinc-500">
                    {supplier ? `${supplier.code} ${supplier.name}` : `供應商 #${section.supplierId}`}
                    {" · "}{section.skus.length} 個 SKU{" · "}{section.stores.length} 間分店
                  </p>
                </div>
                <button
                  onClick={() => submitWave(section)}
                  disabled={submittingPoId !== null}
                  className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
                >
                  {submittingPoId === section.poId ? "建立中…" : "🧾 建立此 PO 撿貨單"}
                </button>
              </header>

              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <colgroup>
                    <col className="w-[180px]" />
                    <col className="w-14" />
                    <col className="w-14" />
                    <col className="w-14" />
                    <col className="w-16" />
                    <col className="w-16" />
                    {section.stores.map((st) => <col key={st.store_id} className="w-20" />)}
                  </colgroup>
                  <thead className="bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th className="sticky left-0 bg-zinc-50 dark:bg-zinc-900">SKU</Th>
                      <Th className="text-center">進貨</Th>
                      <Th className="text-center">已撿</Th>
                      <Th className="text-center">已派</Th>
                      <Th className="text-center">可分配</Th>
                      <Th className="text-center">合計</Th>
                      {section.stores.map((st) => (
                        <Th key={st.store_id} className="text-center">
                          <div className="text-[11px] font-medium">{st.store_name}</div>
                          <div className="font-mono text-[9px] text-zinc-400">{st.store_code}</div>
                        </Th>
                      ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {section.skus.map((sku) => {
                      const remaining = getSkuRemaining(section, sku.sku_id);
                      const allocSum = getSkuAllocTotal(section, sku.sku_id);
                      const overAlloc = allocSum > remaining;
                      let waveTotal = 0, shippedTotal = 0;
                      for (const st of section.stores) {
                        const cell = section.cell.get(`${sku.sku_id}:${st.store_id}`);
                        if (cell) {
                          waveTotal += Number(cell.wave_qty);
                          shippedTotal += Number(cell.shipped_qty);
                        }
                      }
                      return (
                        <tr key={sku.sku_id} className={overAlloc ? "bg-red-50 dark:bg-red-950/30" : ""}>
                          <Td className="sticky left-0 bg-white px-3 py-2 text-xs dark:bg-zinc-900">
                            <div className="font-mono text-[11px] text-zinc-500">{sku.sku_code ?? "—"}</div>
                            <div className="truncate" title={sku.sku_label}>{sku.sku_label}</div>
                          </Td>
                          <NumCell value={sku.gr_qty} bold />
                          <NumCell value={waveTotal} muted />
                          <NumCell value={shippedTotal} muted />
                          <NumCell value={remaining} bold />
                          <NumCell value={allocSum} accent={overAlloc ? "danger" : "primary"} />
                          {section.stores.map((st) => {
                            const cell = section.cell.get(`${sku.sku_id}:${st.store_id}`);
                            const demandQty = cell ? Number(cell.demand_qty) : 0;
                            const value = getAlloc(section.poId, sku.sku_id, st.store_id);
                            return (
                              <td key={st.store_id} className="px-2 py-1.5 text-center align-top">
                                <input
                                  type="number"
                                  value={value}
                                  onChange={(e) => setAlloc(section.poId, sku.sku_id, st.store_id, Number(e.target.value))}
                                  min={0}
                                  step={1}
                                  className={`w-full max-w-[68px] rounded border px-1 py-1 text-center font-mono text-base font-semibold tabular-nums dark:bg-zinc-800 ${
                                    value === 0
                                      ? "border-zinc-200 text-zinc-300 dark:border-zinc-700"
                                      : "border-blue-300 text-blue-700 dark:border-blue-700 dark:text-blue-300"
                                  }`}
                                />
                                <div className="mt-0.5 text-[10px] text-zinc-400">需 {demandQty}</div>
                              </td>
                            );
                          })}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>
          );
        })
      ) : (
        // ============= 分店視角（檢視）=============
        storeSections.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
            沒有任何分店有待撿貨。
          </div>
        ) : storeSections.map((section) => {
          let totalDemand = 0, totalWave = 0, totalShipped = 0, totalAlloc = 0;
          for (const r of section.rows) {
            totalDemand += Number(r.demand_qty);
            totalWave += Number(r.wave_qty);
            totalShipped += Number(r.shipped_qty);
            totalAlloc += getAlloc(r.po_id, r.sku_id, r.store_id!);
          }
          return (
            <section
              key={section.storeId}
              className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
            >
              <header className="flex items-center justify-between gap-3 border-b border-zinc-200 px-3 py-2 dark:border-zinc-800">
                <div>
                  <h2 className="text-sm font-semibold">
                    {section.storeName}
                    <span className="ml-2 font-mono text-[11px] text-zinc-500">{section.storeCode}</span>
                  </h2>
                  <p className="text-[11px] text-zinc-500">
                    {section.rows.length} 筆 (PO×SKU) · 訂單 {totalDemand}{" "}
                    · 已撿 {totalWave} · 已派 {totalShipped} · 本次擬分 {totalAlloc}
                  </p>
                </div>
              </header>

              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <colgroup>
                    <col className="w-[140px]" />
                    <col className="w-[200px]" />
                    <col className="w-14" />
                    <col className="w-14" />
                    <col className="w-14" />
                    <col className="w-16" />
                    <col className="w-16" />
                  </colgroup>
                  <thead className="bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th>採購單</Th>
                      <Th>SKU</Th>
                      <Th className="text-center">訂單</Th>
                      <Th className="text-center">已撿</Th>
                      <Th className="text-center">已派</Th>
                      <Th className="text-center">本次擬分</Th>
                      <Th className="text-center">缺</Th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {section.rows
                      .sort((a, b) => a.po_no.localeCompare(b.po_no) || (a.sku_code ?? "").localeCompare(b.sku_code ?? ""))
                      .map((r, i) => {
                        const alloc = getAlloc(r.po_id, r.sku_id, r.store_id!);
                        const remaining = Math.max(0, Number(r.demand_qty) - Number(r.wave_qty) - Number(r.shipped_qty) - alloc);
                        return (
                          <tr key={`${r.po_id}:${r.sku_id}:${i}`}>
                            <Td className="px-3 py-2 font-mono text-[11px] text-zinc-600 dark:text-zinc-400">{r.po_no}</Td>
                            <Td className="px-3 py-2 text-xs">
                              <div className="font-mono text-[11px] text-zinc-500">{r.sku_code ?? "—"}</div>
                              <div className="truncate" title={r.sku_label}>{r.sku_label}</div>
                            </Td>
                            <NumCell value={Number(r.demand_qty)} bold />
                            <NumCell value={Number(r.wave_qty)} muted />
                            <NumCell value={Number(r.shipped_qty)} muted />
                            <NumCell value={alloc} accent="primary" />
                            <NumCell value={remaining} muted />
                          </tr>
                        );
                      })}
                  </tbody>
                </table>
              </div>
            </section>
          );
        })
      )}
    </div>
  );
}

// ============================================================
// Helpers
// ============================================================

function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={`whitespace-nowrap border-b-2 px-1 py-2 text-sm font-medium transition ${
        active
          ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-400"
          : "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700 dark:hover:text-zinc-300"
      }`}
    >
      {children}
    </button>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-2 py-1.5 text-left text-[11px] font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-2 py-2 ${className}`}>{children}</td>;
}

function NumCell({
  value,
  bold = false,
  muted = false,
  accent,
}: {
  value: number;
  bold?: boolean;
  muted?: boolean;
  accent?: "primary" | "danger";
}) {
  const isZero = value === 0;
  const cls = accent === "danger"
    ? "text-rose-600 font-bold"
    : accent === "primary"
      ? (isZero ? "text-zinc-300" : "text-blue-600 font-bold")
      : muted
        ? (isZero ? "text-zinc-300" : "text-zinc-500")
        : bold
          ? (isZero ? "text-zinc-300" : "text-zinc-900 font-semibold dark:text-zinc-100")
          : "text-zinc-700 dark:text-zinc-300";
  return (
    <td className={`px-2 py-2 text-center font-mono text-base tabular-nums ${cls}`}>
      {value}
    </td>
  );
}
