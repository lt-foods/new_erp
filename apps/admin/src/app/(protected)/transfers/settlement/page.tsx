"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";
import SpinButton from "@/components/SpinButton";
import { useRole, isHqRole } from "@/lib/role";
import StoreSettlementReview from "@/components/StoreSettlementReview";

type SettlementStatus = "draft" | "confirmed" | "settled" | "disputed";
type SettlementStatusExt = SettlementStatus | "cancelled" | "sent" | "remitted";

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
  cost_amount: number;
  branch_amount: number;
  transfer_count: number;
  item_count: number;
  status: SettlementStatusExt;
  confirmed_at: string | null;
  settled_at: string | null;
  generated_receivable_id: number | null;
  notes: string | null;
  updated_at: string;
  sent_at: string | null;
  store_agreed_at: string | null;
  remitted_at: string | null;
  remit_note: string | null;
};

type SettlementDispute = {
  id: number;
  settlement_id: number;
  transfer_item_id: number;
  item_snapshot: {
    entry_type?: string;
    description?: string | null;
    sku_id?: number;
    qty_received?: number;
    branch_amount?: number;
    received_at?: string;
  };
  reason: string;
  status: "open" | "resolved";
  raised_at: string;
  resolved_at: string | null;
  resolution_note: string | null;
};

const SETTLEMENT_SELECT =
  "id, settlement_month, store_id, payable_amount, cost_amount, branch_amount, transfer_count, item_count, status, confirmed_at, settled_at, generated_receivable_id, notes, updated_at, sent_at, store_agreed_at, remitted_at, remit_note";

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
  unit_branch_price: number;
  branch_amount: number;
  received_at: string;
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
  description: string | null;
};

const ENTRY_TYPE_LABEL: Record<HqToStoreItem["entry_type"], string> = {
  hq_inbound: "HQ 進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};
const ENTRY_TYPE_COLOR: Record<HqToStoreItem["entry_type"], string> = {
  hq_inbound: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  air_in: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  air_out: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  free_in: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300",
  free_out: "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-300",
  return_out: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
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
  sent: "已送店家核對",
  disputed: "店家有爭議",
  confirmed: "已鎖定待匯款",
  remitted: "店家已匯款",
  settled: "已結案",
  cancelled: "已取消",
};
const STATUS_COLOR: Record<SettlementStatusExt, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  sent: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  remitted: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  settled: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
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
  const role = useRole();

  // 分店帳號：走店家對帳流程（線上核對/畫押/爭議/已匯款），不見成本口徑
  if (role !== null && !isHqRole(role)) {
    return (
      <div className="flex flex-1 flex-col gap-4 p-6">
        <header>
          <h1 className="text-xl font-semibold">月結對帳</h1>
          <p className="text-sm text-zinc-500">
            總部送來的月結對帳單：逐筆核對，有問題的行按「有問題」附備註送出爭議；
            全部無誤按「同意畫押」鎖定，匯款後回來按「我已匯款」。
          </p>
        </header>
        <StoreSettlementReview />
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">月結算</h1>
        <p className="text-sm text-zinc-500">
          總倉對各分店：賣斷制、依 hq_to_store 已收貨 transfers 計算貨款（含空中轉調整）。
          應付金額以分店價口徑計；成本口徑另計、供總倉毛利參考。
          流程：產生 → 送店家核對 → （爭議處理）→ 雙方同意鎖定 → 店家匯款 → 收款結案。
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
          .select(SETTLEMENT_SELECT)
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
      const r = data as { stores_count?: number; total_cost_amount?: number; total_branch_amount?: number };
      setGenResult(
        `已產生 ${r?.stores_count ?? 0} 家分店 ${genMonth} 月結算（應付合計（分店價口徑）$${r?.total_branch_amount?.toLocaleString?.() ?? 0}／成本口徑 $${r?.total_cost_amount?.toLocaleString?.() ?? 0}）。`,
      );
      setReloadTick((t) => t + 1);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setGenerating(false);
    }
  }

  const totalPayable = rows?.reduce((sum, r) => sum + Number(r.payable_amount), 0) ?? 0;
  const totalCost = rows?.reduce((sum, r) => sum + Number(r.cost_amount ?? 0), 0) ?? 0;

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
          <SpinButton
            onClick={onGenerate}
            disabled={!genMonth || generating}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {generating ? "產生中…" : "產生 / 重算 draft"}
          </SpinButton>
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
              <Th className="text-right">應付總倉（分店價）</Th>
              <Th className="text-right">成本口徑（參考）</Th>
              <Th className="text-right">調撥單數</Th>
              <Th className="text-right">商品行數</Th>
              <Th>狀態</Th>
              <Th className="text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={8} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">{loading ? "載入中…" : "尚無結算紀錄。先用上方「產生 / 重算 draft」。"}</td></tr>
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
                  <Td className="text-right font-mono text-zinc-500">${Number(r.cost_amount ?? 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}</Td>
                  <Td className="text-right font-mono">{r.transfer_count}</Td>
                  <Td className="text-right font-mono">{r.item_count}</Td>
                  <Td><span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span></Td>
                  <Td className="text-right">
                    <SpinButton
                      onClick={() => setDetail(r)}
                      className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      明細
                    </SpinButton>
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
                <td className="px-3 py-2 text-right font-mono font-medium text-zinc-500">
                  ${totalCost.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
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
            key={detail.id}
            settlement={detail}
            store={stores.get(detail.store_id) ?? null}
            onConfirmed={() => {
              setDetail(null);
              setReloadTick((t) => t + 1);
            }}
            onChanged={() => setReloadTick((t) => t + 1)}
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
  onChanged,
}: {
  settlement: HqToStoreSettlement;
  store: Store | null;
  onConfirmed: () => void;
  onChanged: () => void;
}) {
  const [items, setItems] = useState<HqToStoreItem[] | null>(null);
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [disputes, setDisputes] = useState<SettlementDispute[]>([]);
  const [confirming, setConfirming] = useState(false);
  const [acting, setActing] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  // 改估價/流程操作後表頭與明細都要重抓
  const [refreshTick, setRefreshTick] = useState(0);
  const [header, setHeader] = useState<HqToStoreSettlement>(settlement);

  // 自由轉貨行改估價
  const [editItem, setEditItem] = useState<HqToStoreItem | null>(null);
  const [editAmount, setEditAmount] = useState("");
  const [editReason, setEditReason] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      if (refreshTick > 0) {
        const { data: h } = await sb
          .from("store_monthly_settlements")
          .select(SETTLEMENT_SELECT)
          .eq("id", settlement.id)
          .maybeSingle();
        if (cancelled) return;
        if (h) setHeader(h as unknown as HqToStoreSettlement);
      }
      const [{ data, error }, { data: dData }] = await Promise.all([
        sb
          .from("store_monthly_settlement_items")
          .select("id, transfer_id, transfer_item_id, sku_id, qty_received, unit_cost, line_amount, unit_branch_price, branch_amount, received_at, entry_type, description")
          .eq("settlement_id", settlement.id)
          .order("entry_type", { ascending: true })
          .order("received_at", { ascending: true }),
        sb
          .from("store_settlement_disputes")
          .select("id, settlement_id, transfer_item_id, item_snapshot, reason, status, raised_at, resolved_at, resolution_note")
          .eq("settlement_id", settlement.id)
          .order("status", { ascending: false })
          .order("raised_at", { ascending: true }),
      ]);
      if (cancelled) return;
      setDisputes((dData ?? []) as SettlementDispute[]);
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
  }, [settlement.id, refreshTick]);

  async function onSaveEstimate() {
    if (!editItem) return;
    const amt = Number(editAmount);
    if (!Number.isFinite(amt) || amt < 0) { setErr("估價需為 >= 0 的數字"); return; }
    setSaving(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error } = await sb.rpc("rpc_update_free_transfer_amount", {
        p_transfer_item_id: editItem.transfer_item_id,
        p_new_amount: amt,
        p_operator: operator,
        p_reason: editReason.trim() || null,
      });
      if (error) throw new Error(error.message);
      setEditItem(null);
      setEditAmount("");
      setEditReason("");
      setRefreshTick((t) => t + 1);
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  async function onConfirm() {
    if (!confirm("直接確認此月結算（跳過店家線上核對）？確認後鎖定並自動產生應付帳款單。")) return;
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

  // 通用流程動作（送單 / 處理爭議 / 收款結案）
  async function runFlowAction(fn: (operator: string) => Promise<void>) {
    setActing(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      await fn(operator);
      setRefreshTick((t) => t + 1);
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setActing(false);
    }
  }

  function onSendToStore() {
    const isResend = header.status === "disputed";
    if (!confirm(isResend ? "爭議已處理完，重新送店家核對？" : "送出對帳單給店家線上核對？")) return;
    void runFlowAction(async (operator) => {
      const { error } = await getSupabase().rpc("rpc_send_settlement_to_store", {
        p_settlement_id: settlement.id,
        p_operator: operator,
      });
      if (error) throw new Error(error.message);
    });
  }

  function onResolveDispute(d: SettlementDispute) {
    const note = window.prompt("處理說明（選填，例：已修正估價為 $280）", "");
    if (note === null) return;
    void runFlowAction(async (operator) => {
      const { error } = await getSupabase().rpc("rpc_resolve_settlement_dispute", {
        p_dispute_id: d.id,
        p_operator: operator,
        p_note: note.trim() || null,
      });
      if (error) throw new Error(error.message);
    });
  }

  function onSettle() {
    if (!confirm("確認已收到店家匯款？結案後應收單將自動入帳，不可再改。")) return;
    void runFlowAction(async (operator) => {
      const { error } = await getSupabase().rpc("rpc_settle_store_monthly_settlement", {
        p_settlement_id: settlement.id,
        p_operator: operator,
        p_note: null,
      });
      if (error) throw new Error(error.message);
    });
  }

  const isDraft = header.status === "draft";
  // 鎖定（confirmed）前都可修估價；生成器會同步重建 draft/sent/disputed
  const canEditEst = ["draft", "sent", "disputed"].includes(header.status);
  const openDisputes = disputes.filter((d) => d.status === "open");

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-3 gap-3 text-sm">
        <Stat label="分店" value={store?.name ?? `#${header.store_id}`} />
        <Stat label="月份" value={header.settlement_month?.slice(0, 7)} />
        <Stat label="狀態" value={STATUS_LABEL[header.status]} />
        <Stat label="應付金額（分店價口徑）" value={`$${Number(header.payable_amount).toLocaleString("zh-TW")}`} accent="negative" />
        <Stat label="成本口徑金額（參考）" value={`$${Number(header.cost_amount ?? 0).toLocaleString("zh-TW")}`} />
        <Stat label="口徑差額（總部毛利）" value={`$${(Number(header.branch_amount ?? 0) - Number(header.cost_amount ?? 0)).toLocaleString("zh-TW")}`} accent="info" />
        <Stat label="調撥單數" value={String(header.transfer_count)} />
        <Stat label="商品行數" value={String(header.item_count)} />
      </div>

      {/* 流程狀態列 */}
      {header.status === "sent" && (
        <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
          📨 已送店家核對（{header.sent_at ? new Date(header.sent_at).toLocaleString("zh-TW") : "—"}），等待店家同意畫押或提出爭議。
        </div>
      )}
      {header.status === "confirmed" && (
        <div className="rounded-md border border-blue-300 bg-blue-50 p-3 text-sm text-blue-800 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-300">
          🔒 雙方已同意鎖定{header.store_agreed_at ? `（店家畫押：${new Date(header.store_agreed_at).toLocaleString("zh-TW")}）` : "（總部直接確認）"}，等待店家匯款。
        </div>
      )}
      {header.status === "remitted" && (
        <div className="rounded-md border border-indigo-300 bg-indigo-50 p-3 text-sm text-indigo-800 dark:border-indigo-800 dark:bg-indigo-950 dark:text-indigo-300">
          💸 店家已回報匯款（{header.remitted_at ? new Date(header.remitted_at).toLocaleString("zh-TW") : "—"}）
          {header.remit_note && <>，備註：<span className="font-medium">{header.remit_note}</span></>}
          。請核對入帳後按「確認收款結案」。
        </div>
      )}
      {header.status === "settled" && (
        <div className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          ✅ 已結案{header.settled_at ? `（${new Date(header.settled_at).toLocaleString("zh-TW")}）` : ""}。
        </div>
      )}

      {/* 爭議清單 */}
      {disputes.length > 0 && (
        <div className="rounded-md border border-red-200 dark:border-red-900">
          <div className="border-b border-red-200 bg-red-50 px-3 py-2 text-sm font-medium text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            店家爭議（未處理 {openDisputes.length}／共 {disputes.length} 筆）
            {header.status === "disputed" && openDisputes.length > 0 && (
              <span className="ml-2 font-normal">— 修正或說明後逐筆「標記已處理」，全部處理完才能重新送單</span>
            )}
          </div>
          <ul className="divide-y divide-red-100 dark:divide-red-950">
            {disputes.map((d) => (
              <li key={d.id} className="flex items-start gap-3 px-3 py-2 text-sm">
                <span className={`mt-0.5 inline-block rounded px-2 py-0.5 text-xs ${d.status === "open" ? "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300" : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"}`}>
                  {d.status === "open" ? "未處理" : "已處理"}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="text-xs text-zinc-500">
                    {ENTRY_TYPE_LABEL[(d.item_snapshot?.entry_type ?? "hq_inbound") as HqToStoreItem["entry_type"]] ?? d.item_snapshot?.entry_type}
                    {" · "}
                    {d.item_snapshot?.description ?? `SKU #${d.item_snapshot?.sku_id ?? "?"}`}
                    {" · "}${Number(d.item_snapshot?.branch_amount ?? 0).toLocaleString("zh-TW")}
                  </div>
                  <div className="break-words">🗣 {d.reason}</div>
                  {d.resolution_note && (
                    <div className="text-xs text-emerald-700 dark:text-emerald-400">↳ 總部：{d.resolution_note}</div>
                  )}
                </div>
                {d.status === "open" && (
                  <SpinButton
                    onClick={() => onResolveDispute(d)}
                    disabled={acting}
                    className="shrink-0 rounded-md border border-emerald-300 px-2 py-1 text-xs text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
                  >
                    標記已處理
                  </SpinButton>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex items-center justify-between gap-2">
        <div className="text-xs text-zinc-500">
          {header.generated_receivable_id && (
            <span>已產生 HQ 應收單 #{header.generated_receivable_id}</span>
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
          📦 HQ 進貨：總倉送來；✈️ 空中轉入：別店空中轉來（加應付）；✈️ 空中轉出：空中轉去別店（減應付，金額負）。
          應付以分店價口徑計、成本口徑供毛利參考；自由轉貨行以轉貨時申報的估價入帳、兩口徑同額，
          {canEditEst ? "金額回報錯誤可按行內「改估價」修正（兩邊分店未鎖定的結算會一起重算）。" : "已鎖定的結算不可再改估價。"}
        </p>

        {editItem && (
          <div className="mb-2 rounded-md border border-violet-300 bg-violet-50 p-3 text-sm dark:border-violet-800 dark:bg-violet-950">
            <div className="mb-2 text-xs text-violet-800 dark:text-violet-300">
              修改自由轉貨估價：<span className="font-medium">{editItem.description ?? `#${editItem.transfer_item_id}`}</span>
              （目前 ${Math.abs(Number(editItem.line_amount)).toLocaleString("zh-TW")}）
            </div>
            <div className="flex flex-wrap items-end gap-2">
              <label className="text-xs">
                <span className="mb-1 block text-zinc-500">新估價（總額）</span>
                <input
                  type="number"
                  min="0"
                  step="1"
                  value={editAmount}
                  onChange={(e) => setEditAmount(e.target.value)}
                  className="w-32 rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                />
              </label>
              <label className="flex-1 text-xs">
                <span className="mb-1 block text-zinc-500">修正原因（選填）</span>
                <input
                  value={editReason}
                  onChange={(e) => setEditReason(e.target.value)}
                  placeholder="例：店端回報金額與實際分店價不符"
                  className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                />
              </label>
              <SpinButton
                onClick={onSaveEstimate}
                disabled={saving}
                className="rounded-md bg-violet-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-violet-800 disabled:opacity-50"
              >
                {saving ? "儲存中…" : "儲存並重算"}
              </SpinButton>
              <SpinButton
                onClick={() => { setEditItem(null); setErr(null); }}
                disabled={saving}
                className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
              >
                取消
              </SpinButton>
            </div>
          </div>
        )}
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <Th>類型</Th>
                <Th>收貨日</Th>
                <Th>調撥單</Th>
                <Th>商品</Th>
                <Th className="text-right">數量</Th>
                <Th className="text-right">成本單價</Th>
                <Th className="text-right">成本小計</Th>
                <Th className="text-right">分店單價</Th>
                <Th className="text-right">分店小計</Th>
                {canEditEst && <Th className="text-right">操作</Th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items === null ? (
                <tr><td colSpan={canEditEst ? 10 : 9} className="p-3 text-center text-zinc-500">載入中…</td></tr>
              ) : items.length === 0 ? (
                <tr><td colSpan={canEditEst ? 10 : 9} className="p-3 text-center text-zinc-500">無明細。</td></tr>
              ) : items.map((it) => {
                const tx = transfers.get(it.transfer_id);
                const sku = skus.get(it.sku_id);
                const isNeg = Number(it.line_amount) < 0;
                const isFree = it.entry_type === "free_in" || it.entry_type === "free_out";
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
                      {it.description ? (
                        // 自由轉貨行：無真 SKU，顯示轉貨時填的描述
                        <span className="break-words">{it.description}</span>
                      ) : (
                        <>
                          <span className="font-mono text-zinc-500">{sku?.sku_code ?? "—"}</span>{" "}
                          <span>{sku?.product_name ?? "—"}</span>
                          {sku?.variant_name && <span className="ml-1 text-zinc-400">/ {sku.variant_name}</span>}
                        </>
                      )}
                    </Td>
                    <Td className="text-right font-mono">{Number(it.qty_received).toLocaleString()}</Td>
                    <Td className="text-right font-mono text-zinc-500">${Number(it.unit_cost).toFixed(2)}</Td>
                    <Td className={`text-right font-mono ${isNeg ? "text-amber-600" : ""}`}>
                      ${Number(it.line_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                    </Td>
                    <Td className="text-right font-mono text-zinc-500">${Number(it.unit_branch_price ?? 0).toFixed(2)}</Td>
                    <Td className={`text-right font-mono ${Number(it.branch_amount ?? 0) < 0 ? "text-amber-600" : "text-sky-700 dark:text-sky-400"}`}>
                      ${Number(it.branch_amount ?? 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                    </Td>
                    {canEditEst && (
                      <Td className="text-right">
                        {isFree && (
                          <SpinButton
                            onClick={() => {
                              setEditItem(it);
                              setEditAmount(String(Math.abs(Number(it.line_amount))));
                              setEditReason("");
                              setErr(null);
                            }}
                            className="rounded-md border border-violet-300 px-2 py-1 text-xs text-violet-700 hover:bg-violet-50 dark:border-violet-800 dark:text-violet-300 dark:hover:bg-violet-950"
                          >
                            改估價
                          </SpinButton>
                        )}
                      </Td>
                    )}
                  </tr>
                );
              })}
            </tbody>
            {items && items.length > 0 && (
              <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <td colSpan={6} className="px-3 py-2 text-right text-xs text-zinc-500">合計</td>
                  <td className="px-3 py-2 text-right font-mono font-medium text-zinc-500">
                    ${items.reduce((sum, it) => sum + Number(it.line_amount), 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                  </td>
                  <td></td>
                  <td className="px-3 py-2 text-right font-mono font-medium text-sky-700 dark:text-sky-400">
                    ${items.reduce((sum, it) => sum + Number(it.branch_amount ?? 0), 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                  </td>
                  {canEditEst && <td></td>}
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

      <div className="flex flex-wrap justify-end gap-2">
        {isDraft && (
          <>
            <SpinButton
              onClick={onSendToStore}
              disabled={acting}
              className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700 disabled:opacity-50"
            >
              {acting ? "送出中…" : "📨 送店家線上核對"}
            </SpinButton>
            <SpinButton
              onClick={onConfirm}
              disabled={confirming}
              className="rounded-md border border-zinc-300 px-4 py-2 text-sm transition hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              {confirming ? "確認中…" : "直接確認（跳過店家核對）"}
            </SpinButton>
          </>
        )}
        {header.status === "disputed" && (
          <SpinButton
            onClick={onSendToStore}
            disabled={acting || openDisputes.length > 0}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700 disabled:opacity-50"
          >
            {openDisputes.length > 0
              ? `還有 ${openDisputes.length} 筆爭議未處理`
              : acting ? "送出中…" : "📨 重新送店家核對"}
          </SpinButton>
        )}
        {header.status === "remitted" && (
          <SpinButton
            onClick={onSettle}
            disabled={acting}
            className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
          >
            {acting ? "處理中…" : "✅ 確認收款結案（應收單入帳）"}
          </SpinButton>
        )}
      </div>
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
          <SpinButton
            onClick={onGenerate}
            disabled={!genMonth || generating}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {generating ? "產生中…" : "產生 / 重算 draft"}
          </SpinButton>
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
                    <SpinButton
                      onClick={() => setDetail(r)}
                      className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      明細
                    </SpinButton>
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
          <SpinButton
            onClick={onConfirm}
            disabled={confirming}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white transition hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {confirming ? "確認中…" : "確認此結算"}
          </SpinButton>
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
    <SpinButton
      onClick={onClick}
      className={`whitespace-nowrap border-b-2 px-1 py-3 text-sm font-medium transition ${
        active
          ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-400"
          : "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700 dark:hover:text-zinc-300"
      }`}
    >
      {children}
    </SpinButton>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: "positive" | "negative" | "neutral" | "info" }) {
  const cls =
    accent === "positive" ? "text-emerald-600" :
    accent === "negative" ? "text-rose-600" :
    accent === "info" ? "text-sky-700 dark:text-sky-400" :
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
