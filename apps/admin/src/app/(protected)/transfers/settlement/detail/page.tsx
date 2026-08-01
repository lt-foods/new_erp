"use client";

// 總倉端「分店月結算」單張明細頁（整頁、不用彈窗）。
// 流程動作（送店家核對／直接確認／處理爭議／收款結案）都用頁內確認列，
// 不跳瀏覽器對話框。draft/sent/disputed 的自由轉貨行可行內「改估價」。

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { withBasePath } from "@/lib/basePath";
import SpinButton from "@/components/SpinButton";

type SettlementStatus = "draft" | "sent" | "disputed" | "confirmed" | "remitted" | "settled" | "cancelled";

type Settlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  cost_amount: number;
  branch_amount: number;
  adjustment_amount: number;
  transfer_count: number;
  item_count: number;
  status: SettlementStatus;
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

type Item = {
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

type Dispute = {
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

type Adjustment = {
  id: number;
  amount: number;
  reason: string;
  status: "active" | "voided";
  created_at: string;
  voided_at: string | null;
  void_reason: string | null;
};

type Store = { id: number; code: string; name: string };
type Transfer = { id: number; transfer_no: string; status: string; shipped_at: string | null };
type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };

const SETTLEMENT_SELECT =
  "id, settlement_month, store_id, payable_amount, cost_amount, branch_amount, adjustment_amount, transfer_count, item_count, status, confirmed_at, settled_at, generated_receivable_id, notes, updated_at, sent_at, store_agreed_at, remitted_at, remit_note";

const ENTRY_TYPE_LABEL: Record<Item["entry_type"], string> = {
  hq_inbound: "HQ 進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};
const ENTRY_TYPE_COLOR: Record<Item["entry_type"], string> = {
  hq_inbound: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  air_in: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  air_out: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  free_in: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300",
  free_out: "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-300",
  return_out: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
};

const STATUS_LABEL: Record<SettlementStatus, string> = {
  draft: "草稿",
  sent: "已送店家核對",
  disputed: "店家有爭議",
  confirmed: "已鎖定待匯款",
  remitted: "店家已匯款",
  settled: "已結案",
  cancelled: "已取消",
};
const STATUS_COLOR: Record<SettlementStatus, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  sent: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  remitted: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  settled: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
};

export default function HqSettlementDetailPage() {
  const [settlementId, setSettlementId] = useState<number | null>(null);
  const [header, setHeader] = useState<Settlement | null>(null);
  const [store, setStore] = useState<Store | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [disputes, setDisputes] = useState<Dispute[]>([]);
  const [adjustments, setAdjustments] = useState<Adjustment[]>([]);
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  // 自由轉貨行改估價（行內面板）
  const [editItem, setEditItem] = useState<Item | null>(null);
  const [editAmount, setEditAmount] = useState("");
  const [editReason, setEditReason] = useState("");

  // 頁內確認列（取代 confirm()）與爭議處理行內輸入（取代 prompt()）
  const [pendingAction, setPendingAction] = useState<"send" | "confirm" | "settle" | null>(null);
  const [resolvingId, setResolvingId] = useState<number | null>(null);
  const [resolveNote, setResolveNote] = useState("");

  // 金額調整（增減金額＋原因）
  const [showAdjForm, setShowAdjForm] = useState(false);
  const [adjSign, setAdjSign] = useState<"add" | "minus">("add");
  const [adjAmount, setAdjAmount] = useState("");
  const [adjReason, setAdjReason] = useState("");
  const [voidingAdjId, setVoidingAdjId] = useState<number | null>(null);
  const [voidReason, setVoidReason] = useState("");

  useEffect(() => {
    if (typeof window === "undefined") return;
    const id = new URLSearchParams(window.location.search).get("id");
    if (!id) return;
    const t = setTimeout(() => setSettlementId(Number(id)), 0);
    return () => clearTimeout(t);
  }, []);

  useEffect(() => {
    if (!settlementId) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data: h, error: e0 }, { data, error: e1 }, { data: dData }] = await Promise.all([
        sb.from("store_monthly_settlements").select(SETTLEMENT_SELECT).eq("id", settlementId).maybeSingle(),
        sb
          .from("store_monthly_settlement_items")
          .select("id, transfer_id, transfer_item_id, sku_id, qty_received, unit_cost, line_amount, unit_branch_price, branch_amount, received_at, entry_type, description")
          .eq("settlement_id", settlementId)
          .order("entry_type", { ascending: true })
          .order("received_at", { ascending: true }),
        sb
          .from("store_settlement_disputes")
          .select("id, settlement_id, transfer_item_id, item_snapshot, reason, status, raised_at, resolved_at, resolution_note")
          .eq("settlement_id", settlementId)
          .order("status", { ascending: false })
          .order("raised_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (e0) { setErr(e0.message); return; }
      if (!h) { setErr("找不到此月結算"); return; }
      const hd = h as unknown as Settlement;
      setHeader(hd);
      setDisputes((dData ?? []) as Dispute[]);
      if (e1) { setErr(e1.message); setItems([]); return; }
      const list = (data ?? []) as Item[];
      setItems(list);

      const [{ data: storeData }, { data: tx }, { data: sk }, { data: adjData }] = await Promise.all([
        sb.from("stores").select("id, code, name").eq("id", hd.store_id).maybeSingle(),
        list.length
          ? sb.from("transfers").select("id, transfer_no, status, shipped_at").in("id", Array.from(new Set(list.map((it) => it.transfer_id))))
          : Promise.resolve({ data: [] as Transfer[] }),
        list.length
          ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", Array.from(new Set(list.map((it) => it.sku_id))))
          : Promise.resolve({ data: [] as Sku[] }),
        sb
          .from("store_settlement_adjustments")
          .select("id, amount, reason, status, created_at, voided_at, void_reason")
          .eq("store_id", hd.store_id)
          .eq("settlement_month", hd.settlement_month)
          .order("created_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (storeData) setStore(storeData as Store);
      setAdjustments((adjData ?? []) as Adjustment[]);
      const tm = new Map<number, Transfer>();
      for (const t of (tx ?? []) as Transfer[]) tm.set(t.id, t);
      setTransfers(tm);
      const skMap = new Map<number, Sku>();
      for (const s of (sk ?? []) as Sku[]) skMap.set(s.id, s);
      setSkus(skMap);
    })();
    return () => { cancelled = true; };
  }, [settlementId, reloadTick]);

  function refresh() {
    setReloadTick((t) => t + 1);
    window.dispatchEvent(new Event("settlement-badge-refresh"));
  }

  async function runRpc(fn: string, params: Record<string, unknown>) {
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error } = await sb.rpc(fn, { ...params, p_operator: operator });
      if (error) throw new Error(error.message);
      setPendingAction(null);
      setResolvingId(null);
      setResolveNote("");
      setShowAdjForm(false);
      setAdjAmount("");
      setAdjReason("");
      setVoidingAdjId(null);
      setVoidReason("");
      refresh();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function onSaveEstimate() {
    if (!editItem) return;
    const amt = Number(editAmount);
    if (!Number.isFinite(amt) || amt < 0) { setErr("估價需為 >= 0 的數字"); return; }
    setBusy(true);
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
      refresh();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  function onAddAdjustment() {
    if (!settlementId) return;
    const amt = Number(adjAmount);
    if (!Number.isFinite(amt) || amt <= 0) { setErr("調整金額需為 > 0 的數字"); return; }
    if (!adjReason.trim()) { setErr("調整金額必須填原因"); return; }
    void runRpc("rpc_add_settlement_adjustment", {
      p_settlement_id: settlementId,
      p_amount: adjSign === "minus" ? -amt : amt,
      p_reason: adjReason.trim(),
    });
  }

  function onConfirmPending() {
    if (!settlementId || !pendingAction) return;
    if (pendingAction === "send") {
      void runRpc("rpc_send_settlement_to_store", { p_settlement_id: settlementId });
    } else if (pendingAction === "confirm") {
      void runRpc("rpc_confirm_store_monthly_settlement", { p_settlement_id: settlementId });
    } else {
      void runRpc("rpc_settle_store_monthly_settlement", { p_settlement_id: settlementId, p_note: null });
    }
  }

  if (!settlementId) {
    return <div className="p-6 text-sm text-zinc-500">缺少 id 參數。</div>;
  }
  if (err && !header) {
    return (
      <div className="m-6 rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {err}
      </div>
    );
  }
  if (!header) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }

  const isDraft = header.status === "draft";
  const canEditEst = ["draft", "sent", "disputed"].includes(header.status);
  const openDisputes = disputes.filter((d) => d.status === "open");
  const monthLabel = header.settlement_month?.slice(0, 7);
  const showActionBar = isDraft || header.status === "disputed" || header.status === "remitted";

  return (
    <div className={`flex flex-1 flex-col gap-4 p-6 ${showActionBar ? "pb-28" : ""}`}>
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <Link href="/transfers/settlement" className="text-sm text-blue-600 hover:underline dark:text-blue-400">
            ← 回月結算
          </Link>
          <h1 className="mt-1 text-xl font-semibold">
            分店月結算 #{header.id}（{monthLabel}）
            {store && <span className="ml-2 text-base font-normal text-zinc-500">{store.name}</span>}
          </h1>
        </div>
        <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[header.status]}`}>
          {STATUS_LABEL[header.status]}
        </span>
      </header>

      <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
        <Stat label="應付金額（含調整）" value={`$${Number(header.payable_amount).toLocaleString("zh-TW")}`} accent="negative" />
        <Stat label="成本口徑金額（參考）" value={`$${Number(header.cost_amount ?? 0).toLocaleString("zh-TW")}`} />
        <Stat label="口徑差額（總部毛利）" value={`$${(Number(header.branch_amount ?? 0) - Number(header.cost_amount ?? 0)).toLocaleString("zh-TW")}`} accent="info" />
        {Number(header.adjustment_amount ?? 0) !== 0 && (
          <Stat
            label="人工調整合計"
            value={`${Number(header.adjustment_amount) > 0 ? "+" : "−"}$${Math.abs(Number(header.adjustment_amount)).toLocaleString("zh-TW")}`}
            accent="info"
          />
        )}
        <Stat label="調撥單數" value={String(header.transfer_count)} />
        <Stat label="商品行數" value={String(header.item_count)} />
        <Stat label="月份" value={monthLabel} />
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
              <li key={d.id} className="px-3 py-2 text-sm">
                <div className="flex items-start gap-3">
                  <span className={`mt-0.5 inline-block rounded px-2 py-0.5 text-xs ${d.status === "open" ? "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300" : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"}`}>
                    {d.status === "open" ? "未處理" : "已處理"}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="text-xs text-zinc-500">
                      {ENTRY_TYPE_LABEL[(d.item_snapshot?.entry_type ?? "hq_inbound") as Item["entry_type"]] ?? d.item_snapshot?.entry_type}
                      {" · "}
                      {d.item_snapshot?.description ?? `SKU #${d.item_snapshot?.sku_id ?? "?"}`}
                      {" · "}${Number(d.item_snapshot?.branch_amount ?? 0).toLocaleString("zh-TW")}
                    </div>
                    <div className="break-words">🗣 {d.reason}</div>
                    {d.resolution_note && (
                      <div className="text-xs text-emerald-700 dark:text-emerald-400">↳ 總部：{d.resolution_note}</div>
                    )}
                  </div>
                  {d.status === "open" && resolvingId !== d.id && (
                    <SpinButton
                      onClick={() => { setResolvingId(d.id); setResolveNote(""); setPendingAction(null); }}
                      disabled={busy}
                      className="shrink-0 rounded-md border border-emerald-300 px-2 py-1 text-xs text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
                    >
                      標記已處理
                    </SpinButton>
                  )}
                </div>
                {resolvingId === d.id && (
                  <div className="mt-2 flex flex-wrap items-end gap-2 rounded-md border border-emerald-300 bg-emerald-50 p-2 dark:border-emerald-800 dark:bg-emerald-950">
                    <label className="flex-1 text-xs">
                      <span className="mb-1 block text-zinc-500">處理說明（選填，會顯示給店家）</span>
                      <input
                        value={resolveNote}
                        onChange={(e) => setResolveNote(e.target.value)}
                        placeholder="例：已修正估價為 $280"
                        className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    </label>
                    <SpinButton
                      onClick={() => void runRpc("rpc_resolve_settlement_dispute", { p_dispute_id: d.id, p_note: resolveNote.trim() || null })}
                      disabled={busy}
                      className="rounded-md bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
                    >
                      {busy ? "處理中…" : "確定已處理"}
                    </SpinButton>
                    <SpinButton
                      onClick={() => setResolvingId(null)}
                      disabled={busy}
                      className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
                    >
                      取消
                    </SpinButton>
                  </div>
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
          href={withBasePath(`/finance/receivables/print?settlement_id=${header.id}`)}
          target="_blank"
          rel="noopener noreferrer"
          className="rounded-md border border-blue-300 bg-blue-50 px-3 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
        >
          📄 列印對帳單
        </a>
      </div>

      {/* 金額調整（增減金額＋原因） */}
      {(adjustments.length > 0 || canEditEst) && (
        <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900">
            <span className="text-sm font-medium">金額調整（加收 / 減收，需填原因）</span>
            {canEditEst && !showAdjForm && (
              <SpinButton
                onClick={() => { setShowAdjForm(true); setAdjSign("add"); setAdjAmount(""); setAdjReason(""); setVoidingAdjId(null); setErr(null); }}
                disabled={busy}
                className="rounded-md border border-blue-300 px-2 py-1 text-xs text-blue-700 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
              >
                ＋ 新增調整
              </SpinButton>
            )}
          </div>

          {showAdjForm && (
            <div className="border-b border-zinc-200 p-3 dark:border-zinc-800">
              <div className="flex flex-wrap items-end gap-2">
                <label className="text-xs">
                  <span className="mb-1 block text-zinc-500">方向</span>
                  <select
                    value={adjSign}
                    onChange={(e) => setAdjSign(e.target.value as "add" | "minus")}
                    className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                  >
                    <option value="add">增加金額（加收 +）</option>
                    <option value="minus">減少金額（減收 −）</option>
                  </select>
                </label>
                <label className="text-xs">
                  <span className="mb-1 block text-zinc-500">金額</span>
                  <input
                    type="number"
                    min="1"
                    step="1"
                    value={adjAmount}
                    onChange={(e) => setAdjAmount(e.target.value)}
                    className="w-32 rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                  />
                </label>
                <label className="min-w-48 flex-1 text-xs">
                  <span className="mb-1 block text-zinc-500">原因（必填）</span>
                  <input
                    value={adjReason}
                    onChange={(e) => setAdjReason(e.target.value)}
                    placeholder="例：11 月運費分攤／破損折讓"
                    className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                  />
                </label>
                <SpinButton
                  onClick={onAddAdjustment}
                  disabled={busy}
                  className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
                >
                  {busy ? "儲存中…" : "儲存調整"}
                </SpinButton>
                <SpinButton
                  onClick={() => { setShowAdjForm(false); setErr(null); }}
                  disabled={busy}
                  className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
                >
                  取消
                </SpinButton>
              </div>
            </div>
          )}

          {adjustments.length === 0 ? (
            <div className="p-3 text-sm text-zinc-500">
              尚無調整。明細以外的加減項（運費、折讓、補貼、尾差沖抵…）可在此直接增減應付金額。
            </div>
          ) : (
            <>
              <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {adjustments.map((a) => {
                  const voided = a.status === "voided";
                  const positive = Number(a.amount) > 0;
                  return (
                    <li key={a.id} className="flex flex-wrap items-start gap-3 px-3 py-2 text-sm">
                      <span
                        className={`mt-0.5 inline-block rounded px-2 py-0.5 text-xs ${
                          voided
                            ? "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"
                            : positive
                              ? "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300"
                              : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                        }`}
                      >
                        {voided ? "已作廢" : positive ? "加收" : "減收"}
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className={voided ? "text-zinc-400 line-through" : ""}>
                          <span className="font-mono font-medium">
                            {positive ? "+" : "−"}${Math.abs(Number(a.amount)).toLocaleString("zh-TW")}
                          </span>
                          <span className="ml-2 break-words">{a.reason}</span>
                        </div>
                        <div className="text-xs text-zinc-500">
                          {new Date(a.created_at).toLocaleString("zh-TW")}
                          {voided && a.voided_at && (
                            <span className="ml-2">
                              作廢於 {new Date(a.voided_at).toLocaleString("zh-TW")}
                              {a.void_reason && `（${a.void_reason}）`}
                            </span>
                          )}
                        </div>
                      </div>
                      {!voided && canEditEst && voidingAdjId !== a.id && (
                        <SpinButton
                          onClick={() => { setVoidingAdjId(a.id); setVoidReason(""); setShowAdjForm(false); setErr(null); }}
                          disabled={busy}
                          className="shrink-0 rounded-md border border-zinc-300 px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                        >
                          作廢
                        </SpinButton>
                      )}
                      {voidingAdjId === a.id && (
                        <div className="flex w-full flex-wrap items-end gap-2 rounded-md border border-amber-300 bg-amber-50 p-2 dark:border-amber-800 dark:bg-amber-950">
                          <label className="flex-1 text-xs">
                            <span className="mb-1 block text-zinc-500">作廢原因（選填）</span>
                            <input
                              value={voidReason}
                              onChange={(e) => setVoidReason(e.target.value)}
                              placeholder="例：金額打錯，另開一筆"
                              className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                            />
                          </label>
                          <SpinButton
                            onClick={() => void runRpc("rpc_void_settlement_adjustment", { p_adjustment_id: a.id, p_reason: voidReason.trim() || null })}
                            disabled={busy}
                            className="rounded-md bg-amber-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
                          >
                            {busy ? "作廢中…" : "確定作廢"}
                          </SpinButton>
                          <SpinButton
                            onClick={() => setVoidingAdjId(null)}
                            disabled={busy}
                            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
                          >
                            取消
                          </SpinButton>
                        </div>
                      )}
                    </li>
                  );
                })}
              </ul>
              <div className="border-t border-zinc-200 bg-zinc-50 px-3 py-2 text-right text-sm dark:border-zinc-800 dark:bg-zinc-900">
                貨款合計（分店價）<span className="font-mono">${Number(header.branch_amount ?? 0).toLocaleString("zh-TW")}</span>
                <span className="mx-1">＋</span>調整合計{" "}
                <span className="font-mono">
                  {Number(header.adjustment_amount ?? 0) < 0 ? "−" : "+"}${Math.abs(Number(header.adjustment_amount ?? 0)).toLocaleString("zh-TW")}
                </span>
                <span className="mx-1">＝</span>應付金額{" "}
                <span className="font-mono font-semibold text-rose-600">${Number(header.payable_amount).toLocaleString("zh-TW")}</span>
              </div>
            </>
          )}
        </div>
      )}

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
                disabled={busy}
                className="rounded-md bg-violet-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-violet-800 disabled:opacity-50"
              >
                {busy ? "儲存中…" : "儲存並重算"}
              </SpinButton>
              <SpinButton
                onClick={() => { setEditItem(null); setErr(null); }}
                disabled={busy}
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
                  <tr key={it.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                    <Td>
                      <span className={`inline-block whitespace-nowrap rounded px-2 py-0.5 text-xs ${ENTRY_TYPE_COLOR[it.entry_type] ?? ENTRY_TYPE_COLOR.hq_inbound}`}>
                        {ENTRY_TYPE_LABEL[it.entry_type] ?? it.entry_type}
                      </span>
                    </Td>
                    <Td className="whitespace-nowrap text-xs">{new Date(it.received_at).toLocaleDateString("zh-TW")}</Td>
                    <Td className="whitespace-nowrap font-mono text-xs">
                      <a
                        href={withBasePath(`/wms/transfers?open=${it.transfer_id}`)}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-blue-600 hover:underline dark:text-blue-400"
                      >
                        {tx?.transfer_no ?? `#${it.transfer_id}`}
                      </a>
                    </Td>
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
                    <Td className="whitespace-nowrap text-right font-mono text-zinc-500">
                      {isFree ? "—" : `$${Number(it.unit_cost).toFixed(2)}`}
                    </Td>
                    <Td className={`whitespace-nowrap text-right font-mono ${isNeg ? "text-amber-600" : ""}`}>
                      ${Number(it.line_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                    </Td>
                    <Td className="whitespace-nowrap text-right font-mono text-zinc-500">
                      {isFree ? "—" : `$${Number(it.unit_branch_price ?? 0).toFixed(2)}`}
                    </Td>
                    <Td className={`whitespace-nowrap text-right font-mono ${Number(it.branch_amount ?? 0) < 0 ? "text-amber-600" : "text-sky-700 dark:text-sky-400"}`}>
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
                            className="whitespace-nowrap rounded-md border border-violet-300 px-2 py-1 text-xs text-violet-700 hover:bg-violet-50 dark:border-violet-800 dark:text-violet-300 dark:hover:bg-violet-950"
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

      {/* 底部固定動作列（頁內確認，不跳對話框） */}
      {showActionBar && (
        <div className="fixed inset-x-0 bottom-0 z-10 border-t border-zinc-200 bg-white/95 p-3 backdrop-blur md:left-52 dark:border-zinc-800 dark:bg-zinc-950/95 print:hidden">
          <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-end gap-2">
            {pendingAction === null ? (
              <>
                {isDraft && (
                  <>
                    <SpinButton
                      onClick={() => setPendingAction("send")}
                      disabled={busy}
                      className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700 disabled:opacity-50"
                    >
                      📨 送店家線上核對
                    </SpinButton>
                    <SpinButton
                      onClick={() => setPendingAction("confirm")}
                      disabled={busy}
                      className="rounded-md border border-zinc-300 px-4 py-2 text-sm transition hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      直接確認（跳過店家核對）
                    </SpinButton>
                  </>
                )}
                {header.status === "disputed" && (
                  <SpinButton
                    onClick={() => setPendingAction("send")}
                    disabled={busy || openDisputes.length > 0}
                    className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700 disabled:opacity-50"
                  >
                    {openDisputes.length > 0
                      ? `還有 ${openDisputes.length} 筆爭議未處理`
                      : "📨 重新送店家核對"}
                  </SpinButton>
                )}
                {header.status === "remitted" && (
                  <SpinButton
                    onClick={() => setPendingAction("settle")}
                    disabled={busy}
                    className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-700 disabled:opacity-50"
                  >
                    ✅ 確認收款結案（應收單入帳）
                  </SpinButton>
                )}
              </>
            ) : (
              <>
                <span className="text-sm font-medium">
                  {pendingAction === "send" && (header.status === "disputed"
                    ? "爭議已處理完，重新送店家核對？"
                    : "送出對帳單給店家線上核對？")}
                  {pendingAction === "confirm" && "直接確認此月結算（跳過店家線上核對）？確認後鎖定並自動產生應付帳款單。"}
                  {pendingAction === "settle" && "確認已收到店家匯款？結案後應收單將自動入帳，不可再改。"}
                </span>
                <SpinButton
                  onClick={onConfirmPending}
                  disabled={busy}
                  className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900"
                >
                  {busy ? "送出中…" : "確定"}
                </SpinButton>
                <SpinButton
                  onClick={() => setPendingAction(null)}
                  disabled={busy}
                  className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700"
                >
                  取消
                </SpinButton>
              </>
            )}
          </div>
        </div>
      )}
    </div>
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
