"use client";

// 批次撿貨工作站 v3 — 全清單合併視角
// - 預設：所有 PO 合併成一個 SKU × store 矩陣，提交時依 PO 自動 FIFO 切分多張 wave
// - 「依分店」：純檢視，每家店看到的 (PO × SKU) 待撿明細

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";

type DemandRow = {
  po_id: number;
  po_no: string;
  po_status?: string;
  supplier_id: number;
  po_item_id: number;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_ordered: number;
  gr_qty: number;
  qty_in_transit?: number;
  qty_shortage?: number;
  store_id: number | null;
  store_code: string | null;
  store_name: string | null;
  demand_qty: number;
  wave_qty: number;
  shipped_qty: number;
  is_restock_sourced?: boolean;
};

type Supplier = { id: number; code: string; name: string };
type AllocKey = string; // `${sku_id}:${store_id}`
type ViewMode = "matrix" | "by_store";

type RestockRow = {
  restock_request_id: number;
  restock_status: string;
  store_id: number;
  store_code: string | null;
  store_name: string | null;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  demand_qty: number;
  gr_qty: number;        // HQ on_hand
  wave_qty: number;      // 已撿
};

function defaultWaveDate() {
  const d = new Date();
  d.setDate(d.getDate() + 2);
  return d.toLocaleDateString("sv-SE");
}

export default function PickingWorkstationPage() {
  const router = useRouter();
  const [demand, setDemand] = useState<DemandRow[] | null>(null);
  const [restockDemand, setRestockDemand] = useState<RestockRow[] | null>(null);
  const [suppliers, setSuppliers] = useState<Map<number, Supplier>>(new Map());
  const [waveDate, setWaveDate] = useState(defaultWaveDate());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>("matrix");

  const [allocs, setAllocs] = useState<Map<AllocKey, number>>(new Map());
  // restock alloc key: `${restock_request_id}:${sku_id}` -> qty
  const [restockAllocs, setRestockAllocs] = useState<Map<string, number>>(new Map());
  const [submitting, setSubmitting] = useState(false);
  const [submittingRrId, setSubmittingRrId] = useState<number | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        const [{ data: dRows, error: e1 }, { data: supRows }, { data: rrRows, error: e3 }] = await Promise.all([
          sb.from("v_picking_demand_by_po").select("*"),
          sb.from("suppliers").select("id, code, name"),
          sb.from("v_picking_demand_no_po").select("*"),
        ]);
        if (cancelled) return;
        if (e1) { setError(e1.message); return; }
        if (e3) { setError(e3.message); return; }
        setError(null);
        setDemand((dRows ?? []) as DemandRow[]);
        setRestockDemand((rrRows ?? []) as RestockRow[]);
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
  }, [reloadKey]);

  // ===== 合併視角資料：每個 (sku, store) 一格，跨 PO 加總 =====
  type StoreInfo = { store_id: number; store_code: string | null; store_name: string };
  type SkuRow = {
    sku_id: number;
    sku_code: string | null;
    sku_label: string;
    poList: {
      po_id: number;
      po_no: string;
      po_status?: string;
      gr_qty: number;
      qty_ordered: number;
      qty_in_transit: number;
      qty_shortage: number;
      already_wave_for_sku: number;
      is_restock_sourced: boolean;
    }[];                                  // 跨 PO 來源(去重)
    storeDemand: Map<number, number>;
    storeWave: Map<number, number>;
    storeShipped: Map<number, number>;
    totalOrdered: number;                 // 總訂購
    totalGr: number;                      // 總已到貨
    totalInTransit: number;               // 總在途(還會到)
    totalShortage: number;                // 總短少(永遠不會到)
    totalAlreadyWave: number;             // 總已撿
    totalAvailable: number;               // 可分配 = totalGr - totalAlreadyWave
  };

  const skuRows: SkuRow[] = useMemo(() => {
    if (!demand) return [];
    const grouped = new Map<number, SkuRow>();
    // PO×SKU level dedup（gr_qty 在同 PO 同 SKU 不同 store row 重複出現）
    const poSkuSeen = new Set<string>();
    for (const r of demand) {
      if (r.store_id === null) continue;
      let s = grouped.get(r.sku_id);
      if (!s) {
        s = {
          sku_id: r.sku_id,
          sku_code: r.sku_code,
          sku_label: r.sku_label,
          poList: [],
          storeDemand: new Map(),
          storeWave: new Map(),
          storeShipped: new Map(),
          totalOrdered: 0,
          totalGr: 0,
          totalInTransit: 0,
          totalShortage: 0,
          totalAlreadyWave: 0,
          totalAvailable: 0,
        };
        grouped.set(r.sku_id, s);
      }
      const poSkuKey = `${r.po_id}:${r.sku_id}`;
      if (!poSkuSeen.has(poSkuKey)) {
        poSkuSeen.add(poSkuKey);
        const inTransit = Number(r.qty_in_transit ?? 0);
        const shortage = Number(r.qty_shortage ?? 0);
        s.poList.push({
          po_id: r.po_id,
          po_no: r.po_no,
          po_status: r.po_status,
          gr_qty: Number(r.gr_qty),
          qty_ordered: Number(r.qty_ordered),
          qty_in_transit: inTransit,
          qty_shortage: shortage,
          already_wave_for_sku: 0,
          is_restock_sourced: !!r.is_restock_sourced,
        });
        s.totalOrdered += Number(r.qty_ordered);
        s.totalGr += Number(r.gr_qty);
        s.totalInTransit += inTransit;
        s.totalShortage += shortage;
      }
      s.storeDemand.set(r.store_id, (s.storeDemand.get(r.store_id) ?? 0) + Number(r.demand_qty));
      s.storeWave.set(r.store_id, (s.storeWave.get(r.store_id) ?? 0) + Number(r.wave_qty));
      s.storeShipped.set(r.store_id, (s.storeShipped.get(r.store_id) ?? 0) + Number(r.shipped_qty));
      // already_wave per (po, sku) 累加（跨 store）
      const poEntry = s.poList.find((p) => p.po_id === r.po_id)!;
      poEntry.already_wave_for_sku += Number(r.wave_qty);
    }
    // 計算 totals
    for (const s of grouped.values()) {
      s.totalAlreadyWave = s.poList.reduce((sum, p) => sum + p.already_wave_for_sku, 0);
      s.totalAvailable = Math.max(0, s.totalGr - s.totalAlreadyWave);
      s.poList.sort((a, b) => a.po_id - b.po_id);
    }
    return Array.from(grouped.values())
      // 隱藏「已到貨且全部撿完」的 SKU;到貨 0 (sent 在路上)的繼續顯示讓使用者看得到
      .filter((s) => !(s.totalGr > 0 && s.totalAvailable === 0))
      .sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? ""));
  }, [demand]);

  const allStores: StoreInfo[] = useMemo(() => {
    if (!demand) return [];
    const m = new Map<number, StoreInfo>();
    for (const r of demand) {
      if (r.store_id !== null && !m.has(r.store_id)) {
        m.set(r.store_id, {
          store_id: r.store_id,
          store_code: r.store_code,
          store_name: r.store_name ?? `#${r.store_id}`,
        });
      }
    }
    return Array.from(m.values()).sort((a, b) => (a.store_code ?? "").localeCompare(b.store_code ?? ""));
  }, [demand]);

  // 依分店視角（純檢視）
  type StoreSection = {
    storeId: number;
    storeCode: string | null;
    storeName: string;
    rows: DemandRow[];
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

  // 補貨申請預設分配 = min(申請量 - 已撿, HQ 庫存) per (rr, sku)
  useEffect(() => {
    if (!restockDemand) return;
    setRestockAllocs((prev) => {
      const next = new Map(prev);
      for (const r of restockDemand) {
        const k = `${r.restock_request_id}:${r.sku_id}`;
        if (next.has(k)) continue;
        const cap = Math.max(
          0,
          Math.min(Number(r.demand_qty) - Number(r.wave_qty), Number(r.gr_qty)),
        );
        next.set(k, cap);
      }
      return next;
    });
  }, [restockDemand]);

  // 預設分配 = max(0, demand - wave - shipped) per (sku, store)
  useEffect(() => {
    if (!demand) return;
    setAllocs((prev) => {
      const next = new Map(prev);
      const agg = new Map<AllocKey, { demand: number; wave: number; shipped: number }>();
      for (const r of demand) {
        if (r.store_id === null) continue;
        const k: AllocKey = `${r.sku_id}:${r.store_id}`;
        const slot = agg.get(k) ?? { demand: 0, wave: 0, shipped: 0 };
        slot.demand += Number(r.demand_qty);
        slot.wave += Number(r.wave_qty);
        slot.shipped += Number(r.shipped_qty);
        agg.set(k, slot);
      }
      for (const [k, v] of agg.entries()) {
        if (!next.has(k)) {
          next.set(k, Math.max(0, v.demand - v.wave - v.shipped));
        }
      }
      return next;
    });
  }, [demand]);

  // ===== Allocation Helpers =====
  function setAlloc(skuId: number, storeId: number, qty: number) {
    const k: AllocKey = `${skuId}:${storeId}`;
    setAllocs((prev) => {
      const next = new Map(prev);
      next.set(k, Math.max(0, qty));
      return next;
    });
  }
  // 受限版本:同 SKU 已分配總和不可超過 totalAvailable(即「可分配」上限)
  function setAllocCapped(skuId: number, storeId: number, requested: number, totalAvailable: number) {
    setAllocs((prev) => {
      const k: AllocKey = `${skuId}:${storeId}`;
      const cur = prev.get(k) ?? 0;
      let sum = 0;
      const prefix = `${skuId}:`;
      for (const [key, val] of prev) {
        if (key.startsWith(prefix)) sum += val;
      }
      const headroom = Math.max(0, totalAvailable - sum); // 還能再加多少
      const maxAllowed = cur + headroom;                  // 此格的最大允許值
      const capped = Math.max(0, Math.min(requested, maxAllowed));
      const next = new Map(prev);
      next.set(k, capped);
      return next;
    });
  }
  function getAlloc(skuId: number, storeId: number): number {
    return allocs.get(`${skuId}:${storeId}`) ?? 0;
  }
  function getSkuAllocTotal(skuRow: SkuRow): number {
    let sum = 0;
    for (const st of allStores) sum += getAlloc(skuRow.sku_id, st.store_id);
    return sum;
  }
  // 「⚖ 平均」自動分配:把 totalAvailable 平均分到「需求 > 0」的店,cap 在各店 demand。
  // 若有店 demand 不足分到的份額,剩餘量會在下一輪重新平均。
  function autoDistribute(sku: SkuRow) {
    const stores = allStores;
    let pool = sku.totalAvailable;
    const give = new Map<number, number>();
    for (const s of stores) give.set(s.store_id, 0);
    for (let iter = 0; iter < 10 && pool > 0; iter += 1) {
      const eligible = stores.filter((s) => {
        const d = sku.storeDemand.get(s.store_id) ?? 0;
        const cur = give.get(s.store_id) ?? 0;
        return cur < d;
      });
      if (eligible.length === 0) break;
      const base = Math.floor(pool / eligible.length);
      if (base === 0) {
        // pool < eligible 數量,依 demand 大小排序給 +1
        const sorted = [...eligible].sort(
          (a, b) =>
            (sku.storeDemand.get(b.store_id) ?? 0) -
            (sku.storeDemand.get(a.store_id) ?? 0),
        );
        for (let i = 0; i < pool && i < sorted.length; i += 1) {
          const s = sorted[i];
          const d = sku.storeDemand.get(s.store_id) ?? 0;
          const cur = give.get(s.store_id) ?? 0;
          if (cur < d) give.set(s.store_id, cur + 1);
        }
        pool = 0;
        break;
      }
      let givenThisRound = 0;
      for (const s of eligible) {
        const d = sku.storeDemand.get(s.store_id) ?? 0;
        const cur = give.get(s.store_id) ?? 0;
        const add = Math.min(base, d - cur);
        give.set(s.store_id, cur + add);
        givenThisRound += add;
      }
      pool -= givenThisRound;
      if (givenThisRound === 0) break;
    }
    setAllocs((prev) => {
      const next = new Map(prev);
      for (const s of stores) {
        next.set(`${sku.sku_id}:${s.store_id}`, give.get(s.store_id) ?? 0);
      }
      return next;
    });
  }

  // FIFO 提交：把每個 (sku, store) 的擬分量切分到含此 sku 的多張 PO，再對每張 PO 各別發 RPC
  async function submitAll() {
    if (!demand) return;
    setError(null);
    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      // 校驗：每個 SKU 的擬分總量 ≤ totalAvailable
      const overSkus: string[] = [];
      for (const sk of skuRows) {
        const allocSum = getSkuAllocTotal(sk);
        if (allocSum > sk.totalAvailable) {
          overSkus.push(`「${sk.sku_code ?? ""} ${sk.sku_label}」分配 ${allocSum} 超過可分配 ${sk.totalAvailable}`);
        }
      }
      if (overSkus.length > 0) throw new Error("超過可分配量：\n" + overSkus.join("\n"));

      // 建可消耗的 PO 容量表 perPoSkuLeft.get(`${po}:${sku}`) = 該 PO 該 SKU 還可分配
      const perPoSkuLeft = new Map<string, number>();
      for (const sk of skuRows) {
        for (const po of sk.poList) {
          const left = Math.max(0, po.gr_qty - po.already_wave_for_sku);
          perPoSkuLeft.set(`${po.po_id}:${sk.sku_id}`, left);
        }
      }

      // 對每個 (sku, store) 的擬分量做 FIFO 切到 PO
      const perPoAllocs = new Map<number, Array<{ sku_id: number; store_id: number; qty: number }>>();
      const insufficient: string[] = [];
      for (const sk of skuRows) {
        for (const st of allStores) {
          const qty = getAlloc(sk.sku_id, st.store_id);
          if (qty <= 0) continue;
          let remaining = qty;
          for (const po of sk.poList) {
            if (remaining <= 0) break;
            const k = `${po.po_id}:${sk.sku_id}`;
            const av = perPoSkuLeft.get(k) ?? 0;
            if (av <= 0) continue;
            const take = Math.min(remaining, av);
            const slot = perPoAllocs.get(po.po_id) ?? [];
            slot.push({ sku_id: sk.sku_id, store_id: st.store_id, qty: take });
            perPoAllocs.set(po.po_id, slot);
            perPoSkuLeft.set(k, av - take);
            remaining -= take;
          }
          if (remaining > 0) {
            insufficient.push(`「${sk.sku_code ?? ""} ${sk.sku_label}」→ ${st.store_name} 缺 ${remaining}`);
          }
        }
      }

      if (insufficient.length > 0) throw new Error("可分配量不足：\n" + insufficient.join("\n"));
      if (perPoAllocs.size === 0) throw new Error("沒有任何分配 — 請先填數量");

      // 對每個 PO 各發一次 RPC
      const results: { po_no: string; wave_id: number; wave_code: string }[] = [];
      const failures: { po_no: string; error: string }[] = [];
      for (const [poId, allocations] of perPoAllocs.entries()) {
        const sample = demand.find((d) => d.po_id === poId);
        const poNo = sample?.po_no ?? `PO#${poId}`;
        try {
          const { data, error: e } = await sb.rpc("rpc_create_wave_from_po", {
            p_po_id: poId,
            p_wave_date: waveDate,
            p_allocations: allocations,
            p_operator: operator,
          });
          if (e) throw new Error(e.message);
          const r = data as { wave_id: number; wave_code: string };
          results.push({ po_no: poNo, wave_id: r.wave_id, wave_code: r.wave_code });
        } catch (err) {
          failures.push({ po_no: poNo, error: err instanceof Error ? err.message : String(err) });
        }
      }

      if (failures.length === 0) {
        if (results.length === 1) {
          alert(`✅ 已建立撿貨單 ${results[0].wave_code}`);
        } else {
          alert(
            `✅ 已建立 ${results.length} 張撿貨單：\n` +
              results.map((r) => `  ${r.po_no} → ${r.wave_code}`).join("\n"),
          );
        }
        router.push("/hq/inbox?source=picking");
      } else {
        const okPart =
          results.length > 0
            ? `✅ 成功 ${results.length} 張：${results.map((r) => r.wave_code).join(", ")}\n\n`
            : "";
        const failPart =
          `⚠️ 失敗 ${failures.length} 張：\n` +
          failures.map((f) => `  ${f.po_no}: ${f.error}`).join("\n");
        throw new Error(okPart + failPart);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  // ============================================================
  // 渲染
  // ============================================================
  const totalAllocSum = useMemo(() => {
    let s = 0;
    for (const v of allocs.values()) s += v;
    return s;
  }, [allocs]);

  const involvedPos = useMemo(() => {
    const set = new Set<number>();
    for (const sk of skuRows) {
      const skuAlloc = getSkuAllocTotal(sk);
      if (skuAlloc <= 0) continue;
      // 模擬 FIFO 估算會涉及哪幾張 PO
      let remaining = skuAlloc;
      for (const po of sk.poList) {
        if (remaining <= 0) break;
        const av = Math.max(0, po.gr_qty - po.already_wave_for_sku);
        if (av <= 0) continue;
        const take = Math.min(remaining, av);
        if (take > 0) set.add(po.po_id);
        remaining -= take;
      }
    }
    return set.size;
  }, [skuRows, allocs]); // eslint-disable-line react-hooks/exhaustive-deps

  // ===== 補貨申請(無 PO 來源)分組 =====
  type RestockGroup = {
    rrId: number;
    rrStatus: string;
    storeId: number;
    storeCode: string | null;
    storeName: string;
    lines: RestockRow[];
  };
  const restockGroups: RestockGroup[] = useMemo(() => {
    if (!restockDemand) return [];
    const map = new Map<number, RestockGroup>();
    for (const r of restockDemand) {
      let g = map.get(r.restock_request_id);
      if (!g) {
        g = {
          rrId: r.restock_request_id,
          rrStatus: r.restock_status,
          storeId: r.store_id,
          storeCode: r.store_code,
          storeName: r.store_name ?? `#${r.store_id}`,
          lines: [],
        };
        map.set(r.restock_request_id, g);
      }
      g.lines.push(r);
    }
    return Array.from(map.values()).sort((a, b) => a.rrId - b.rrId);
  }, [restockDemand]);

  function getRestockAlloc(rrId: number, skuId: number): number {
    return restockAllocs.get(`${rrId}:${skuId}`) ?? 0;
  }
  function setRestockAlloc(rrId: number, skuId: number, qty: number, max: number) {
    setRestockAllocs((prev) => {
      const next = new Map(prev);
      next.set(`${rrId}:${skuId}`, Math.max(0, Math.min(qty, max)));
      return next;
    });
  }

  async function submitRestockWave(group: RestockGroup) {
    setError(null);
    setSubmittingRrId(group.rrId);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const allocations: { sku_id: number; store_id: number; qty: number }[] = [];
      for (const ln of group.lines) {
        const qty = getRestockAlloc(group.rrId, ln.sku_id);
        if (qty > 0) {
          allocations.push({ sku_id: ln.sku_id, store_id: group.storeId, qty });
        }
      }
      if (allocations.length === 0) {
        throw new Error("沒有任何分配 — 請先填數量");
      }
      const { data, error: e } = await sb.rpc("rpc_create_wave_from_restock", {
        p_restock_request_id: group.rrId,
        p_wave_date: waveDate,
        p_allocations: allocations,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      const r = data as { wave_id: number; wave_code: string };
      alert(`✅ 已建立撿貨單 ${r.wave_code}`);
      setReloadKey((k) => k + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmittingRrId(null);
    }
  }

  // KPI 總覽
  const kpis = useMemo(() => {
    let totalAvailable = 0, totalInTransit = 0, totalShortage = 0;
    let skuShortageCount = 0;
    for (const sk of skuRows) {
      totalAvailable += sk.totalAvailable;
      totalInTransit += sk.totalInTransit;
      totalShortage += sk.totalShortage;
      if (sk.totalShortage > 0) skuShortageCount += 1;
    }
    return { totalAvailable, totalInTransit, totalShortage, skuShortageCount };
  }, [skuRows]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">🚦 派貨工作台</h1>
          <p className="text-sm text-zinc-500">
            合併所有未派完 PO 為一張矩陣 — 直接針對 品項 × 分店分配,提交時依 PO 自動切分。包含客戶訂單派貨與補貨申請(📦)。
          </p>
        </div>
        <Link
          href="/hq/inbox?source=picking"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          撿貨單列表 →
        </Link>
      </header>

      {/* KPI bar */}
      {skuRows.length > 0 && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <KpiCard label="可分配庫存" value={kpis.totalAvailable} accent="text-emerald-700 dark:text-emerald-400" hint="HQ 已到貨可派" />
          <KpiCard label="本次擬分" value={totalAllocSum} accent="text-blue-700 dark:text-blue-400" hint={involvedPos > 0 ? `預計切 ${involvedPos} 張 wave` : "尚未填入分配量"} />
          <KpiCard label="在途待到" value={kpis.totalInTransit} accent="text-amber-700 dark:text-amber-400" hint="PO 部分收,還會再來" />
          <KpiCard
            label={kpis.totalShortage > 0 ? "⚠ 短少" : "無短少"}
            value={kpis.totalShortage}
            accent={kpis.totalShortage > 0 ? "text-rose-700 dark:text-rose-400" : "text-zinc-400"}
            hint={kpis.skuShortageCount > 0 ? `${kpis.skuShortageCount} 品項受影響` : "—"}
          />
        </div>
      )}

      {/* Tab 切換 */}
      <div className="border-b border-zinc-200 dark:border-zinc-800">
        <nav className="-mb-px flex gap-4">
          <TabBtn active={viewMode === "matrix"} onClick={() => setViewMode("matrix")}>
            🧾 全清單矩陣（建單）
          </TabBtn>
          <TabBtn active={viewMode === "by_store"} onClick={() => setViewMode("by_store")}>
            🏬 依分店（檢視）
          </TabBtn>
        </nav>
      </div>

      {/* 控制列 */}
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
          {loading
            ? "載入中…"
            : viewMode === "matrix"
              ? `${skuRows.length} 個品項 · ${allStores.length} 間分店 · 擬分總量 ${totalAllocSum}${
                  involvedPos > 0 ? ` · 預計切 ${involvedPos} 張撿貨單` : ""
                }`
              : `${storeSections.length} 間分店有待撿貨`}
        </span>

        {viewMode === "matrix" && skuRows.length > 0 && (
          <div className="ml-auto">
            <SpinButton
              onClick={submitAll}
              disabled={submitting || totalAllocSum === 0}
              className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {submitting ? "建立中…" : `🧾 建立撿貨單${involvedPos > 1 ? ` (${involvedPos} 張)` : ""}`}
            </SpinButton>
          </div>
        )}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <pre className="whitespace-pre-wrap font-mono text-xs">{error}</pre>
        </div>
      )}

      {demand === null ? (
        <div className="text-center text-sm text-zinc-500">載入中…</div>
      ) : viewMode === "matrix" ? (
        skuRows.length === 0 ? (
          <div className="rounded-md border border-zinc-200 p-12 text-center text-sm text-zinc-500 dark:border-zinc-800">
            沒有待撿貨的品項(所有已進貨的都已派完)。
          </div>
        ) : (
          <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <colgroup>
                <col className="w-[220px]" />
                <col className="w-14" />
                <col className="w-14" />
                <col className="w-14" />
                <col className="w-14" />
                <col className="w-14" />
                <col className="w-16" />
                <col className="w-16" />
                {allStores.map((st) => <col key={st.store_id} className="w-20" />)}
              </colgroup>
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Th className="sticky left-0 bg-zinc-50 dark:bg-zinc-900">品項 / 來源 PO</Th>
                  <Th className="text-center">訂購</Th>
                  <Th className="text-center">已到</Th>
                  <Th className="text-center" title="PO 還沒結、還會繼續到的數量">在途</Th>
                  <Th className="text-center" title="PO 結了但供應商少給的數量(永遠不會到)">短少</Th>
                  <Th className="text-center">已撿</Th>
                  <Th className="text-center">可分配</Th>
                  <Th className="text-center">合計</Th>
                  {allStores.map((st) => (
                    <Th key={st.store_id} className="text-center">
                      <div className="text-[11px] font-medium">{st.store_name}</div>
                      <div className="font-mono text-[9px] text-zinc-400">{st.store_code}</div>
                    </Th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {skuRows.map((sk) => {
                  const allocSum = getSkuAllocTotal(sk);
                  const overAlloc = allocSum > sk.totalAvailable;
                  const remaining = sk.totalAvailable - allocSum; // 可分配剩餘
                  return (
                    <tr key={sk.sku_id} className={overAlloc ? "bg-red-50 dark:bg-red-950/30" : ""}>
                      <Td className="sticky left-0 bg-white px-3 py-2 text-xs dark:bg-zinc-900">
                        <div className="flex items-start justify-between gap-2">
                          <div className="min-w-0 flex-1">
                            <div className="font-mono text-[11px] text-zinc-500">{sk.sku_code ?? "—"}</div>
                            <div className="truncate" title={sk.sku_label}>{sk.sku_label}</div>
                            <div className="mt-1 flex flex-wrap items-center gap-1 text-[10px] text-zinc-400">
                              {sk.poList.length === 1
                                ? <span className="font-mono" title={`${sk.poList[0].po_status ?? ""} · 訂 ${sk.poList[0].qty_ordered}/已到 ${sk.poList[0].gr_qty}/在途 ${sk.poList[0].qty_in_transit}/短少 ${sk.poList[0].qty_shortage}`}>{sk.poList[0].po_no}</span>
                                : <span title={sk.poList.map((p) => `${p.po_no} (${p.po_status ?? ""}): 訂 ${p.qty_ordered}/到 ${p.gr_qty}/在途 ${p.qty_in_transit}/短少 ${p.qty_shortage}/撿 ${p.already_wave_for_sku}`).join("\n")}>跨 {sk.poList.length} 張 PO</span>}
                              {sk.poList.some((p) => p.is_restock_sourced) && (
                                <span
                                  className="rounded bg-amber-100 px-1 py-0.5 text-[9px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                                  title="此 PO 來源為補貨申請(restock)"
                                >
                                  📦 補貨
                                </span>
                              )}
                            </div>
                          </div>
                          <SpinButton
                            type="button"
                            onClick={() => autoDistribute(sk)}
                            disabled={sk.totalAvailable === 0}
                            title={`依可分配 ${sk.totalAvailable} 平均分到各店(cap 在各店需求量)`}
                            className="shrink-0 self-center rounded border border-blue-300 bg-blue-50 px-1.5 py-0.5 text-[10px] font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-40 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                          >
                            ⚖ 平均
                          </SpinButton>
                        </div>
                      </Td>
                      <NumCell value={sk.totalOrdered} muted />
                      <NumCell value={sk.totalGr} bold />
                      <NumCell value={sk.totalInTransit} accent={sk.totalInTransit > 0 ? "transit" : undefined} />
                      <NumCell value={sk.totalShortage} accent={sk.totalShortage > 0 ? "danger" : undefined} />
                      <NumCell value={sk.totalAlreadyWave} muted />
                      {/* 可分配 = 剩餘 (totalAvailable - allocSum) */}
                      <td className="px-2 py-2 text-center align-middle">
                        <span
                          title={`可分配上限 ${sk.totalAvailable} / 已分配 ${allocSum}${overAlloc ? ` / 超出 ${allocSum - sk.totalAvailable}` : ""}`}
                          className={`font-mono text-lg font-bold tabular-nums ${
                            overAlloc
                              ? "text-red-700 dark:text-red-400"
                              : remaining === 0
                                ? "text-zinc-300 dark:text-zinc-600"
                                : "text-rose-700 dark:text-rose-300"
                          }`}
                        >
                          {remaining}
                        </span>
                      </td>
                      <NumCell value={allocSum} accent={overAlloc ? "danger" : "primary"} />
                      {allStores.map((st) => {
                        const value = getAlloc(sk.sku_id, st.store_id);
                        const demandQty = sk.storeDemand.get(st.store_id) ?? 0;
                        const maxForCell = value + Math.max(0, sk.totalAvailable - allocSum);
                        return (
                          <td key={st.store_id} className="px-2 py-1.5 text-center align-top">
                            <input
                              type="number"
                              value={value}
                              onChange={(e) => setAllocCapped(sk.sku_id, st.store_id, Number(e.target.value), sk.totalAvailable)}
                              min={0}
                              max={maxForCell}
                              step={1}
                              title={`需 ${demandQty} · 此格最多可填 ${maxForCell}`}
                              className={`w-full max-w-[68px] rounded border px-1 py-0.5 text-center font-mono text-sm font-medium tabular-nums dark:bg-zinc-800 ${
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
        )
      ) : (
        // 依分店視角 (純檢視)
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
            totalAlloc += getAlloc(r.sku_id, r.store_id!);
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
                    {section.rows.length} 筆 (PO×品項) · 訂單 {totalDemand}
                    {" · 已撿 "}{totalWave}
                    {" · 已派 "}{totalShipped}
                    {" · 本次擬分 "}{totalAlloc}
                  </p>
                </div>
              </header>

              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <thead className="bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th>採購單</Th>
                      <Th>品項</Th>
                      <Th className="text-center">訂單</Th>
                      <Th className="text-center">已撿</Th>
                      <Th className="text-center">已派</Th>
                      <Th className="text-center">本次擬分(該品項合計)</Th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {section.rows
                      .sort((a, b) => a.po_no.localeCompare(b.po_no) || (a.sku_code ?? "").localeCompare(b.sku_code ?? ""))
                      .map((r, i) => {
                        const alloc = getAlloc(r.sku_id, r.store_id!);
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

      {/* === 補貨申請(無 PO 來源) section === */}
      {restockDemand !== null && restockGroups.length > 0 && (
        <section className="mt-2 rounded-md border border-amber-200 bg-amber-50/40 dark:border-amber-900 dark:bg-amber-950/20">
          <header className="border-b border-amber-200 px-4 py-2 dark:border-amber-900">
            <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">
              📦 補貨申請(無 PO 來源)
              <span className="ml-2 text-xs font-normal text-amber-700/80 dark:text-amber-300/70">
                {restockGroups.length} 張申請 · 供給來自 HQ 即時庫存
              </span>
            </h2>
          </header>
          <div className="flex flex-col gap-3 p-3">
            {restockGroups.map((g) => {
              const allocSum = g.lines.reduce(
                (s, ln) => s + getRestockAlloc(g.rrId, ln.sku_id),
                0,
              );
              const canSubmit = allocSum > 0 && submittingRrId !== g.rrId;
              return (
                <div
                  key={g.rrId}
                  className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900"
                >
                  <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
                    <div className="flex flex-wrap items-baseline gap-2">
                      <span className="font-mono text-sm font-semibold">
                        RR-{g.rrId}
                      </span>
                      <span className="inline-flex rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                        {g.rrStatus === "pending" ? "待處理" : "已批准"}
                      </span>
                      <span className="text-sm">{g.storeName}</span>
                      {g.storeCode && (
                        <span className="font-mono text-[11px] text-zinc-500">
                          {g.storeCode}
                        </span>
                      )}
                    </div>
                    <SpinButton
                      onClick={() => submitRestockWave(g)}
                      disabled={!canSubmit}
                      className="rounded-md bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
                    >
                      {submittingRrId === g.rrId
                        ? "建立中…"
                        : `🧾 建立撿貨單 (擬分 ${allocSum})`}
                    </SpinButton>
                  </div>
                  <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                    <thead className="bg-zinc-50 dark:bg-zinc-950">
                      <tr>
                        <Th>品項</Th>
                        <Th className="text-center">申請量</Th>
                        <Th className="text-center" title="HQ 即時庫存 (on_hand)">HQ 庫存</Th>
                        <Th className="text-center">已撿</Th>
                        <Th className="text-center">本次撿</Th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                      {g.lines.map((ln) => {
                        const maxForLine = Math.max(
                          0,
                          Math.min(
                            Number(ln.demand_qty) - Number(ln.wave_qty),
                            Number(ln.gr_qty),
                          ),
                        );
                        const value = getRestockAlloc(g.rrId, ln.sku_id);
                        return (
                          <tr key={ln.sku_id}>
                            <Td className="text-xs">
                              <div className="font-mono text-[11px] text-zinc-500">
                                {ln.sku_code ?? "—"}
                              </div>
                              <div title={ln.sku_label}>{ln.sku_label}</div>
                            </Td>
                            <NumCell value={Number(ln.demand_qty)} bold />
                            <NumCell
                              value={Number(ln.gr_qty)}
                              accent={
                                Number(ln.gr_qty) < Number(ln.demand_qty)
                                  ? "danger"
                                  : undefined
                              }
                            />
                            <NumCell value={Number(ln.wave_qty)} muted />
                            <td className="px-2 py-1.5 text-center">
                              <input
                                type="number"
                                value={value}
                                min={0}
                                max={maxForLine}
                                step={1}
                                onChange={(e) =>
                                  setRestockAlloc(
                                    g.rrId,
                                    ln.sku_id,
                                    Number(e.target.value),
                                    maxForLine,
                                  )
                                }
                                title={`最多可撿 ${maxForLine}(申請 ${ln.demand_qty}、庫存 ${ln.gr_qty}、已撿 ${ln.wave_qty})`}
                                className={`w-full max-w-[80px] rounded border px-1 py-0.5 text-center font-mono text-sm font-medium tabular-nums dark:bg-zinc-800 ${
                                  value === 0
                                    ? "border-zinc-200 text-zinc-300 dark:border-zinc-700"
                                    : "border-amber-300 text-amber-700 dark:border-amber-700 dark:text-amber-300"
                                }`}
                              />
                              <div className="mt-0.5 text-[10px] text-zinc-400">
                                ≤ {maxForLine}
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              );
            })}
          </div>
        </section>
      )}
    </div>
  );
}

// ============================================================
// Helpers
// ============================================================

function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <SpinButton
      onClick={onClick}
      className={`whitespace-nowrap border-b-2 px-1 py-2 text-sm font-medium transition ${
        active
          ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-400"
          : "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700 dark:hover:text-zinc-300"
      }`}
    >
      {children}
    </SpinButton>
  );
}

function Th({ children, className = "", title }: { children: React.ReactNode; className?: string; title?: string }) {
  return <th title={title} className={`px-2 py-1.5 text-left text-[11px] font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}

function KpiCard({ label, value, accent = "text-zinc-900 dark:text-zinc-100", hint }: { label: string; value: number; accent?: string; hint?: string }) {
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-0.5 font-mono text-2xl font-semibold tabular-nums ${accent}`}>{value}</div>
      {hint && <div className="mt-0.5 text-[10px] text-zinc-400">{hint}</div>}
    </div>
  );
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
  accent?: "primary" | "danger" | "transit";
}) {
  const isZero = value === 0;
  const cls = accent === "danger"
    ? "text-rose-600 font-medium"
    : accent === "transit"
      ? "text-amber-600 font-medium dark:text-amber-400"
      : accent === "primary"
        ? (isZero ? "text-zinc-300" : "text-blue-600 font-medium")
        : muted
          ? (isZero ? "text-zinc-300" : "text-zinc-500")
          : bold
            ? (isZero ? "text-zinc-300" : "text-zinc-700 dark:text-zinc-200")
            : "text-zinc-600 dark:text-zinc-400";
  return (
    <td className={`px-2 py-2 text-center font-mono text-sm tabular-nums ${cls}`}>
      {value}
    </td>
  );
}
