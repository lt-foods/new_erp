"use client";

import Link from "next/link";
import { Suspense, useEffect, useState } from "react";
import { useSearchParams, useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";
import { Modal } from "@/components/Modal";
import { MemberForm, type MemberFormValues } from "@/components/MemberForm";
import { MemberDetail } from "@/components/MemberDetail";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow } from "@/components/DataTable";
import type { OrderStatus } from "@/lib/orderStatus";

const PENDING_STATUSES: OrderStatus[] = ["pending", "confirmed", "shipping", "ready"];

type Status = "active" | "inactive" | "blocked" | "merged" | "deleted";
type SortKey = "updated_at" | "name" | "home_store_id" | "joined_at" | "last_visit_at" | "external_source";
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
  joined_at: string;
  last_visit_at: string | null;
  external_source: string | null;
  external_id: string | null;
  line_user_id: string | null;
  home_store_id: number | null;
  takeout_store_name_hint: string | null;
  merged_into_member_id: number | null;
};

const MEMBER_SELECT_COLS =
  "id, member_no, name, phone, avatar_url, tier_id, status, updated_at, joined_at, last_visit_at, external_source, external_id, line_user_id, home_store_id, takeout_store_name_hint, merged_into_member_id";

/** 顯示手機，若是 LIFF auto-register 的 placeholder (line:Uxxxx) 則視為未填 */
function displayPhone(p: string | null): string {
  if (!p) return "—";
  if (p.startsWith("line:")) return "—";
  return p;
}

type Store = { id: number; code: string; name: string };

const PAGE_SIZE = 20;

export default function MembersListPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <MembersListBody />
    </Suspense>
  );
}

function MembersListBody() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const idFromUrl = searchParams.get("id");
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
  useDefaultStoreFromUser(stores, storeId, setStoreId);
  const [balances, setBalances] = useState<Map<number, { unpicked: number; wallet: number; orderCount: number }>>(new Map());
  // 有 web push 訂閱（=已安裝 PWA + 開啟通知）的 member id；走 SECURITY DEFINER RPC，
  // 因 push_subscriptions RLS 對 admin（role 非 hq）會靜默回 0 列。
  const [pushSet, setPushSet] = useState<Set<number>>(new Set());
  const [reloadTick, setReloadTick] = useState(0);
  const [modal, setModal] = useState<
    | { mode: "new" }
    | { mode: "edit"; values: MemberFormValues }
    | { mode: "detail"; memberId: number; memberNo: string }
    | null
  >(null);

  // URL ?id=N → 自動開 detail modal（讓外部 link 進來能直接看 detail）
  useEffect(() => {
    if (!idFromUrl) return;
    const idNum = Number(idFromUrl);
    if (!Number.isFinite(idNum) || idNum <= 0) return;
    setModal((cur) =>
      cur && cur.mode === "detail" && cur.memberId === idNum
        ? cur
        : { mode: "detail", memberId: idNum, memberNo: "" }
    );
  }, [idFromUrl]);

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
          .select(MEMBER_SELECT_COLS, { count: "exact" })
          .order(sortBy, { ascending: sortDir === "asc" })
          .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

        // Google 式：空白 / + 拆 token，每個 token 都要在 name / phone / member_no 至少一個欄位命中
        const tokens = query.replace(/[%,()]/g, " ").split(/[\s+]+/).filter(Boolean);
        for (const tok of tokens) {
          q = q.or(`name.ilike.%${tok}%,phone.ilike.%${tok}%,member_no.ilike.%${tok}%`);
        }
        if (storeId) q = q.eq("home_store_id", Number(storeId));
        // 沒輸入搜尋字串時：只看活躍會員。
        // 有搜尋字串時：把 merged 也撈出來（之後會把命中的「已合併舊檔」翻譯成它被併進去的新會員）；
        // deleted 永遠不顯示
        if (tokens.length === 0) q = q.not("status", "in", "(merged,deleted)");
        else q = q.neq("status", "deleted");

        const { data, count, error } = await q;
        if (cancelled) return;
        if (error) {
          setError(error.message);
          return;
        }

        // 把命中的 merged 舊檔翻譯成 merged_into 的新會員（追隨 chain 直到 active；最多 5 跳）
        let resolved = (data ?? []) as MemberRow[];
        const targetsToFetch = new Set<number>();
        for (const r of resolved) {
          if (r.status === "merged" && r.merged_into_member_id != null) {
            targetsToFetch.add(r.merged_into_member_id);
          }
        }
        const fetched = new Map<number, MemberRow>();
        let hop = 0;
        while (targetsToFetch.size > 0 && hop < 5) {
          const ids = [...targetsToFetch].filter((id) => !fetched.has(id));
          targetsToFetch.clear();
          if (ids.length === 0) break;
          const { data: ts } = await getSupabase()
            .from("members")
            .select(MEMBER_SELECT_COLS)
            .in("id", ids);
          for (const t of (ts ?? []) as MemberRow[]) {
            fetched.set(t.id, t);
            if (t.status === "merged" && t.merged_into_member_id != null && !fetched.has(t.merged_into_member_id)) {
              targetsToFetch.add(t.merged_into_member_id);
            }
          }
          hop += 1;
        }
        const resolveChain = (m: MemberRow): MemberRow | null => {
          let cur: MemberRow | undefined = m;
          let i = 0;
          while (cur && cur.status === "merged" && cur.merged_into_member_id != null && i < 5) {
            cur = fetched.get(cur.merged_into_member_id);
            i += 1;
          }
          if (!cur || cur.status === "merged" || cur.status === "deleted") return null;
          return cur;
        };
        if (tokens.length > 0) {
          const seen = new Set<number>();
          const out: MemberRow[] = [];
          for (const r of resolved) {
            const target = r.status === "merged" ? resolveChain(r) : r;
            if (!target || seen.has(target.id)) continue;
            seen.add(target.id);
            out.push(target);
          }
          resolved = out;
        }
        setError(null);
        setRows(resolved);
        setTotal(count ?? 0);

        const ids = resolved.map((r) => r.id);
        if (ids.length) {
          const [ord, wal, push] = await Promise.all([
            getSupabase()
              .from("customer_orders")
              .select("id, member_id, status")
              .in("member_id", ids),
            getSupabase().from("wallet_balances").select("member_id, balance").in("member_id", ids),
            getSupabase().rpc("rpc_members_with_push", { p_member_ids: ids }),
          ]);
          // 訂單數量 不計取消/過期/轉出（視為 void）
          const VOID_STATUSES = new Set<string>(["cancelled", "expired", "transferred_out"]);
          const orderToMember = new Map<number, number>();
          const countByMember = new Map<number, number>();
          for (const o of (ord.data ?? []) as { id: number; member_id: number; status: string }[]) {
            if (!VOID_STATUSES.has(o.status)) {
              countByMember.set(o.member_id, (countByMember.get(o.member_id) ?? 0) + 1);
            }
            if ((PENDING_STATUSES as string[]).includes(o.status)) {
              orderToMember.set(o.id, o.member_id);
            }
          }
          const orderIds = Array.from(orderToMember.keys());
          const m = new Map<number, { unpicked: number; wallet: number; orderCount: number }>();
          for (const id of ids) m.set(id, { unpicked: 0, wallet: 0, orderCount: countByMember.get(id) ?? 0 });
          if (orderIds.length) {
            const items = await getSupabase()
              .from("customer_order_items")
              .select("order_id, qty, unit_price")
              .in("order_id", orderIds);
            for (const it of (items.data ?? []) as { order_id: number; qty: number; unit_price: number }[]) {
              const mid = orderToMember.get(it.order_id);
              if (mid == null) continue;
              const cur = m.get(mid);
              if (!cur) continue;
              cur.unpicked += Number(it.qty) * Number(it.unit_price);
            }
          }
          for (const w of wal.data ?? []) {
            const cur = m.get(w.member_id)!;
            cur.wallet = Number(w.balance) || 0;
          }
          const ps = new Set<number>();
          for (const row of (push.data ?? []) as { member_id: number }[]) {
            if (row?.member_id != null) ps.add(Number(row.member_id));
          }
          if (!cancelled) {
            setBalances(m);
            setPushSet(ps);
          }
        } else {
          setBalances(new Map());
          setPushSet(new Set());
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
            href="/members/import"
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:hover:bg-zinc-800"
          >
            批次匯入
          </Link>
          <SpinButton
            onClick={() => setModal({ mode: "new" })}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            新增會員
          </SpinButton>
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

      <Table>
        <THead>
          <ThSort label="姓名" col="name" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
          <ThSort label="取貨店" col="home_store_id" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} />
          <Th>手機</Th>
          <Th align="right">訂單數</Th>
          <Th align="right">未取貨金額</Th>
          <Th align="right">儲值</Th>
          <ThSort label="加入時間" col="joined_at" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} align="right" />
          <ThSort label="最後登入" col="last_visit_at" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} align="right" />
          <ThSort label="更新" col="updated_at" sortBy={sortBy} sortDir={sortDir} onToggle={toggleSort} align="right" />
          <Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <SkeletonRows cols={10} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={10}>
              {total === 0 && !query ? "還沒有會員，按「新增會員」開始建立。" : "沒有符合條件的會員。"}
            </EmptyRow>
          ) : (
            rows.map((r) => {
              const bal = balances.get(r.id);
              const store = r.home_store_id ? stores.find((s) => s.id === r.home_store_id) : null;
              return (
                <Tr
                  key={r.id}
                  onClick={() => setModal({ mode: "detail", memberId: r.id, memberNo: r.member_no })}
                  className="cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                >
                  <Td>
                    <div className="flex items-center gap-2">
                      <span className="flex w-12 shrink-0 flex-col items-end gap-0.5">
                        {r.line_user_id && (
                          <span
                            title="已綁定 LINE"
                            className="whitespace-nowrap rounded bg-green-100 px-1.5 py-0.5 text-[10px] font-normal text-green-700 dark:bg-green-950 dark:text-green-300"
                          >
                            LINE
                          </span>
                        )}
                        {pushSet.has(r.id) && (
                          <span
                            title="已安裝 App 並開啟通知"
                            className="whitespace-nowrap rounded bg-blue-100 px-1.5 py-0.5 text-[10px] font-normal text-blue-700 dark:bg-blue-950 dark:text-blue-300"
                          >
                            通知
                          </span>
                        )}
                      </span>
                      {r.avatar_url ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={r.avatar_url} alt="" className="h-7 w-7 rounded-full object-cover" />
                      ) : (
                        <div className="flex h-7 w-7 items-center justify-center rounded-full bg-zinc-200 text-[10px] text-zinc-500 dark:bg-zinc-800">
                          {r.name?.[0] ?? "?"}
                        </div>
                      )}
                      <span className={r.status === "merged" || r.status === "deleted" ? "text-zinc-400" : ""}>
                        {r.name ?? "—"}
                      </span>
                      {r.external_source === "lele" && (
                        <span
                          title={r.external_id ? `樂樂顧客代號 ${r.external_id}` : "樂樂匯入"}
                          className="whitespace-nowrap rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-normal text-amber-700 dark:bg-amber-950 dark:text-amber-300"
                        >
                          樂樂
                        </span>
                      )}
                      {r.status === "merged" && (
                        <span className="whitespace-nowrap rounded bg-zinc-200 px-1.5 py-0.5 text-[10px] font-normal text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300">已合併</span>
                      )}
                      {r.status === "deleted" && (
                        <span className="whitespace-nowrap rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-normal text-red-700 dark:bg-red-950 dark:text-red-300">已刪除</span>
                      )}
                    </div>
                  </Td>
                  <Td className="text-xs">
                    {store ? (
                      <span>{store.name}</span>
                    ) : r.takeout_store_name_hint ? (
                      <span className="text-zinc-500" title="樂樂標籤、尚未對應到 store">
                        {r.takeout_store_name_hint}
                        <span className="ml-1 rounded bg-zinc-100 px-1 py-0.5 text-[10px] text-zinc-500 dark:bg-zinc-800">hint</span>
                      </span>
                    ) : (
                      <span className="text-zinc-400">—</span>
                    )}
                  </Td>
                  <Td className="font-mono text-xs">{displayPhone(r.phone)}</Td>
                  <Td align="right" className="font-mono">{bal?.orderCount ?? 0}</Td>
                  <Td align="right" className="font-mono">{bal?.unpicked ? `$${bal.unpicked.toLocaleString()}` : "—"}</Td>
                  <Td align="right" className="font-mono">{bal?.wallet?.toLocaleString() ?? "—"}</Td>
                  <Td align="right" className="whitespace-nowrap text-xs text-zinc-500">
                    {new Date(r.joined_at).toLocaleDateString("zh-TW")}
                  </Td>
                  <Td align="right" className="whitespace-nowrap text-xs text-zinc-500">
                    {r.last_visit_at
                      ? new Date(r.last_visit_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })
                      : "—"}
                  </Td>
                  <Td align="right" className="whitespace-nowrap text-xs text-zinc-500">
                    {new Date(r.updated_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                  </Td>
                  <Td>
                    <div className="flex items-center justify-end gap-3">
                      <Link
                        href={`/pickup?q=${encodeURIComponent(r.member_no)}`}
                        onClick={(e) => e.stopPropagation()}
                        className="text-xs text-emerald-600 hover:underline dark:text-emerald-400"
                      >
                        🔎 查訂單
                      </Link>
                      <SpinButton
                        onClick={async (e) => {
                          e.stopPropagation();
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
                      </SpinButton>
                    </div>
                  </Td>
                </Tr>
              );
            })
          )}
        </TBody>
      </Table>

      <Modal
        open={!!modal}
        onClose={() => {
          setModal(null);
          // 從 URL ?id= 進來開的 detail modal，關閉同步清 URL，避免 back 又自動打開
          if (modal?.mode === "detail" && idFromUrl) {
            router.replace("/members");
          }
        }}
        title={
          modal?.mode === "edit"   ? `編輯會員 #${modal.values.member_no}` :
          modal?.mode === "detail" ? `會員明細${modal.memberNo ? ` #${modal.memberNo}` : ""}` :
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
    <SpinButton
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-zinc-300 px-2 py-1 transition-colors hover:bg-zinc-100 disabled:opacity-40 disabled:hover:bg-transparent dark:border-zinc-700 dark:hover:bg-zinc-800"
    >
      {children}
    </SpinButton>
  );
}
