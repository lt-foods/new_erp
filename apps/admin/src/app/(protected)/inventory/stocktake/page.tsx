"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import { translateRpcError } from "@/lib/rpcError";

type Loc = { id: number; code: string; name: string; type: string };
type StoreRow = { id: number; name: string; location_id: number | null };
type Sku = { id: number; sku_code: string; product_name: string | null; variant_name: string | null };
type ST = {
  id: number;
  stocktake_no: string;
  location_id: number;
  type: string;
  status: string;
  created_at: string | null;
};

const TYPE_LABEL: Record<string, string> = { full: "全盤", partial: "部分", cycle: "循環" };
const STATUS_LABEL: Record<string, string> = {
  draft: "草稿", counting: "盤點中", review: "覆核中", adjusted: "已調整", cancelled: "已取消",
};
const STATUS_CLS: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  counting: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  review: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  adjusted: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

export default function StocktakeListPage() {
  const router = useRouter();
  const [locs, setLocs] = useState<Loc[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [locationId, setLocationId] = useState<string>("");
  const [statusF, setStatusF] = useState<string>("");
  const [rows, setRows] = useState<ST[] | null>(null);
  const [counts, setCounts] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [createOpen, setCreateOpen] = useState(false);

  const storeLocOptions = useMemo(
    () => stores.filter((s) => s.location_id != null).map((s) => ({ id: s.location_id as number, name: s.name })),
    [stores],
  );
  const branchLocationId = useUserBranchStoreId(storeLocOptions);
  useEffect(() => {
    if (branchLocationId != null && locationId !== String(branchLocationId)) setLocationId(String(branchLocationId));
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
        let q = sb.from("stocktakes").select("id, stocktake_no, location_id, type, status, created_at")
          .order("id", { ascending: false }).limit(500);
        if (locationId) q = q.eq("location_id", Number(locationId));
        if (statusF) q = q.eq("status", statusF);
        const { data, error: e } = await q;
        if (e) throw e;
        if (cancelled) return;
        const list = (data as ST[]) ?? [];
        setRows(list);
        setError(null);
        const ids = list.map((r) => r.id);
        if (ids.length) {
          const { data: items } = await sb.from("stocktake_items").select("stocktake_id").in("stocktake_id", ids);
          const m = new Map<number, number>();
          for (const it of (items as { stocktake_id: number }[]) ?? []) m.set(it.stocktake_id, (m.get(it.stocktake_id) ?? 0) + 1);
          if (!cancelled) setCounts(m);
        } else setCounts(new Map());
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [locationId, statusF, reloadTick]);

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
  const branchLocked = branchLocationId != null;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-start justify-between">
        <div>
          <h1 className="text-xl font-semibold">盤點</h1>
          <p className="text-sm text-zinc-500">
            {rows === null ? "載入中…" : `共 ${rows.length} 張`}
            <Link href="/inventory" className="ml-3 text-blue-600 hover:underline dark:text-blue-400">← 庫存總覽</Link>
          </p>
        </div>
        <SpinButton
          onClick={() => setCreateOpen(true)}
          className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
        >
          + 新增盤點
        </SpinButton>
      </header>

      <div className="grid gap-3 sm:grid-cols-3">
        {branchLocked ? (
          <div className="flex items-center rounded-md border border-zinc-300 bg-zinc-50 px-3 py-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
            🏬 {locLabel(branchLocationId)}<span className="ml-2 text-xs text-zinc-500">(僅本店)</span>
          </div>
        ) : (
          <select value={locationId} onChange={(e) => setLocationId(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
            <option value="">全部倉別</option>
            {locs.map((l) => (
              <option key={l.id} value={l.id}>{storeByLoc.get(l.id) ?? l.name}{l.type === "central_warehouse" ? "（總倉）" : ""}</option>
            ))}
          </select>
        )}
        <select value={statusF} onChange={(e) => setStatusF(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p><p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <Table>
        <THead>
          <Th>盤點單號</Th><Th>倉別</Th><Th>類型</Th><Th>狀態</Th><Th align="right">品項數</Th><Th align="right">建立</Th><Th />
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={7} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={7}>尚無盤點單。點「+ 新增盤點」建立。</EmptyRow>
          ) : (
            rows.map((r) => (
              <Tr key={r.id} onClick={() => router.push(`/inventory/stocktake/session?id=${r.id}`)}>
                <Td className="font-mono text-xs">{r.stocktake_no}</Td>
                <Td className="text-xs">{locLabel(r.location_id)}</Td>
                <Td className="text-xs">{TYPE_LABEL[r.type] ?? r.type}</Td>
                <Td><span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_CLS[r.status] ?? ""}`}>{STATUS_LABEL[r.status] ?? r.status}</span></Td>
                <Td align="right" className="font-mono">{counts.get(r.id) ?? 0}</Td>
                <Td align="right" className="text-xs text-zinc-500">
                  {r.created_at ? new Date(r.created_at).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" }) : "—"}
                </Td>
                <Td align="right" className="text-xs text-zinc-400">›</Td>
              </Tr>
            ))
          )}
        </TBody>
      </Table>

      <CreateStocktakeModal
        open={createOpen}
        locs={locs}
        storeByLoc={storeByLoc}
        defaultLocationId={locationId ? Number(locationId) : null}
        onClose={() => setCreateOpen(false)}
        onCreated={(id) => { setCreateOpen(false); setReloadTick((n) => n + 1); router.push(`/inventory/stocktake/session?id=${id}`); }}
      />
    </div>
  );
}

function CreateStocktakeModal({
  open, locs, storeByLoc, defaultLocationId, onClose, onCreated,
}: {
  open: boolean;
  locs: Loc[];
  storeByLoc: Map<number, string>;
  defaultLocationId: number | null;
  onClose: () => void;
  onCreated: (id: number) => void;
}) {
  const [locationId, setLocationId] = useState<number | null>(null);
  const [type, setType] = useState<"full" | "partial">("full");
  const [picked, setPicked] = useState<Sku[]>([]);
  const [skuQuery, setSkuQuery] = useState("");
  const [skuResults, setSkuResults] = useState<Sku[]>([]);
  const [searching, setSearching] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (open) { setLocationId(defaultLocationId); setType("full"); setPicked([]); setSkuQuery(""); setSkuResults([]); setErr(null); }
  }, [open, defaultLocationId]);

  useEffect(() => {
    const q = skuQuery.replace(/[,()%*]/g, " ").trim();
    if (q.length < 1) { setSkuResults([]); setSearching(false); return; }
    let cancelled = false;
    setSearching(true);
    const t = setTimeout(async () => {
      try {
        const { data } = await getSupabase().from("skus")
          .select("id, sku_code, product_name, variant_name")
          .or(`sku_code.ilike.%${q}%,product_name.ilike.%${q}%,variant_name.ilike.%${q}%`).limit(15);
        if (!cancelled) setSkuResults((data as Sku[]) ?? []);
      } finally {
        if (!cancelled) setSearching(false);
      }
    }, 250);
    return () => { cancelled = true; clearTimeout(t); };
  }, [skuQuery]);

  const clientErr =
    locationId == null ? "請選倉別"
    : type === "partial" && picked.length === 0 ? "部分盤點需至少選 1 個 SKU"
    : null;

  async function create() {
    if (clientErr) { setErr(clientErr); return; }
    setBusy(true); setErr(null);
    try {
      const { data, error: e } = await getSupabase().rpc("rpc_create_stocktake", {
        p_location_id: locationId,
        p_type: type,
        p_sku_ids: type === "partial" ? picked.map((s) => s.id) : null,
      });
      if (e) throw e;
      onCreated(Number((data as { id?: number })?.id));
    } catch (e) { setErr(translateRpcError(e)); } finally { setBusy(false); }
  }

  const inputCls = "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <Modal open={open} onClose={onClose} title="新增盤點" maxWidth="max-w-lg">
      <div className="flex flex-col gap-4">
        {err && <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{err}</div>}
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">倉別 *</span>
          <select value={locationId ?? ""} onChange={(e) => setLocationId(Number(e.target.value) || null)} className={inputCls}>
            <option value="">— 請選 —</option>
            {locs.map((l) => (
              <option key={l.id} value={l.id}>{storeByLoc.get(l.id) ?? l.name}{l.type === "central_warehouse" ? "（總倉）" : ""}</option>
            ))}
          </select>
        </label>

        <div className="flex flex-col gap-1.5 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">類型 *</span>
          <div className="flex gap-4">
            <label className="flex cursor-pointer items-center gap-1.5">
              <input type="radio" name="sttype" checked={type === "full"} onChange={() => setType("full")} /> 全盤（該倉所有有庫存 SKU）
            </label>
            <label className="flex cursor-pointer items-center gap-1.5">
              <input type="radio" name="sttype" checked={type === "partial"} onChange={() => setType("partial")} /> 部分（指定 SKU）
            </label>
          </div>
        </div>

        {type === "partial" && (
          <div className="flex flex-col gap-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">SKU（可多選）*</span>
            {picked.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {picked.map((s) => (
                  <span key={s.id} className="inline-flex items-center gap-1 rounded bg-zinc-100 px-2 py-0.5 text-xs dark:bg-zinc-800">
                    {s.sku_code}
                    <button type="button" onClick={() => setPicked((p) => p.filter((x) => x.id !== s.id))} className="text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100">×</button>
                  </span>
                ))}
              </div>
            )}
            <div className="relative">
              <input value={skuQuery} onChange={(e) => setSkuQuery(e.target.value)} placeholder="搜尋 SKU / 商品名稱…" className={`${inputCls} w-full pr-8`} />
              <SearchSpinner active={searching} />
            </div>
            {skuResults.length > 0 && (
              <ul className="max-h-48 overflow-y-auto rounded-md border border-zinc-300 dark:border-zinc-700">
                {skuResults.filter((s) => !picked.some((p) => p.id === s.id)).map((s) => (
                  <li key={s.id}
                    onClick={() => { setPicked((p) => [...p, s]); setSkuQuery(""); setSkuResults([]); }}
                    className="cursor-pointer px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800">
                    <span className="font-mono text-zinc-500">{s.sku_code}</span> {s.product_name}{s.variant_name ? ` / ${s.variant_name}` : ""}
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {clientErr && <p className="text-xs text-amber-600 dark:text-amber-400">{clientErr}</p>}

        <div className="flex gap-2">
          <SpinButton onClick={create} disabled={busy || clientErr != null}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900">
            {busy ? "建立中…" : "建立並開始盤點"}
          </SpinButton>
          <SpinButton onClick={onClose} disabled={busy} className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700">取消</SpinButton>
        </div>
      </div>
    </Modal>
  );
}
