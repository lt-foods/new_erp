"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { withBasePath } from "@/lib/basePath";
import { DatePicker } from "@/components/DatePicker";

type ReceivableStatus = "pending" | "partially_paid" | "paid" | "cancelled" | "disputed";
type SourceType = "store_monthly_settlement" | "manual";

type Receivable = {
  id: number;
  receivable_no: string;
  store_id: number;
  source_type: SourceType;
  source_id: number | null;
  bill_date: string;
  due_date: string;
  amount: number;
  paid_amount: number;
  status: ReceivableStatus;
  currency: string;
  notes: string | null;
  created_at: string;
  updated_at: string;
};

type Store = { id: number; code: string; name: string };

const STATUS_LABEL: Record<ReceivableStatus, string> = {
  pending: "未收",
  partially_paid: "部分已收",
  paid: "已收清",
  cancelled: "已取消",
  disputed: "爭議中",
};
const STATUS_COLOR: Record<ReceivableStatus, string> = {
  pending: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  partially_paid: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  paid: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};
const SOURCE_LABEL: Record<SourceType, string> = {
  store_monthly_settlement: "店月結算",
  manual: "手動建立",
};

const PAGE_SIZE = 50;

export default function ReceivablesPage() {
  const [rows, setRows] = useState<Receivable[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  const [statusFilter, setStatusFilter] = useState<string>("");
  const [storeFilter, setStoreFilter] = useState<string>("");
  const [page, setPage] = useState(1);

  const [stores, setStores] = useState<Map<number, Store>>(new Map());
  const [detail, setDetail] = useState<Receivable | null>(null);

  useEffect(() => { setPage(1); }, [statusFilter, storeFilter]);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data } = await sb.from("stores").select("id, code, name").order("name");
      const m = new Map<number, Store>();
      for (const s of (data ?? []) as Store[]) m.set(s.id, s);
      setStores(m);
    })();
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("store_receivables")
          .select(
            "id, receivable_no, store_id, source_type, source_id, bill_date, due_date, amount, paid_amount, status, currency, notes, created_at, updated_at",
            { count: "exact" },
          )
          .order("bill_date", { ascending: false })
          .order("id", { ascending: false })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (statusFilter) q = q.eq("status", statusFilter);
        if (storeFilter) q = q.eq("store_id", Number(storeFilter));

        const { data, count, error: e1 } = await q;
        if (cancelled) return;
        if (e1) { setError(e1.message); return; }
        setError(null);
        setRows((data ?? []) as Receivable[]);
        setTotal(count ?? 0);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [statusFilter, storeFilter, page, reloadTick]);

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  const stats = useMemo(() => {
    if (!rows) return { totalAmount: 0, totalPaid: 0, totalUnpaid: 0, pendingCount: 0 };
    let totalAmount = 0, totalPaid = 0, pendingCount = 0;
    for (const b of rows) {
      if (b.status === "cancelled") continue;
      totalAmount += Number(b.amount);
      totalPaid += Number(b.paid_amount);
      if (b.status === "pending" || b.status === "partially_paid") pendingCount++;
    }
    return { totalAmount, totalPaid, totalUnpaid: totalAmount - totalPaid, pendingCount };
  }, [rows]);

  const today = new Date().toISOString().slice(0, 10);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">HQ 應收帳款</h1>
        <p className="text-sm text-zinc-500">
          各分店欠 HQ 的貨款（從月結算來）。{loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（${fromIdx}-${toIdx}）`}
        </p>
      </header>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="本頁總額" value={`$${stats.totalAmount.toLocaleString()}`} />
        <Stat label="本頁已收" value={`$${stats.totalPaid.toLocaleString()}`} accent="positive" />
        <Stat label="本頁未收" value={`$${stats.totalUnpaid.toLocaleString()}`} accent={stats.totalUnpaid > 0 ? "negative" : "neutral"} />
        <Stat label="未結清張數" value={String(stats.pendingCount)} />
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部狀態</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
        <select value={storeFilter} onChange={(e) => setStoreFilter(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800">
          <option value="">全部分店</option>
          {Array.from(stores.values()).map((s) => (
            <option key={s.id} value={s.id}>{s.code} {s.name}</option>
          ))}
        </select>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>應收單號</Th>
              <Th>分店</Th>
              <Th>來源</Th>
              <Th>帳單日</Th>
              <Th>到期日</Th>
              <Th className="text-right">金額</Th>
              <Th className="text-right">已收</Th>
              <Th className="text-right">未收</Th>
              <Th>狀態</Th>
              <Th className="text-right">操作</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={10} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={10} className="p-6 text-center text-zinc-500">尚無應收帳款。</td></tr>
            ) : rows.map((b) => {
              const store = stores.get(b.store_id);
              const unpaid = Number(b.amount) - Number(b.paid_amount);
              const overdue = b.status !== "paid" && b.status !== "cancelled" && b.due_date < today;
              return (
                <tr key={b.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="font-mono text-xs">{b.receivable_no}</Td>
                  <Td className="text-xs">
                    <span className="font-mono text-zinc-500">{store?.code ?? "—"}</span>{" "}
                    <span>{store?.name ?? `#${b.store_id}`}</span>
                  </Td>
                  <Td className="text-xs">
                    <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] dark:bg-zinc-800">{SOURCE_LABEL[b.source_type]}</span>
                  </Td>
                  <Td className="text-xs">{b.bill_date}</Td>
                  <Td className={`text-xs ${overdue ? "text-rose-600 font-medium" : ""}`}>
                    {b.due_date}{overdue && " ⚠️"}
                  </Td>
                  <Td className="text-right font-mono">${Number(b.amount).toLocaleString()}</Td>
                  <Td className="text-right font-mono text-emerald-600">${Number(b.paid_amount).toLocaleString()}</Td>
                  <Td className={`text-right font-mono ${unpaid > 0 ? "text-rose-600" : "text-zinc-400"}`}>${unpaid.toLocaleString()}</Td>
                  <Td><span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[b.status]}`}>{STATUS_LABEL[b.status]}</span></Td>
                  <Td className="text-right">
                    <button
                      onClick={() => setDetail(b)}
                      className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      詳情
                    </button>
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <button disabled={page <= 1} onClick={() => setPage((p) => Math.max(1, p - 1))}
            className="rounded-md border border-zinc-300 px-3 py-1 disabled:opacity-50 dark:border-zinc-700">
            上一頁
          </button>
          <span className="text-zinc-500">{page} / {totalPages}</span>
          <button disabled={page >= totalPages} onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            className="rounded-md border border-zinc-300 px-3 py-1 disabled:opacity-50 dark:border-zinc-700">
            下一頁
          </button>
        </div>
      )}

      <Modal
        open={detail !== null}
        onClose={() => setDetail(null)}
        title={detail ? `應收帳款 ${detail.receivable_no}` : ""}
        maxWidth="max-w-4xl"
      >
        {detail && (
          <ReceivableDetail
            receivable={detail}
            store={stores.get(detail.store_id) ?? null}
            onChanged={() => {
              setDetail(null);
              setReloadTick((t) => t + 1);
            }}
          />
        )}
      </Modal>
    </div>
  );
}

// ============================================================
// Receivable 詳情 Modal
// ============================================================

type Payment = {
  id: number;
  payment_no: string;
  amount: number;
  method: string;
  paid_at: string;
  notes: string | null;
};

const PAYMENT_METHOD_LABEL: Record<string, string> = {
  cash: "現金",
  bank_transfer: "銀行轉帳",
  check: "支票",
  offset: "對沖",
  other: "其他",
};

function ReceivableDetail({
  receivable,
  store,
  onChanged,
}: {
  receivable: Receivable;
  store: Store | null;
  onChanged: () => void;
}) {
  const [payments, setPayments] = useState<Payment[] | null>(null);
  const [showPayForm, setShowPayForm] = useState(false);

  const unpaid = Number(receivable.amount) - Number(receivable.paid_amount);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data } = await sb
        .from("store_receivable_payments")
        .select("id, payment_no, amount, method, paid_at, notes")
        .eq("receivable_id", receivable.id)
        .order("paid_at", { ascending: false });
      if (cancelled) return;
      setPayments((data ?? []) as Payment[]);
    })();
    return () => { cancelled = true; };
  }, [receivable.id]);

  return (
    <div className="space-y-4 text-sm">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label="分店" value={store ? `${store.code} ${store.name}` : `#${receivable.store_id}`} />
        <Stat label="來源" value={SOURCE_LABEL[receivable.source_type]} />
        <Stat label="狀態" value={STATUS_LABEL[receivable.status]} />
        <Stat label="總金額" value={`$${Number(receivable.amount).toLocaleString()}`} />
        <Stat label="已收" value={`$${Number(receivable.paid_amount).toLocaleString()}`} accent="positive" />
        <Stat label="未收" value={`$${unpaid.toLocaleString()}`} accent={unpaid > 0 ? "negative" : "neutral"} />
        <Stat label="帳單日" value={receivable.bill_date} />
        <Stat label="到期日" value={receivable.due_date} />
      </div>

      {receivable.notes && (
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300">
          <span className="text-zinc-500">備註：</span>{receivable.notes}
        </div>
      )}

      {receivable.source_type === "store_monthly_settlement" && receivable.source_id && (
        <div className="flex justify-end">
          <a
            href={withBasePath(`/finance/receivables/print?settlement_id=${receivable.source_id}`)}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-md border border-blue-300 bg-blue-50 px-3 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
          >
            📄 列印對帳單
          </a>
        </div>
      )}

      <div>
        <div className="mb-2 flex items-center justify-between">
          <span className="text-sm font-medium">收款記錄（{payments?.length ?? 0} 筆）</span>
          {unpaid > 0 && receivable.status !== "cancelled" && (
            <button
              onClick={() => setShowPayForm(!showPayForm)}
              className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white shadow-sm hover:bg-emerald-700"
            >
              {showPayForm ? "取消" : "💰 標記收款"}
            </button>
          )}
        </div>
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <Th>收款單號</Th>
                <Th>收款日</Th>
                <Th>方式</Th>
                <Th className="text-right">金額</Th>
                <Th>備註</Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {payments === null ? (
                <tr><td colSpan={5} className="p-3 text-center text-zinc-500">載入中…</td></tr>
              ) : payments.length === 0 ? (
                <tr><td colSpan={5} className="p-3 text-center text-zinc-500">尚未收款。</td></tr>
              ) : payments.map((p) => (
                <tr key={p.id}>
                  <Td className="font-mono text-xs">{p.payment_no}</Td>
                  <Td className="text-xs">{p.paid_at?.slice(0, 10)}</Td>
                  <Td className="text-xs">{PAYMENT_METHOD_LABEL[p.method] ?? p.method}</Td>
                  <Td className="text-right font-mono">${Number(p.amount).toLocaleString()}</Td>
                  <Td className="text-xs text-zinc-500">{p.notes ?? "—"}</Td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {showPayForm && (
        <PaymentForm
          receivable={receivable}
          unpaid={unpaid}
          store={store}
          onDone={() => { setShowPayForm(false); onChanged(); }}
        />
      )}
    </div>
  );
}

function PaymentForm({
  receivable,
  unpaid,
  store,
  onDone,
}: {
  receivable: Receivable;
  unpaid: number;
  store: Store | null;
  onDone: () => void;
}) {
  const [amount, setAmount] = useState(unpaid);
  const [method, setMethod] = useState("bank_transfer");
  const [paidAt, setPaidAt] = useState(new Date().toISOString().slice(0, 10));
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit() {
    if (amount <= 0 || amount > unpaid) {
      setErr(`金額必須在 0 ~ ${unpaid} 之間`);
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      const { error } = await sb.rpc("rpc_record_store_receivable_payment", {
        p_receivable_id: receivable.id,
        p_amount: amount,
        p_method: method,
        p_paid_at: paidAt,
        p_operator: operator,
        p_notes: notes || null,
      });
      if (error) throw new Error(error.message);
      onDone();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="rounded-md border border-emerald-200 bg-emerald-50 p-4 dark:border-emerald-900 dark:bg-emerald-950">
      <h3 className="mb-3 text-sm font-medium">收款自 {store?.name ?? `分店 #${receivable.store_id}`}</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">收款金額（最多 ${unpaid.toLocaleString()}）</span>
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(Number(e.target.value))}
            min={0}
            max={unpaid}
            step={0.01}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">收款方式</span>
          <select
            value={method}
            onChange={(e) => setMethod(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            {Object.entries(PAYMENT_METHOD_LABEL).map(([v, l]) => (
              <option key={v} value={v}>{l}</option>
            ))}
          </select>
        </label>
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">收款日</span>
          <DatePicker
            value={paidAt}
            onChange={setPaidAt}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-left text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
          />
        </label>
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">備註</span>
          <input
            type="text"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
      </div>
      {err && <p className="mt-2 text-xs text-rose-600">{err}</p>}
      <div className="mt-3 flex justify-end">
        <button
          onClick={submit}
          disabled={busy || amount <= 0 || amount > unpaid}
          className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-emerald-700 disabled:opacity-50"
        >
          {busy ? "處理中…" : `💰 確認收款 $${Number(amount).toLocaleString()}`}
        </button>
      </div>
    </div>
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
