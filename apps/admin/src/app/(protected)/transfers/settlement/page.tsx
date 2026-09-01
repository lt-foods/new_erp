"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
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

type Transfer = {
  id: number;
  transfer_no: string;
  status: string;
  shipped_at: string | null;
};

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
        <header className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold">月結對帳</h1>
            <p className="text-sm text-zinc-500">
              總部送來的月結對帳單：逐筆核對，有問題的行按「有問題」附備註送出爭議；
              全部無誤按「同意畫押」鎖定，匯款後回來按「我已匯款」。
            </p>
          </div>
          {/* 店家當天就想知道「今天進了多少錢」— 不用等月結送單 */}
          <Link
            href="/transfers/settlement/daily"
            className="rounded-md bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
          >
            查每日進貨金額
          </Link>
        </header>
        <StoreSettlementReview />
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">月結算</h1>
          {/* ⚠️ 2026-09-01 改寫：原本寫「依 hq_to_store **已收貨** transfers 計算貨款」，
              那句從 2026-09-01 起是假的 —— 口徑已改成「總倉派車當下、MAX(派出量,實收量)」
              (20260901000000_settlement_dispatch_basis.sql:148-149 金額、:358-391 明細)。
              ⛔ 這是給總倉看「錢怎麼算出來的」的唯一一句說明，寫錯就是對帳吵架的起點。 */}
          <p className="text-sm text-zinc-500">
            總倉對各分店：賣斷制。<span className="font-medium">2026-09-01 起，貨款算在總倉派車出貨的那一天</span>，
            數量取「派出量」與「實際收到量」之中較大的那個（店家超收照實收算、少收先照派出算，
            總倉在異常同意退回後會自動扣掉）。含空中轉調整。
            應付金額以分店價口徑計；成本口徑另計、供總倉毛利參考。
            流程：產生 → 送店家核對 → （爭議處理）→ 雙方同意鎖定 → 店家匯款 → 收款結案。
          </p>
        </div>
        {/* 店家臨時問「今天進了多少」時，總部也能直接查任一店的每日金額 */}
        <Link
          href="/transfers/settlement/daily"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          查分店每日進貨金額
        </Link>
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
                    <Link
                      href={`/transfers/settlement/detail?id=${r.id}`}
                      className="inline-block rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      明細
                    </Link>
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

    </>
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
