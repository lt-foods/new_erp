"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { CampaignForm, type CampaignFormValues } from "@/components/CampaignForm";
import { CampaignItemsTable } from "@/components/CampaignItemsTable";

type Status =
  | "draft" | "open" | "closed" | "ordered" | "receiving" | "ready" | "completed" | "cancelled";

type Row = {
  id: number;
  campaign_no: string;
  name: string;
  status: Status;
  start_at: string | null;
  end_at: string | null;
  pickup_deadline: string | null;
  updated_at: string;
};

const STATUS_LABEL: Record<Status, string> = {
  draft: "草稿", open: "開團中", closed: "已收單", ordered: "已下訂",
  receiving: "到貨中", ready: "可取貨", completed: "已完成", cancelled: "已取消",
};

const PAGE_SIZE = 50;

export default function CampaignsListPage() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<string>("");
  const [page, setPage] = useState(1);

  const [itemCounts, setItemCounts] = useState<Map<number, number>>(new Map());
  const [modal, setModal] = useState<
    | { mode: "new" }
    | { mode: "edit"; values: CampaignFormValues }
    | null
  >(null);
  const [reloadTick, setReloadTick] = useState(0);

  async function openEdit(id: number) {
    const { data, error: err } = await getSupabase()
      .from("group_buy_campaigns")
      .select("id, campaign_no, name, description, status, close_type, start_at, end_at, pickup_deadline, pickup_days, total_cap_qty, notes")
      .eq("id", id).maybeSingle();
    if (err || !data) { setError(err?.message ?? "找不到開團"); return; }
    setModal({
      mode: "edit",
      values: {
        id: data.id,
        campaign_no: data.campaign_no,
        name: data.name,
        description: data.description,
        status: data.status as CampaignFormValues["status"],
        close_type: data.close_type as CampaignFormValues["close_type"],
        start_at: data.start_at,
        end_at: data.end_at,
        pickup_deadline: data.pickup_deadline,
        pickup_days: data.pickup_days,
        total_cap_qty: data.total_cap_qty != null ? Number(data.total_cap_qty) : null,
        notes: data.notes,
      },
    });
  }

  useEffect(() => {
    const t = setTimeout(() => { setQuery(queryDraft); setPage(1); }, 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  useEffect(() => { setPage(1); }, [status]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("group_buy_campaigns")
          .select("id, campaign_no, name, status, start_at, end_at, pickup_deadline, updated_at", { count: "exact" })
          .order("updated_at", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
        if (query.trim()) {
          const safe = query.replace(/[%,()]/g, " ").trim();
          q = q.or(`name.ilike.%${safe}%,campaign_no.ilike.%${safe}%`);
        }
        if (status) q = q.eq("status", status);

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) { setError(error.message); return; }
        setError(null);
        setRows((data ?? []) as Row[]);
        setTotal(count ?? 0);

        // 補商品數
        const ids = (data ?? []).map((r) => r.id);
        if (ids.length) {
          const { data: items } = await getSupabase()
            .from("campaign_items").select("campaign_id").in("campaign_id", ids);
          const m = new Map<number, number>();
          for (const id of ids) m.set(id, 0);
          for (const it of items ?? []) m.set(it.campaign_id, (m.get(it.campaign_id) ?? 0) + 1);
          if (!cancelled) setItemCounts(m);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [query, status, page, reloadTick]);

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">開團</h1>
          <p className="text-sm text-zinc-500">
            {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
          </p>
        </div>
        <button onClick={() => setModal({ mode: "new" })} className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">
          新增開團
        </button>
      </header>

      <div className="grid gap-3 sm:grid-cols-2">
        <input
          type="search" placeholder="搜尋 團號 / 名稱" value={queryDraft} onChange={(e) => setQueryDraft(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <select value={status} onChange={(e) => setStatus(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>團號</Th><Th>名稱</Th><Th>狀態</Th><Th>開團/收單</Th><Th>取貨截止</Th><Th className="text-right">商品數</Th><Th className="text-right">更新</Th><Th>{""}</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={8} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">{total === 0 && !query && !status ? "還沒有開團，按「新增開團」開始。" : "沒有符合條件的開團。"}</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <Td className="font-mono">
                  <button onClick={() => openEdit(r.id)} className="hover:underline">{r.campaign_no}</button>
                </Td>
                <Td>{r.name}</Td>
                <Td><StatusBadge s={r.status} /></Td>
                <Td className="text-xs text-zinc-500">
                  {r.start_at ? new Date(r.start_at).toLocaleDateString("zh-TW") : "—"}
                  {" → "}
                  {r.end_at ? new Date(r.end_at).toLocaleDateString("zh-TW") : "—"}
                </Td>
                <Td className="text-xs">{r.pickup_deadline ?? "—"}</Td>
                <Td className="text-right font-mono">{itemCounts.get(r.id) ?? 0}</Td>
                <Td className="text-right text-xs text-zinc-500">{new Date(r.updated_at).toLocaleString("zh-TW")}</Td>
                <Td>
                  <div className="flex gap-2">
                    <button
                      onClick={() => openEdit(r.id)}
                      className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                    >
                      編輯
                    </button>
                    {r.status === "open" && (
                      <a
                        href={`/campaigns/order-entry?id=${r.id}`}
                        className="text-xs text-green-600 hover:underline dark:text-green-400"
                      >
                        key 單
                      </a>
                    )}
                  </div>
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <Modal
        open={!!modal}
        onClose={() => setModal(null)}
        title={modal?.mode === "edit" ? `編輯開團 #${modal.values.campaign_no}` : "新增開團"}
        maxWidth="max-w-4xl"
      >
        {modal?.mode === "new" && (
          <CampaignForm
            onSaved={async (id) => {
              setReloadTick((t) => t + 1);
              await openEdit(id);
            }}
            onCancel={() => setModal(null)}
          />
        )}
        {modal?.mode === "edit" && (
          <div className="space-y-6">
            <CampaignForm
              initial={modal.values}
              onSaved={() => { setModal(null); setReloadTick((t) => t + 1); }}
              onCancel={() => setModal(null)}
            />
            <div className="border-t border-zinc-200 pt-4 dark:border-zinc-800">
              <CampaignItemsTable campaignId={modal.values.id!} />
            </div>
          </div>
        )}
      </Modal>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn disabled={page === 1} onClick={() => setPage(1)}>« 第一頁</PagerBtn>
          <PagerBtn disabled={page === 1} onClick={() => setPage((p) => p - 1)}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage((p) => p + 1)}>下頁 ›</PagerBtn>
          <PagerBtn disabled={page === totalPages} onClick={() => setPage(totalPages)}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return <button onClick={onClick} disabled={disabled} className="rounded-md border border-zinc-300 px-2 py-1 hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800 dark:disabled:hover:bg-transparent">{children}</button>;
}
function StatusBadge({ s }: { s: Status }) {
  const st: Record<Status, string> = {
    draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    open: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    closed: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    ordered: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
    receiving: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
    ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
    completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
    cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  };
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${st[s]}`}>{STATUS_LABEL[s]}</span>;
}
