"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";

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
  line_count: number;
  total_amount: number;
};

const STATUS_LABEL: Record<Status, string> = {
  pending: "待處理",
  approved_transfer: "已派貨",
  approved_pr: "已轉採購",
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
  const [reload, setReload] = useState(0);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data, error: err } = await sb
        .from("restock_requests")
        .select("id, requesting_store_id, status, notes, rejected_reason, linked_transfer_id, linked_pr_id, created_at, requested_at, approved_at, rejected_at, stores!inner(name)")
        .order("created_at", { ascending: false })
        .limit(200);
      if (err) { setError(err.message); return; }
      const reqRows = (data ?? []) as unknown as Array<Row & { stores?: { name: string } }>;
      const ids = reqRows.map((r) => r.id);
      const lineMap = new Map<number, { count: number; total: number }>();
      if (ids.length > 0) {
        const { data: lineData } = await sb.from("restock_request_lines").select("request_id, qty, unit_price").in("request_id", ids);
        for (const l of (lineData ?? []) as { request_id: number; qty: number; unit_price: number }[]) {
          const slot = lineMap.get(l.request_id) ?? { count: 0, total: 0 };
          slot.count += 1;
          slot.total += Number(l.qty) * Number(l.unit_price);
          lineMap.set(l.request_id, slot);
        }
      }
      // 取 transfer_no / pr_no
      const transferIds = reqRows.map((r) => r.linked_transfer_id).filter((x): x is number => !!x);
      const prIds = reqRows.map((r) => r.linked_pr_id).filter((x): x is number => !!x);
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
        linked_transfer_no: r.linked_transfer_id ? xferMap.get(r.linked_transfer_id) ?? null : null,
        linked_pr_no: r.linked_pr_id ? prMap.get(r.linked_pr_id) ?? null : null,
      })));
    })();
  }, [reload]);

  async function approveToTransfer(id: number) {
    if (!confirm("確定派庫存出貨？此動作會建一張 transfer 單。")) return;
    setBusy(id);
    try {
      const { error: err } = await getSupabase().rpc("rpc_approve_restock_to_transfer", { p_request_id: id });
      if (err) throw err;
      setReload((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  async function approveToPr(id: number) {
    if (!confirm("確定轉為採購？此動作會把申請項目掛到 PR。")) return;
    setBusy(id);
    try {
      const { error: err } = await getSupabase().rpc("rpc_approve_restock_to_pr", { p_request_id: id });
      if (err) throw err;
      setReload((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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
      setError(e instanceof Error ? e.message : String(e));
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
      setError(e instanceof Error ? e.message : String(e));
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
        <p className="text-sm text-zinc-500">處理分店補貨申請：派庫存出貨 / 轉採購 / 拒絕</p>
      </header>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}

      <div className="grid gap-3 sm:grid-cols-4">
        <Stat label="待處理" value={stats.pending} accent="text-amber-700 dark:text-amber-400" />
        <Stat label="已派貨 / 出貨中" value={stats.shipped} accent="text-blue-700 dark:text-blue-400" />
        <Stat label="已轉採購" value={stats.toPr} accent="text-indigo-700 dark:text-indigo-400" />
        <Stat label="已拒絕" value={stats.rejected} accent="text-red-700 dark:text-red-400" />
      </div>

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["pending", "history"] as const).map((v) => (
          <button
            key={v}
            onClick={() => setTab(v)}
            className={tab === v
              ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
              : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "pending" ? `待處理 (${stats.pending})` : "歷史"}
          </button>
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
                <td className="px-3 py-3"><span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span></td>
                <td className="max-w-xs px-3 py-3 text-xs text-zinc-500">{r.notes ?? "—"}</td>
                <td className="px-3 py-3">
                  {r.status === "pending" ? (
                    <div className="flex flex-wrap gap-1">
                      <button onClick={() => approveToTransfer(r.id)} disabled={busy === r.id} className="rounded border border-blue-400 bg-blue-50 px-2 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-50 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300">派貨</button>
                      <button onClick={() => approveToPr(r.id)} disabled={busy === r.id} className="rounded border border-indigo-400 bg-indigo-50 px-2 py-1 text-xs font-medium text-indigo-700 hover:bg-indigo-100 disabled:opacity-50 dark:border-indigo-700 dark:bg-indigo-950 dark:text-indigo-300">進貨</button>
                      <button onClick={() => setRejectModal({ id: r.id, reason: "" })} disabled={busy === r.id} className="rounded border border-red-400 bg-red-50 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-100 disabled:opacity-50 dark:border-red-700 dark:bg-red-950 dark:text-red-300">拒絕</button>
                    </div>
                  ) : (
                    <div className="flex flex-col gap-1 text-xs">
                      {r.linked_pr_id && (
                        <Link href={`/purchase/requests/edit?id=${r.linked_pr_id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                          → {r.linked_pr_no ?? `採購單 #${r.linked_pr_id}`}
                        </Link>
                      )}
                      {r.linked_transfer_id && (
                        <Link href={`/transfers?id=${r.linked_transfer_id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                          → {r.linked_transfer_no ?? `轉貨單 #${r.linked_transfer_id}`}
                        </Link>
                      )}
                      {r.status === "approved_pr" && (
                        <button
                          onClick={() => shipPrReceived(r.id)}
                          disabled={busy === r.id}
                          className="mt-1 self-start rounded border border-emerald-400 bg-emerald-50 px-2 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-100 disabled:opacity-50 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
                        >
                          📦 PO 到貨、建轉貨單
                        </button>
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
              <button onClick={reject} disabled={!rejectModal.reason.trim() || busy === rejectModal.id} className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-500 disabled:opacity-50">
                {busy === rejectModal.id ? "拒絕中…" : "確認拒絕"}
              </button>
              <button onClick={() => setRejectModal(null)} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">取消</button>
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
