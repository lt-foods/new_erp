"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import { maskLineUserId } from "@/lib/maskLineUserId";
import { useRole, canSeeCost, canSeeBranch } from "@/lib/role";
import { AddStockModal } from "@/components/AddStockModal";
import { SpotSaleModal } from "@/components/SpotSaleModal";
import { translateRpcError } from "@/lib/rpcError";

type Loc = { id: number; code: string; name: string; type: string };
type StoreRow = { id: number; name: string; location_id: number | null };
type Balance = {
  location_id: number;
  sku_id: number;
  on_hand: number;
  reserved: number;
  in_transit_in: number;
  avg_cost: number;
  last_movement_at: string | null;
};
type Sku = { id: number; sku_code: string; product_name: string | null; variant_name: string | null; base_unit: string };
// 每個 SKU 的現行售價（effective_to IS NULL 的那筆；同 scope 多筆取 effective_from 最新）
type SkuPrices = { retail?: number; branch?: number };
type Reorder = { location_id: number; sku_id: number; safety_stock: number; reorder_point: number };
// rpc_get_stock_commitment_bulk 的一列：這個 (倉別, SKU) 的貨被誰佔著、還剩幾件能配
type Commitment = {
  location_id: number;
  sku_id: number;
  promised: number;     // 已承諾未取（客人單 ready/部分取貨/shipping）
  waiting: number;      // confirmed 還在等貨的需求
  pool: number;         // 【內部】店現貨池（含還在路上的 RR-）
  pool_arrived: number; // 其中已到店的部分 —— 現貨直配配得掉，配掉時自動扣池子
  free: number;         // 純自由量＝在庫 − 上面三項（下限 0）
  // 可分配（畫面上那一欄）＝在庫 − 待客取 − 等貨 − 在途池子（下限 0）。
  // 已到貨的池子算可分配：20260824060000 起現貨直配會在同一個交易扣池子。
  free_with_pool: number;
};
type Movement = {
  id: number;
  quantity: number;
  movement_type: string;
  source_doc_type: string | null;
  source_doc_id: number | null;
  batch_no: string | null;
  expiry_date: string | null;
  reason: string | null;
  notes: string | null;
  created_at: string;
  reverses: number | null; // 這筆沖銷了哪一筆（只有 reversal 列有值）
  // ★ 前端反查出來的，不是 DB 欄位：這筆已經被別的沖銷列撤掉了。
  //   不能用 stock_movements.reversed_by —— 那欄永遠是 NULL，因為
  //   trg_no_update_mov（20260422120003:266）無條件擋掉所有 UPDATE。
  reversed: boolean;
};

const PAGE_SIZE = 50;
const LOW_STOCK_SCAN_CAP = 2000;

const MOVE_LABEL: Record<string, string> = {
  purchase_receipt: "進貨",
  return_to_supplier: "退供應商",
  sale: "銷售出貨",
  customer_return: "客退入庫",
  transfer_out: "調撥出",
  transfer_in: "調撥入",
  stocktake_gain: "盤盈",
  stocktake_loss: "盤虧",
  damage: "報廢/損壞",
  manual_adjust: "手動調整",
  reversal: "沖銷",
};

const LINE_ID_RE = /U[0-9a-f]{32}/gi;
function maskFreeText(s: string | null): string {
  if (!s) return "";
  return s.replace(LINE_ID_RE, (m) => maskLineUserId(m));
}

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
function fmtQty(v: number): string {
  // NUMERIC(18,3) — 去掉無意義小數
  return Number(v.toFixed(3)).toLocaleString("zh-TW");
}
function fmtCost(v: number): string {
  return `$${Number(v.toFixed(4)).toLocaleString("zh-TW")}`;
}
function fmtDateTime(s: string | null): string {
  if (!s) return "—";
  return new Date(s).toLocaleString("zh-TW", { hour12: false });
}
// 「↩ 撤銷」只出現在庫存總覽自己補進來的那種：手動調整、正數、沒有來源單據。
// 判定與 rpc_reverse_stock_adjust 的守衛 4/5/9 對齊 —— 但真正的關卡在後端，
// 這裡只是不要讓使用者按下去才被擋。
// （後端還多兩道：帶成本的不給撤、分店只能撤自己店。前者這裡看不到 unit_cost
//   —— 成本不給分店角色看，不撈進 payload；現行寫入者只有 rpc_add_stock_by_product
//   會產生「沒有來源單據」的手動調整，而它一律不帶成本。）
function canReverse(m: Movement): boolean {
  return m.movement_type === "manual_adjust" && m.quantity > 0 && m.source_doc_type == null;
}
function sanitizeSearch(q: string): string {
  // PostgREST or() 語法用 , ( ) 當分隔；% 是 ilike wildcard — 全部移除避免破壞 filter
  return q.replace(/[,()%*]/g, " ").trim();
}

export default function InventoryOverviewPage() {
  // 成本只給總倉層級看（分店 store_manager / store_staff 一律遮掉）
  const role = useRole();
  const showCost = canSeeCost(role);
  // 分店價只給 canSeeBranch 的角色看（store_staff 只看零售價）
  const showBranchPrice = canSeeBranch(role);
  // 商品/倉別/在庫/待客取/內部單/可分配/在途/(均成本)/最後異動/展開箭頭
  const colCount = showCost ? 10 : 9;

  const [locs, setLocs] = useState<Loc[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);

  const [locationId, setLocationId] = useState<string>("");
  const [search, setSearch] = useState<string>("");
  const [searchInput, setSearchInput] = useState<string>("");
  const [onlyLow, setOnlyLow] = useState<boolean>(false);
  // 只看「可分配 > 0」的列：店員想知道「現在有哪些貨可以直接配給客人」。
  // 候選集合由 rpc_list_allocatable_pairs 給（很小），再照 onlyLow 的既有作法
  // 撈 stock_balances、前端分頁。
  // 20260824060000 起「可分配」含已到貨的內部現貨池 —— 那支 RPC 與這一欄、
  // 與配單彈窗的上限全部同一套算法（_sku_free_qty_with_pool），
  // 不然又會出現「列表寫得出數字、按鈕按不下去」。
  const [onlyFree, setOnlyFree] = useState<boolean>(false);
  const [page, setPage] = useState(1);

  const [rows, setRows] = useState<Balance[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [skuMap, setSkuMap] = useState<Map<number, Sku>>(new Map());
  // 零售價／分店價（老闆 2026-08-27：庫存頁要看得到兩個價；分店價照 canSeeBranch 收斂，
  // RLS 那層對 store_staff 本來就不回 branch 列，這裡只是雙保險）
  const [priceMap, setPriceMap] = useState<Map<number, SkuPrices>>(new Map());
  const [reorderMap, setReorderMap] = useState<Map<string, Reorder>>(new Map());
  const [truncated, setTruncated] = useState(false);

  const [expanded, setExpanded] = useState<string | null>(null);
  // 本頁每列的承諾量拆解（已承諾/等貨/池子/可分配），一頁一次批次取。
  // 算式留在伺服端（rpc_get_stock_commitment_bulk）—— 前端只顯示，不重算，
  // 否則等於把自由量公式又抄一份到前端。
  const [commitMap, setCommitMap] = useState<Map<string, Commitment>>(new Map());
  // 「退貨中 N」（2026-09-04 老闆裁示 2，乙案）：店家已經送出退貨、總倉還沒回覆，
  // 而且**還沒扣過庫存**的件數。key = `${location_id}-${sku_id}`。
  // 資料來源 v_store_pending_returns（20260904020000，母體定義寫在那支檔頭）。
  const [returningMap, setReturningMap] = useState<Map<string, number>>(new Map());
  const [moveCache, setMoveCache] = useState<Map<string, Movement[]>>(new Map());
  const [moveLoading, setMoveLoading] = useState(false);
  // 依商品新增庫存（manual_adjust +N）— 開庫存減抵單前把帳外現貨補進帳用
  const [adding, setAdding] = useState(false);
  // 現貨直配：把自由庫存直接配給客人（不用先開團）。null = 沒開
  const [spotTarget, setSpotTarget] = useState<{
    storeId: number;
    storeName: string;
    skuId: number;
    skuCode: string | null;
    skuLabel: string;
  } | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  // 分店帳號鎖定：用 store.name 比對 user.app_metadata.stores，回該 store 的 location_id
  const storeLocOptions = useMemo(
    () =>
      stores
        .filter((s) => s.location_id != null)
        .map((s) => ({ id: s.location_id as number, name: s.name })),
    [stores],
  );
  const branchLocationId = useUserBranchStoreId(storeLocOptions);
  useEffect(() => {
    if (branchLocationId != null && locationId !== String(branchLocationId)) {
      setLocationId(String(branchLocationId));
    }
  }, [branchLocationId, locationId]);
  useDefaultStoreFromUser(storeLocOptions, locationId, setLocationId);

  useEffect(() => {
    setPage(1);
  }, [locationId, search, onlyLow, onlyFree]);

  // 篩選來源（一次載入）
  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [l, s] = await Promise.all([
        sb.from("locations").select("id, code, name, type").eq("is_active", true).order("type").order("name"),
        sb.from("stores").select("id, name, location_id").eq("is_active", true).order("name"),
      ]);
      setLocs((l.data as Loc[]) ?? []);
      setStores((s.data as StoreRow[]) ?? []);
    })();
  }, []);

  // 主查詢
  useEffect(() => {
    // 等 role 解析完再查 — 免得先用「不能看成本」的欄位查一次、role 到齊又重查一次
    if (role === null) return;
    let cancelled = false;
    setLoading(true);
    setSearching(true);
    (async () => {
      try {
        const sb = getSupabase();
        // 不能看成本的角色連 avg_cost 都不撈，資料不會出現在 network payload
        const balanceCols = `location_id, sku_id, on_hand, reserved, in_transit_in, last_movement_at${showCost ? ", avg_cost" : ""}`;

        // 搜尋 → 先解析符合的 sku_id
        let skuIdFilter: number[] | null = null;
        const q = sanitizeSearch(search);
        if (q) {
          const { data: sk } = await sb
            .from("skus")
            .select("id")
            .or(`sku_code.ilike.%${q}%,product_name.ilike.%${q}%,variant_name.ilike.%${q}%`)
            .limit(1000);
          skuIdFilter = ((sk as { id: number }[]) ?? []).map((r) => r.id);
          if (skuIdFilter.length === 0) {
            if (!cancelled) {
              setRows([]);
              setTotal(0);
              setTruncated(false);
            }
            return;
          }
        }

        let pageRows: Balance[];
        let count: number;
        let isTruncated = false;

        // 「只看可配給客人」的候選集合。與 onlyLow 可以並用（取交集）。
        // 全站實測 507 組 / 15 個倉別，一次撈回來很便宜；
        // 但「全部倉別」時伺服端要走過每間店的訂單一次（~3s），所以有 spinner。
        let allocSet: Set<string> | null = null;
        let allocSkuIds: number[] | null = null;
        if (onlyFree) {
          const { data: ap, error: apErr } = await sb.rpc("rpc_list_allocatable_pairs", {
            p_location_id: locationId ? Number(locationId) : null,
            p_sku_ids: skuIdFilter,
            p_limit: 20000,
          });
          if (apErr) throw apErr;
          const pairs = (ap as { location_id: number; sku_id: number }[]) ?? [];
          if (pairs.length === 0) {
            if (!cancelled) { setRows([]); setTotal(0); setTruncated(false); setCommitMap(new Map()); setReturningMap(new Map()); }
            return;
          }
          allocSet = new Set(pairs.map((p) => `${p.location_id}-${p.sku_id}`));
          allocSkuIds = Array.from(new Set(pairs.map((p) => p.sku_id)));
        }

        if (onlyLow) {
          // 低庫存：先抓 reorder_rules（受管 SKU 集合、有界），再比對 on_hand
          let rr = sb.from("reorder_rules").select("location_id, sku_id, safety_stock, reorder_point").limit(LOW_STOCK_SCAN_CAP);
          if (locationId) rr = rr.eq("location_id", Number(locationId));
          if (skuIdFilter) rr = rr.in("sku_id", skuIdFilter);
          const { data: rrData } = await rr;
          const rules = (rrData as Reorder[]) ?? [];
          if (rules.length === 0) {
            if (!cancelled) { setRows([]); setTotal(0); setTruncated(false); }
            return;
          }
          if (rules.length >= LOW_STOCK_SCAN_CAP) isTruncated = true;
          const ruleSkuIds = Array.from(new Set(rules.map((r) => r.sku_id)));
          let bq = sb
            .from("stock_balances")
            .select(balanceCols)
            .in("sku_id", ruleSkuIds);
          if (locationId) bq = bq.eq("location_id", Number(locationId));
          const { data: bData, error: bErr } = await bq.limit(10000);
          if (bErr) throw bErr;
          const ruleByKey = new Map(rules.map((r) => [`${r.location_id}-${r.sku_id}`, r]));
          const low = ((bData as unknown as Balance[]) ?? [])
            .map((b) => ({ ...b, on_hand: num(b.on_hand), reserved: num(b.reserved), in_transit_in: num(b.in_transit_in), avg_cost: num(b.avg_cost) }))
            .filter((b) => {
              const r = ruleByKey.get(`${b.location_id}-${b.sku_id}`);
              if (r == null || b.on_hand > num(r.reorder_point)) return false;
              // 兩個篩選並用時取交集
              return allocSet == null || allocSet.has(`${b.location_id}-${b.sku_id}`);
            })
            .sort((a, b) => a.on_hand - b.on_hand);
          count = low.length;
          pageRows = low.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
        } else if (allocSkuIds != null && allocSet != null) {
          // 只看可配給客人：候選集合已知 → 撈那些 SKU 的餘額，前端分頁
          //（伺服端 range 分頁在這裡用不了，因為要先按 (倉別,SKU) 過濾）
          let bq = sb.from("stock_balances").select(balanceCols).in("sku_id", allocSkuIds);
          if (locationId) bq = bq.eq("location_id", Number(locationId));
          const { data: bData, error: bErr } = await bq.limit(10000);
          if (bErr) throw bErr;
          const hit = ((bData as unknown as Balance[]) ?? [])
            .map((b) => ({ ...b, on_hand: num(b.on_hand), reserved: num(b.reserved), in_transit_in: num(b.in_transit_in), avg_cost: num(b.avg_cost) }))
            .filter((b) => allocSet!.has(`${b.location_id}-${b.sku_id}`))
            .sort((a, b) => b.on_hand - a.on_hand);
          count = hit.length;
          pageRows = hit.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
        } else {
          let bq = sb
            .from("stock_balances")
            .select(balanceCols, { count: "exact" })
            .order("last_movement_at", { ascending: false, nullsFirst: false })
            .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
          if (locationId) bq = bq.eq("location_id", Number(locationId));
          if (skuIdFilter) bq = bq.in("sku_id", skuIdFilter);
          const { data: bData, count: bCount, error: bErr } = await bq;
          if (bErr) throw bErr;
          pageRows = ((bData as unknown as Balance[]) ?? []).map((b) => ({
            ...b,
            on_hand: num(b.on_hand),
            reserved: num(b.reserved),
            in_transit_in: num(b.in_transit_in),
            avg_cost: num(b.avg_cost),
          }));
          count = bCount ?? 0;
        }

        if (cancelled) return;
        setError(null);
        setRows(pageRows);
        setTotal(count);
        setTruncated(isTruncated);

        // 補 sku + reorder_rules + 承諾量拆解（僅本頁可見列）
        const skuIds = Array.from(new Set(pageRows.map((r) => r.sku_id)));
        if (skuIds.length > 0) {
          const [sk, rr, cm, pr, ret] = await Promise.all([
            sb.from("skus").select("id, sku_code, product_name, variant_name, base_unit").in("id", skuIds),
            sb.from("reorder_rules").select("location_id, sku_id, safety_stock, reorder_point").in("sku_id", skuIds),
            // 一頁一次，不要每列各打一次
            sb.rpc("rpc_get_stock_commitment_bulk", {
              p_pairs: pageRows.map((r) => ({ location_id: r.location_id, sku_id: r.sku_id })),
            }),
            // 現行售價（RLS 依 role × scope 過濾：store_staff 拿不到 branch）
            sb
              .from("prices")
              .select("sku_id, scope, price, effective_from")
              .in("sku_id", skuIds)
              .in("scope", ["retail", "branch"])
              .is("effective_to", null)
              .order("effective_from", { ascending: false }),
            // 退貨中（2026-09-04 乙案）：只撈本頁看得到的 SKU，跟上面四支同一個節奏。
            // ⚠ 這個 view 只收「還沒扣過庫存」的退貨單（out_movement_id IS NULL）——
            //   舊路徑（內部調撥 → ↩ 退貨回總倉）建單當下就扣掉了，不該再提醒一次。
            // ⚠ 有選倉別就一起帶上去：stock_balances 對分店帳號是**只讀自己那家**
            //   （store_read_own，20260707000070:65），但這支 view 沒有那道 RLS
            //   （比照 v_hq_exceptions 的既有寫法，不加 security_invoker）。
            //   不帶條件的話分店帳號會白拿到別家店的列 —— 畫面上不會顯示（key 對不上），
            //   但沒必要送過來。
            (() => {
              const q = sb
                .from("v_store_pending_returns")
                .select("location_id, sku_id, pending_qty")
                .in("sku_id", skuIds);
              return locationId ? q.eq("location_id", Number(locationId)) : q;
            })(),
          ]);
          if (cancelled) return;
          const sm = new Map<number, Sku>();
          for (const s of (sk.data as Sku[]) ?? []) sm.set(s.id, s);
          const pm = new Map<number, SkuPrices>();
          for (const p of (pr.data as { sku_id: number; scope: string; price: number }[]) ?? []) {
            const slot = pm.get(p.sku_id) ?? {};
            // 已依 effective_from 倒序 → 同 scope 只收第一筆（最新生效的）
            if (p.scope === "retail" && slot.retail === undefined) slot.retail = Number(p.price);
            if (p.scope === "branch" && slot.branch === undefined) slot.branch = Number(p.price);
            pm.set(p.sku_id, slot);
          }
          const rm = new Map<string, Reorder>();
          for (const r of (rr.data as Reorder[]) ?? []) rm.set(`${r.location_id}-${r.sku_id}`, r);
          const cmap = new Map<string, Commitment>();
          for (const c of (cm.data as Commitment[]) ?? []) {
            cmap.set(`${c.location_id}-${c.sku_id}`, {
              ...c,
              promised: num(c.promised),
              waiting: num(c.waiting),
              pool: num(c.pool),
              pool_arrived: num(c.pool_arrived),
              free: num(c.free),
              free_with_pool: num(c.free_with_pool),
            });
          }
          const retm = new Map<string, number>();
          for (const x of (ret.data as { location_id: number; sku_id: number; pending_qty: number }[]) ?? []) {
            retm.set(`${x.location_id}-${x.sku_id}`, num(x.pending_qty));
          }
          setSkuMap(sm);
          setPriceMap(pm);
          setReorderMap(rm);
          setCommitMap(cmap);
          setReturningMap(retm);
        } else {
          setSkuMap(new Map());
          setPriceMap(new Map());
          setReorderMap(new Map());
          setCommitMap(new Map());
          setReturningMap(new Map());
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) {
          setLoading(false);
          setSearching(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [locationId, search, onlyLow, onlyFree, page, role, showCost, reloadTick]);

  const storeByLoc = useMemo(() => {
    const m = new Map<number, string>();
    for (const s of stores) if (s.location_id != null) m.set(s.location_id, s.name);
    return m;
  }, [stores]);
  // 現貨直配要的是 store_id（承諾量/訂單都掛在店上，不是倉別上）；
  // 總倉這類沒有對應分店的倉別查不到 → 不出「配給客人」按鈕。
  const storeObjByLoc = useMemo(() => {
    const m = new Map<number, StoreRow>();
    for (const s of stores) if (s.location_id != null) m.set(s.location_id, s);
    return m;
  }, [stores]);
  const locLabel = (id: number) => {
    const l = locs.find((x) => x.id === id);
    if (!l) return `#${id}`;
    return storeByLoc.get(id) ?? l.name;
  };

  // 撈某個（倉別, SKU）的近 50 筆異動，並反查哪幾筆已經被撤銷過。
  // 一律重新撈 —— 撤銷完要馬上看到「已撤銷」與新的沖銷列；要不要跳過由呼叫端決定。
  async function loadMovements(key: string, loc: number, sku: number) {
    setMoveLoading(true);
    try {
      const sb = getSupabase();
      const { data } = await sb
        .from("stock_movements")
        .select("id, quantity, movement_type, source_doc_type, source_doc_id, batch_no, expiry_date, reason, notes, created_at, reverses")
        .eq("location_id", loc)
        .eq("sku_id", sku)
        .order("created_at", { ascending: false })
        .limit(50);
      const list = ((data as Movement[]) ?? []).map((m) => ({
        ...m,
        quantity: num(m.quantity),
        reversed: false,
      }));
      // 「這筆撤過了沒」只能用 reverses 反查（reversed_by 永遠寫不進去，見 Movement 型別註解）。
      // 另外查一次而不是從上面 50 筆裡找 —— 沖銷列很可能落在 50 筆視窗之外。
      const ids = list.map((m) => m.id);
      if (ids.length > 0) {
        const { data: rev } = await sb.from("stock_movements").select("reverses").in("reverses", ids);
        const done = new Set(((rev as { reverses: number | null }[]) ?? []).map((r) => r.reverses));
        for (const m of list) if (done.has(m.id)) m.reversed = true;
      }
      setMoveCache((c) => new Map(c).set(key, list));
    } finally {
      setMoveLoading(false);
    }
  }

  async function toggleExpand(key: string, loc: number, sku: number) {
    if (expanded === key) {
      setExpanded(null);
      return;
    }
    setExpanded(key);
    if (moveCache.has(key)) return;
    await loadMovements(key, loc, sku);
  }

  // 撤銷「＋ 新增庫存」補錯的那一筆：開一筆反向分錄（rpc_reverse_stock_adjust）。
  // 原本那筆不會消失 —— stock_movements 是 append-only，帳留痕。
  async function reverseAdjust(m: Movement, key: string, loc: number, sku: number, label: string) {
    if (
      !confirm(
        `撤銷這筆手動新增庫存？\n\n${label}\n${fmtDateTime(m.created_at)}　+${fmtQty(m.quantity)}\n\n` +
          `會開一筆反向分錄（−${fmtQty(m.quantity)}），庫存扣回去。\n` +
          `原本那筆不會消失，兩筆都留在異動紀錄裡（帳留痕）。`,
      )
    )
      return;
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_reverse_stock_adjust", {
        p_movement_id: m.id,
        p_operator: operator,
        p_reason: null,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as { on_hand?: number };
      alert(`✅ 已撤銷 ${fmtQty(m.quantity)} 件。${label} 目前在庫 ${fmtQty(num(r.on_hand))} 件。`);
      await loadMovements(key, loc, sku); // 異動清單 + 「已撤銷」標示
      setReloadTick((n) => n + 1); // 上面那排在庫/可分配數字
    } catch (err) {
      alert(`❌ ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);
  const branchLocked = branchLocationId != null;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between">
        <div>
        <h1 className="text-xl font-semibold">庫存總覽</h1>
        <p className="text-sm text-zinc-500">
          {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
          {truncated && <span className="ml-2 text-amber-600 dark:text-amber-400">（低庫存掃描已達 {LOW_STOCK_SCAN_CAP} 上限）</span>}
        </p>
        </div>
        <div className="flex items-center gap-2">
          <SpinButton
            onClick={() => setAdding(true)}
            className="rounded-md bg-emerald-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-emerald-700"
            title="對某倉別某商品直接加庫存（手動調整）。店內現貨沒入帳時先補帳，才能開庫存減抵單。"
          >
            ＋ 新增庫存
          </SpinButton>
          <Link
            href="/inventory/deductions"
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            庫存減抵單 →
          </Link>
          <Link
            href="/inventory/reorder-rules"
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            補貨規則 →
          </Link>
        </div>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        <div className="relative">
          <input
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") setSearch(searchInput);
            }}
            onBlur={() => setSearch(searchInput)}
            placeholder="搜尋 商品 / SKU / 規格…"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 pr-8 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
          <SearchSpinner active={searching} />
        </div>
        {branchLocked ? (
          <div className="flex items-center rounded-md border border-zinc-300 bg-zinc-50 px-3 py-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
            🏬 {locLabel(branchLocationId)}
            <span className="ml-2 text-xs text-zinc-500">(僅本店)</span>
          </div>
        ) : (
          <select
            value={locationId}
            onChange={(e) => setLocationId(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部倉別</option>
            {locs.map((l) => (
              <option key={l.id} value={l.id}>
                {storeByLoc.get(l.id) ?? l.name}
                {l.type === "central_warehouse" ? "（總倉）" : ""}
              </option>
            ))}
          </select>
        )}
        <label className="flex cursor-pointer items-center gap-2 rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <input type="checkbox" checked={onlyLow} onChange={(e) => setOnlyLow(e.target.checked)} />
          只看低於補貨點
        </label>
        <label
          className={`flex cursor-pointer items-center gap-2 rounded-md border px-3 py-2 text-sm ${
            onlyFree
              ? "border-violet-400 bg-violet-50 text-violet-800 dark:border-violet-700 dark:bg-violet-950/40 dark:text-violet-300"
              : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
          }`}
          title="只列出「可分配 > 0」的品項 —— 現在就能直接配給客人的貨。可與「只看低於補貨點」並用（取交集）。"
        >
          <input type="checkbox" checked={onlyFree} onChange={(e) => setOnlyFree(e.target.checked)} />
          🤝 只看可配給客人
        </label>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <Table>
        <THead>
          <Th>商品 / SKU</Th>
          <Th>倉別</Th>
          <Th align="right">在庫</Th>
          {/* 「保留 / 可用」拿掉了：stock_balances.reserved 全站沒在維護
              （2026-08-16 實測 7,712 筆有庫存的列，reserved<>0 的是 0 筆）
              → 可用 恆等於 在庫，是一欄假數字，而且會跟「可分配」互相打臉
              （截圖回報：列表寫可用 3、配單視窗寫自由量 0）。
              換成真的有意義的三欄。reserved 若哪天真的開始用，會以標記
              形式掛在「在庫」旁邊（見下方 rows 渲染）。 */}
          <Th align="right">待客取</Th>
          <Th align="right">內部單</Th>
          {/* 可分配含「已到店的內部現貨池」：那些貨在架上、配得掉，配的當下
              rpc_create_spot_sale 會把池子扣掉（20260824060000）。
              只算純自由量的話線上四間店有 800+ 件永遠顯示 0，店員補了帳
              還是 0（回報：「調整庫存完不能把庫存再轉出去」）。 */}
          <Th align="right">可分配</Th>
          <Th align="right">在途</Th>
          {showCost && <Th align="right">均成本</Th>}
          <Th align="right">最後異動</Th>
          <Th />
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={colCount} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={colCount}>沒有符合條件的庫存。</EmptyRow>
          ) : (
            rows.flatMap((r) => {
              const key = `${r.location_id}-${r.sku_id}`;
              const sku = skuMap.get(r.sku_id);
              const prices = priceMap.get(r.sku_id);
              const rule = reorderMap.get(key);
              const commit = commitMap.get(key) ?? null;
              const returningQty = returningMap.get(key) ?? 0;
              const isLow = rule != null && r.on_hand <= num(rule.reorder_point);
              const open = expanded === key;
              const out: React.ReactNode[] = [
                <Tr
                  key={key}
                  onClick={() => toggleExpand(key, r.location_id, r.sku_id)}
                  className={isLow ? "bg-amber-50 dark:bg-amber-950/30" : ""}
                >
                  <Td>
                    <div className="font-medium text-zinc-900 dark:text-zinc-100">
                      {sku?.product_name ?? "—"}
                      {sku?.variant_name ? <span className="ml-1 text-zinc-500">/ {sku.variant_name}</span> : null}
                    </div>
                    <div className="font-mono text-xs text-zinc-500">{sku?.sku_code ?? `sku#${r.sku_id}`}</div>
                    {/* 零售/分店價（老闆 2026-08-27）：配給客人用零售價，這裡先看得到 */}
                    {(prices?.retail !== undefined || (showBranchPrice && prices?.branch !== undefined)) && (
                      <div className="mt-0.5 flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-[10px]">
                        {prices?.retail !== undefined && (
                          <span className="rounded bg-emerald-100 px-1 py-0.5 font-bold text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                            零售 ${prices.retail}
                          </span>
                        )}
                        {showBranchPrice && prices?.branch !== undefined && (
                          <span className="rounded bg-amber-100 px-1 py-0.5 font-bold text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                            分店 ${prices.branch}
                          </span>
                        )}
                      </div>
                    )}
                  </Td>
                  <Td className="text-xs">{locLabel(r.location_id)}</Td>
                  <Td align="right" className="font-mono">
                    {fmtQty(r.on_hand)}
                    {/* reserved 目前全站恆為 0，所以不給一整欄；真的開始用的話
                        這個標記會自己冒出來，不會靜靜地被吃掉 */}
                    {r.reserved !== 0 && (
                      <span
                        className="ml-1 text-[10px] text-zinc-400"
                        title={`其中 ${fmtQty(r.reserved)} 件被 stock_balances.reserved 鎖住`}
                      >
                        (保留 {fmtQty(r.reserved)})
                      </span>
                    )}
                    {/* 退貨中（2026-09-04 老闆裁示 2 乙案）：
                        「先不扣 → 帳上還是 10，旁邊標『退貨中 3』讓人看得到」。
                        ⚠ 這個數字**已經算在左邊的在庫裡**（乙案就是還沒扣），
                          不是額外的、也不是被鎖住的 —— title 要把這件事講白，
                          不然店員會以為在庫 10 只剩 7 能賣。
                        ⚠ 大於在庫時轉紅：那代表總倉按同意時會扣不動而失敗
                          （20260904020010 會擋下來），要讓人在庫存頁就看得到。 */}
                    {returningQty > 0 && (
                      <span
                        className={`ml-1 text-[10px] ${
                          returningQty > r.on_hand
                            ? "font-semibold text-red-600 dark:text-red-400"
                            : "text-amber-700 dark:text-amber-400"
                        }`}
                        title={
                          returningQty > r.on_hand
                            ? `已送出 ${fmtQty(returningQty)} 件退貨在等總倉回覆，但店裡帳上只剩 ${fmtQty(r.on_hand)} 件 —— 總倉按「同意收回」時會扣不動而失敗，請先確認貨還在。`
                            : `已送出 ${fmtQty(returningQty)} 件退貨、還在等總倉回覆。這些件數還算在左邊的「在庫」裡（總倉同意的那一刻才會扣掉）。`
                        }
                      >
                        (退貨中 {fmtQty(returningQty)})
                      </span>
                    )}
                    {isLow && (
                      <span className="ml-1.5 rounded bg-amber-200 px-1 text-[10px] font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-300">
                        低
                      </span>
                    )}
                  </Td>
                  <Td align="right" className="font-mono text-zinc-500" title="待客取：貨已到店、客人的訂單也掛著了，就等他來領 —— 不能再賣給別人">
                    {commit ? fmtQty(commit.promised) : "—"}
                    {commit != null && commit.waiting > 0 && (
                      <span className="ml-1 text-[10px] text-zinc-400" title="還在等貨的 confirmed 訂單需求">
                        +{fmtQty(commit.waiting)}待
                      </span>
                    )}
                  </Td>
                  <Td align="right" className="font-mono text-zinc-500" title="掛在【內部】xx 店名下的貨（RR- / OV- / AB- 單）。已到店的部分「🤝 配給客人」配得掉，配掉時會自動從池子扣">
                    {commit ? fmtQty(commit.pool) : "—"}
                  </Td>
                  <Td
                    align="right"
                    className={`font-mono font-semibold ${
                      commit == null
                        ? "text-zinc-400"
                        : commit.free_with_pool > 0
                          ? "text-emerald-700 dark:text-emerald-400"
                          : "text-zinc-400"
                    }`}
                    title="可分配＝在庫 − 待客取 − 等貨 − 還在路上的內部單。這才是能直接配給客人的量（已到店的內部現貨池算在內，配掉時會自動扣池子）"
                  >
                    {commit ? fmtQty(commit.free_with_pool) : "—"}
                    {/* 有多少是要從池子扣的，先講清楚 —— 配掉之後店家看到的
                        內部單數量會跟著少，沒有提示就像貨憑空消失 */}
                    {commit != null && commit.free_with_pool > commit.free && (
                      <span
                        className="ml-1 text-[10px] font-normal text-zinc-400"
                        title="其中這些件數掛在【內部】店現貨池，配給客人時會自動從池子扣"
                      >
                        含{fmtQty(commit.free_with_pool - commit.free)}池
                      </span>
                    )}
                  </Td>
                  <Td align="right" className="font-mono text-zinc-500">{fmtQty(r.in_transit_in)}</Td>
                  {showCost && <Td align="right" className="font-mono text-zinc-500">{fmtCost(r.avg_cost)}</Td>}
                  <Td align="right" className="text-xs text-zinc-500">
                    <span title={fmtDateTime(r.last_movement_at)}>
                      {r.last_movement_at
                        ? new Date(r.last_movement_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" })
                        : "—"}
                    </span>
                  </Td>
                  <Td align="right" className="text-xs text-zinc-400">{open ? "▾" : "▸"}</Td>
                </Tr>,
              ];
              if (open) {
                const moves = moveCache.get(key);
                out.push(
                  <tr key={`${key}-detail`} className="bg-zinc-50 dark:bg-zinc-900/50">
                    <td colSpan={colCount} className="px-4 py-3">
                      {/* 現貨直配入口：把店內現貨（自由庫存 ＋ 已到貨的內部現貨池）
                          直接配給客人。可配量由 modal 自己去 rpc_get_spot_availability
                          拿 —— 這裡不預先撈，免得展開每一列都多打一次 RPC。 */}
                      {(() => {
                        const st = storeObjByLoc.get(r.location_id);
                        if (!st) return null; // 總倉等沒有對應分店的倉別不出這顆
                        return (
                          <div className="mb-3 flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 pb-2 dark:border-zinc-800">
                            <span className="text-xs text-zinc-500">
                              店內現貨可以直接配給客人（不用先開團）—— 配單＝待取，取貨時才扣庫存收款。
                              {commit != null && commit.free_with_pool > commit.free && (
                                <>
                                  <br />
                                  {`其中 ${fmtQty(commit.free_with_pool - commit.free)} 件掛在【內部】${st.name}現貨池，配掉時會自動從池子扣。`}
                                </>
                              )}
                            </span>
                            <SpinButton
                              onClick={() =>
                                setSpotTarget({
                                  storeId: st.id,
                                  storeName: st.name,
                                  skuId: r.sku_id,
                                  skuCode: sku?.sku_code ?? null,
                                  skuLabel:
                                    `${sku?.product_name ?? ""}${sku?.variant_name ? ` / ${sku.variant_name}` : ""}`.trim() ||
                                    `sku#${r.sku_id}`,
                                })
                              }
                              className="shrink-0 rounded-md bg-violet-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-violet-700"
                              title="把店內自由庫存直接配給客人（會開一張待取訂單）"
                            >
                              🤝 配給客人
                            </SpinButton>
                          </div>
                        );
                      })()}
                      <div className="text-xs font-medium text-zinc-500">近 50 筆庫存異動</div>
                      {moveLoading && !moves ? (
                        <div className="py-3 text-center text-sm text-zinc-500">載入中…</div>
                      ) : !moves || moves.length === 0 ? (
                        <div className="py-3 text-center text-sm text-zinc-500">無異動紀錄</div>
                      ) : (
                        <div className="mt-2 overflow-x-auto">
                          <table className="min-w-full text-xs">
                            <thead className="text-zinc-500">
                              <tr>
                                <th className="px-2 py-1 text-left">時間</th>
                                <th className="px-2 py-1 text-left">類型</th>
                                <th className="px-2 py-1 text-right">數量</th>
                                <th className="px-2 py-1 text-left">來源單據</th>
                                <th className="px-2 py-1 text-left">批號 / 效期</th>
                                <th className="px-2 py-1 text-left">原因 / 備註</th>
                                <th className="px-2 py-1 text-right">操作</th>
                              </tr>
                            </thead>
                            <tbody>
                              {moves.map((m) => (
                                <tr key={m.id} className="border-t border-zinc-200 dark:border-zinc-800">
                                  <td className="px-2 py-1 text-zinc-500">{fmtDateTime(m.created_at)}</td>
                                  <td className="px-2 py-1">
                                    {MOVE_LABEL[m.movement_type] ?? m.movement_type}
                                    {/* 沖銷列指回它撤掉的那一筆，兩邊對得起來 */}
                                    {m.reverses != null && (
                                      <span className="ml-1 text-[10px] text-zinc-400">← 撤 #{m.reverses}</span>
                                    )}
                                  </td>
                                  <td
                                    className={`px-2 py-1 text-right font-mono ${m.quantity < 0 ? "text-red-600 dark:text-red-400" : "text-emerald-600 dark:text-emerald-400"} ${m.reversed ? "line-through opacity-60" : ""}`}
                                  >
                                    {m.quantity > 0 ? "+" : ""}
                                    {fmtQty(m.quantity)}
                                  </td>
                                  <td className="px-2 py-1 text-zinc-500">
                                    {m.source_doc_type ? `${m.source_doc_type}${m.source_doc_id ? ` #${m.source_doc_id}` : ""}` : "—"}
                                  </td>
                                  <td className="px-2 py-1 text-zinc-500">
                                    {m.batch_no || "—"}
                                    {m.expiry_date ? ` / ${m.expiry_date}` : ""}
                                  </td>
                                  <td className="px-2 py-1 text-zinc-500">
                                    {maskFreeText(m.reason) || "—"}
                                    {m.notes ? <span className="text-zinc-400"> · {maskFreeText(m.notes)}</span> : null}
                                  </td>
                                  <td className="px-2 py-1 text-right whitespace-nowrap">
                                    {m.reversed ? (
                                      <span
                                        className="text-zinc-400"
                                        title="這筆已經被撤銷了（下面/上面有一筆對應的沖銷紀錄）"
                                      >
                                        已撤銷
                                      </span>
                                    ) : canReverse(m) ? (
                                      <SpinButton
                                        onClick={() =>
                                          reverseAdjust(
                                            m,
                                            key,
                                            r.location_id,
                                            r.sku_id,
                                            `${sku?.product_name ?? ""}${sku?.variant_name ? ` / ${sku.variant_name}` : ""}`.trim() ||
                                              `sku#${r.sku_id}`,
                                          )
                                        }
                                        className="rounded border border-zinc-300 px-2 py-0.5 text-[11px] hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                                        title="補錯了要撤掉這一筆：會開一筆反向分錄把庫存扣回去。原本那筆不會消失（帳留痕）。"
                                      >
                                        ↩ 撤銷
                                      </SpinButton>
                                    ) : null}
                                  </td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                      )}
                    </td>
                  </tr>,
                );
              }
              return out;
            })
          )}
        </TBody>
      </Table>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}

      {adding && (
        <AddStockModal
          // 分店帳號只能對自己店的倉別加庫存 — 清單本身就過濾掉別店，
          // 不只是把下拉 disabled（disabled 的下拉仍會列出全部店名）
          locations={locs
            .filter((l) => branchLocationId == null || l.id === branchLocationId)
            .map((l) => ({
              id: l.id,
              label: `${storeByLoc.get(l.id) ?? l.name}${l.type === "central_warehouse" ? "（總倉）" : ""}`,
            }))}
          defaultLocationId={locationId}
          locked={branchLocked}
          onClose={() => setAdding(false)}
          onSaved={() => {
            // 重載當前列表 + 清掉展開列的異動快取（新異動要看得到）
            setMoveCache(new Map());
            // 展開中的那一列要直接重撈：只清快取不重撈的話，畫面會停在
            // 「無異動紀錄」（toggleExpand 已經跑過了不會再觸發），
            // 剛補完的那筆反而看不到，也就按不到它的「↩ 撤銷」。
            if (expanded) {
              const [loc, sku] = expanded.split("-").map(Number);
              if (Number.isFinite(loc) && Number.isFinite(sku)) void loadMovements(expanded, loc, sku);
            }
            setReloadTick((n) => n + 1);
          }}
        />
      )}

      {spotTarget && (
        <SpotSaleModal
          storeId={spotTarget.storeId}
          storeName={spotTarget.storeName}
          skuId={spotTarget.skuId}
          skuCode={spotTarget.skuCode}
          skuLabel={spotTarget.skuLabel}
          onClose={() => setSpotTarget(null)}
          onSaved={() => {
            // 配單當下不動庫存（取貨才扣），但自由量變了 → 重載讓下次展開拿到新數字
            setMoveCache(new Map());
            setReloadTick((n) => n + 1);
          }}
        />
      )}
    </div>
  );
}

function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <SpinButton
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800"
    >
      {children}
    </SpinButton>
  );
}
