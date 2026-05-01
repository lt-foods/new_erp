"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
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

type View = "list" | "week" | "month";

type CalRow = {
  id: number;
  campaign_no: string;
  name: string;
  status: Status;
  start_at: string | null;
};

function localDateKey(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function startOfDay(d: Date): Date {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}

function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

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
  const [modal, setModal] = useState<{ mode: "edit"; values: CampaignFormValues } | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [closingId, setClosingId] = useState<number | null>(null);
  const [finalizingId, setFinalizingId] = useState<number | null>(null);

  const [view, setView] = useState<View>(() => {
    if (typeof window === "undefined") return "list";
    const saved = window.localStorage.getItem("campaigns:view");
    return saved === "week" || saved === "month" || saved === "list" ? saved : "list";
  });

  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem("campaigns:view", view);
  }, [view]);

  const [showRecurring, setShowRecurring] = useState(false);

  const [calRows, setCalRows] = useState<CalRow[] | null>(null);
  const [calItemCounts, setCalItemCounts] = useState<Map<number, number>>(new Map());
  const [calOrderCounts, setCalOrderCounts] = useState<Map<number, number>>(new Map());
  const [monthAnchor, setMonthAnchor] = useState<Date>(() => startOfDay(new Date()));

  async function closeCampaign(id: number, name: string) {
    if (!confirm(`確定結單「${name}」？結單後可從採購單頁面「帶入該日商品」產生 PR。`)) return;
    setClosingId(id);
    try {
      const { error: rpcErr } = await getSupabase().rpc("rpc_close_campaign", {
        p_campaign_id: id,
        p_operator: (await getSupabase().auth.getUser()).data.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setClosingId(null);
    }
  }

  async function finalizeCampaign(id: number, name: string) {
    if (!confirm(`整單結算「${name}」？結算後無法復原，請確認所有顧客訂單皆已完成 / 逾期 / 取消。`)) return;
    setFinalizingId(id);
    try {
      const { error: rpcErr } = await getSupabase().rpc("rpc_finalize_campaign", {
        p_campaign_id: id,
        p_operator: (await getSupabase().auth.getUser()).data.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setFinalizingId(null);
    }
  }

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

  // Calendar (week / month) 取資料：依視圖決定範圍
  useEffect(() => {
    if (view === "list") return;
    let cancelled = false;
    (async () => {
      const today = startOfDay(new Date());
      let from: Date;
      let to: Date;
      if (view === "week") {
        from = today;
        to = addDays(today, 7);
      } else {
        from = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth(), 1);
        to = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() + 1, 1);
      }
      const { data, error } = await getSupabase()
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, status, start_at")
        .gte("start_at", from.toISOString())
        .lt("start_at", to.toISOString())
        .order("start_at", { ascending: true });
      if (cancelled) return;
      if (error) { setError(error.message); return; }
      setError(null);
      const list = (data ?? []) as CalRow[];
      setCalRows(list);

      // 補商品數 + 訂單數
      const ids = list.map((r) => r.id);
      if (ids.length > 0) {
        const sb = getSupabase();
        const [itemRes, orderRes] = await Promise.all([
          sb.from("campaign_items").select("campaign_id").in("campaign_id", ids),
          sb.from("customer_orders").select("campaign_id").in("campaign_id", ids),
        ]);
        if (cancelled) return;
        const im = new Map<number, number>();
        const om = new Map<number, number>();
        for (const id of ids) { im.set(id, 0); om.set(id, 0); }
        for (const it of itemRes.data ?? []) im.set(it.campaign_id, (im.get(it.campaign_id) ?? 0) + 1);
        for (const o of orderRes.data ?? []) om.set(o.campaign_id, (om.get(o.campaign_id) ?? 0) + 1);
        setCalItemCounts(im);
        setCalOrderCounts(om);
      } else {
        setCalItemCounts(new Map());
        setCalOrderCounts(new Map());
      }
    })();
    return () => { cancelled = true; };
  }, [view, monthAnchor, reloadTick]);

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
        <div className="flex gap-2">
          <button
            onClick={() => setShowRecurring(true)}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            🔁 批次建立
          </button>
          <Link href="/products?mode=campaign" className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200">
            + 從商品開團
          </Link>
        </div>
      </header>

      <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["list", "week", "month"] as View[]).map((v) => (
          <button
            key={v}
            onClick={() => setView(v)}
            className={
              view === v
                ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {v === "list" ? "列表" : v === "week" ? "未來 7 天" : "月曆"}
          </button>
        ))}
      </div>

      {view === "list" && (
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
      )}

      {view === "month" && (
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <button
              onClick={() => setMonthAnchor(new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() - 1, 1))}
              className="rounded-md border border-zinc-300 px-2 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >‹ 上月</button>
            <span className="font-medium">
              {monthAnchor.getFullYear()} 年 {monthAnchor.getMonth() + 1} 月
            </span>
            <button
              onClick={() => setMonthAnchor(new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() + 1, 1))}
              className="rounded-md border border-zinc-300 px-2 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >下月 ›</button>
            <button
              onClick={() => setMonthAnchor(startOfDay(new Date()))}
              className="rounded-md border border-zinc-300 px-2 py-1 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >今天</button>
          </div>
          <span className="text-sm text-zinc-500">
            {calRows === null ? "載入中…" : `${calRows.length} 場`}
          </span>
        </div>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-medium">讀取失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}

      {view !== "list" && (
        <CalendarView
          view={view}
          rows={calRows}
          monthAnchor={monthAnchor}
          itemCounts={calItemCounts}
          orderCounts={calOrderCounts}
          onPick={(id) => openEdit(id)}
        />
      )}

      {view === "list" && (
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
                      <Link
                        href={`/campaigns/order-entry?id=${r.id}`}
                        className="text-xs text-green-600 hover:underline dark:text-green-400"
                      >
                        加單
                      </Link>
                    )}
                    {r.status === "open" && (
                      <button
                        onClick={() => closeCampaign(r.id, r.name)}
                        disabled={closingId === r.id}
                        className="text-xs text-amber-600 hover:underline disabled:opacity-50 dark:text-amber-400"
                      >
                        {closingId === r.id ? "結單中…" : "結單"}
                      </button>
                    )}
                    {(["closed", "ordered", "receiving", "ready"] as Status[]).includes(r.status) && (
                      <button
                        onClick={() => finalizeCampaign(r.id, r.name)}
                        disabled={finalizingId === r.id}
                        className="text-xs text-purple-600 hover:underline disabled:opacity-50 dark:text-purple-400"
                      >
                        {finalizingId === r.id ? "結算中…" : "結算"}
                      </button>
                    )}
                  </div>
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      )}

      <Modal
        open={showRecurring}
        onClose={() => setShowRecurring(false)}
        title="批次建立草稿開團"
        maxWidth="max-w-2xl"
      >
        {showRecurring && (
          <RecurringCampaignsForm
            onClose={() => setShowRecurring(false)}
            onCreated={() => { setShowRecurring(false); setReloadTick((t) => t + 1); }}
          />
        )}
      </Modal>

      <Modal
        open={!!modal}
        onClose={() => setModal(null)}
        title={modal ? `編輯開團 #${modal.values.campaign_no}｜${modal.values.name}` : ""}
        maxWidth="max-w-4xl"
      >
        {modal && (
          <div className="space-y-6">
            <CampaignItemsTable campaignId={modal.values.id!} />
            <div className="border-t border-zinc-200 pt-4 dark:border-zinc-800">
              <CampaignForm
                initial={modal.values}
                onSaved={() => { setModal(null); setReloadTick((t) => t + 1); }}
                onCancel={() => setModal(null)}
              />
            </div>
          </div>
        )}
      </Modal>

      {view === "list" && totalPages > 1 && (
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

// ============================================================
// Calendar (week / month) view — 點卡片 → 開編輯 modal（共用 openEdit）
// ============================================================
function CalendarView({
  view,
  rows,
  monthAnchor,
  itemCounts,
  orderCounts,
  onPick,
}: {
  view: View;
  rows: CalRow[] | null;
  monthAnchor: Date;
  itemCounts: Map<number, number>;
  orderCounts: Map<number, number>;
  onPick: (id: number) => void;
}) {
  if (rows === null) {
    return <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>;
  }
  // 按日期分桶（key = YYYY-MM-DD）
  const buckets = new Map<string, CalRow[]>();
  for (const r of rows) {
    if (!r.start_at) continue;
    const key = localDateKey(new Date(r.start_at));
    const arr = buckets.get(key) ?? [];
    arr.push(r);
    buckets.set(key, arr);
  }

  if (view === "week") {
    const today = startOfDay(new Date());
    const days = Array.from({ length: 7 }, (_, i) => addDays(today, i));
    const weekdayCh = "日一二三四五六";
    return (
      <div className="grid gap-2 md:grid-cols-7">
        {days.map((d) => {
          const key = localDateKey(d);
          const list = buckets.get(key) ?? [];
          const isToday = key === localDateKey(new Date());
          return (
            <div
              key={key}
              className={`flex min-h-[200px] flex-col rounded-md border ${
                isToday
                  ? "border-zinc-900 dark:border-zinc-100"
                  : "border-zinc-200 dark:border-zinc-800"
              }`}
            >
              <div
                className={`flex items-baseline justify-between border-b px-3 py-2 ${
                  isToday
                    ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                    : "border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900"
                }`}
              >
                <div>
                  <div className={`text-[11px] ${isToday ? "opacity-90" : "text-zinc-500"}`}>
                    {d.getMonth() + 1} 月
                  </div>
                  <div className="flex items-baseline gap-1.5">
                    <span className="text-xl font-semibold leading-none">{d.getDate()}</span>
                    <span className={`text-xs ${isToday ? "opacity-90" : "text-zinc-500"}`}>
                      週{weekdayCh[d.getDay()]}
                    </span>
                  </div>
                </div>
                {isToday && (
                  <span className="rounded bg-white px-1.5 py-0.5 text-[10px] font-medium text-zinc-900 dark:bg-zinc-900 dark:text-zinc-100">
                    今天
                  </span>
                )}
              </div>
              <div className="flex-1 space-y-2 p-2">
                {list.length === 0 && (
                  <div className="py-4 text-center text-[11px] text-zinc-400">—</div>
                )}
                {list.map((r) => (
                  <CampaignCard
                    key={r.id}
                    r={r}
                    itemCount={itemCounts.get(r.id) ?? 0}
                    orderCount={orderCounts.get(r.id) ?? 0}
                    onPick={onPick}
                  />
                ))}
              </div>
            </div>
          );
        })}
      </div>
    );
  }

  // month
  const year = monthAnchor.getFullYear();
  const month = monthAnchor.getMonth();
  const firstOfMonth = new Date(year, month, 1);
  const startWeekday = firstOfMonth.getDay(); // 0=Sun ... 6=Sat
  // 從這週日開始，一直渲到 6 週（42 格）
  const gridStart = addDays(firstOfMonth, -startWeekday);
  const cells = Array.from({ length: 42 }, (_, i) => addDays(gridStart, i));
  const todayKey = localDateKey(new Date());

  return (
    <div>
      <div className="grid grid-cols-7 border-l border-t border-zinc-200 dark:border-zinc-800">
        {"日一二三四五六".split("").map((d) => (
          <div
            key={d}
            className="border-b border-r border-zinc-200 bg-zinc-50 px-2 py-1.5 text-center text-xs font-medium text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400"
          >
            {d}
          </div>
        ))}
        {cells.map((d) => {
          const key = localDateKey(d);
          const inMonth = d.getMonth() === month;
          const isToday = key === todayKey;
          const list = buckets.get(key) ?? [];
          return (
            <div
              key={key}
              className={`min-h-[110px] border-b border-r border-zinc-200 p-1.5 dark:border-zinc-800 ${
                inMonth ? "bg-white dark:bg-zinc-950" : "bg-zinc-50 dark:bg-zinc-900/40"
              }`}
            >
              <div
                className={`mb-1 text-right text-xs ${
                  isToday
                    ? "font-bold text-zinc-900 dark:text-zinc-100"
                    : inMonth
                    ? "text-zinc-600 dark:text-zinc-400"
                    : "text-zinc-400 dark:text-zinc-600"
                }`}
              >
                {d.getDate()}
              </div>
              <div className="space-y-1">
                {list.slice(0, 3).map((r) => (
                  <CampaignCard
                    key={r.id}
                    r={r}
                    compact
                    itemCount={itemCounts.get(r.id) ?? 0}
                    orderCount={orderCounts.get(r.id) ?? 0}
                    onPick={onPick}
                  />
                ))}
                {list.length > 3 && (
                  <div className="text-[10px] text-zinc-500">+{list.length - 3} 場</div>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ============================================================
// RecurringCampaignsForm — 批次建立草稿開團（每月 N 號 / 每週 N / 每隔 N 天）
// ============================================================

type RecMode = "monthly" | "weekly" | "daily";

type ActiveProductRow = {
  id: number;
  product_code: string;
  name: string;
  skus: { id: number; sku_code: string; variant_name: string | null; status: string }[];
};

function RecurringCampaignsForm({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: () => void;
}) {
  const [products, setProducts] = useState<ActiveProductRow[] | null>(null);
  const [productId, setProductId] = useState<number | null>(null);
  const [skuId, setSkuId] = useState<number | null>(null);
  const [mode, setMode] = useState<RecMode>("monthly");
  const [anchorDate, setAnchorDate] = useState<string>(() => localDateKey(addDays(startOfDay(new Date()), 1)));
  const [time, setTime] = useState<string>("08:00");
  const [count, setCount] = useState<number>(3);
  const [intervalDays, setIntervalDays] = useState<number>(7);
  const [dayOfMonth, setDayOfMonth] = useState<number>(() => new Date().getDate());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: prods, error } = await sb
        .from("products")
        .select("id, product_code, name, status")
        .eq("status", "active")
        .order("product_code");
      if (cancelled) return;
      if (error) { setError(error.message); return; }
      const ids = (prods ?? []).map((p) => p.id);
      let skusByProd = new Map<number, ActiveProductRow["skus"]>();
      if (ids.length > 0) {
        const { data: skus } = await sb
          .from("skus")
          .select("id, product_id, sku_code, variant_name, status")
          .in("product_id", ids)
          .eq("status", "active")
          .order("id");
        for (const s of (skus ?? []) as { id: number; product_id: number; sku_code: string; variant_name: string | null; status: string }[]) {
          const arr = skusByProd.get(s.product_id) ?? [];
          arr.push({ id: s.id, sku_code: s.sku_code, variant_name: s.variant_name, status: s.status });
          skusByProd.set(s.product_id, arr);
        }
      }
      const list: ActiveProductRow[] = (prods ?? [])
        .map((p) => ({ ...p, skus: skusByProd.get(p.id) ?? [] }))
        .filter((p) => p.skus.length > 0);
      setProducts(list);
    })();
    return () => { cancelled = true; };
  }, []);

  const selectedProduct = products?.find((p) => p.id === productId) ?? null;

  // 切換 product 時、自動選第一個 sku
  useEffect(() => {
    if (selectedProduct && selectedProduct.skus.length > 0) {
      if (!selectedProduct.skus.some((s) => s.id === skuId)) {
        setSkuId(selectedProduct.skus[0].id);
      }
    } else {
      setSkuId(null);
    }
  }, [selectedProduct, skuId]);

  // 計算預覽日期
  // monthly: 使用 anchorDate 的年月當起點 + dayOfMonth 為固定日；遇 30/31 不存在月份用該月最後一天
  const previewDates = (() => {
    if (!anchorDate) return [];
    const [y, m, d] = anchorDate.split("-").map(Number);
    const result: Date[] = [];
    const n = Math.max(1, Math.min(count, 24));
    for (let i = 0; i < n; i++) {
      if (mode === "monthly") {
        const targetMonth = m - 1 + i;
        const lastDay = new Date(y, targetMonth + 1, 0).getDate();
        const day = Math.min(dayOfMonth, lastDay);
        result.push(new Date(y, targetMonth, day));
      } else if (mode === "weekly") {
        const base = new Date(y, m - 1, d);
        result.push(new Date(base.getFullYear(), base.getMonth(), base.getDate() + i * 7));
      } else {
        const base = new Date(y, m - 1, d);
        result.push(new Date(base.getFullYear(), base.getMonth(), base.getDate() + i * intervalDays));
      }
    }
    return result;
  })();

  async function handleSubmit() {
    setError(null);
    if (!productId || !skuId || !selectedProduct) {
      setError("請先選擇商品 / 規格");
      return;
    }
    if (previewDates.length === 0) {
      setError("無預覽日期");
      return;
    }
    setBusy(true);
    setProgress({ done: 0, total: previewDates.length });
    const sb = getSupabase();

    const errors: string[] = [];
    for (let i = 0; i < previewDates.length; i++) {
      const d = previewDates[i];
      const [hh, mm] = time.split(":").map(Number);
      const startAt = new Date(d.getFullYear(), d.getMonth(), d.getDate(), hh ?? 8, mm ?? 0);
      const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
      const campaignNo = `GB${ymd}-S${String(skuId).padStart(6, "0")}`;

      try {
        const { data: campId, error: cErr } = await sb.rpc("rpc_upsert_campaign", {
          p_id: null,
          p_campaign_no: campaignNo,
          p_name: selectedProduct.name,
          p_description: null,
          p_status: "draft",
          p_close_type: "regular",
          p_start_at: startAt.toISOString(),
          p_end_at: null,
          p_pickup_deadline: null,
          p_pickup_days: null,
          p_total_cap_qty: null,
          p_notes: `recurring batch (${mode}) for product ${selectedProduct.product_code}`,
        });
        if (cErr) throw cErr;
        const { error: iErr } = await sb.rpc("rpc_upsert_campaign_item", {
          p_id: null,
          p_campaign_id: Number(campId),
          p_sku_id: skuId,
          p_unit_price: 0,
          p_cap_qty: null,
          p_sort_order: 0,
          p_notes: null,
        });
        if (iErr) throw iErr;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        errors.push(`${campaignNo}: ${msg}`);
      }
      setProgress({ done: i + 1, total: previewDates.length });
    }

    setBusy(false);
    if (errors.length > 0) {
      setError(`完成 ${previewDates.length - errors.length} / ${previewDates.length}\n失敗：\n${errors.join("\n")}`);
    } else {
      onCreated();
    }
  }

  if (products === null) {
    return <div className="p-4 text-center text-sm text-zinc-500">載入上架商品…</div>;
  }
  if (products.length === 0) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-zinc-700 dark:text-zinc-300">目前沒有上架商品。請先到商品頁把商品設為「上架」（需有規格 + 三種價格）。</p>
        <button onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700">關閉</button>
      </div>
    );
  }

  const inputCls = "w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="space-y-4">
      {/* 商品 / 規格 */}
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">商品（上架中）</span>
          <select value={productId ?? ""} onChange={(e) => setProductId(Number(e.target.value) || null)} className={inputCls}>
            <option value="">— 請選 —</option>
            {products.map((p) => (
              <option key={p.id} value={p.id}>{p.product_code} {p.name}</option>
            ))}
          </select>
        </label>

        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">規格</span>
          <select value={skuId ?? ""} onChange={(e) => setSkuId(Number(e.target.value) || null)} disabled={!selectedProduct} className={inputCls}>
            <option value="">— 請選商品先 —</option>
            {selectedProduct?.skus.map((s) => (
              <option key={s.id} value={s.id}>{s.sku_code}{s.variant_name ? ` / ${s.variant_name}` : ""}</option>
            ))}
          </select>
        </label>
      </div>

      {/* 重複頻率 */}
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">重複頻率</span>
          <select value={mode} onChange={(e) => setMode(e.target.value as RecMode)} className={inputCls}>
            <option value="monthly">每月</option>
            <option value="weekly">每週</option>
            <option value="daily">每隔 N 天</option>
          </select>
        </label>

        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">第一場日期</span>
          <input type="date" value={anchorDate} onChange={(e) => setAnchorDate(e.target.value)} className={inputCls} />
        </label>

        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">開團時間</span>
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} className={inputCls} />
        </label>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        {mode === "monthly" && (
          <label className="block space-y-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">每月 N 號（1-31，超過該月天數會用該月最後一天）</span>
            <input type="number" min={1} max={31} value={dayOfMonth} onChange={(e) => setDayOfMonth(Math.max(1, Math.min(31, Number(e.target.value) || 1)))} className={inputCls} />
          </label>
        )}
        {mode === "daily" && (
          <label className="block space-y-1 text-sm">
            <span className="text-zinc-600 dark:text-zinc-400">每隔幾天</span>
            <input type="number" min={1} max={60} value={intervalDays} onChange={(e) => setIntervalDays(Math.max(1, Math.min(60, Number(e.target.value) || 1)))} className={inputCls} />
          </label>
        )}
        <label className="block space-y-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">建立場次（最多 24）</span>
          <input type="number" min={1} max={24} value={count} onChange={(e) => setCount(Math.max(1, Math.min(24, Number(e.target.value) || 1)))} className={inputCls} />
        </label>
      </div>

      {/* 預覽 */}
      <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
        <div className="mb-2 text-xs font-medium text-zinc-700 dark:text-zinc-300">
          將建立 {previewDates.length} 場開團（draft）：
        </div>
        <div className="flex flex-wrap gap-1.5">
          {previewDates.map((d, i) => (
            <span key={i} className="rounded bg-zinc-100 px-2 py-0.5 text-xs text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
              {d.getFullYear()}/{d.getMonth() + 1}/{d.getDate()}（週{"日一二三四五六"[d.getDay()]}）
            </span>
          ))}
        </div>
      </div>

      {error && (
        <div className="whitespace-pre-wrap rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {progress && (
        <div className="text-xs text-zinc-500">
          建立中 {progress.done} / {progress.total}
        </div>
      )}

      <div className="flex items-center gap-2">
        <button
          onClick={handleSubmit}
          disabled={busy || !productId || !skuId}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
        >
          {busy ? `建立中… ${progress?.done ?? 0}/${progress?.total ?? 0}` : `建立 ${previewDates.length} 場`}
        </button>
        <button onClick={onClose} disabled={busy} className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700">取消</button>
      </div>
    </div>
  );
}

function CampaignCard({
  r,
  compact,
  itemCount,
  orderCount,
  onPick,
}: {
  r: CalRow;
  compact?: boolean;
  itemCount: number;
  orderCount: number;
  onPick: (id: number) => void;
}) {
  const statusBadgeColor: Record<Status, string> = {
    draft: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-200",
    open: "bg-green-200 text-green-800 dark:bg-green-900 dark:text-green-200",
    closed: "bg-amber-200 text-amber-800 dark:bg-amber-900 dark:text-amber-200",
    ordered: "bg-blue-200 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
    receiving: "bg-indigo-200 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200",
    ready: "bg-emerald-200 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200",
    completed: "bg-zinc-300 text-zinc-700 dark:bg-zinc-600 dark:text-zinc-200",
    cancelled: "bg-red-200 text-red-800 dark:bg-red-900 dark:text-red-200",
  };
  const compactBg: Record<Status, string> = {
    draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    open: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    closed: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    ordered: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
    receiving: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
    ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
    completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
    cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  };

  if (compact) {
    return (
      <button
        onClick={() => onPick(r.id)}
        className={`block w-full truncate rounded px-1.5 py-0.5 text-left text-[10px] ${compactBg[r.status]} hover:opacity-80`}
        title={`${r.campaign_no}｜${r.name}｜${STATUS_LABEL[r.status]}｜${itemCount} 商品｜${orderCount} 單`}
      >
        <span className="font-medium">{r.name || r.campaign_no}</span>
      </button>
    );
  }

  return (
    <div className="rounded-md border border-zinc-200 bg-white p-2.5 shadow-sm transition hover:border-zinc-400 hover:shadow dark:border-zinc-700 dark:bg-zinc-900 dark:hover:border-zinc-500">
      {/* 標題：商品名稱 + 狀態 */}
      <div className="mb-1.5 flex items-start justify-between gap-1.5">
        <button
          onClick={() => onPick(r.id)}
          className="flex-1 truncate text-left text-sm font-semibold text-zinc-900 hover:underline dark:text-zinc-100"
          title={`${r.campaign_no}｜${r.name}`}
        >
          {r.name || r.campaign_no}
        </button>
        <span className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${statusBadgeColor[r.status]}`}>
          {STATUS_LABEL[r.status]}
        </span>
      </div>

      {/* 團號 */}
      <button
        onClick={() => onPick(r.id)}
        className="mb-2 block w-full truncate text-left font-mono text-[10px] text-zinc-500 hover:underline"
      >
        {r.campaign_no}
      </button>

      {/* 數據：商品數 / 訂單數 */}
      <div className="mb-2 flex gap-2 text-[11px]">
        <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
          📦 {itemCount} 商品
        </span>
        <span className={`rounded px-1.5 py-0.5 ${orderCount > 0 ? "bg-blue-100 font-medium text-blue-800 dark:bg-blue-950 dark:text-blue-300" : "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"}`}>
          🛒 {orderCount} 單
        </span>
      </div>

      {/* 動作 */}
      <div className="flex flex-wrap gap-1">
        {r.status === "open" && (
          <Link
            href={`/campaigns/order-entry?id=${r.id}`}
            className="rounded border border-green-400 bg-green-50 px-2 py-0.5 text-[11px] font-medium text-green-700 hover:bg-green-100 dark:border-green-700 dark:bg-green-950 dark:text-green-300 dark:hover:bg-green-900"
          >
            + 加單
          </Link>
        )}
        <button
          onClick={() => onPick(r.id)}
          className="rounded border border-zinc-300 px-2 py-0.5 text-[11px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400 dark:hover:bg-zinc-800"
        >
          編輯
        </button>
      </div>
    </div>
  );
}
