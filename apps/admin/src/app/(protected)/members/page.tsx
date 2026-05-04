"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import { MemberForm, type MemberFormValues } from "@/components/MemberForm";
import { MemberDetail } from "@/components/MemberDetail";

type Status = "active" | "inactive" | "blocked" | "merged" | "deleted";
type SortKey = "updated_at" | "member_no" | "name";
type SortDir = "asc" | "desc";

type MemberRow = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  avatar_url: string | null;
  tier_id: number | null;
  status: Status;
  updated_at: string;
};

/** 顯示手機，若是 LIFF auto-register 的 placeholder (line:Uxxxx) 則視為未填 */
function displayPhone(p: string | null): string {
  if (!p) return "—";
  if (p.startsWith("line:")) return "—";
  return p;
}

type Store = { id: number; code: string; name: string };

const PAGE_SIZE = 50;

export default function MembersListPage() {
  const [rows, setRows] = useState<MemberRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [storeId, setStoreId] = useState<string>("");
  const [sortBy, setSortBy] = useState<SortKey>("updated_at");
  const [sortDir, setSortDir] = useState<SortDir>("desc");
  const [page, setPage] = useState(1);

  const [stores, setStores] = useState<Store[]>([]);
  const [balances, setBalances] = useState<Map<number, { points: number; wallet: number }>>(new Map());
  const [reloadTick, setReloadTick] = useState(0);
  const [modal, setModal] = useState<
    | { mode: "new" }
    | { mode: "edit"; values: MemberFormValues }
    | { mode: "detail"; memberId: number; memberNo: string }
    | null
  >(null);

  useEffect(() => {
    const t = setTimeout(() => {
      setQuery(queryDraft);
      setPage(1);
    }, 250);
    return () => clearTimeout(t);
  }, [queryDraft]);

  useEffect(() => {
    setPage(1);
  }, [storeId, sortBy, sortDir]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const s = await getSupabase()
        .from("stores")
        .select("id, code, name")
        .eq("is_active", true)
        .order("name");
      if (cancelled) return;
      if (s.error) {
        setError(s.error.message);
        return;
      }
      setStores((s.data ?? []) as Store[]);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        let q = getSupabase()
          .from("members")
          .select("id, member_no, name, phone, avatar_url, tier_id, status, updated_at", { count: "exact" })
          .order(sortBy, { ascending: sortDir === "asc" })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        if (query.trim()) {
          const safe = query.replace(/[%,()]/g, " ").trim();
          q = q.or(`name.ilike.%${safe}%,phone.ilike.%${safe}%,member_no.ilike.%${safe}%`);
        }
        if (storeId) q = q.eq("home_store_id", Number(storeId));

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
  }, [query, storeId, sortBy, sortDir, page, reloadTick]);

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
        <div className="flex items-center gap-2">
          <Link
            href="/pickup"
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
          >
            🔎 查詢會員訂單
          </Link>
          <button
            onClick={() => setModal({ mode: "new" })}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            新增會員
          </button>
        </div>
      </header>

      <div className="grid gap-3 sm:grid-cols-2">
        <input
          type="search"
          placeholder="搜尋 會員編號 / 姓名 / 手機"
          value={queryDraft}
          onChange={(e) => setQueryDraft(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <select
          value={storeId}
          onChange={(e) => setStoreId(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        >
          <option value="">全部門市</option>
          {stores.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name} ({s.code})
            </option>
          ))}
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
              <Th className="text-right">積分</Th>
              <Th className="text-right">儲值</Th>
              <ThSort label="更新" col="updated_at" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} align="right" />
              <Th>{""}</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <SkeletonRows cols={7} />
            ) : rows.length === 0 ? (
              <tr>
                <td colSpan={7} className="p-6 text-center text-sm text-zinc-500">
                  {total === 0 && !query
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
                      <button
                        onClick={() => setModal({ mode: "detail", memberId: r.id, memberNo: r.member_no })}
                        className="hover:underline"
                      >
                        {r.member_no}
                      </button>
                    </Td>
                    <Td>
                      <div className="flex items-center gap-2">
                        {r.avatar_url ? (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img src={r.avatar_url} alt="" className="h-7 w-7 rounded-full object-cover" />
                        ) : (
                          <div className="flex h-7 w-7 items-center justify-center rounded-full bg-zinc-200 text-[10px] text-zinc-500 dark:bg-zinc-800">
                            {r.name?.[0] ?? "?"}
                          </div>
                        )}
                        <span>{r.name ?? "—"}</span>
                      </div>
                    </Td>
                    <Td className="font-mono text-xs">{displayPhone(r.phone)}</Td>
                    <Td className="text-right font-mono">{bal?.points?.toLocaleString() ?? "—"}</Td>
                    <Td className="text-right font-mono">{bal?.wallet?.toLocaleString() ?? "—"}</Td>
                    <Td className="text-right text-zinc-500">
                      {new Date(r.updated_at).toLocaleString("zh-TW")}
                    </Td>
                    <Td>
                      <button
                        onClick={async () => {
                          const { data } = await getSupabase()
                            .from("members")
                            .select("id, member_no, phone, name, gender, birthday, email, tier_id, home_store_id, status, notes")
                            .eq("id", r.id).maybeSingle();
                          if (data) setModal({ mode: "edit", values: {
                            id: data.id, member_no: data.member_no,
                            // LIFF auto-register 的 placeholder「line:<uid>」不要灌進編輯表單
                            phone: data.phone && !data.phone.startsWith("line:") ? data.phone : "",
                            name: data.name ?? "", gender: data.gender, birthday: data.birthday,
                            email: data.email, tier_id: data.tier_id, home_store_id: data.home_store_id,
                            status: data.status, notes: data.notes,
                          }});
                        }}
                        className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                      >
                        編輯
                      </button>
                    </Td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      <Modal
        open={!!modal}
        onClose={() => setModal(null)}
        title={
          modal?.mode === "edit"   ? `編輯會員 #${modal.values.member_no}` :
          modal?.mode === "detail" ? `會員明細 #${modal.memberNo}` :
          "新增會員"
        }
        maxWidth={modal?.mode === "detail" ? "max-w-4xl" : "max-w-3xl"}
      >
        {modal?.mode === "detail" ? (
          <MemberDetail memberId={modal.memberId} />
        ) : modal ? (
          <MemberForm
            initial={modal.mode === "edit" ? modal.values : undefined}
            onSaved={() => { setModal(null); setReloadTick((t) => t + 1); }}
            onCancel={() => setModal(null)}
          />
        ) : null}
      </Modal>

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
      className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800"
    >
      {children}
    </button>
  );
}
