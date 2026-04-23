"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type Status = "active" | "inactive" | "blocked" | "merged" | "deleted";
type SortKey = "updated_at" | "member_no" | "name";
type SortDir = "asc" | "desc";

type MemberRow = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  tier_id: number | null;
  status: Status;
  updated_at: string;
};

type Tier = { id: number; code: string; name: string };

const STATUS_LABEL: Record<Status, string> = {
  active: "活躍",
  inactive: "停用",
  blocked: "封鎖",
  merged: "已合併",
  deleted: "已刪除",
};

const PAGE_SIZE = 50;

export default function MembersListPage() {
  const [rows, setRows] = useState<MemberRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [tierId, setTierId] = useState<string>("");
  const [status, setStatus] = useState<string>("");
  const [sortBy, setSortBy] = useState<SortKey>("updated_at");
  const [sortDir, setSortDir] = useState<SortDir>("desc");
  const [page, setPage] = useState(1);

  const [tiers, setTiers] = useState<Tier[]>([]);
  const [balances, setBalances] = useState<Map<number, { points: number; wallet: number }>>(new Map());

  useEffect(() => {
    const t = setTimeout(() => {
      setQuery(queryDraft);
      setPage(1);
    }, 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  useEffect(() => {
    setPage(1);
  }, [tierId, status, sortBy, sortDir]);

  useEffect(() => {
    (async () => {
      const { data } = await getSupabase()
        .from("member_tiers")
        .select("id, code, name")
        .order("sort_order");
      if (data) setTiers(data as Tier[]);
    })();
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("members")
          .select("id, member_no, name, phone, tier_id, status, updated_at", { count: "exact" })
          .order(sortBy, { ascending: sortDir === "asc" })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (query.trim()) {
          const safe = query.replace(/[%,()]/g, " ").trim();
          q = q.or(`name.ilike.%${safe}%,phone.ilike.%${safe}%,member_no.ilike.%${safe}%`);
        }
        if (tierId) q = q.eq("tier_id", Number(tierId));
        if (status) q = q.eq("status", status);

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) {
          setError(error.message);
          return;
        }
        setError(null);
        setRows((data ?? []) as MemberRow[]);
        setTotal(count ?? 0);

        const ids = (data ?? []).map((r) => r.id);
        if (ids.length) {
          const [pts, wal] = await Promise.all([
            getSupabase().from("member_points_balance").select("member_id, balance").in("member_id", ids),
            getSupabase().from("wallet_balances").select("member_id, balance").in("member_id", ids),
          ]);
          const m = new Map<number, { points: number; wallet: number }>();
          for (const id of ids) m.set(id, { points: 0, wallet: 0 });
          for (const p of pts.data ?? []) {
            const cur = m.get(p.member_id)!;
            cur.points = Number(p.balance) || 0;
          }
          for (const w of wal.data ?? []) {
            const cur = m.get(w.member_id)!;
            cur.wallet = Number(w.balance) || 0;
          }
          if (!cancelled) setBalances(m);
        } else {
          setBalances(new Map());
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [query, tierId, status, sortBy, sortDir, page]);

  const tierMap = useMemo(() => new Map(tiers.map((t) => [t.id, t])), [tiers]);
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const fromIdx = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const toIdx = Math.min(page * PAGE_SIZE, total);

  function toggleSort(k: SortKey) {
    if (sortBy === k) setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    else {
      setSortBy(k);
      setSortDir(k === "updated_at" ? "desc" : "asc");
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">會員</h1>
          <p className="text-sm text-zinc-500">
            {loading ? "載入中…" : total === 0 ? "共 0 筆" : `共 ${total} 筆（顯示 ${fromIdx}-${toIdx}）`}
          </p>
        </div>
        <Link
          href="/members/new"
          className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          新增會員
        </Link>
      </header>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <input
          type="search"
          placeholder="搜尋 會員編號 / 姓名 / 手機"
          value={queryDraft}
          onChange={(e) => setQueryDraft(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <select
          value={tierId}
          onChange={(e) => setTierId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部等級</option>
          {tiers.map((t) => (
            <option key={t.id} value={t.id}>
              {t.name}
            </option>
          ))}
        </select>
        <select
          value={status}
          onChange={(e) => setStatus(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部狀態</option>
          <option value="active">活躍</option>
          <option value="inactive">停用</option>
          <option value="blocked">封鎖</option>
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
              <ThSort label="編號" col="member_no" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
              <ThSort label="姓名" col="name" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
              <Th>手機</Th>
              <Th>等級</Th>
              <Th className="text-right">積分</Th>
              <Th className="text-right">儲值</Th>
              <Th>狀態</Th>
              <ThSort label="更新" col="updated_at" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} align="right" />
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <SkeletonRows cols={8} />
            ) : rows.length === 0 ? (
              <tr>
                <td colSpan={8} className="p-6 text-center text-sm text-zinc-500">
                  {total === 0 && !query && !tierId && !status
                    ? "還沒有會員，按「新增會員」開始建立。"
                    : "沒有符合條件的會員。"}
                </td>
              </tr>
            ) : (
              rows.map((r) => {
                const bal = balances.get(r.id);
                return (
                  <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                    <Td className="font-mono">
                      <Link href={`/members/detail?id=${r.id}`} className="hover:underline">
                        {r.member_no}
                      </Link>
                    </Td>
                    <Td>{r.name ?? "—"}</Td>
                    <Td className="font-mono text-xs">{r.phone ?? "—"}</Td>
                    <Td className="text-xs text-zinc-600 dark:text-zinc-400">
                      {r.tier_id ? tierMap.get(r.tier_id)?.name ?? "—" : "—"}
                    </Td>
                    <Td className="text-right font-mono">{bal?.points?.toLocaleString() ?? "—"}</Td>
                    <Td className="text-right font-mono">{bal?.wallet?.toLocaleString() ?? "—"}</Td>
                    <Td>
                      <StatusBadge status={r.status} />
                    </Td>
                    <Td className="text-right text-zinc-500">
                      {new Date(r.updated_at).toLocaleString("zh-TW")}
                    </Td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <PagerBtn onClick={() => setPage(1)} disabled={page === 1}>« 第一頁</PagerBtn>
          <PagerBtn onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1}>‹ 上頁</PagerBtn>
          <span className="px-2 text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages}>下頁 ›</PagerBtn>
          <PagerBtn onClick={() => setPage(totalPages)} disabled={page === totalPages}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}

function ThSort({
  label, col, sortBy, sortDir, onToggle, align = "left",
}: {
  label: string; col: SortKey; sortBy: SortKey; sortDir: SortDir;
  onToggle: (c: SortKey) => void; align?: "left" | "right";
}) {
  const active = sortBy === col;
  const arrow = active ? (sortDir === "asc" ? "↑" : "↓") : "";
  return (
    <th
      onClick={() => onToggle(col)}
      className={`cursor-pointer px-4 py-2 text-xs font-medium uppercase tracking-wide text-zinc-500 select-none hover:text-zinc-900 dark:hover:text-zinc-100 ${align === "right" ? "text-right" : "text-left"}`}
    >
      {label} <span className="text-zinc-400">{arrow}</span>
    </th>
  );
}

function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}

function StatusBadge({ status }: { status: Status }) {
  const styles: Record<Status, string> = {
    active: "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
    inactive: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    blocked: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
    merged: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    deleted: "bg-zinc-100 text-zinc-500 line-through dark:bg-zinc-800",
  };
  return <span className={`inline-block rounded px-2 py-0.5 text-xs ${styles[status]}`}>{STATUS_LABEL[status]}</span>;
}

function SkeletonRows({ cols }: { cols: number }) {
  return (
    <>
      {Array.from({ length: 5 }).map((_, i) => (
        <tr key={i}>
          <td colSpan={cols} className="p-3">
            <div className="h-4 animate-pulse rounded bg-zinc-100 dark:bg-zinc-800" />
          </td>
        </tr>
      ))}
    </>
  );
}

function PagerBtn({ onClick, disabled, children }: { onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-zinc-300 px-2 py-1 disabled:opacity-40 dark:border-zinc-700"
    >
      {children}
    </button>
  );
}
