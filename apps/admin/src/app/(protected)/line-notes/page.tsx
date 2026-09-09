"use client";

// LINE 記事本：帳號（備用 LINE 帳號登入）→ 社群設定 → 開團自動發文 → 定時讀留言加單。
// 真正跟 LINE 講話的是地端 worker（tools/line-note-scraper/src/worker.mjs），
// 這頁只做設定、丟工作（line_note_jobs）、看結果。

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { translateRpcError } from "@/lib/rpcError";
import { campaignStatusBadge, campaignStatusLabel } from "@/lib/campaignStatus";

type Account = {
  id: number; label: string; status: "logged_out" | "pending_qr" | "active" | "error";
  line_mid: string | null; display_name: string | null;
  qr_image: string | null; qr_url: string | null; pin_code: string | null;
  last_error: string | null; last_seen_at: string | null;
};
type Store = { id: number; code: string; name: string };
type Community = {
  id: number; account_id: number; store_id: number | null; home_id: string; home_name: string | null;
  home_kind: "group" | "square" | "square_chat"; listen_enabled: boolean; read_times: string[];
  auto_post_on_open: boolean; post_template: string | null; read_days: number; last_read_at: string | null; last_error: string | null;
};
type Post = {
  id: number; community_id: number; campaign_id: number; line_post_id: string | null; text: string | null;
  status: "queued" | "posted" | "failed" | "closed"; posted_at: string | null; last_read_at: string | null;
  comment_count: number; last_error: string | null; created_at: string;
  group_buy_campaigns: { id: number; campaign_no: string; name: string; status: string } | null;
};
type Comment = {
  id: number; line_comment_id: string; commenter_id: string | null; commenter_name: string | null; text: string;
  commented_at: string | null; member_no_hint: string | null; parsed: { code: string | null; qty: number; cancel: boolean }[];
  status: "pending" | "ordered" | "unmatched" | "no_order" | "error" | "ignored" | "resolved" | "duplicate";
  member_id: number | null; customer_order_id: number | null; error: string | null;
  resolved_at: string | null; resolution_note: string | null;
};
type Row = Comment & { line_note_posts: { community_id: number; campaign_id: number; group_buy_campaigns: { name: string; campaign_no: string } | null } | null };
type OrderInfo = { id: number; order_no: string; store_name: string | null };
type Home = { kind: string; homeId: string; name: string };
type Campaign = { id: number; campaign_no: string; name: string; status: string };

const ACCOUNT_STATUS: Record<Account["status"], string> = {
  logged_out: "未登入", pending_qr: "等待掃 QR", active: "已登入", error: "錯誤",
};
const POST_STATUS: Record<Post["status"], string> = { queued: "排隊中", posted: "已發文", failed: "失敗", closed: "已結束" };
const COMMENT_STATUS: Record<Comment["status"], string> = {
  pending: "待處理", ordered: "已加單", unmatched: "找不到會員", no_order: "非下單", error: "錯誤", ignored: "忽略", resolved: "已解決", duplicate: "已有訂單",
};
const KIND_LABEL: Record<string, string> = { group: "群組", square: "社群", square_chat: "社群聊天室" };

const fmt = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleString("zh-TW", { hour12: false, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "—";
const kindOf = (homeId: string): Community["home_kind"] =>
  homeId.startsWith("c") ? "group" : homeId.startsWith("s") ? "square" : "square_chat";

function Badge({ tone, children }: { tone: "gray" | "green" | "amber" | "red" | "blue"; children: ReactNode }) {
  const cls = {
    gray: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    green: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300",
    amber: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
    red: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300",
    blue: "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
  }[tone];
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${cls}`}>{children}</span>;
}

// Edge Function line-note-worker：排程每分鐘會自己跑；按了按鈕就順手叫一下，不用等下一分鐘
function kickWorker(body: Record<string, unknown> = { action: "run" }) {
  void getSupabase().functions.invoke("line-note-worker", { body }).catch(() => {});
}

const btn = "rounded border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800";
const btnPrimary = "rounded bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";
const input = "w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900";

export default function LineNotesPage() {
  const [tab, setTab] = useState<"accounts" | "communities" | "comments" | "posts">("accounts");
  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [communities, setCommunities] = useState<Community[] | null>(null);
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const notify = useCallback((msg: string) => { setToast(msg); setTimeout(() => setToast(null), 3000); }, []);
  const fail = useCallback((e: unknown) => setError(translateRpcError(e)), []);

  const loadAccounts = useCallback(async () => {
    const { data, error } = await getSupabase().from("v_line_note_accounts").select("*").order("id");
    if (error) fail(error); else setAccounts((data ?? []) as Account[]);
  }, [fail]);
  const loadCommunities = useCallback(async () => {
    const sb = getSupabase();
    const [c, ch] = await Promise.all([
      sb.from("line_note_communities").select("*").order("id"),
      sb.from("stores").select("id,code,name").eq("is_active", true).order("name"),
    ]);
    if (c.error) fail(c.error); else setCommunities((c.data ?? []) as Community[]);
    if (!ch.error) setStores((ch.data ?? []) as Store[]);
  }, [fail]);
  const loadPosts = useCallback(async () => {
    const { data, error } = await getSupabase()
      .from("line_note_posts")
      .select("*,group_buy_campaigns(id,campaign_no,name,status)")
      .order("created_at", { ascending: false })
      .limit(100);
    if (error) fail(error); else setPosts((data ?? []) as Post[]);
  }, [fail]);

  useEffect(() => { void loadAccounts(); void loadCommunities(); void loadPosts(); }, [loadAccounts, loadCommunities, loadPosts]);

  // 帳號狀態每 3 秒刷新（登入中 / worker 有沒有在跑）
  useEffect(() => {
    const t = setInterval(() => { void loadAccounts(); }, 3000);
    return () => clearInterval(t);
  }, [loadAccounts]);

  const accountById = useMemo(() => new Map((accounts ?? []).map((a) => [a.id, a])), [accounts]);
  const storeById = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);
  const communityById = useMemo(() => new Map((communities ?? []).map((c) => [c.id, c])), [communities]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">LINE 記事本</h1>
          <p className="text-sm text-zinc-500">
            備用 LINE 帳號登入 → 綁社群 → 開團自動發文 → 定時讀留言，留言裡的「會員編號 6 碼 ＋ A+1」自動加單。
            排程每分鐘自動跑（Supabase），不用另外開程式。
          </p>
        </div>
        <nav className="flex gap-1 rounded-lg bg-zinc-100 p-1 dark:bg-zinc-800">
          {([["accounts", "帳號"], ["communities", "社群設定"], ["comments", "留言加單"], ["posts", "貼文"]] as const).map(([k, l]) => (
            <button key={k} type="button" onClick={() => setTab(k)}
              className={`rounded-md px-3 py-1 text-sm ${tab === k ? "bg-white shadow dark:bg-zinc-900" : "text-zinc-600 dark:text-zinc-300"}`}>
              {l}
            </button>
          ))}
        </nav>
      </div>

      {error && (
        <div className="flex items-start justify-between rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
          <span className="whitespace-pre-wrap">{error}</span>
          <button type="button" className="ml-3 text-xs underline" onClick={() => setError(null)}>關閉</button>
        </div>
      )}
      {toast && <div className="rounded bg-emerald-600 px-3 py-2 text-sm text-white">{toast}</div>}

      {tab === "accounts" && (
        <AccountsTab accounts={accounts} reload={loadAccounts} notify={notify} fail={fail} />
      )}
      {tab === "communities" && (
        <CommunitiesTab
          communities={communities} accounts={accounts ?? []} stores={stores}
          accountById={accountById} storeById={storeById}
          reload={loadCommunities} reloadPosts={loadPosts} notify={notify} fail={fail}
        />
      )}
      {tab === "comments" && (
        <CommentsTab communityById={communityById} notify={notify} fail={fail} />
      )}
      {tab === "posts" && (
        <PostsTab posts={posts} communityById={communityById} reload={loadPosts} notify={notify} fail={fail} />
      )}
    </div>
  );
}

// ── 帳號 ────────────────────────────────────────────────────────────────────
function AccountsTab({ accounts, reload, notify, fail }: {
  accounts: Account[] | null; reload: () => Promise<void>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [busy, setBusy] = useState<number | "new" | null>(null);
  const [loginId, setLoginId] = useState<number | null>(null);
  const loginAccount = loginId == null ? null : accounts?.find((a) => a.id === loginId) ?? null;

  const addAccount = async () => {
    const label = window.prompt("帳號名稱（例：社群小幫手 1）");
    if (!label?.trim()) return;
    setBusy("new");
    const { error } = await getSupabase().rpc("rpc_line_note_account_upsert", { p_id: null, p_label: label.trim() });
    setBusy(null);
    if (error) return fail(error);
    notify("已新增帳號");
    await reload();
  };
  const enqueue = async (a: Account, kind: "login" | "logout") => {
    setBusy(a.id);
    if (kind === "login") {
      // 登入要等人掃 QR，直接叫 Edge Function 跑（它會把 QR 寫進 DB，這邊輪詢帳號列顯示）
      kickWorker({ action: "login", account_id: a.id });
      setBusy(null);
      setLoginId(a.id);
      await reload();
      return;
    }
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", { p_kind: kind, p_account_id: a.id });
    setBusy(null);
    if (error) return fail(error);
    kickWorker();
    notify("已送出登出");
    await reload();
  };
  const remove = async (a: Account) => {
    if (!window.confirm(`刪除帳號「${a.label}」？底下的社群設定與貼文紀錄會一起刪掉。`)) return;
    setBusy(a.id);
    const { error } = await getSupabase().rpc("rpc_line_note_account_delete", { p_id: a.id });
    setBusy(null);
    if (error) return fail(error);
    notify("已刪除");
    await reload();
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-zinc-500">一個帳號可以進多個社群；不同社群要用不同帳號就多建幾個。<b>只用備用帳號</b>，可能被 LINE 停權。</p>
        <SpinButton type="button" className={btnPrimary} loading={busy === "new"} onClick={addAccount}>＋ 新增帳號</SpinButton>
      </div>
      <Table>
        <THead><Th>名稱</Th><Th>狀態</Th><Th>LINE 顯示名稱</Th><Th>最後活動</Th><Th>錯誤</Th><Th align="right">操作</Th></THead>
        <TBody>
          {accounts === null ? <LoadingRow colSpan={6} /> : accounts.length === 0 ? <EmptyRow colSpan={6}>還沒有帳號</EmptyRow> : accounts.map((a) => (
            <Tr key={a.id}>
              <Td>{a.label}</Td>
              <Td>
                <Badge tone={a.status === "active" ? "green" : a.status === "pending_qr" ? "amber" : a.status === "error" ? "red" : "gray"}>
                  {ACCOUNT_STATUS[a.status]}
                </Badge>
              </Td>
              <Td>{a.display_name ?? "—"}</Td>
              <Td>{fmt(a.last_seen_at)}</Td>
              <Td className="max-w-xs truncate text-xs text-red-600" title={a.last_error ?? ""}>{a.last_error ?? ""}</Td>
              <Td align="right">
                <div className="flex justify-end gap-1">
                  {a.status === "pending_qr" && <button type="button" className={btn} onClick={() => setLoginId(a.id)}>看 QR</button>}
                  {a.status !== "active" && <SpinButton type="button" className={btn} loading={busy === a.id} onClick={() => enqueue(a, "login")}>登入</SpinButton>}
                  {a.status === "active" && <SpinButton type="button" className={btn} loading={busy === a.id} onClick={() => enqueue(a, "logout")}>登出</SpinButton>}
                  <SpinButton type="button" className={`${btn} text-red-600`} loading={busy === a.id} onClick={() => remove(a)}>刪除</SpinButton>
                </div>
              </Td>
            </Tr>
          ))}
        </TBody>
      </Table>

      {loginAccount && (
        <Modal title={`登入「${loginAccount.label}」`} onClose={() => setLoginId(null)}>
          {loginAccount.status === "active" ? (
            <p className="text-emerald-700">✅ 已登入：{loginAccount.display_name}</p>
          ) : loginAccount.status === "error" ? (
            <p className="whitespace-pre-wrap text-red-600">登入失敗：{loginAccount.last_error}</p>
          ) : !loginAccount.qr_image && !loginAccount.qr_url ? (
            <p className="text-zinc-500">正在產生 QR…（約 5 秒）。QR 出現後 2 分鐘內要掃完，逾時再按一次登入。</p>
          ) : (
            <div className="space-y-3 text-center">
              {loginAccount.qr_image
                // eslint-disable-next-line @next/next/no-img-element -- data URL，不走 next/image
                ? <img src={loginAccount.qr_image} alt="LINE 登入 QR" className="mx-auto h-64 w-64" />
                : <a className="break-all text-sky-700 underline" href={loginAccount.qr_url ?? "#"} target="_blank" rel="noreferrer">{loginAccount.qr_url}</a>}
              <p className="text-sm">用<b>備用帳號</b>的手機 LINE 掃描（LINE → 加入好友 → 行動條碼）。</p>
              {loginAccount.pin_code && (
                <p className="text-lg">手機會要你輸入 PIN：<b className="font-mono text-2xl tracking-widest">{loginAccount.pin_code}</b></p>
              )}
            </div>
          )}
        </Modal>
      )}
    </div>
  );
}

// ── 社群設定 ─────────────────────────────────────────────────────────────────
type CommunityForm = {
  id: number | null; account_id: number | ""; store_id: number | ""; home_id: string; home_name: string;
  listen_enabled: boolean; read_times: string; auto_post_on_open: boolean; post_template: string; read_days: number;
};
const EMPTY_FORM: CommunityForm = {
  id: null, account_id: "", store_id: "", home_id: "", home_name: "",
  listen_enabled: true, read_times: "12:00", auto_post_on_open: true, post_template: "", read_days: 3,
};

function CommunitiesTab({ communities, accounts, stores, accountById, storeById, reload, reloadPosts, notify, fail }: {
  communities: Community[] | null; accounts: Account[]; stores: Store[];
  accountById: Map<number, Account>; storeById: Map<number, Store>;
  reload: () => Promise<void>; reloadPosts: () => Promise<void>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [form, setForm] = useState<CommunityForm | null>(null);
  const [busy, setBusy] = useState<number | "save" | "homes" | null>(null);
  const [homes, setHomes] = useState<Home[] | null>(null);
  const [postFor, setPostFor] = useState<Community | null>(null);

  const openNew = () => { setHomes(null); setForm({ ...EMPTY_FORM, account_id: accounts[0]?.id ?? "" }); };
  const openEdit = (c: Community) => {
    setHomes(null);
    setForm({ id: c.id, account_id: c.account_id, store_id: c.store_id ?? "", home_id: c.home_id, home_name: c.home_name ?? "",
      listen_enabled: c.listen_enabled, read_times: c.read_times.join(", "), auto_post_on_open: c.auto_post_on_open, post_template: c.post_template ?? "", read_days: c.read_days ?? 3 });
  };

  const loadHomes = async () => {
    if (!form || form.account_id === "") return;
    setBusy("homes");
    try {
      const sb = getSupabase();
      const { data: jobId, error } = await sb.rpc("rpc_line_note_enqueue", { p_kind: "list_homes", p_account_id: form.account_id });
      if (error) throw error;
      kickWorker();
      for (let i = 0; i < 40; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        const { data } = await sb.from("line_note_jobs").select("status,result,error").eq("id", jobId).single();
        if (data?.status === "done") { setHomes(((data.result as { homes?: Home[] })?.homes) ?? []); return; }
        if (data?.status === "failed") throw new Error(data.error ?? "worker 回報失敗");
      }
      throw new Error("等太久沒回應：帳號登入了嗎？");
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const save = async () => {
    if (!form) return;
    setBusy("save");
    const { error } = await getSupabase().rpc("rpc_line_note_community_upsert", {
      p_id: form.id, p_account_id: form.account_id || null, p_store_id: form.store_id || null,
      p_home_id: form.home_id.trim(), p_home_name: form.home_name.trim() || null, p_home_kind: kindOf(form.home_id.trim()),
      p_listen_enabled: form.listen_enabled,
      p_read_times: form.read_times.split(/[,\s，、]+/).map((s) => s.trim()).filter(Boolean),
      p_auto_post_on_open: form.auto_post_on_open, p_post_template: form.post_template || null,
      p_read_days: Math.min(30, Math.max(1, Math.round(form.read_days || 3))),
    });
    setBusy(null);
    if (error) return fail(error);
    notify("已儲存");
    setForm(null);
    await reload();
  };
  const remove = async (c: Community) => {
    if (!window.confirm(`刪除社群「${c.home_name || c.home_id}」的設定？`)) return;
    setBusy(c.id);
    const { error } = await getSupabase().rpc("rpc_line_note_community_delete", { p_id: c.id });
    setBusy(null);
    if (error) return fail(error);
    await reload();
  };
  const readNow = async (c: Community) => {
    setBusy(c.id);
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", { p_kind: "read", p_account_id: c.account_id, p_community_id: c.id });
    setBusy(null);
    if (error) return fail(error);
    kickWorker();
    notify("已開始讀取，幾秒後到「留言加單」看");
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-zinc-500">
          總部開的團會發到所有開自動發文的社群；店家自開的團只發到標了那家店的社群。加單的取貨店一律跟會員自己設定的店。
        </p>
        <button type="button" className={btnPrimary} onClick={openNew} disabled={accounts.length === 0}>＋ 新增社群</button>
      </div>
      <Table>
        <THead><Th>社群</Th><Th>帳號</Th><Th>店家</Th><Th>監聽</Th><Th>讀取時間</Th><Th>開團自動發文</Th><Th>最後讀取</Th><Th align="right">操作</Th></THead>
        <TBody>
          {communities === null ? <LoadingRow colSpan={8} /> : communities.length === 0 ? <EmptyRow colSpan={8}>還沒有社群</EmptyRow> : communities.map((c) => {
            const a = accountById.get(c.account_id);
            return (
              <Tr key={c.id}>
                <Td>
                  <div>{c.home_name || c.home_id}</div>
                  <div className="text-xs text-zinc-500">{KIND_LABEL[c.home_kind]} · <span className="font-mono">{c.home_id}</span></div>
                  {c.last_error && <div className="text-xs text-red-600">{c.last_error}</div>}
                </Td>
                <Td>{a ? <>{a.label} <Badge tone={a.status === "active" ? "green" : "red"}>{ACCOUNT_STATUS[a.status]}</Badge></> : "—"}</Td>
                <Td>{c.store_id ? (storeById.get(c.store_id)?.name ?? c.store_id) : <span className="text-zinc-400">總部（全部）</span>}</Td>
                <Td><Badge tone={c.listen_enabled ? "green" : "gray"}>{c.listen_enabled ? "監聽中" : "停用"}</Badge></Td>
                <Td className="font-mono text-xs">{c.read_times.join(" ")}<div className="text-zinc-400">近 {c.read_days} 天</div></Td>
                <Td>{c.auto_post_on_open ? "是" : "否"}</Td>
                <Td>{fmt(c.last_read_at)}</Td>
                <Td align="right">
                  <div className="flex justify-end gap-1">
                    <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => readNow(c)}>立即讀取</SpinButton>
                    <button type="button" className={btn} onClick={() => setPostFor(c)}>發文</button>
                    <button type="button" className={btn} onClick={() => openEdit(c)}>編輯</button>
                    <SpinButton type="button" className={`${btn} text-red-600`} loading={busy === c.id} onClick={() => remove(c)}>刪除</SpinButton>
                  </div>
                </Td>
              </Tr>
            );
          })}
        </TBody>
      </Table>

      {form && (
        <Modal title={form.id ? "編輯社群" : "新增社群"} onClose={() => setForm(null)} wide>
          <div className="grid gap-3 md:grid-cols-2">
            <label className="text-sm">帳號
              <select className={input} value={form.account_id} onChange={(e) => setForm({ ...form, account_id: Number(e.target.value) })}>
                {accounts.map((a) => <option key={a.id} value={a.id}>{a.label}（{ACCOUNT_STATUS[a.status]}）</option>)}
              </select>
            </label>
            <label className="text-sm">店家（選填）
              <select className={input} value={form.store_id} onChange={(e) => setForm({ ...form, store_id: e.target.value ? Number(e.target.value) : "" })}>
                <option value="">總部社群（所有團都發）</option>
                {stores.map((st) => <option key={st.id} value={st.id}>{st.name}</option>)}
              </select>
              <span className="text-xs text-zinc-500">只影響店家自開的團要不要發到這裡；取貨店跟會員走，不看這個。</span>
            </label>
            <div className="text-sm md:col-span-2">
              <div className="flex items-end gap-2">
                <label className="flex-1">社群 homeId
                  <input className={`${input} font-mono`} value={form.home_id} placeholder="m… / c… / s…"
                    onChange={(e) => setForm({ ...form, home_id: e.target.value })} />
                </label>
                <SpinButton type="button" className={btn} loading={busy === "homes"} onClick={loadHomes}>從帳號載入清單</SpinButton>
              </div>
              {homes && (
                <select className={`${input} mt-2`} size={Math.min(8, Math.max(2, homes.length))}
                  onChange={(e) => { const h = homes.find((x) => x.homeId === e.target.value); if (h) setForm({ ...form, home_id: h.homeId, home_name: h.name }); }}>
                  {homes.length === 0 && <option disabled>這個帳號沒有加入任何群組／社群</option>}
                  {homes.map((h) => <option key={h.homeId} value={h.homeId}>[{KIND_LABEL[h.kind] ?? h.kind}] {h.name} — {h.homeId}</option>)}
                </select>
              )}
              <p className="mt-1 text-xs text-zinc-500">社群記事本先選「社群聊天室」（m…）；不行再試「社群」（s…）。群組用 c…。</p>
            </div>
            <label className="text-sm">顯示名稱
              <input className={input} value={form.home_name} onChange={(e) => setForm({ ...form, home_name: e.target.value })} />
            </label>
            <label className="text-sm">讀取範圍（最近幾天的貼文；也用來認小幫手手貼的團）
              <input type="number" min={1} max={30} className={input} value={form.read_days} onChange={(e) => setForm({ ...form, read_days: Number(e.target.value) })} />
            </label>
            <label className="text-sm">讀留言時間（台北，HH:MM，逗號分隔）
              <input className={`${input} font-mono`} value={form.read_times} onChange={(e) => setForm({ ...form, read_times: e.target.value })} placeholder="09:00, 12:00, 18:00" />
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={form.listen_enabled} onChange={(e) => setForm({ ...form, listen_enabled: e.target.checked })} /> 啟用監聽（到時間自動讀留言加單）
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={form.auto_post_on_open} onChange={(e) => setForm({ ...form, auto_post_on_open: e.target.checked })} /> 開團（狀態變「開團中」）時自動發文
            </label>
            <label className="text-sm md:col-span-2">發文模板（留空用預設；可用 {"{{name}} {{description}} {{items}} {{end_at}} {{pickup_deadline}}"}）
              <textarea className={`${input} h-40 font-mono text-xs`} value={form.post_template} onChange={(e) => setForm({ ...form, post_template: e.target.value })}
                placeholder={"📣 {{name}}\n{{description}}\n\n{{items}}\n\n⏰ 收單：{{end_at}}\n📝 留言「會員編號 6 碼 ＋ A+1」"} />
            </label>
          </div>
          <div className="mt-4 flex justify-end gap-2">
            <button type="button" className={btn} onClick={() => setForm(null)}>取消</button>
            <SpinButton type="button" className={btnPrimary} loading={busy === "save"} onClick={save}>儲存</SpinButton>
          </div>
        </Modal>
      )}

      {postFor && <PostCampaignModal community={postFor} onClose={() => setPostFor(null)} notify={notify} fail={fail} reloadPosts={reloadPosts} />}
    </div>
  );
}

function PostCampaignModal({ community, onClose, notify, fail, reloadPosts }: {
  community: Community; onClose: () => void; notify: (m: string) => void; fail: (e: unknown) => void; reloadPosts: () => Promise<void>;
}) {
  const [campaigns, setCampaigns] = useState<Campaign[] | null>(null);
  const [campaignId, setCampaignId] = useState<number | "">("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    void (async () => {
      const { data, error } = await getSupabase().from("group_buy_campaigns")
        .select("id,campaign_no,name,status").in("status", ["open", "closed"]).order("id", { ascending: false }).limit(50);
      if (error) fail(error); else { setCampaigns((data ?? []) as Campaign[]); setCampaignId((data?.[0] as Campaign | undefined)?.id ?? ""); }
    })();
  }, [fail]);
  const submit = async () => {
    if (campaignId === "") return;
    setBusy(true);
    const { error } = await getSupabase().rpc("rpc_line_note_queue_post", { p_community_id: community.id, p_campaign_id: campaignId });
    setBusy(false);
    if (error) return fail(error);
    kickWorker();
    notify("已開始發文，幾秒後到「貼文」看");
    onClose();
    await reloadPosts();
  };
  return (
    <Modal title={`發文到「${community.home_name || community.home_id}」`} onClose={onClose}>
      <label className="text-sm">選擇要發的團（開團中／已收單）
        <select className={input} value={campaignId} onChange={(e) => setCampaignId(Number(e.target.value))}>
          {(campaigns ?? []).map((c) => <option key={c.id} value={c.id}>{c.campaign_no} {c.name}（{c.status}）</option>)}
        </select>
      </label>
      <div className="mt-4 flex justify-end gap-2">
        <button type="button" className={btn} onClick={onClose}>取消</button>
        <SpinButton type="button" className={btnPrimary} loading={busy} disabled={campaignId === ""} onClick={submit}>發文</SpinButton>
      </div>
    </Modal>
  );
}

// ── 貼文與留言 ───────────────────────────────────────────────────────────────
type Filter = "todo" | "ordered" | "all";
const TODO_STATUSES: Comment["status"][] = ["pending", "unmatched", "error"];
const isTodo = (c: Comment) => TODO_STATUSES.includes(c.status) || (c.status === "no_order" && !!c.member_no_hint);

// ── 留言加單：一張表，一則留言一列 ─────────────────────────────────────────
function CommentsTab({ communityById, notify, fail }: {
  communityById: Map<number, Community>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [filter, setFilter] = useState<Filter>("todo");
  const [rows, setRows] = useState<Row[] | null>(null);
  const [orders, setOrders] = useState<Map<number, OrderInfo>>(new Map());
  const [busy, setBusy] = useState<number | null>(null);

  const load = useCallback(async () => {
    const sb = getSupabase();
    const { data, error } = await sb.from("line_note_comments")
      .select("*,line_note_posts(community_id,campaign_id,group_buy_campaigns(name,campaign_no))")
      .order("commented_at", { ascending: false }).limit(300);
    if (error) return fail(error);
    const list = (data ?? []) as Row[];
    setRows(list);
    // 有加到單的 → 查訂單號與取貨店
    const ids = [...new Set(list.map((c) => c.customer_order_id).filter((x): x is number => !!x))];
    if (ids.length === 0) { setOrders(new Map()); return; }
    const { data: od } = await sb.from("customer_orders")
      .select("id,order_no,stores!customer_orders_pickup_store_id_fkey(name)").in("id", ids);
    const m = new Map<number, OrderInfo>();
    for (const o of (od ?? []) as { id: number; order_no: string; stores: { name: string } | { name: string }[] | null }[]) {
      const st = Array.isArray(o.stores) ? o.stores[0] : o.stores;
      m.set(o.id, { id: o.id, order_no: o.order_no, store_name: st?.name ?? null });
    }
    setOrders(m);
  }, [fail]);
  useEffect(() => { void load(); }, [load]);

  const retry = async (c: Comment) => {
    setBusy(c.id);
    const { data, error } = await getSupabase().rpc("rpc_line_note_apply_comment", { p_comment_id: c.id });
    setBusy(null);
    if (error) return fail(error);
    const r = (Array.isArray(data) ? data[0] : data) as { out_status?: string; out_error?: string } | null;
    notify(r?.out_status === "ordered" ? "已加單" : `${COMMENT_STATUS[(r?.out_status ?? "error") as Comment["status"]] ?? r?.out_status}${r?.out_error ? "：" + r.out_error : ""}`);
    await load();
  };
  const setStatus = async (c: Comment, status: Comment["status"]) => {
    let note: string | null = null;
    if (status === "resolved") {
      note = window.prompt("怎麼處理的？（選填）", c.resolution_note ?? "");
      if (note === null) return;
    }
    setBusy(c.id);
    const body = status === "resolved" ? { status, resolved_at: new Date().toISOString(), resolution_note: note || null } : { status };
    const { error } = await getSupabase().from("line_note_comments").update(body).eq("id", c.id);
    setBusy(null);
    if (error) return fail(error);
    await load();
  };

  const shown = useMemo(() => {
    if (!rows) return null;
    if (filter === "todo") return rows.filter(isTodo);
    if (filter === "ordered") return rows.filter((c) => c.status === "ordered" || c.status === "duplicate");
    return rows;
  }, [rows, filter]);
  const todoCount = rows?.filter(isTodo).length ?? 0;

  // 結果欄：一個徽章 + 一句話
  const result = (c: Comment) => {
    const o = c.customer_order_id ? orders.get(c.customer_order_id) : null;
    const orderText = o ? `${o.store_name ?? "？店"}　${o.order_no}` : c.customer_order_id ? `訂單 #${c.customer_order_id}` : "";
    switch (c.status) {
      case "ordered":   return <><Badge tone="green">已加單</Badge><span>{orderText}</span></>;
      case "duplicate": return <><Badge tone="blue">已有訂單</Badge><span>{orderText}</span></>;
      case "resolved":  return <><Badge tone="green">已解決</Badge><span className="text-zinc-500">{c.resolution_note ?? ""}</span></>;
      case "ignored":   return <Badge tone="gray">忽略</Badge>;
      case "pending":   return <Badge tone="amber">等 worker 處理</Badge>;
      case "no_order":  return c.member_no_hint
        ? <><Badge tone="red">看不懂</Badge><span className="text-red-700 dark:text-red-300">有會員編號，看不出要買什麼</span></>
        : <Badge tone="gray">非下單</Badge>;
      default:          return <><Badge tone="red">{COMMENT_STATUS[c.status]}</Badge><span className="text-red-700 dark:text-red-300">{c.error ?? ""}</span></>;
    }
  };
  const actions = (c: Comment) => {
    if (c.status === "ordered" || c.status === "duplicate") return null;
    if (c.status === "ignored" || c.status === "resolved") {
      return <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => setStatus(c, "pending")}>退回</SpinButton>;
    }
    return (
      <div className="flex justify-end gap-1">
        <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => retry(c)}>重試</SpinButton>
        <SpinButton type="button" className={`${btn} text-emerald-700`} loading={busy === c.id} onClick={() => setStatus(c, "resolved")}>已解決</SpinButton>
        <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => setStatus(c, "ignored")}>忽略</SpinButton>
      </div>
    );
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-1 rounded-lg bg-zinc-100 p-1 dark:bg-zinc-800">
          {([["todo", `待處理 ${todoCount}`], ["ordered", "已加單"], ["all", "全部"]] as const).map(([k, l]) => (
            <button key={k} type="button" onClick={() => setFilter(k)}
              className={`rounded-md px-3 py-1 text-sm ${filter === k ? "bg-white shadow dark:bg-zinc-900" : "text-zinc-600 dark:text-zinc-300"}`}>
              {l}
            </button>
          ))}
        </div>
        <button type="button" className={btn} onClick={() => void load()}>重新整理</button>
      </div>

      <Table>
        <THead><Th>時間</Th><Th>留言者</Th><Th>留言</Th><Th>團</Th><Th>結果</Th><Th align="right"></Th></THead>
        <TBody>
          {shown === null ? <LoadingRow colSpan={6} /> : shown.length === 0 ? (
            <EmptyRow colSpan={6}>{filter === "todo" ? "沒有要處理的留言 🎉" : "沒有留言"}</EmptyRow>
          ) : shown.map((c) => (
            <Tr key={c.id} className={isTodo(c) ? "bg-amber-50/60 dark:bg-amber-950/20" : ""}>
              <Td className="whitespace-nowrap text-sm text-zinc-500">{fmt(c.commented_at)}</Td>
              <Td className="whitespace-nowrap font-medium">{c.commenter_name ?? "—"}</Td>
              <Td className="max-w-xs whitespace-pre-wrap text-base">{c.text}</Td>
              <Td className="max-w-[12rem] text-sm">
                <div className="truncate" title={c.line_note_posts?.group_buy_campaigns?.name ?? ""}>{c.line_note_posts?.group_buy_campaigns?.name ?? "—"}</div>
                <div className="truncate text-xs text-zinc-500">{communityById.get(c.line_note_posts?.community_id ?? -1)?.home_name ?? ""}</div>
              </Td>
              <Td><div className="flex flex-wrap items-center gap-2 text-sm">{result(c)}</div></Td>
              <Td align="right" className="whitespace-nowrap">{actions(c)}</Td>
            </Tr>
          ))}
        </TBody>
      </Table>
    </div>
  );
}

// ── 貼文：哪些團已經發到哪些社群 ─────────────────────────────────────────────
function PostsTab({ posts, communityById, reload, notify, fail }: {
  posts: Post[] | null; communityById: Map<number, Community>; reload: () => Promise<void>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [busy, setBusy] = useState<number | null>(null);
  const [open, setOpen] = useState<number | null>(null);
  const readNow = async (p: Post) => {
    const c = communityById.get(p.community_id);
    if (!c) return;
    setBusy(p.id);
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", { p_kind: "read", p_account_id: c.account_id, p_community_id: c.id, p_post_id: p.id });
    setBusy(null);
    if (error) return fail(error);
    kickWorker();
    notify("已開始讀取，留言幾秒後會出現在「留言加單」");
  };
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-zinc-500">開團自動發的、和小幫手手貼後被系統認出來的貼文。</p>
        <button type="button" className={btn} onClick={() => void reload()}>重新整理</button>
      </div>
      <Table>
        <THead><Th>團</Th><Th>社群</Th><Th>狀態</Th><Th>發文</Th><Th>最後讀取</Th><Th align="right">留言</Th><Th align="right"></Th></THead>
        <TBody>
          {posts === null ? <LoadingRow colSpan={7} /> : posts.length === 0 ? <EmptyRow colSpan={7}>還沒有貼文</EmptyRow> : posts.map((p) => {
            const c = communityById.get(p.community_id);
            const cs = p.group_buy_campaigns?.status;
            return (
              <Tr key={p.id}>
                <Td>
                  <div className="font-medium">{p.group_buy_campaigns?.name ?? p.campaign_id}</div>
                  <div className="mt-0.5 flex items-center gap-2 text-xs text-zinc-500">
                    {cs && <span className={`rounded px-1.5 py-0.5 ${campaignStatusBadge(cs)}`}>{campaignStatusLabel(cs)}</span>}
                    {p.text && <button type="button" className="underline" onClick={() => setOpen(open === p.id ? null : p.id)}>{open === p.id ? "收起內容" : "看內容"}</button>}
                  </div>
                  {open === p.id && p.text && <pre className="mt-2 whitespace-pre-wrap rounded bg-zinc-50 p-3 text-sm text-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">{p.text}</pre>}
                </Td>
                <Td className="whitespace-nowrap">{c?.home_name || c?.home_id || p.community_id}</Td>
                <Td>
                  <Badge tone={p.status === "posted" ? "green" : p.status === "queued" ? "amber" : p.status === "failed" ? "red" : "gray"}>{POST_STATUS[p.status]}</Badge>
                  {p.last_error && <div className="mt-1 max-w-xs truncate text-xs text-red-600" title={p.last_error}>{p.last_error}</div>}
                </Td>
                <Td className="whitespace-nowrap">{fmt(p.posted_at)}</Td>
                <Td className="whitespace-nowrap">{fmt(p.last_read_at)}</Td>
                <Td align="right" className="tabular-nums">{p.comment_count}</Td>
                <Td align="right">
                  {p.status === "posted" && <SpinButton type="button" className={btn} loading={busy === p.id} onClick={() => readNow(p)}>立即讀取</SpinButton>}
                </Td>
              </Tr>
            );
          })}
        </TBody>
      </Table>
    </div>
  );
}

// ── 小元件 ───────────────────────────────────────────────────────────────────
function Modal({ title, onClose, children, wide }: { title: string; onClose: () => void; children: ReactNode; wide?: boolean }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className={`max-h-[90vh] w-full overflow-y-auto rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900 ${wide ? "max-w-3xl" : "max-w-md"}`} onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-lg font-semibold">{title}</h2>
          <button type="button" className="text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100" onClick={onClose} aria-label="關閉">✕</button>
        </div>
        {children}
      </div>
    </div>
  );
}
