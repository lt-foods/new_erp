"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";

type SettlementStatus = "draft" | "confirmed" | "settled" | "disputed";
type SettlementStatusExt = SettlementStatus | "cancelled";

type StoreToStoreSettlement = {
  id: number;
  settlement_month: string;
  store_a_id: number;
  store_b_id: number;
  a_to_b_amount: number;
  b_to_a_amount: number;
  net_amount: number;
  transfer_count: number;
  status: SettlementStatus;
  settled_at: string | null;
  generated_vendor_bill_id: number | null;
  notes: string | null;
  updated_at: string;
};

type HqToStoreSettlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  transfer_count: number;
  item_count: number;
  status: SettlementStatusExt;
  confirmed_at: string | null;
  settled_at: string | null;
  generated_receivable_id: number | null;
  notes: string | null;
  updated_at: string;
};

type Store = { id: number; code: string; name: string };

type StoreToStoreItem = {
  id: number;
  transfer_id: number;
  direction: "a_to_b" | "b_to_a";
  amount: number;
  transfer_date: string;
};

type HqToStoreItem = {
  id: number;
  transfer_id: number;
  transfer_item_id: number;
  sku_id: number;
  qty_received: number;
  unit_cost: number;
  line_amount: number;
  received_at: string;
  entry_type: "hq_inbound" | "air_in" | "air_out";
};

const ENTRY_TYPE_LABEL: Record<HqToStoreItem["entry_type"], string> = {
  hq_inbound: "HQ 進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
};
const ENTRY_TYPE_COLOR: Record<HqToStoreItem["entry_type"], string> = {
  hq_inbound: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  air_in: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  air_out: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
};

type Transfer = {
  id: number;
  transfer_no: string;
  status: string;
  shipped_at: string | null;
};

type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };

const STATUS_LABEL: Record<SettlementStatusExt, string> = {
  draft: "草稿",
  confirmed: "已確認",
  settled: "已結清",
  disputed: "爭議中",
  cancelled: "已取消",
};
const STATUS_COLOR: Record<SettlementStatusExt, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  settled: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  cancelled: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
};

function defaultMonth() {
  const d = new Date();
  d.setMonth(d.getMonth() - 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

function monthToDate(m: string): string {
  return `${m}-01`;
}

// 註：「店間互調」tab (StoreToStoreTab) 隱藏中 — 目前所有調撥都走 HQ 中轉、
// 直接店間互調 transfer 一直為 0。component 保留以備未來啟用、schema/RPC 不動。
export default function SettlementPage() {
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">月結算</h1>
        <p className="text-sm text-zinc-500">
          總倉對各分店：賣斷制、依 hq_to_store 已收貨 transfers 計算貨款（含空中轉調整）。
        </p>
      </header>

      <HqToStoreTab />
    </div>
  );
}

// ============================================================
// 總倉 → 各店 Tab
// ============================================================
function HqToStoreTab() {
  const [rows, setRows] = useState<HqToStoreSettlement[] | null>(null);
  const [stores, setStores] = useState<Map<number, Store>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  const [genMonth, setGenMonth] = useState(defaultMonth());
  const [generating, setGenerating] = useState(false);
  const [genResult, setGenResult] = useState<string | null>(null);

  const [monthFilter, setMonthFilter] = useState<string>("");
  const [statusFilter, setStatusFilter] = useState<string>("");

  const [detail, setDetail] = useState<HqToStoreSettlement | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("store_monthly_settlements")
          .select(
            "id, settlement_month, store_id, payable_amount, transfer_count, item_count, status, confirmed_at, settled_at, generated_receivable_id, notes, updated_at",
          )
          .order("settlement_month", { ascending: false })
          .order("store_id", { ascending: true })
          .limit(200);
        if (monthFilter) q = q.eq("settlement_month", monthToDate(monthFilter));
        if (statusFilter) q = q.eq("status", statusFilter);

        const [{ data, error: e1 }, { data: storeData }] = await Promise.all([
          q,
          sb.from("stores").select("id, code, name").order("name"),
        ]);
        if (cancelled) return;
        if (e1) { setError(e1.message); setRows([]); return; }
        setError(null);
        setRows((data ?? []) as HqToStoreSettlement[]);
        const sm = new Map<number, Store>();
        for (const s of (storeData ?? []) as Store[]) sm.set(s.id, s);
        setStores(sm);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [monthFilter, statusFilter, reloadTick]);

  async function onGenerate() {
    if (!genMonth) return;
    setGenerating(true);
    setGenResult(null);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const { data, error: e } = await sb.rpc("rpc_generate_hq_to_store_settlement", {
        p_month: monthToDate(genMonth),
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      const r = data as { stores_count?: number; total_amount?: number };
      setGenResult(`已產生 ${r?.stores_count ?? 0} 家分店 ${genMonth} 月結算（總額 $${r?.total_amount?.toLocaleString?.() ?? 0}）。`);
      setReloadTick((t) => t + 1);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setGenerating(false);
    }
  }

  const totalPayable = rows?.reduce((sum, r) => sum + Number(r.payable_amount), 0) ?? 0;

  return (
    <>
      <div className="rounded-md border border-zinc-200 bg-zinc-50 p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="flex flex-wrap items-end gap-3">
          <label className="text-sm">
            <span className="mb-1 block text-xs text-zinc-500">產生月份</span>
            <input
              type="month"
              value={genMonth}
              onChange={(e) => setGenMonth(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <button
            onClick={onGenerate}
            disabled={!genMonth || generating}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {generating ? "產生中…" : "產生 / 重算 draft"}
          </button>
          <p className="text-xs text-zinc-500">
            ⚠️ 該月已 confirmed/settled 的不會重算；draft 會重建。
          </p>
        </div>
        {genResult && <p className="mt-3 text-sm text-emerald-700 dark:text-emerald-400">{genResult}</p>}
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">月份篩選</span>
          <input
            type="month"
            value={monthFilter}
            onChange={(e) => setMonthFilter(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">狀態</span>
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部狀態</option>
            {Object.entries(STATUS_LABEL).map(([v, l]) => (
              <option key={v} value={v}>{l}</option>
            ))}
          </select>
        </label>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">錯誤</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>月份</Th>
              <Th>分店</Th>
              <Th className="text-right">應付總倉</Th>
              <Th className="text-right">調撥單數</Th>
              <Th className="text-right">商品行數</Th>
              <Th>狀態</Th>
              <Th className="text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={7} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={7} className="p-6 text-center text-zinc-500">{loading ? "載入中…" : "尚無結算紀錄。先用上方「產生 / 重算 draft」。"}</td></tr>
            ) : rows.map((r) => {
              const s = stores.get(r.store_id);
              const month = r.settlement_month?.slice(0, 7);
              return (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono text-xs">{month}</Td>
                  <Td className="text-xs">
                    <span className="font-mono text-zinc-500">{s?.code}</span>{" "}
                    <span className="text-zinc-700 dark:text-zinc-200">{s?.name ?? `#${r.store_id}`}</span>
                  </Td>
                  <Td className="text-right font-mono text-rose-600">${Number(r.payable_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}</Td>
                  <Td className="text-right font-mono">{r.transfer_count}</Td>
                  <Td className="text-right font-mono">{r.item_count}</Td>
                  <Td><span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span></Td>
                  <Td className="text-right">
                    <button
                      onClick={() => setDetail(r)}
                      className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      明細
                    </button>
                  </Td>
                </tr>
              );
            })}
          </tbody>
          {rows && rows.length > 0 && (
            <tfoot className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <td colSpan={2} className="px-3 py-2 text-right text-xs text-zinc-500">合計</td>
                <td className="px-3 py-2 text-right font-mono font-medium text-rose-600">
                  ${totalPayable.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                </td>
                <td colSpan={4}></td>
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      <Modal
        open={detail !== null}
        onClose={() => setDetail(null)}
        title={detail ? `分店月結算 #${detail.id}（${detail.settlement_month?.slice(0, 7)}）` : ""}
        maxWidth="max-w-3xl"
      >
        {detail && (
          <HqToStoreDetail
            settlement={detail}
            store={stores.get(detail.store_id) ?? null}
            onConfirmed={() => {
              setDetail(null);
              setReloadTick((t) => t + 1);
            }}
          />
        )}
      </Modal>
    </>
  );
}

function HqToStoreDetail({
  settlement,
  store,
  onConfirmed,
}: {
  settlement: HqToStoreSettlement;
  store: Store | null;
  onConfirmed: () => void;
}) {
  const [items, setItems] = useState<HqToStoreItem[] | null>(null);
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [confirming, setConfirming] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error } = await sb
        .from("store_monthly_settlement_items")
        .select("id, transfer_id, transfer_item_id, sku_id, qty_received, unit_cost, line_amount, received_at, entry_type")
        .eq("settlement_id", settlement.id)
        .order("entry_type", { ascending: true })
        .order("received_at", { ascending: true });
      if (cancelled) return;
      if (error) { setErr(error.message); setItems([]); return; }
      const list = (data ?? []) as HqToStoreItem[];
      setItems(list);

      const txIds = Array.from(new Set(list.map((it) => it.transfer_id)));
      const skuIds = Array.from(new Set(list.map((it) => it.sku_id)));
      const [{ data: tx }, { data: sk }] = await Promise.all([
        txIds.length ? sb.from("transfers").select("id, transfer_no, status, shipped_at").in("id", txIds) : Promise.resolve({ data: [] as Transfer[] }),
        skuIds.length ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds) : Promise.resolve({ data: [] as Sku[] }),
      ]);
      if (cancelled) return;
      const tm = new Map<number, Transfer>();
      for (const t of (tx ?? []) as Transfer[]) tm.set(t.id, t);
      setTransfers(tm);
      const skMap = new Map<number, Sku>();
      for (const s of (sk ?? []) as Sku[]) skMap.set(s.id, s);
      setSkus(skMap);
    })();
    return () => { cancelled = true; };
  }, [settlement.id]);

  async function onConfirm() {
    if (!confirm("確認此月結算？確認後將自動產生應付帳款單入帳。")) return;
    setConfirming(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error } = await sb.rpc("rpc_confirm_store_monthly_settlement", {
        p_settlement_id: settlement.id,
        p_operator: operator,
      });
      if (error) throw new Error(error.message);
      onConfirmed();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setConfirming(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-3 gap-3 text-sm">
        <Stat label="分店" value={store?.name ?? `#${settlement.store_id}`} />
        <Stat label="月份" value={settlement.settlement_month?.slice(0, 7)} />
        <Stat label="狀態" value={STATUS_LABEL[settlement.status]} />
        <Stat label="應付金額" value={`$${Number(settlement.payable_amount).toLocaleString("zh-TW")}`} accent="negative" />
        <Stat label="調撥單數" value={String(settlement.transfer_count)} />
        <Stat label="商品行數" value={String(settlement.item_count)} />
      </div>

      <div className="flex items-center justify-between gap-2">
        <div className="text-xs text-zinc-500">
          {settlement.generated_receivable_id && (
            <span>已產生 HQ 應收單 #{settlement.generated_receivable_id}</span>
          )}
        </div>
        <a
          href={withBasePath(`/finance/receivables/print?settlement_id=${settlement.id}`)}
          target="_blank"
          rel="noopener noreferrer"
          className="rounded-md border border-blue-300 bg-blue-50 px-3 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
        >
          📄 列印對帳單
        </a>
      </div>

      <div>
        <div className="mb-2 text-sm font-medium">出貨明細（{items?.length ?? 0} 筆）</div>
        <p className="mb-2 text-xs text-zinc-500">
          📦 HQ 進貨：總倉送來；✈️ 空中轉入：別店空中轉來（加應付）；✈️ 空中轉出：空中轉去別店（減應付，金額負）
        </p>
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <Th>類型</Th>
                <Th>收貨日</Th>
                <Th>調撥單</Th>
                <Th>商品</Th>
                <Th className="text-right">數量</Th>
                <Th className="text-right">單價</Th>
                <Th className="text-right">小計</Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items === null ? (
                <tr><td colSpan={7} className="p-3 text-center text-zinc-500">載入中…</td></tr>
              ) : items.length === 0 ? (
                <tr><td colSpan={7} className="p-3 text-center text-zinc-500">無明細。</td></tr>
              ) : items.map((it) => {
                const tx = transfers.get(it.transfer_id);
                const sku = skus.get(it.sku_id);
                const isNeg = Number(it.line_amount) < 0;
                return (
                  <tr key={it.id}>
                    <Td>
                      <span className={`inline-block rounded px-2 py-0.5 text-xs ${ENTRY_TYPE_COLOR[it.entry_type] ?? ENTRY_TYPE_COLOR.hq_inbound}`}>
                        {ENTRY_TYPE_LABEL[it.entry_type] ?? it.entry_type}
                      </span>
                    </Td>
                    <Td className="text-xs">{new Date(it.received_at).toLocaleDateString("zh-TW")}</Td>
                    <Td className="font-mono text-xs">{tx?.transfer_no ?? `#${it.transfer_id}`}</Td>
                    <Td className="text-xs">
                      <span className="font-mono text-zinc-500">{sku?.sku_code ?? "—"}</span>{" "}
                      <span>{sku?.product_name ?? "—"}</span>
                      {sku?.variant_name && <span className="ml-1 text-zinc-400">/ {sku.variant_name}</span>}
                    </Td>
                    <Td className="text-right font-mono">{Number(it.qty_received).toLocaleString()}</Td>
                    <Td className="text-right font-mono text-zinc-500">${Number(it.unit_cost).toFixed(2)}</Td>
                    <Td className={`text-right font-mono ${isNeg ? "text-amber-600" : ""}`}>
                      ${Number(it.line_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
            {items && items.length > 0 && (
              <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <td colSpan={6} className="px-3 py-2 text-right text-xs text-zinc-500">合計</td>
                  <td className="px-3 py-2 text-right font-mono font-medium text-rose-600">
                    ${items.reduce((sum, it) => sum + Number(it.line_amount), 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                  </td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>
      </div>

      {err && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{err}</p>
        </div>
      )}

      {settlement.status === "draft" && (
        <div className="flex justify-end">
          <button
            onClick={onConfirm}
            disabled={confirming}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {confirming ? "確認中…" : "確認此結算（產生應付帳款單）"}
          </button>
        </div>
      )}
    </div>
  );
}

// ============================================================
// 店間互調 Tab（既有功能）
// ============================================================
function StoreToStoreTab() {
  const [rows, setRows] = useState<StoreToStoreSettlement[] | null>(null);
  const [stores, setStores] = useState<Map<number, Store>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  const [genMonth, setGenMonth] = useState(defaultMonth());
  const [generating, setGenerating] = useState(false);
  const [genResult, setGenResult] = useState<string | null>(null);

  const [monthFilter, setMonthFilter] = useState<string>("");
  const [statusFilter, setStatusFilter] = useState<string>("");

  const [detail, setDetail] = useState<StoreToStoreSettlement | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("transfer_settlements")
          .select(
            "id, settlement_month, store_a_id, store_b_id, a_to_b_amount, b_to_a_amount, net_amount, transfer_count, status, settled_at, generated_vendor_bill_id, notes, updated_at",
          )
          .order("settlement_month", { ascending: false })
          .order("id", { ascending: false })
          .limit(200);
        if (monthFilter) q = q.eq("settlement_month", monthToDate(monthFilter));
        if (statusFilter) q = q.eq("status", statusFilter);

        const [{ data, error: e1 }, { data: storeData }] = await Promise.all([
          q,
          sb.from("stores").select("id, code, name").order("name"),
        ]);
        if (cancelled) return;
        if (e1) { setError(e1.message); setRows([]); return; }
        setError(null);
        setRows((data ?? []) as StoreToStoreSettlement[]);
        const sm = new Map<number, Store>();
        for (const s of (storeData ?? []) as Store[]) sm.set(s.id, s);
        setStores(sm);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [monthFilter, statusFilter, reloadTick]);

  async function onGenerate() {
    if (!genMonth) return;
    setGenerating(true);
    setGenResult(null);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const tenantId = (sess.session?.user?.app_metadata as Record<string, unknown> | undefined)
        ?.tenant_id as string | undefined;
      const operator = sess.session?.user?.id;
      if (!tenantId || !operator) throw new Error("尚未登入或 JWT 缺 tenant_id");

      const { data, error: e } = await sb.rpc("rpc_generate_transfer_settlement", {
        p_tenant_id: tenantId,
        p_month: monthToDate(genMonth),
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      const count = typeof data === "number" ? data : 0;
      setGenResult(`已產生 ${count} 筆 ${genMonth} 月結算（draft）。`);
      setReloadTick((t) => t + 1);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setGenerating(false);
    }
  }

  return (
    <>
      <div className="rounded-md border border-zinc-200 bg-zinc-50 p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="flex flex-wrap items-end gap-3">
          <label className="text-sm">
            <span className="mb-1 block text-xs text-zinc-500">產生月份</span>
            <input
              type="month"
              value={genMonth}
              onChange={(e) => setGenMonth(e.target.value)}
              className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <button
            onClick={onGenerate}
            disabled={!genMonth || generating}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {generating ? "產生中…" : "產生 / 重算 draft"}
          </button>
          <p className="text-xs text-zinc-500">
            ⚠️ 該月已有 confirmed / settled 不會重算；draft 會砍掉重建。
          </p>
        </div>
        {genResult && <p className="mt-3 text-sm text-emerald-700 dark:text-emerald-400">{genResult}</p>}
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">月份篩選</span>
          <input
            type="month"
            value={monthFilter}
            onChange={(e) => setMonthFilter(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">狀態</span>
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部狀態</option>
            {(["draft","confirmed","settled","disputed"] as const).map((v) => (
              <option key={v} value={v}>{STATUS_LABEL[v]}</option>
            ))}
          </select>
        </label>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">錯誤</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>月份</Th>
              <Th>店 A → 店 B</Th>
              <Th className="text-right">A→B 金額</Th>
              <Th className="text-right">B→A 金額</Th>
              <Th className="text-right">淨額</Th>
              <Th className="text-right">調撥數</Th>
              <Th>狀態</Th>
              <Th>欠誰</Th>
              <Th className="text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">{loading ? "載入中…" : "尚無結算紀錄。先用上方「產生 / 重算 draft」。"}</td></tr>
            ) : rows.map((r) => {
              const sa = stores.get(r.store_a_id);
              const sb = stores.get(r.store_b_id);
              const month = r.settlement_month?.slice(0, 7);
              return (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono text-xs">{month}</Td>
                  <Td className="text-xs">
                    <span>{sa?.name ?? `#${r.store_a_id}`}</span>
                    <span className="mx-1 text-zinc-400">↔</span>
                    <span>{sb?.name ?? `#${r.store_b_id}`}</span>
                  </Td>
                  <Td className="text-right font-mono">${Number(r.a_to_b_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}</Td>
                  <Td className="text-right font-mono">${Number(r.b_to_a_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}</Td>
                  <Td className={`text-right font-mono ${Number(r.net_amount) > 0 ? "text-rose-600" : Number(r.net_amount) < 0 ? "text-emerald-600" : "text-zinc-500"}`}>
                    ${Number(r.net_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                  </Td>
                  <Td className="text-right font-mono">{r.transfer_count}</Td>
                  <Td><span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span></Td>
                  <Td className="text-xs">
                    {Number(r.net_amount) > 0
                      ? <span><span className="text-rose-600">{sa?.name}</span> 欠 <span className="text-emerald-600">{sb?.name}</span></span>
                      : Number(r.net_amount) < 0
                      ? <span><span className="text-rose-600">{sb?.name}</span> 欠 <span className="text-emerald-600">{sa?.name}</span></span>
                      : <span className="text-zinc-400">兩平</span>}
                  </Td>
                  <Td className="text-right">
                    <button
                      onClick={() => setDetail(r)}
                      className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      明細
                    </button>
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <Modal
        open={detail !== null}
        onClose={() => setDetail(null)}
        title={detail ? `店間結算明細 #${detail.id}（${detail.settlement_month?.slice(0, 7)}）` : ""}
        maxWidth="max-w-3xl"
      >
        {detail && (
          <StoreToStoreDetail
            settlement={detail}
            storeA={stores.get(detail.store_a_id) ?? null}
            storeB={stores.get(detail.store_b_id) ?? null}
            onConfirmed={() => {
              setDetail(null);
              setReloadTick((t) => t + 1);
            }}
          />
        )}
      </Modal>
    </>
  );
}

function StoreToStoreDetail({
  settlement,
  storeA,
  storeB,
  onConfirmed,
}: {
  settlement: StoreToStoreSettlement;
  storeA: Store | null;
  storeB: Store | null;
  onConfirmed: () => void;
}) {
  const [items, setItems] = useState<StoreToStoreItem[] | null>(null);
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [confirming, setConfirming] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error } = await sb
        .from("transfer_settlement_items")
        .select("id, transfer_id, direction, amount, transfer_date")
        .eq("settlement_id", settlement.id)
        .order("transfer_date", { ascending: true });
      if (cancelled) return;
      if (error) { setErr(error.message); setItems([]); return; }
      const list = (data ?? []) as StoreToStoreItem[];
      setItems(list);
      const txIds = list.map((it) => it.transfer_id);
      if (txIds.length > 0) {
        const { data: tx } = await sb
          .from("transfers")
          .select("id, transfer_no, status, shipped_at")
          .in("id", txIds);
        const m = new Map<number, Transfer>();
        for (const t of (tx ?? []) as Transfer[]) m.set(t.id, t);
        if (!cancelled) setTransfers(m);
      }
    })();
    return () => { cancelled = true; };
  }, [settlement.id]);

  async function onConfirm() {
    if (!confirm("確認此結算？確認後淨額不為零會自動產生應付帳款單。")) return;
    setConfirming(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error } = await sb.rpc("rpc_confirm_transfer_settlement", {
        p_settlement_id: settlement.id,
        p_operator: operator,
      });
      if (error) throw new Error(error.message);
      onConfirmed();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setConfirming(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3 text-sm">
        <Stat label="店 A" value={storeA?.name ?? `#${settlement.store_a_id}`} />
        <Stat label="店 B" value={storeB?.name ?? `#${settlement.store_b_id}`} />
        <Stat label="A→B 金額" value={`$${Number(settlement.a_to_b_amount).toLocaleString("zh-TW")}`} />
        <Stat label="B→A 金額" value={`$${Number(settlement.b_to_a_amount).toLocaleString("zh-TW")}`} />
        <Stat label="淨額" value={`$${Number(settlement.net_amount).toLocaleString("zh-TW")}`}
          accent={Number(settlement.net_amount) > 0 ? "negative" : Number(settlement.net_amount) < 0 ? "positive" : "neutral"} />
        <Stat label="調撥數" value={String(settlement.transfer_count)} />
      </div>

      {settlement.generated_vendor_bill_id && (
        <p className="text-xs text-zinc-500">已產生應付帳款單 #{settlement.generated_vendor_bill_id}</p>
      )}

      <div>
        <div className="mb-2 text-sm font-medium">明細（{items?.length ?? 0} 筆）</div>
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <Th>日期</Th>
                <Th>調撥單</Th>
                <Th>方向</Th>
                <Th className="text-right">金額</Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items === null ? (
                <tr><td colSpan={4} className="p-3 text-center text-zinc-500">載入中…</td></tr>
              ) : items.length === 0 ? (
                <tr><td colSpan={4} className="p-3 text-center text-zinc-500">無明細。</td></tr>
              ) : items.map((it) => {
                const tx = transfers.get(it.transfer_id);
                const fromName = it.direction === "a_to_b" ? storeA?.name : storeB?.name;
                const toName = it.direction === "a_to_b" ? storeB?.name : storeA?.name;
                return (
                  <tr key={it.id}>
                    <Td className="text-xs">{it.transfer_date}</Td>
                    <Td className="font-mono text-xs">{tx?.transfer_no ?? `#${it.transfer_id}`}</Td>
                    <Td className="text-xs"><span>{fromName}</span><span className="mx-1 text-zinc-400">→</span><span>{toName}</span></Td>
                    <Td className="text-right font-mono">${Number(it.amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}</Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {err && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{err}</p>
        </div>
      )}

      {settlement.status === "draft" && (
        <div className="flex justify-end">
          <button
            onClick={onConfirm}
            disabled={confirming}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {confirming ? "確認中…" : "確認此結算"}
          </button>
        </div>
      )}
    </div>
  );
}

// ============================================================
// 共用 UI helpers
// ============================================================
function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={`whitespace-nowrap border-b-2 px-1 py-3 text-sm font-medium transition ${
        active
          ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-400"
          : "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700 dark:hover:text-zinc-300"
      }`}
    >
      {children}
    </button>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: "positive" | "negative" | "neutral" }) {
  const cls =
    accent === "positive" ? "text-emerald-600" :
    accent === "negative" ? "text-rose-600" :
    "text-zinc-700 dark:text-zinc-200";
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-1 text-base font-medium ${cls}`}>{value}</div>
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}
