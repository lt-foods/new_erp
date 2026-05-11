"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";

const PAGE_SIZE = 20;

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

type Tab = "all" | "pending" | "approved" | "received" | "rejected";

export default function RestockListPage() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("pending");
  const [page, setPage] = useState(1);

  useEffect(() => { setPage(1); }, [tab]);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data, error: err } = await sb
        .from("restock_requests")
        .select("id, requesting_store_id, status, notes, rejected_reason, linked_transfer_id, linked_pr_id, created_at, stores!inner(name)")
        .order("created_at", { ascending: false })
        .limit(100);
      if (err) { setError(err.message); return; }
      const reqRows = (data ?? []) as unknown as Array<Row & { stores?: { name: string } }>;
      const ids = reqRows.map((r) => r.id);
      // 取 line count + total
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
      // 取 transfer / pr 編號
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
  }, []);

  const filtered = useMemo(() => (rows ?? []).filter((r) => {
    if (tab === "all") return true;
    if (tab === "pending") return r.status === "pending";
    if (tab === "approved") return r.status === "approved_transfer" || r.status === "approved_pr" || r.status === "shipped";
    if (tab === "received") return r.status === "received";
    if (tab === "rejected") return r.status === "rejected" || r.status === "cancelled";
    return true;
  }), [rows, tab]);

  const totalPages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const paginated = useMemo(
    () => filtered.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE),
    [filtered, page],
  );

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">補貨申請</h1>
          <p className="text-sm text-zinc-500">{rows === null ? "載入中…" : `共 ${rows.length} 筆`}</p>
        </div>
        <Link href="/restock/new" className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">
          + 建立申請
        </Link>
      </header>

      {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</div>}

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["pending", "approved", "received", "rejected", "all"] as Tab[]).map((v) => (
          <SpinButton
            key={v}
            onClick={() => setTab(v)}
            className={tab === v
              ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
              : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "pending" ? "待處理" : v === "approved" ? "處理中" : v === "received" ? "已收貨" : v === "rejected" ? "已拒絕 / 取消" : "全部"}
          </SpinButton>
        ))}
      </div>

      <Table>
        <THead>
          <Th>日期</Th>
          <Th>店</Th>
          <Th align="right">商品數</Th>
          <Th align="right">總金額</Th>
          <Th>狀態</Th>
          <Th>連結 / 拒絕原因</Th>
          <Th>備註</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={7} />
          ) : filtered.length === 0 ? (
            <EmptyRow colSpan={7}>沒有符合條件的申請</EmptyRow>
          ) : paginated.map((r) => (
            <Tr key={r.id}>
              <Td className="whitespace-nowrap text-xs text-zinc-500">{new Date(r.created_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}</Td>
              <Td>{r.store_name ?? "—"}</Td>
              <Td align="right" className="font-mono">{r.line_count}</Td>
              <Td align="right" className="font-mono">${r.total_amount.toFixed(0)}</Td>
              <Td>
                <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[r.status]}`}>
                  {STATUS_LABEL[r.status]}
                </span>
              </Td>
              <Td className="text-xs">
                {r.linked_transfer_no && (
                  <Link href={`/hq/inbox?source=transfer&id=${r.linked_transfer_id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                    → {r.linked_transfer_no}
                  </Link>
                )}
                {r.linked_pr_no && (
                  <Link href={`/purchase/requests/edit?id=${r.linked_pr_id}`} className="font-mono text-blue-600 hover:underline dark:text-blue-400">
                    → {r.linked_pr_no}
                  </Link>
                )}
                {r.status === "rejected" && r.rejected_reason && <span className="text-red-600">拒絕：{r.rejected_reason}</span>}
              </Td>
              <Td className="max-w-xs text-xs text-zinc-500">
                <span title={r.notes ?? ""}>{r.notes ? r.notes.slice(0, 30) + (r.notes.length > 30 ? "…" : "") : "—"}</span>
              </Td>
            </Tr>
          ))}
        </TBody>
      </Table>

      {filtered.length > PAGE_SIZE && (
        <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
          <span className="text-xs text-zinc-500">
            共 {filtered.length} 筆 · 顯示 {(page - 1) * PAGE_SIZE + 1} - {Math.min(page * PAGE_SIZE, filtered.length)}
          </span>
          <SpinButton onClick={() => setPage(1)} disabled={page === 1} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">« 第一頁</SpinButton>
          <SpinButton onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">‹ 上頁</SpinButton>
          <span className="text-xs text-zinc-500">{page} / {totalPages}</span>
          <SpinButton onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">下頁 ›</SpinButton>
          <SpinButton onClick={() => setPage(totalPages)} disabled={page === totalPages} className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">最末頁 »</SpinButton>
        </div>
      )}
    </div>
  );
}
