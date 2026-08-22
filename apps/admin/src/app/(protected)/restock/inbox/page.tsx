"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import RestockToPrModal from "@/components/RestockToPrModal";
import { PR_TERM_ZH } from "@/lib/prStatus";
import { translateRpcError } from "@/lib/rpcError";

type Status = "pending" | "approved_transfer" | "approved_pr" | "shipped" | "received" | "rejected" | "cancelled";

type Row = {
  id: number;
  requesting_store_id: number;
  store_name: string | null;
  status: Status;
  notes: string | null;
  rejected_reason: string | null;
  linked_transfer_id: number | null;
  linked_pr_id: number | null;
  linked_transfer_no: string | null;
  linked_pr_no: string | null;
  created_at: string;
  requested_at: string;
  approved_at: string | null;
  rejected_at: string | null;
  stockout_at: string | null;
  standby_at: string | null;
  line_count: number;
  total_amount: number;
  /** 已開請購單的明細（品相）數；pending 但 >0 = 部分開單 */
  pr_line_count: number;
  /** 明細層開出的請購單（依品相分張） */
  line_prs: { id: number; no: string | null }[];
};

const STATUS_LABEL: Record<Status, string> = {
  pending: "待處理",
  // ⚠ 2026-06-12 起這個狀態不再建 transfer、貨也不會動（rpc_approve_restock_to_transfer
  //   最新版 20260714000040:260-270 只 UPDATE status、linked_transfer_id=NULL），
  //   原本寫「已派貨」會讓分店以為貨在路上。⛔ 不要改回去。
  approved_transfer: "已派至工作台",
  approved_pr: "已下單",
  shipped: "已出貨",
  received: "已收貨",
  rejected: "已拒絕",
  cancelled: "已取消",
};

const STATUS_COLOR: Record<Status, string> = {
  pending: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  approved_transfer: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  approved_pr: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  shipped: "bg-cyan-100 text-cyan-800 dark:bg-cyan-950 dark:text-cyan-300",
  received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  rejected: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  cancelled: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
};

export default function RestockInboxPage() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<"pending" | "history">("pending");
  const [busy, setBusy] = useState<number | null>(null);
  const [rejectModal, setRejectModal] = useState<{ id: number; reason: string } | null>(null);
  const [prModalId, setPrModalId] = useState<number | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data, error: err } = await sb
        .from("restock_requests")
        .select("id, requesting_store_id, status, notes, rejected_reason, linked_transfer_id, linked_pr_id, created_at, requested_at, approved_at, rejected_at, stockout_at, standby_at, stores!inner(name)")
        .order("created_at", { ascending: false })
        .limit(200);
      if (err) { setError(err.message); return; }
      const reqRows = (data ?? []) as unknown as Array<Row & { stores?: { name: string } }>;
      const ids = reqRows.map((r) => r.id);
      const lineMap = new Map<number, { count: number; total: number; prCount: number; prIds: number[] }>();
      if (ids.length > 0) {
        const { data: lineData } = await sb.from("restock_request_lines").select("request_id, qty, unit_price, linked_pr_id, cancelled_at").in("request_id", ids);
        for (const l of (lineData ?? []) as { request_id: number; qty: number; unit_price: number; linked_pr_id: number | null; cancelled_at: string | null }[]) {
          const slot = lineMap.get(l.request_id) ?? { count: 0, total: 0, prCount: 0, prIds: [] };
          if (l.cancelled_at === null) {
            slot.count += 1;
            slot.total += Number(l.qty) * Number(l.unit_price);
          }
          if (l.linked_pr_id != null) {
            slot.prCount += 1;
            if (!slot.prIds.includes(l.linked_pr_id)) slot.prIds.push(l.linked_pr_id);
          }
          lineMap.set(l.request_id, slot);
        }
      }
      // 取 transfer_no / pr_no（header 連結 + 明細層依品相開出的 PR）
      const transferIds = reqRows.map((r) => r.linked_transfer_id).filter((x): x is number => !!x);
      const prIds = Array.from(new Set([
        ...reqRows.map((r) => r.linked_pr_id).filter((x): x is number => !!x),
        ...Array.from(lineMap.values()).flatMap((s) => s.prIds),
      ]));
      const xferMap = new Map<number, string>();
      const prMap = new Map<number, string>();
      if (transferIds.length > 0) {
        const { data: xfer } = await sb.from("transfers").select("id, transfer_no").in("id", transferIds);
        for (const t of (xfer ?? []) as { id: number; transfer_no: string }[]) xferMap.set(t.id, t.transfer_no);
      }
      if (prIds.length > 0) {
        const { data: pr } = await sb.from("purchase_requests").select("id, pr_no").in("id", prIds);
        for (const p of (pr ?? []) as { id: number; pr_no: string }[]) prMap.set(p.id, p.pr_no);
      }

      setRows(reqRows.map((r) => ({
        ...r,
        store_name: r.stores?.name ?? null,
        line_count: lineMap.get(r.id)?.count ?? 0,
        total_amount: lineMap.get(r.id)?.total ?? 0,
        pr_line_count: lineMap.get(r.id)?.prCount ?? 0,
        line_prs: (lineMap.get(r.id)?.prIds ?? []).map((id) => ({ id, no: prMap.get(id) ?? null })),
        linked_transfer_no: r.linked_transfer_id ? xferMap.get(r.linked_transfer_id) ?? null : null,
        linked_pr_no: r.linked_pr_id ? prMap.get(r.linked_pr_id) ?? null : null,
      })));
    })();
  }, [reload]);

  async function approveToTransfer(id: number) {
    // ⚠ 舊文案「此動作會建一張 transfer 單」是 2026-06-12 以前的行為，現在不成立。見 hq/inbox 同名函式註解。
    if (!confirm(
      "確定核准這張補貨申請？\n\n" +
      "這一步只是核准：總倉的貨不會動，也不會產生出貨單。\n" +
      "接著要到「派貨工作台」挑貨、建撿貨單，\n" +
      "最後按「派貨出倉」，貨才會真的離開總倉。"
    )) return;
    setBusy(id);
    try {
      const { error: err } = await getSupabase().rpc("rpc_approve_restock_to_transfer", { p_request_id: id });
      if (err) throw err;
      setReload((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  async function shipPrReceived(id: number) {
    if (!confirm("確定 PR 已到貨、現在從 HQ 派貨到分店？")) return;
    setBusy(id);
    try {
      const { error: err } = await getSupabase().rpc("rpc_ship_restock_pr_received", { p_request_id: id });
      if (err) throw err;
      setReload((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  async function setStandby(id: number, standby: boolean) {
    setBusy(id);
    try {
      const { error: err } = await getSupabase().rpc("rpc_restock_set_standby", { p_request_id: id, p_standby: standby });
      if (err) throw err;
      setReload((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  async function reject() {
    if (!rejectModal || !rejectModal.reason.trim()) return;
    setBusy(rejectModal.id);
    try {
      const { error: err } = await getSupabase().rpc("rpc_reject_restock", {
        p_request_id: rejectModal.id,
        p_reason: rejectModal.reason.trim(),
      });
      if (err) throw err;
      setRejectModal(null);
      setReload((t) => t + 1);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(null);
    }
  }

  const stats = (rows ?? []).reduce(
    (acc, r) => {
      if (r.status === "pending") acc.pending += 1;
      if (r.status === "approved_transfer" || r.status === "shipped" || r.status === "received") acc.shipped += 1;
      if (r.status === "approved_pr") acc.toPr += 1;
      if (r.status === "rejected") acc.rejected += 1;
      return acc;
    },
    { pending: 0, shipped: 0, toPr: 0, rejected: 0 }
  );

  const filtered = (rows ?? []).filter((r) => tab === "pending" ? r.status === "pending" : r.status !== "pending");

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">補貨申請 - HQ Inbox</h1>
        <p className="text-sm text-zinc-500">處理分店補貨申請：派至工作台 / 下訂單 / 拒絕</p>
      </header>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}

      <div className="grid gap-3 sm:grid-cols-4">
        <Stat label="待處理" value={stats.pending} accent="text-amber-700 dark:text-amber-400" />
        {/* ⚠ 這格數的是 approved_transfer + shipped + received 三種狀態（見上面 stats）。
            舊標題「已派貨 / 出貨中」兩邊都不對：approved_transfer 根本還沒出貨，received 也不是「出貨中」。
            改成把三個狀態名逐字列出來，標題描述的範圍＝實際數到的範圍。 */}
        <Stat label="已派至工作台 / 已出貨 / 已收貨" value={stats.shipped} accent="text-blue-700 dark:text-blue-400" />
        <Stat label="已下單" value={stats.toPr} accent="text-indigo-700 dark:text-indigo-400" />
        <Stat label="已拒絕" value={stats.rejected} accent="text-red-700 dark:text-red-400" />
      </div>

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["pending", "history"] as const).map((v) => (
          <SpinButton
            key={v}
            onClick={() => setTab(v)}
            className={tab === v
              ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
              : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "pending" ? `待處理 (${stats.pending})` : "歷史"}
          </SpinButton>
        ))}
      </div>

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full text-sm">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">申請時間</th>
              <th className="px-3 py-2">店</th>
              <th className="px-3 py-2 text-right">項數 / 金額</th>
              <th className="px-3 py-2">狀態</th>
              <th className="px-3 py-2">備註</th>
              <th className="px-3 py-2">動作 / 連結</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={6} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : filtered.length === 0 ? (
              <tr><td colSpan={6} className="p-6 text-center text-zinc-500">{tab === "pending" ? "目前沒有待處理申請" : "沒有歷史紀錄"}</td></tr>
            ) : filtered.map((r) => (
              <tr key={r.id}>
                <td className="whitespace-nowrap px-3 py-3 text-xs text-zinc-500">{new Date(r.requested_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}</td>
                <td className="px-3 py-3">{r.store_name ?? "—"}</td>
                <td className="px-3 py-3 text-right font-mono text-xs">{r.line_count} 項 / ${r.total_amount.toFixed(0)}</td>
                <td className="px-3 py-3">
                  {/* 斷貨取消（stockout_at 有值）與一般取消區分顯示 */}
                  {r.status === "cancelled" && r.stockout_at ? (
                    <span
                      title={`採購斷貨於 ${new Date(r.stockout_at).toLocaleString("zh-TW")}`}
                      className="inline-flex rounded bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-950 dark:text-red-300"
                    >
                      ⛔ 斷貨
                    </span>
                  ) : r.status === "pending" && r.standby_at ? (
                    <span
                      title={`轉入候補於 ${new Date(r.standby_at).toLocaleString("zh-TW")}`}
                      className="inline-flex rounded bg-violet-100 px-2 py-0.5 text-xs font-medium text-violet-800 dark:bg-violet-950 dark:text-violet-300"
                    >
                      ⏳ 候補中
                    </span>
                  ) : (
                    <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span>
                  )}
                </td>
                <td className="max-w-xs px-3 py-3 text-xs text-zinc-500">{r.notes ?? "—"}</td>
                <td className="px-3 py-3">
                  {r.status === "pending" ? (
                    <div className="flex flex-col gap-1">
                      <div className="flex flex-wrap gap-1">
                        {r.pr_line_count === 0 && (
                          <SpinButton onClick={() => approveToTransfer(r.id)} disabled={busy === r.id} className="rounded border border-blue-400 bg-blue-50 px-2 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-50 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300" title="只核可、貨不會動；核可後到「派貨工作台」挑貨">派至工作台</SpinButton>
                        )}
                        <SpinButton onClick={() => setPrModalId(r.id)} disabled={busy === r.id} className="rounded border border-indigo-400 bg-indigo-50 px-2 py-1 text-xs font-medium text-indigo-700 hover:bg-indigo-100 disabled:opacity-50 dark:border-indigo-700 dark:bg-indigo-950 dark:text-indigo-300">下訂單</SpinButton>
                        {r.standby_at ? (
                          <SpinButton onClick={() => setStandby(r.id, false)} disabled={busy === r.id} className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">取消候補</SpinButton>
                        ) : (
                          <SpinButton onClick={() => setStandby(r.id, true)} disabled={busy === r.id} title="等貨源、先移入候補" className="rounded border border-violet-400 bg-violet-50 px-2 py-1 text-xs font-medium text-violet-700 hover:bg-violet-100 disabled:opacity-50 dark:border-violet-700 dark:bg-violet-950 dark:text-violet-300">⏳ 轉候補</SpinButton>
                        )}
                        {r.pr_line_count === 0 && (
                          <SpinButton onClick={() => setRejectModal({ id: r.id, reason: "" })} disabled={busy === r.id} className="rounded border border-red-400 bg-red-50 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-100 disabled:opacity-50 dark:border-red-700 dark:bg-red-950 dark:text-red-300">拒絕</SpinButton>
                        )}
                      </div>
                      {r.pr_line_count > 0 && (
                        <div className="flex flex-col gap-0.5 text-xs">
                          <span className="text-indigo-600 dark:text-indigo-400">已開單 {r.pr_line_count}/{r.line_count} 品相</span>
                          {r.line_prs.map((p) => (
                            <Link key={p.id} href={`/purchase/requests/edit?id=${p.id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                              → {p.no ?? `${PR_TERM_ZH} #${p.id}`}
                            </Link>
                          ))}
                        </div>
                      )}
                    </div>
                  ) : (
                    <div className="flex flex-col gap-1 text-xs">
                      {(r.line_prs.length > 0
                        ? r.line_prs
                        : r.linked_pr_id
                          ? [{ id: r.linked_pr_id, no: r.linked_pr_no }]
                          : []
                      ).map((p) => (
                        <Link key={p.id} href={`/purchase/requests/edit?id=${p.id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                          → {p.no ?? `${PR_TERM_ZH} #${p.id}`}
                        </Link>
                      ))}
                      {r.linked_transfer_id && (
                        <Link href={`/hq/inbox?source=transfer&id=${r.linked_transfer_id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                          → {r.linked_transfer_no ?? `轉貨單 #${r.linked_transfer_id}`}
                        </Link>
                      )}
                      {r.status === "approved_pr" && (
                        <SpinButton
                          onClick={() => shipPrReceived(r.id)}
                          disabled={busy === r.id}
                          className="mt-1 self-start rounded border border-emerald-400 bg-emerald-50 px-2 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-100 disabled:opacity-50 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
                        >
                          📦 PO 到貨、建轉貨單
                        </SpinButton>
                      )}
                      {r.status === "rejected" && r.rejected_reason && <span className="text-red-600">拒絕：{r.rejected_reason}</span>}
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <RestockToPrModal
        open={prModalId !== null}
        restockId={prModalId}
        onClose={() => setPrModalId(null)}
        onDone={() => setReload((t) => t + 1)}
      />

      {rejectModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-md rounded-md bg-white p-4 shadow-lg dark:bg-zinc-900">
            <h2 className="mb-3 text-base font-semibold">拒絕補貨申請 #{rejectModal.id}</h2>
            <label className="block space-y-1 text-sm">
              <span className="text-zinc-600 dark:text-zinc-400">拒絕原因 *</span>
              <textarea
                value={rejectModal.reason}
                onChange={(e) => setRejectModal({ ...rejectModal, reason: e.target.value })}
                placeholder="例如：庫存不足且採購週期太長 / 商品已停售…"
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                rows={3}
              />
            </label>
            <div className="mt-3 flex gap-2">
              <SpinButton onClick={reject} disabled={!rejectModal.reason.trim() || busy === rejectModal.id} className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-500 disabled:opacity-50">
                {busy === rejectModal.id ? "拒絕中…" : "確認拒絕"}
              </SpinButton>
              <SpinButton onClick={() => setRejectModal(null)} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</SpinButton>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: number; accent: string }) {
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`text-2xl font-semibold ${accent}`}>{value}</div>
    </div>
  );
}
