"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import { translateRpcError } from "@/lib/rpcError";

type Loc = { id: number; code: string; name: string; type: string };
type StoreRow = { id: number; name: string; location_id: number | null };
type Sku = { id: number; sku_code: string; product_name: string | null; variant_name: string | null };
type Rule = {
  location_id: number;
  sku_id: number;
  safety_stock: number;
  reorder_point: number;
  max_stock: number | null;
  lead_time_days: number | null;
  updated_at: string | null;
};

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
function sanitizeSearch(q: string): string {
  return q.replace(/[,()%*]/g, " ").trim();
}

export default function ReorderRulesPage() {
  const [locs, setLocs] = useState<Loc[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [locationId, setLocationId] = useState<string>("");
  const [searchInput, setSearchInput] = useState("");
  const [search, setSearch] = useState("");

  const [rows, setRows] = useState<Rule[] | null>(null);
  const [skuMap, setSkuMap] = useState<Map<number, Sku>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  const [editOpen, setEditOpen] = useState(false);
  const [editRule, setEditRule] = useState<Rule | null>(null); // null = 新增

  const storeLocOptions = useMemo(
    () => stores.filter((s) => s.location_id != null).map((s) => ({ id: s.location_id as number, name: s.name })),
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

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        let skuIds: number[] | null = null;
        const q = sanitizeSearch(search);
        if (q) {
          const { data: sk } = await sb
            .from("skus")
            .select("id")
            .or(`sku_code.ilike.%${q}%,product_name.ilike.%${q}%,variant_name.ilike.%${q}%`)
            .limit(1000);
          skuIds = ((sk as { id: number }[]) ?? []).map((r) => r.id);
          if (skuIds.length === 0) {
            if (!cancelled) { setRows([]); setSkuMap(new Map()); }
            return;
          }
        }
        let rq = sb
          .from("reorder_rules")
          .select("location_id, sku_id, safety_stock, reorder_point, max_stock, lead_time_days, updated_at")
          .order("updated_at", { ascending: false })
          .limit(2000);
        if (locationId) rq = rq.eq("location_id", Number(locationId));
        if (skuIds) rq = rq.in("sku_id", skuIds);
        const { data, error: e } = await rq;
        if (e) throw e;
        if (cancelled) return;
        const list = ((data as Rule[]) ?? []).map((r) => ({
          ...r,
          safety_stock: num(r.safety_stock),
          reorder_point: num(r.reorder_point),
          max_stock: r.max_stock == null ? null : num(r.max_stock),
          lead_time_days: r.lead_time_days == null ? null : num(r.lead_time_days),
        }));
        setRows(list);
        setError(null);
        const ids = Array.from(new Set(list.map((r) => r.sku_id)));
        if (ids.length > 0) {
          const { data: sk } = await sb
            .from("skus")
            .select("id, sku_code, product_name, variant_name")
            .in("id", ids);
          if (cancelled) return;
          const m = new Map<number, Sku>();
          for (const s of (sk as Sku[]) ?? []) m.set(s.id, s);
          setSkuMap(m);
        } else setSkuMap(new Map());
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [locationId, search, reloadTick]);

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
  const skuLabel = (id: number) => {
    const s = skuMap.get(id);
    if (!s) return `sku#${id}`;
    return `${s.product_name ?? ""}${s.variant_name ? " / " + s.variant_name : ""}`.trim() || s.sku_code;
  };

  const branchLocked = branchLocationId != null;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between">
        <div>
          <h1 className="text-xl font-semibold">補貨規則</h1>
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : `共 ${rows.length} 條`}
            <Link href="/inventory" className="ml-3 text-blue-600 hover:underline dark:text-blue-400">← 庫存總覽</Link>
          </p>
        </div>
        <SpinButton
          onClick={() => { setEditRule(null); setEditOpen(true); }}
          className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
        >
          + 新增規則
        </SpinButton>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        <input
          value={searchInput}
          onChange={(e) => setSearchInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") setSearch(searchInput); }}
          onBlur={() => setSearch(searchInput)}
          placeholder="搜尋 商品 / SKU / 規格…"
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
        {branchLocked ? (
          <div className="flex items-center rounded-md border border-zinc-300 bg-zinc-50 px-3 py-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
            🏬 {locLabel(branchLocationId)}<span className="ml-2 text-xs text-zinc-500">(僅本店)</span>
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
                {storeByLoc.get(l.id) ?? l.name}{l.type === "central_warehouse" ? "（總倉）" : ""}
              </option>
            ))}
          </select>
        )}
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
          <Th align="right">安全庫存</Th>
          <Th align="right">補貨點</Th>
          <Th align="right">最高量</Th>
          <Th align="right">前置天數</Th>
          <Th align="right">操作</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={7} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={7}>尚無補貨規則。點「+ 新增規則」建立。</EmptyRow>
          ) : (
            rows.map((r) => {
              const s = skuMap.get(r.sku_id);
              return (
                <Tr key={`${r.location_id}-${r.sku_id}`}>
                  <Td>
                    <div className="font-medium text-zinc-900 dark:text-zinc-100">
                      {s?.product_name ?? "—"}
                      {s?.variant_name ? <span className="ml-1 text-zinc-500">/ {s.variant_name}</span> : null}
                    </div>
                    <div className="font-mono text-xs text-zinc-500">{s?.sku_code ?? `sku#${r.sku_id}`}</div>
                  </Td>
                  <Td className="text-xs">{locLabel(r.location_id)}</Td>
                  <Td align="right" className="font-mono">{r.safety_stock}</Td>
                  <Td align="right" className="font-mono font-medium">{r.reorder_point}</Td>
                  <Td align="right" className="font-mono text-zinc-500">{r.max_stock ?? "—"}</Td>
                  <Td align="right" className="font-mono text-zinc-500">{r.lead_time_days ?? "—"}</Td>
                  <Td align="right">
                    <div className="flex justify-end gap-1">
                      <SpinButton
                        onClick={() => { setEditRule(r); setEditOpen(true); }}
                        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                      >
                        編輯
                      </SpinButton>
                      <SpinButton
                        onClick={async () => {
                          if (!confirm(`刪除「${skuLabel(r.sku_id)} @ ${locLabel(r.location_id)}」的補貨規則？`)) return;
                          const { error: e } = await getSupabase().rpc("rpc_delete_reorder_rule", {
                            p_location_id: r.location_id,
                            p_sku_id: r.sku_id,
                          });
                          if (e) { alert(translateRpcError(e)); return; }
                          setReloadTick((n) => n + 1);
                        }}
                        className="rounded-md bg-red-600 px-2 py-1 text-xs font-medium text-white hover:bg-red-700"
                      >
                        刪除
                      </SpinButton>
                    </div>
                  </Td>
                </Tr>
              );
            })
          )}
        </TBody>
      </Table>

      <RuleEditModal
        open={editOpen}
        rule={editRule}
        locs={locs}
        stores={stores}
        storeByLoc={storeByLoc}
        defaultLocationId={locationId ? Number(locationId) : null}
        onClose={() => setEditOpen(false)}
        onSaved={() => { setEditOpen(false); setReloadTick((n) => n + 1); }}
      />
    </div>
  );
}

function RuleEditModal({
  open, rule, locs, stores, storeByLoc, defaultLocationId, onClose, onSaved,
}: {
  open: boolean;
  rule: Rule | null;
  locs: Loc[];
  stores: StoreRow[];
  storeByLoc: Map<number, string>;
  defaultLocationId: number | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const isEdit = rule != null;
  const [locationId, setLocationId] = useState<number | null>(null);
  const [skuId, setSkuId] = useState<number | null>(null);
  const [skuQuery, setSkuQuery] = useState("");
  const [skuResults, setSkuResults] = useState<Sku[]>([]);
  const [skuOpen, setSkuOpen] = useState(false);
  const [pickedSkuLabel, setPickedSkuLabel] = useState("");
  const [ss, setSs] = useState("0");
  const [rp, setRp] = useState("0");
  const [ms, setMs] = useState("");
  const [lt, setLt] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const boxRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    if (rule) {
      setLocationId(rule.location_id);
      setSkuId(rule.sku_id);
      setSs(String(rule.safety_stock));
      setRp(String(rule.reorder_point));
      setMs(rule.max_stock == null ? "" : String(rule.max_stock));
      setLt(rule.lead_time_days == null ? "" : String(rule.lead_time_days));
      (async () => {
        const { data } = await getSupabase().from("skus").select("id, sku_code, product_name, variant_name").eq("id", rule.sku_id).maybeSingle();
        const s = data as Sku | null;
        setPickedSkuLabel(s ? `${s.sku_code} ${s.product_name ?? ""}${s.variant_name ? " / " + s.variant_name : ""}` : `sku#${rule.sku_id}`);
      })();
    } else {
      setLocationId(defaultLocationId);
      setSkuId(null);
      setPickedSkuLabel("");
      setSs("0"); setRp("0"); setMs(""); setLt("");
    }
    setSkuQuery(""); setSkuResults([]); setSkuOpen(false); setErr(null);
  }, [open, rule, defaultLocationId]);

  useEffect(() => {
    if (!skuOpen) return;
    function away(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setSkuOpen(false);
    }
    document.addEventListener("mousedown", away);
    return () => document.removeEventListener("mousedown", away);
  }, [skuOpen]);

  useEffect(() => {
    const q = skuQuery.replace(/[,()%*]/g, " ").trim();
    if (!skuOpen || q.length < 1) { setSkuResults([]); return; }
    let cancelled = false;
    const t = setTimeout(async () => {
      const { data } = await getSupabase()
        .from("skus")
        .select("id, sku_code, product_name, variant_name")
        .or(`sku_code.ilike.%${q}%,product_name.ilike.%${q}%,variant_name.ilike.%${q}%`)
        .limit(20);
      if (!cancelled) setSkuResults((data as Sku[]) ?? []);
    }, 250);
    return () => { cancelled = true; clearTimeout(t); };
  }, [skuQuery, skuOpen]);

  const ssN = Number(ss) || 0;
  const rpN = Number(rp) || 0;
  const msN = ms.trim() === "" ? null : Number(ms);
  const ltN = lt.trim() === "" ? null : Number(lt);
  const clientErr =
    locationId == null ? "請選倉別"
    : skuId == null ? "請選 SKU"
    : ssN < 0 || rpN < 0 || (msN != null && msN < 0) || (ltN != null && ltN < 0) ? "數值不可為負"
    : rpN < ssN ? "補貨點必須 ≥ 安全庫存"
    : msN != null && msN < rpN ? "最高量必須 ≥ 補貨點"
    : null;

  async function save() {
    if (clientErr) { setErr(clientErr); return; }
    setBusy(true); setErr(null);
    try {
      const { error: e } = await getSupabase().rpc("rpc_upsert_reorder_rule", {
        p_location_id: locationId,
        p_sku_id: skuId,
        p_safety_stock: ssN,
        p_reorder_point: rpN,
        p_max_stock: msN,
        p_lead_time_days: ltN,
      });
      if (e) throw e;
      onSaved();
    } catch (e) {
      setErr(translateRpcError(e));
    } finally {
      setBusy(false);
    }
  }

  const inputCls = "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <Modal open={open} onClose={onClose} title={isEdit ? "編輯補貨規則" : "新增補貨規則"} maxWidth="max-w-lg">
      <div className="flex flex-col gap-4">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{err}</div>
        )}
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">倉別 *</span>
          <select
            value={locationId ?? ""}
            onChange={(e) => setLocationId(Number(e.target.value) || null)}
            disabled={isEdit}
            className={inputCls}
          >
            <option value="">— 請選 —</option>
            {locs.map((l) => (
              <option key={l.id} value={l.id}>
                {storeByLoc.get(l.id) ?? l.name}{l.type === "central_warehouse" ? "（總倉）" : ""}
              </option>
            ))}
          </select>
        </label>

        <div className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">SKU *</span>
          {isEdit ? (
            <div className={`${inputCls} bg-zinc-50 dark:bg-zinc-900`}>{pickedSkuLabel}</div>
          ) : (
            <div className="relative" ref={boxRef}>
              <input
                type="text"
                value={skuOpen ? skuQuery : pickedSkuLabel}
                onFocus={() => { setSkuOpen(true); setSkuQuery(""); }}
                onChange={(e) => { setSkuOpen(true); setSkuQuery(e.target.value); }}
                placeholder="搜尋 SKU / 商品名稱…"
                className={`${inputCls} w-full`}
              />
              {skuOpen && skuResults.length > 0 && (
                <ul className="absolute z-10 mt-1 max-h-60 w-full overflow-y-auto rounded-md border border-zinc-300 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
                  {skuResults.map((s) => (
                    <li
                      key={s.id}
                      onMouseDown={(e) => {
                        e.preventDefault();
                        setSkuId(s.id);
                        setPickedSkuLabel(`${s.sku_code} ${s.product_name ?? ""}${s.variant_name ? " / " + s.variant_name : ""}`);
                        setSkuOpen(false);
                        setSkuQuery("");
                      }}
                      className="cursor-pointer px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800"
                    >
                      <span className="font-mono text-zinc-500">{s.sku_code}</span>{" "}
                      {s.product_name}{s.variant_name ? ` / ${s.variant_name}` : ""}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </div>

        <div className="grid grid-cols-2 gap-3">
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">安全庫存 *</span>
            <input type="number" min="0" step="1" value={ss} onChange={(e) => setSs(e.target.value)} className={`text-right ${inputCls}`} />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">補貨點 *</span>
            <input type="number" min="0" step="1" value={rp} onChange={(e) => setRp(e.target.value)} className={`text-right ${inputCls}`} />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">最高量（選填）</span>
            <input type="number" min="0" step="1" value={ms} onChange={(e) => setMs(e.target.value)} className={`text-right ${inputCls}`} />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">前置天數（選填）</span>
            <input type="number" min="0" step="1" value={lt} onChange={(e) => setLt(e.target.value)} className={`text-right ${inputCls}`} />
          </label>
        </div>

        {clientErr && <p className="text-xs text-amber-600 dark:text-amber-400">{clientErr}</p>}

        <div className="flex gap-2">
          <SpinButton
            onClick={save}
            disabled={busy || clientErr != null}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
          >
            {busy ? "儲存中…" : isEdit ? "更新" : "建立"}
          </SpinButton>
          <SpinButton onClick={onClose} disabled={busy} className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700">
            取消
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
