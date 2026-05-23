"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { fetchAllPaginated } from "@/lib/fetchAllPaginated";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import SpinButton from "@/components/SpinButton";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import { maskLineUserId } from "@/lib/maskLineUserId";

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
type Reorder = { location_id: number; sku_id: number; safety_stock: number; reorder_point: number };
type Movement = {
  id: number;
  quantity: number;
  unit_cost: number | null;
  movement_type: string;
  source_doc_type: string | null;
  source_doc_id: number | null;
  batch_no: string | null;
  expiry_date: string | null;
  reason: string | null;
  notes: string | null;
  created_at: string;
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
function sanitizeSearch(q: string): string {
  // PostgREST or() 語法用 , ( ) 當分隔；% 是 ilike wildcard — 全部移除避免破壞 filter
  return q.replace(/[,()%*]/g, " ").trim();
}

export default function InventoryOverviewPage() {
  const [locs, setLocs] = useState<Loc[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);

  const [locationId, setLocationId] = useState<string>("");
  const [search, setSearch] = useState<string>("");
  const [searchInput, setSearchInput] = useState<string>("");
  const [onlyLow, setOnlyLow] = useState<boolean>(false);
  const [page, setPage] = useState(1);

  const [rows, setRows] = useState<Balance[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [skuMap, setSkuMap] = useState<Map<number, Sku>>(new Map());
  const [reorderMap, setReorderMap] = useState<Map<string, Reorder>>(new Map());
  const [truncated, setTruncated] = useState(false);

  const [expanded, setExpanded] = useState<string | null>(null);
  const [moveCache, setMoveCache] = useState<Map<string, Movement[]>>(new Map());
  const [moveLoading, setMoveLoading] = useState(false);

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
  }, [locationId, search, onlyLow]);

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
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();

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

        if (onlyLow) {
          // 低庫存：先抓 reorder_rules（受管 SKU 集合）。
          // AUDIT #7: 原本寫死 .limit(LOW_STOCK_SCAN_CAP=2000) 會漏掃低庫存警示;
          // 改用 fetchAllPaginated 翻完所有 rule (safetyCap 50000)。
          const rules = await fetchAllPaginated<Reorder>(({ from, to }) => {
            let rr = sb.from("reorder_rules").select("location_id, sku_id, safety_stock, reorder_point").order("location_id", { ascending: true }).order("sku_id", { ascending: true }).range(from, to);
            if (locationId) rr = rr.eq("location_id", Number(locationId));
            if (skuIdFilter) rr = rr.in("sku_id", skuIdFilter);
            return rr;
          }, { label: "reorder_rules low-stock scan", safetyCap: 50000 });
          if (rules.length === 0) {
            if (!cancelled) { setRows([]); setTotal(0); setTruncated(false); }
            return;
          }
          // fetchAllPaginated 已內建 safetyCap;真撞到會 throw。原 isTruncated 旗標不再需要。
          const ruleSkuIds = Array.from(new Set(rules.map((r) => r.sku_id)));
          let bq = sb
            .from("stock_balances")
            .select("location_id, sku_id, on_hand, reserved, in_transit_in, avg_cost, last_movement_at")
            .in("sku_id", ruleSkuIds);
          if (locationId) bq = bq.eq("location_id", Number(locationId));
          const { data: bData, error: bErr } = await bq.limit(10000);
          if (bErr) throw bErr;
          const ruleByKey = new Map(rules.map((r) => [`${r.location_id}-${r.sku_id}`, r]));
          const low = ((bData as Balance[]) ?? [])
            .map((b) => ({ ...b, on_hand: num(b.on_hand), reserved: num(b.reserved), in_transit_in: num(b.in_transit_in), avg_cost: num(b.avg_cost) }))
            .filter((b) => {
              const r = ruleByKey.get(`${b.location_id}-${b.sku_id}`);
              return r != null && b.on_hand <= num(r.reorder_point);
            })
            .sort((a, b) => a.on_hand - b.on_hand);
          count = low.length;
          pageRows = low.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
        } else {
          let bq = sb
            .from("stock_balances")
            .select("location_id, sku_id, on_hand, reserved, in_transit_in, avg_cost, last_movement_at", { count: "exact" })
            .order("last_movement_at", { ascending: false, nullsFirst: false })
            .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
          if (locationId) bq = bq.eq("location_id", Number(locationId));
          if (skuIdFilter) bq = bq.in("sku_id", skuIdFilter);
          const { data: bData, count: bCount, error: bErr } = await bq;
          if (bErr) throw bErr;
          pageRows = ((bData as Balance[]) ?? []).map((b) => ({
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

        // 補 sku + reorder_rules（僅本頁可見列）
        const skuIds = Array.from(new Set(pageRows.map((r) => r.sku_id)));
        if (skuIds.length > 0) {
          const [sk, rr] = await Promise.all([
            sb.from("skus").select("id, sku_code, product_name, variant_name, base_unit").in("id", skuIds),
            sb.from("reorder_rules").select("location_id, sku_id, safety_stock, reorder_point").in("sku_id", skuIds),
          ]);
          if (cancelled) return;
          const sm = new Map<number, Sku>();
          for (const s of (sk.data as Sku[]) ?? []) sm.set(s.id, s);
          const rm = new Map<string, Reorder>();
          for (const r of (rr.data as Reorder[]) ?? []) rm.set(`${r.location_id}-${r.sku_id}`, r);
          setSkuMap(sm);
          setReorderMap(rm);
        } else {
          setSkuMap(new Map());
          setReorderMap(new Map());
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [locationId, search, onlyLow, page]);

  const storeByLoc = useMemo(() => {
    const m = new Map<number, string>();
    for (const s of stores) if (s.location_id != null) m.set(s.location_id, s.name);
    return m;
  }, [stores]);
  const locLabel = (id: number) => {
    const l = locs.find((x) => x.id === id);
    if (!l) return `#${id}`;
    return storeByLoc.get(id) ?? l.name;
  };

  async function toggleExpand(key: string, loc: number, sku: number) {
    if (expanded === key) {
      setExpanded(null);
      return;
    }
    setExpanded(key);
    if (moveCache.has(key)) return;
    setMoveLoading(true);
    try {
      // AUDIT #17: 原本寫死 .limit(50),detail 面板看不到完整移動史。
      // 改 fetchAllPaginated(safetyCap=5000),取完該 sku × location 的所有 movement。
      const data = await fetchAllPaginated<Movement>(({ from, to }) =>
        getSupabase()
          .from("stock_movements")
          .select("id, quantity, unit_cost, movement_type, source_doc_type, source_doc_id, batch_no, expiry_date, reason, notes, created_at")
          .eq("location_id", loc)
          .eq("sku_id", sku)
          .order("id", { ascending: false })
          .range(from, to),
        { label: "inventory stock_movements detail", safetyCap: 5000 },
      );
      const list = data.map((m) => ({ ...m, quantity: num(m.quantity) }));
      setMoveCache((c) => new Map(c).set(key, list));
    } finally {
      setMoveLoading(false);
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
          {/* truncated 旗標保留作為未來 helper safetyCap 命中時的視覺提示;目前 fetchAllPaginated 撞到會 throw,此 span 暫無作用 */}
        </p>
        </div>
        <Link
          href="/inventory/reorder-rules"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          補貨規則 →
        </Link>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        <input
          value={searchInput}
          onChange={(e) => setSearchInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") setSearch(searchInput);
          }}
          onBlur={() => setSearch(searchInput)}
          placeholder="搜尋 商品 / SKU / 規格…"
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
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
          <Th align="right">保留</Th>
          <Th align="right">在途</Th>
          <Th align="right">可用</Th>
          <Th align="right">均成本</Th>
          <Th align="right">最後異動</Th>
          <Th />
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={9} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={9}>沒有符合條件的庫存。</EmptyRow>
          ) : (
            rows.flatMap((r) => {
              const key = `${r.location_id}-${r.sku_id}`;
              const sku = skuMap.get(r.sku_id);
              const rule = reorderMap.get(key);
              const available = r.on_hand - r.reserved;
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
                  </Td>
                  <Td className="text-xs">{locLabel(r.location_id)}</Td>
                  <Td align="right" className="font-mono">
                    {fmtQty(r.on_hand)}
                    {isLow && (
                      <span className="ml-1.5 rounded bg-amber-200 px-1 text-[10px] font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-300">
                        低
                      </span>
                    )}
                  </Td>
                  <Td align="right" className="font-mono text-zinc-500">{fmtQty(r.reserved)}</Td>
                  <Td align="right" className="font-mono text-zinc-500">{fmtQty(r.in_transit_in)}</Td>
                  <Td align="right" className={`font-mono ${available < 0 ? "text-red-600 dark:text-red-400" : ""}`}>
                    {fmtQty(available)}
                  </Td>
                  <Td align="right" className="font-mono text-zinc-500">{fmtCost(r.avg_cost)}</Td>
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
                    <td colSpan={9} className="px-4 py-3">
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
                              </tr>
                            </thead>
                            <tbody>
                              {moves.map((m) => (
                                <tr key={m.id} className="border-t border-zinc-200 dark:border-zinc-800">
                                  <td className="px-2 py-1 text-zinc-500">{fmtDateTime(m.created_at)}</td>
                                  <td className="px-2 py-1">{MOVE_LABEL[m.movement_type] ?? m.movement_type}</td>
                                  <td
                                    className={`px-2 py-1 text-right font-mono ${m.quantity < 0 ? "text-red-600 dark:text-red-400" : "text-emerald-600 dark:text-emerald-400"}`}
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
