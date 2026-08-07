"use client";

// 分店端「月結對帳」單張核對頁（整頁、不用彈窗）。
// - 逐行「✓ 核對」只是自己標記核對到哪筆（存 localStorage，不上傳），
//   隨時可直接送出，不必全部核對完。
// - 有問題的行按「有問題」+ 必填原因 → 送出爭議；全部無誤 → 同意畫押。
// - 調撥單號可點：連到內部調撥（?open= 直接開該張明細）。
// - 送出動作用頁內確認列，不跳瀏覽器對話框。
// 只顯示分店價口徑（單價/小計），不顯示總倉成本。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";
import { withBasePath } from "@/lib/basePath";
import SpinButton from "@/components/SpinButton";

type Settlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  adjustment_amount: number;
  item_count: number;
  status: "sent" | "disputed" | "confirmed" | "remitted" | "settled" | "draft" | "cancelled";
  sent_at: string | null;
  store_agreed_at: string | null;
  remitted_at: string | null;
  remit_note: string | null;
  settled_at: string | null;
};

type Item = {
  id: number;
  transfer_id: number;
  transfer_item_id: number;
  sku_id: number;
  qty_received: number;
  unit_branch_price: number;
  branch_amount: number;
  received_at: string;
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
  description: string | null;
};

type Dispute = {
  id: number;
  transfer_item_id: number;
  reason: string;
  status: "open" | "resolved";
  raised_by: string;
  resolved_by: string | null;
  resolution_note: string | null;
};

type Adjustment = {
  id: number;
  amount: number;
  reason: string;
  created_at: string;
};

type Transfer = { id: number; transfer_no: string };
type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };
type StoreRow = { id: number; name: string };

const ENTRY_TYPE_LABEL: Record<Item["entry_type"], string> = {
  hq_inbound: "總倉進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};

const STATUS_LABEL: Record<string, string> = {
  sent: "待核對",
  disputed: "爭議處理中",
  confirmed: "已同意待匯款",
  remitted: "已匯款待總部確認",
  settled: "已結案",
};
const STATUS_COLOR: Record<string, string> = {
  sent: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  remitted: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  settled: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
};

// 逐行核對進度存 localStorage（純本機標記，不上傳）
const checkKey = (settlementId: number) => `sms-review-checked-${settlementId}`;

function loadChecked(settlementId: number): Set<number> {
  try {
    const raw = localStorage.getItem(checkKey(settlementId));
    if (raw) return new Set(JSON.parse(raw) as number[]);
  } catch { /* noop */ }
  return new Set();
}

function saveChecked(settlementId: number, ids: Set<number>) {
  try {
    localStorage.setItem(checkKey(settlementId), JSON.stringify(Array.from(ids)));
  } catch { /* noop */ }
}

export default function SettlementReviewPage() {
  const { user } = useAuth();
  const [settlementId, setSettlementId] = useState<number | null>(null);
  const [settlement, setSettlement] = useState<Settlement | null>(null);
  const [store, setStore] = useState<StoreRow | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [disputes, setDisputes] = useState<Dispute[]>([]);
  const [adjustments, setAdjustments] = useState<Adjustment[]>([]);
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);

  // 逐行狀態：checked = 自己核對過（本機）；flags = 有問題 + 原因
  const [checked, setChecked] = useState<Set<number>>(new Set());
  const [flags, setFlags] = useState<Map<number, string>>(new Map());
  const [remitNote, setRemitNote] = useState("");
  // 頁內確認列（取代瀏覽器 confirm 對話框）
  const [pendingAction, setPendingAction] = useState<"agree" | "dispute" | "remit" | null>(null);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const id = new URLSearchParams(window.location.search).get("id");
    if (!id) return;
    const t = setTimeout(() => setSettlementId(Number(id)), 0);
    return () => clearTimeout(t);
  }, []);

  useEffect(() => {
    if (!settlementId) return;
    const t = setTimeout(() => setChecked(loadChecked(settlementId)), 0);
    return () => clearTimeout(t);
  }, [settlementId]);

  useEffect(() => {
    if (!settlementId) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data: s, error: e0 }, { data: itemRows, error: e1 }, { data: dData }] = await Promise.all([
        sb
          .from("store_monthly_settlements")
          .select("id, settlement_month, store_id, payable_amount, adjustment_amount, item_count, status, sent_at, store_agreed_at, remitted_at, remit_note, settled_at")
          .eq("id", settlementId)
          .maybeSingle(),
        sb
          .from("store_monthly_settlement_items")
          .select("id, transfer_id, transfer_item_id, sku_id, qty_received, unit_branch_price, branch_amount, received_at, entry_type, description")
          .eq("settlement_id", settlementId)
          .order("entry_type", { ascending: true })
          .order("received_at", { ascending: true }),
        sb
          .from("store_settlement_disputes")
          .select("id, transfer_item_id, reason, status, raised_by, resolved_by, resolution_note")
          .eq("settlement_id", settlementId)
          .order("raised_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (e0) { setErr(e0.message); return; }
      if (!s) { setErr("找不到此對帳單"); return; }
      const sd = s as unknown as Settlement;
      setSettlement(sd);
      const dList = (dData ?? []) as Dispute[];
      setDisputes(dList);
      if (e1) { setErr(e1.message); setItems([]); return; }
      const list = (itemRows ?? []) as Item[];
      setItems(list);

      // 爭議訊息的發話人（自家誰提的 / 總部誰回的）→ 顯示名稱
      const staffUids = Array.from(
        new Set(dList.flatMap((d) => [d.raised_by, d.resolved_by]).filter((x): x is string => Boolean(x))),
      );

      const [{ data: storeData }, { data: tx }, { data: sk }, { data: adjData }, { data: staffData }] = await Promise.all([
        sb.from("stores").select("id, name").eq("id", sd.store_id).maybeSingle(),
        list.length
          ? sb.from("transfers").select("id, transfer_no").in("id", Array.from(new Set(list.map((it) => it.transfer_id))))
          : Promise.resolve({ data: [] as Transfer[] }),
        list.length
          ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", Array.from(new Set(list.map((it) => it.sku_id))))
          : Promise.resolve({ data: [] as Sku[] }),
        sb
          .from("store_settlement_adjustments")
          .select("id, amount, reason, created_at")
          .eq("store_id", sd.store_id)
          .eq("settlement_month", sd.settlement_month)
          .eq("status", "active")
          .order("created_at", { ascending: true }),
        staffUids.length
          ? sb.rpc("rpc_get_staff_names", { p_uids: staffUids })
          : Promise.resolve({ data: [] as { id: string; display_name: string }[] }),
      ]);
      if (cancelled) return;
      if (storeData) setStore(storeData as StoreRow);
      setAdjustments((adjData ?? []) as Adjustment[]);
      const nameMap = new Map<string, string>();
      for (const n of ((staffData ?? []) as { id: string; display_name: string }[])) nameMap.set(n.id, n.display_name);
      setStaffNames(nameMap);
      const tm = new Map<number, Transfer>();
      for (const t of (tx ?? []) as Transfer[]) tm.set(t.id, t);
      setTransfers(tm);
      const sm = new Map<number, Sku>();
      for (const x of (sk ?? []) as Sku[]) sm.set(x.id, x);
      setSkus(sm);
    })();
    return () => { cancelled = true; };
  }, [settlementId, reloadTick]);

  const disputeByItem = useMemo(() => {
    const m = new Map<number, Dispute>();
    for (const d of disputes) {
      const prev = m.get(d.transfer_item_id);
      if (!prev || d.status === "open") m.set(d.transfer_item_id, d);
    }
    return m;
  }, [disputes]);

  // 爭議行排最上方
  const sortedItems = useMemo(() => {
    if (!items) return null;
    const rank = (it: Item) => {
      const d = disputeByItem.get(it.transfer_item_id);
      if (d?.status === "open") return 0;
      if (d) return 1;
      return 2;
    };
    return [...items].sort((a, b) => rank(a) - rank(b));
  }, [items, disputeByItem]);

  // 分店帳號只能看自己店的對帳單（HQ / 總倉帳號可代看）
  const allowed = useMemo(() => {
    if (!settlement || !store) return true; // 載入中先不擋
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores) || userStores.length === 0) return true; // HQ（無 stores）
    if (userStores.includes("總倉")) return true;
    return userStores.includes(store.name);
  }, [settlement, store, user]);

  const isSent = settlement?.status === "sent";
  const flaggedCount = flags.size;
  const allReasonsFilled = Array.from(flags.values()).every((v) => v.trim().length > 0);
  const total = (items ?? []).reduce((s, it) => s + Number(it.branch_amount ?? 0), 0);
  const checkedCount = (items ?? []).filter((it) => checked.has(it.transfer_item_id)).length;

  function toggleChecked(transferItemId: number) {
    if (!settlementId) return;
    setChecked((cur) => {
      const next = new Set(cur);
      if (next.has(transferItemId)) next.delete(transferItemId);
      else next.add(transferItemId);
      saveChecked(settlementId, next);
      return next;
    });
    // 標核對 = 這行沒問題 → 順手清掉有問題標記
    setFlags((m) => {
      if (!m.has(transferItemId)) return m;
      const next = new Map(m);
      next.delete(transferItemId);
      return next;
    });
  }

  function toggleFlag(transferItemId: number) {
    setFlags((m) => {
      const next = new Map(m);
      if (next.has(transferItemId)) next.delete(transferItemId);
      else next.set(transferItemId, "");
      return next;
    });
    // 標有問題 → 取消本機核對標記
    setChecked((cur) => {
      if (!cur.has(transferItemId) || !settlementId) return cur;
      const next = new Set(cur);
      next.delete(transferItemId);
      saveChecked(settlementId, next);
      return next;
    });
    setPendingAction(null);
  }

  async function callRpc(fn: string, params: Record<string, unknown>) {
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
      setFlags(new Map());
      setReloadTick((t) => t + 1);
      window.dispatchEvent(new Event("settlement-badge-refresh"));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  function onConfirmPending() {
    if (!settlementId || !pendingAction) return;
    if (pendingAction === "agree") {
      void callRpc("rpc_store_review_settlement", { p_settlement_id: settlementId, p_agree: true, p_disputes: null });
    } else if (pendingAction === "dispute") {
      void callRpc("rpc_store_review_settlement", {
        p_settlement_id: settlementId,
        p_agree: false,
        p_disputes: Array.from(flags.entries()).map(([transfer_item_id, reason]) => ({
          transfer_item_id,
          reason: reason.trim(),
        })),
      });
    } else {
      void callRpc("rpc_mark_settlement_remitted", { p_settlement_id: settlementId, p_note: remitNote.trim() || null });
    }
  }

  if (!settlementId) {
    return <div className="p-6 text-sm text-zinc-500">缺少 id 參數。</div>;
  }
  if (err && !settlement) {
    return (
      <div className="m-6 rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {err}
      </div>
    );
  }
  if (!settlement) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }
  if (!allowed) {
    return (
      <div className="m-6 rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
        這不是你分店的對帳單。
      </div>
    );
  }

  const monthLabel = settlement.settlement_month?.slice(0, 7);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6 pb-28">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <Link href="/transfers/settlement" className="text-sm text-blue-600 hover:underline dark:text-blue-400">
            ← 回月結對帳
          </Link>
          <h1 className="mt-1 text-xl font-semibold">
            {monthLabel} 月結對帳單
            {store && <span className="ml-2 text-base font-normal text-zinc-500">{store.name}</span>}
          </h1>
        </div>
        <div className="text-right">
          <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[settlement.status] ?? ""}`}>
            {STATUS_LABEL[settlement.status] ?? settlement.status}
          </span>
          <div className="mt-1 text-sm">
            應付總部金額：
            <span className="ml-1 font-mono text-lg font-semibold text-rose-600">
              ${Number(settlement.payable_amount).toLocaleString("zh-TW")}
            </span>
          </div>
        </div>
      </header>

      {settlement.status === "disputed" && (
        <div className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          已送出爭議，等總部處理後會重新送來核對。爭議行列在最上方。
        </div>
      )}
      {settlement.status === "confirmed" && (
        <div className="rounded-md border border-blue-300 bg-blue-50 p-3 text-sm text-blue-800 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-300">
          🔒 對帳單已同意鎖定。請匯款 <span className="font-mono font-semibold">${Number(settlement.payable_amount).toLocaleString("zh-TW")}</span> 給總部後，在下方按「我已匯款」。
        </div>
      )}
      {settlement.status === "remitted" && (
        <div className="rounded-md border border-indigo-300 bg-indigo-50 p-3 text-sm text-indigo-800 dark:border-indigo-800 dark:bg-indigo-950 dark:text-indigo-300">
          已回報匯款{settlement.remit_note ? `（備註：${settlement.remit_note}）` : ""}，等總部確認收款結案。
        </div>
      )}
      {settlement.status === "settled" && (
        <div className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          ✅ 本月對帳已結案，謝謝。
        </div>
      )}

      {isSent && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm dark:border-zinc-800 dark:bg-zinc-900">
          <span className="text-zinc-600 dark:text-zinc-300">
            逐行核對：沒問題按「✓ 核對」記錄自己核對到哪筆（只存在這台裝置）；
            金額有問題按「有問題」填原因。不必全部核對完也可以直接送出。
          </span>
          <span className="font-mono text-xs text-zinc-500">
            已核對 {checkedCount}／{items?.length ?? 0} 筆
            {flaggedCount > 0 && <span className="ml-2 text-amber-600">有問題 {flaggedCount} 筆</span>}
          </span>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">類型</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">收貨日</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">調撥單</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">商品</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">數量</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">單價</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">小計</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">核對</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {sortedItems === null ? (
              <tr><td colSpan={8} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : sortedItems.length === 0 ? (
              <tr><td colSpan={8} className="p-3 text-center text-zinc-500">無明細。</td></tr>
            ) : sortedItems.map((it) => {
              const tx = transfers.get(it.transfer_id);
              const sku = skus.get(it.sku_id);
              const isFree = it.description != null;
              const d = disputeByItem.get(it.transfer_item_id);
              const flagged = flags.has(it.transfer_item_id);
              const isChecked = checked.has(it.transfer_item_id);
              const rowCls =
                d?.status === "open" ? "bg-red-50 dark:bg-red-950/40"
                : flagged ? "bg-amber-50 dark:bg-amber-950/40"
                : isChecked ? "bg-emerald-50/60 dark:bg-emerald-950/30"
                : "hover:bg-zinc-50 dark:hover:bg-zinc-900";
              return (
                <tr key={it.id} className={rowCls}>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{ENTRY_TYPE_LABEL[it.entry_type] ?? it.entry_type}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{new Date(it.received_at).toLocaleDateString("zh-TW")}</td>
                  <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">
                    <a
                      href={withBasePath(`/wms/transfers?open=${it.transfer_id}`)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-blue-600 hover:underline dark:text-blue-400"
                    >
                      {tx?.transfer_no ?? `#${it.transfer_id}`}
                    </a>
                  </td>
                  <td className="px-3 py-2 text-xs">
                    {it.description ? (
                      <span className="break-words">{it.description}</span>
                    ) : (
                      <>
                        <span className="font-mono text-zinc-500">{sku?.sku_code ?? "—"}</span>{" "}
                        <span>{sku?.product_name ?? "—"}</span>
                        {sku?.variant_name && <span className="ml-1 text-zinc-400">/ {sku.variant_name}</span>}
                      </>
                    )}
                    {d && (
                      <div className="mt-1 text-xs text-red-700 dark:text-red-400">
                        🗣 {staffNames.get(d.raised_by) && (
                          <span className="font-medium">{staffNames.get(d.raised_by)}：</span>
                        )}
                        {d.reason}
                        {d.status === "resolved" && (
                          <span className="ml-1 text-emerald-700 dark:text-emerald-400">
                            （總部{d.resolved_by && staffNames.get(d.resolved_by) ? ` ${staffNames.get(d.resolved_by)} ` : ""}已處理{d.resolution_note ? `：${d.resolution_note}` : ""}）
                          </span>
                        )}
                      </div>
                    )}
                    {flagged && (
                      <input
                        value={flags.get(it.transfer_item_id) ?? ""}
                        onChange={(e) =>
                          setFlags((m) => new Map(m).set(it.transfer_item_id, e.target.value))
                        }
                        placeholder="請填原因（必填），例：實際金額應為 $280"
                        className="mt-1 w-full rounded-md border border-amber-400 bg-white px-2 py-1 text-xs dark:border-amber-700 dark:bg-zinc-800"
                      />
                    )}
                  </td>
                  <td className="px-3 py-2 text-right font-mono">{Number(it.qty_received).toLocaleString()}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-right font-mono text-zinc-500">
                    {isFree ? "—" : `$${Number(it.unit_branch_price ?? 0).toFixed(2)}`}
                  </td>
                  <td className={`whitespace-nowrap px-3 py-2 text-right font-mono ${Number(it.branch_amount ?? 0) < 0 ? "text-amber-600" : ""}`}>
                    ${Number(it.branch_amount ?? 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2">
                    {isSent ? (
                      <span className="flex items-center gap-1">
                        <SpinButton
                          onClick={() => toggleChecked(it.transfer_item_id)}
                          className={`rounded-md px-2 py-1 text-xs ${
                            isChecked
                              ? "bg-emerald-600 font-medium text-white"
                              : "border border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                          }`}
                        >
                          {isChecked ? "✓ 已核對" : "✓ 核對"}
                        </SpinButton>
                        <SpinButton
                          onClick={() => toggleFlag(it.transfer_item_id)}
                          className={`rounded-md px-2 py-1 text-xs ${
                            flagged
                              ? "bg-amber-500 font-medium text-white"
                              : "border border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                          }`}
                        >
                          {flagged ? "↩ 取消" : "有問題"}
                        </SpinButton>
                      </span>
                    ) : d?.status === "open" ? (
                      <span className="text-xs text-red-600 dark:text-red-400">爭議中</span>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
          {items && items.length > 0 && (
            <tfoot className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <td colSpan={6} className="px-3 py-2 text-right text-xs text-zinc-500">合計</td>
                <td className="px-3 py-2 text-right font-mono font-medium text-rose-600">
                  ${total.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                </td>
                <td></td>
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      {/* 總部金額調整（明細以外的加減項，含原因） */}
      {adjustments.length > 0 && (
        <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
          <div className="border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-sm font-medium dark:border-zinc-800 dark:bg-zinc-900">
            總部金額調整（{adjustments.length} 筆）
          </div>
          <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {adjustments.map((a) => {
              const positive = Number(a.amount) > 0;
              return (
                <li key={a.id} className="flex items-start justify-between gap-3 px-3 py-2 text-sm">
                  <div className="min-w-0 flex-1">
                    <span className="break-words">{a.reason}</span>
                    <span className="ml-2 text-xs text-zinc-500">{new Date(a.created_at).toLocaleDateString("zh-TW")}</span>
                  </div>
                  <span className={`shrink-0 font-mono ${positive ? "text-rose-600" : "text-emerald-600"}`}>
                    {positive ? "+" : "−"}${Math.abs(Number(a.amount)).toLocaleString("zh-TW")}
                  </span>
                </li>
              );
            })}
          </ul>
          <div className="border-t border-zinc-200 bg-zinc-50 px-3 py-2 text-right text-sm dark:border-zinc-800 dark:bg-zinc-900">
            商品合計 <span className="font-mono">${total.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}</span>
            <span className="mx-1">＋</span>調整{" "}
            <span className="font-mono">
              {Number(settlement.adjustment_amount ?? 0) < 0 ? "−" : "+"}${Math.abs(Number(settlement.adjustment_amount ?? 0)).toLocaleString("zh-TW")}
            </span>
            <span className="mx-1">＝</span>應付總部{" "}
            <span className="font-mono font-semibold text-rose-600">${Number(settlement.payable_amount).toLocaleString("zh-TW")}</span>
          </div>
        </div>
      )}

      {err && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{err}</p>
        </div>
      )}

      {/* 底部固定動作列（頁內確認，不跳對話框） */}
      {(isSent || settlement.status === "confirmed") && (
        <div className="fixed inset-x-0 bottom-0 z-10 border-t border-zinc-200 bg-white/95 p-3 backdrop-blur md:left-52 dark:border-zinc-800 dark:bg-zinc-950/95 print:hidden">
          <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-end gap-2">
            {pendingAction === null ? (
              <>
                {isSent && flaggedCount > 0 && (
                  <>
                    {!allReasonsFilled && (
                      <span className="text-xs text-amber-700 dark:text-amber-400">每筆有問題的行都要填原因</span>
                    )}
                    <SpinButton
                      onClick={() => setPendingAction("dispute")}
                      disabled={busy || !allReasonsFilled}
                      className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
                    >
                      ⚠️ 送出爭議（{flaggedCount} 筆）
                    </SpinButton>
                  </>
                )}
                {isSent && flaggedCount === 0 && (
                  <>
                    {checkedCount < (items?.length ?? 0) && (
                      <span className="text-xs text-zinc-500">
                        還有 {(items?.length ?? 0) - checkedCount} 筆未標核對（可直接送出）
                      </span>
                    )}
                    <SpinButton
                      onClick={() => setPendingAction("agree")}
                      disabled={busy}
                      className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
                    >
                      ✅ 全部無誤，同意畫押
                    </SpinButton>
                  </>
                )}
                {settlement.status === "confirmed" && (
                  <>
                    <label className="text-xs">
                      <span className="mb-1 block text-zinc-500">匯款備註（選填，例：帳號後五碼）</span>
                      <input
                        value={remitNote}
                        onChange={(e) => setRemitNote(e.target.value)}
                        className="w-56 rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    </label>
                    <SpinButton
                      onClick={() => setPendingAction("remit")}
                      disabled={busy}
                      className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
                    >
                      💸 我已匯款
                    </SpinButton>
                  </>
                )}
              </>
            ) : (
              <>
                <span className="text-sm font-medium">
                  {pendingAction === "agree" && "確定整份無誤、同意畫押？同意後金額鎖定並產生應付帳款。"}
                  {pendingAction === "dispute" && `確定送出 ${flaggedCount} 筆爭議給總部處理？`}
                  {pendingAction === "remit" && `確定已匯款 $${Number(settlement.payable_amount).toLocaleString("zh-TW")} 給總部？`}
                </span>
                <SpinButton
                  onClick={onConfirmPending}
                  disabled={busy}
                  className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900"
                >
                  {busy ? "送出中…" : "確定送出"}
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
