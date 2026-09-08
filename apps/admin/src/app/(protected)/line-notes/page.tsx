"use client";

// LINE 記事本：帳號（備用 LINE 帳號登入）→ 社群設定 → 開團自動發文 → 定時讀留言加單。
// 真正跟 LINE 講話的是地端 worker（tools/line-note-scraper/src/worker.mjs），
// 這頁只做設定、丟工作（line_note_jobs）、看結果。

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { translateRpcError } from "@/lib/rpcError";

type Account = {
  id: number; label: string; status: "logged_out" | "pending_qr" | "active" | "error";
  line_mid: string | null; display_name: string | null;
  qr_image: string | null; qr_url: string | null; pin_code: string | null;
  last_error: string | null; last_seen_at: string | null;
};
type Channel = { id: number; code: string; name: string; channel_type: string; home_store_id: number };
type Community = {
  id: number; account_id: number; channel_id: number; home_id: string; home_name: string | null;
  home_kind: "group" | "square" | "square_chat"; listen_enabled: boolean; read_times: string[];
  auto_post_on_open: boolean; post_template: string | null; last_read_at: string | null; last_error: string | null;
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
  status: "pending" | "ordered" | "unmatched" | "no_order" | "error" | "ignored";
  member_id: number | null; customer_order_id: number | null; error: string | null;
};
type Home = { kind: string; homeId: string; name: string };
type Campaign = { id: number; campaign_no: string; name: string; status: string };

const ACCOUNT_STATUS: Record<Account["status"], string> = {
  logged_out: "未登入", pending_qr: "等待掃 QR", active: "已登入", error: "錯誤",
};
const POST_STATUS: Record<Post["status"], string> = { queued: "排隊中", posted: "已發文", failed: "失敗", closed: "已結束" };
const COMMENT_STATUS: Record<Comment["status"], string> = {
  pending: "待處理", ordered: "已加單", unmatched: "找不到會員", no_order: "非下單", error: "錯誤", ignored: "忽略",
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

const btn = "rounded border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800";
const btnPrimary = "rounded bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";
const input = "w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900";

export default function LineNotesPage() {
  const [tab, setTab] = useState<"accounts" | "communities" | "posts">("accounts");
  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [channels, setChannels] = useState<Channel[]>([]);
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
      sb.from("line_channels").select("id,code,name,channel_type,home_store_id").eq("is_active", true).order("name"),
    ]);
    if (c.error) fail(c.error); else setCommunities((c.data ?? []) as Community[]);
    if (!ch.error) setChannels((ch.data ?? []) as Channel[]);
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
  const channelById = useMemo(() => new Map(channels.map((c) => [c.id, c])), [channels]);
  const communityById = useMemo(() => new Map((communities ?? []).map((c) => [c.id, c])), [communities]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">LINE 記事本</h1>
          <p className="text-sm text-zinc-500">
            備用 LINE 帳號登入 → 綁社群 → 開團自動發文 → 定時讀留言，留言裡的「會員編號 6 碼 ＋ A+1」自動加單。
            要有地端 worker 在跑（<code>tools/line-note-scraper</code>：<code>npm run worker</code>）。
          </p>
        </div>
        <nav className="flex gap-1 rounded-lg bg-zinc-100 p-1 dark:bg-zinc-800">
          {([["accounts", "帳號"], ["communities", "社群設定"], ["posts", "貼文與留言"]] as const).map(([k, l]) => (
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
          communities={communities} accounts={accounts ?? []} channels={channels}
          accountById={accountById} channelById={channelById}
          reload={loadCommunities} reloadPosts={loadPosts} notify={notify} fail={fail}
        />
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
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", { p_kind: kind, p_account_id: a.id });
    setBusy(null);
    if (error) return fail(error);
    if (kind === "login") setLoginId(a.id);
    else notify("已送出登出");
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
        <THead><Tr><Th>名稱</Th><Th>狀態</Th><Th>LINE 顯示名稱</Th><Th>最後活動</Th><Th>錯誤</Th><Th align="right">操作</Th></Tr></THead>
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
            <p className="text-zinc-500">等待 worker 產生 QR…（worker 沒在跑的話會一直停在這裡）</p>
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
  id: number | null; account_id: number | ""; channel_id: number | ""; home_id: string; home_name: string;
  listen_enabled: boolean; read_times: string; auto_post_on_open: boolean; post_template: string;
};
const EMPTY_FORM: CommunityForm = {
  id: null, account_id: "", channel_id: "", home_id: "", home_name: "",
  listen_enabled: true, read_times: "12:00", auto_post_on_open: true, post_template: "",
};

function CommunitiesTab({ communities, accounts, channels, accountById, channelById, reload, reloadPosts, notify, fail }: {
  communities: Community[] | null; accounts: Account[]; channels: Channel[];
  accountById: Map<number, Account>; channelById: Map<number, Channel>;
  reload: () => Promise<void>; reloadPosts: () => Promise<void>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [form, setForm] = useState<CommunityForm | null>(null);
  const [busy, setBusy] = useState<number | "save" | "homes" | null>(null);
  const [homes, setHomes] = useState<Home[] | null>(null);
  const [postFor, setPostFor] = useState<Community | null>(null);

  const openNew = () => { setHomes(null); setForm({ ...EMPTY_FORM, account_id: accounts[0]?.id ?? "", channel_id: channels[0]?.id ?? "" }); };
  const openEdit = (c: Community) => {
    setHomes(null);
    setForm({ id: c.id, account_id: c.account_id, channel_id: c.channel_id, home_id: c.home_id, home_name: c.home_name ?? "",
      listen_enabled: c.listen_enabled, read_times: c.read_times.join(", "), auto_post_on_open: c.auto_post_on_open, post_template: c.post_template ?? "" });
  };

  const loadHomes = async () => {
    if (!form || form.account_id === "") return;
    setBusy("homes");
    try {
      const sb = getSupabase();
      const { data: jobId, error } = await sb.rpc("rpc_line_note_enqueue", { p_kind: "list_homes", p_account_id: form.account_id });
      if (error) throw error;
      for (let i = 0; i < 40; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        const { data } = await sb.from("line_note_jobs").select("status,result,error").eq("id", jobId).single();
        if (data?.status === "done") { setHomes(((data.result as { homes?: Home[] })?.homes) ?? []); return; }
        if (data?.status === "failed") throw new Error(data.error ?? "worker 回報失敗");
      }
      throw new Error("等太久沒回應：worker 有在跑嗎？帳號登入了嗎？");
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const save = async () => {
    if (!form) return;
    setBusy("save");
    const { error } = await getSupabase().rpc("rpc_line_note_community_upsert", {
      p_id: form.id, p_account_id: form.account_id || null, p_channel_id: form.channel_id || null,
      p_home_id: form.home_id.trim(), p_home_name: form.home_name.trim() || null, p_home_kind: kindOf(form.home_id.trim()),
      p_listen_enabled: form.listen_enabled,
      p_read_times: form.read_times.split(/[,\s，、]+/).map((s) => s.trim()).filter(Boolean),
      p_auto_post_on_open: form.auto_post_on_open, p_post_template: form.post_template || null,
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
    notify("已排立即讀取，worker 跑完後到「貼文與留言」看");
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-zinc-500">
          「取貨門市」跟開團的 LINE 渠道共用（line_channels）：開團時有勾到這個渠道，才會自動發到這個社群；加單的取貨店也用渠道的主店。
        </p>
        <button type="button" className={btnPrimary} onClick={openNew} disabled={accounts.length === 0}>＋ 新增社群</button>
      </div>
      <Table>
        <THead><Tr><Th>社群</Th><Th>帳號</Th><Th>渠道 / 取貨店</Th><Th>監聽</Th><Th>讀取時間</Th><Th>開團自動發文</Th><Th>最後讀取</Th><Th align="right">操作</Th></Tr></THead>
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
                <Td>{channelById.get(c.channel_id)?.name ?? c.channel_id}</Td>
                <Td><Badge tone={c.listen_enabled ? "green" : "gray"}>{c.listen_enabled ? "監聽中" : "停用"}</Badge></Td>
                <Td className="font-mono text-xs">{c.read_times.join(" ")}</Td>
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
            <label className="text-sm">渠道（決定取貨店）
              <select className={input} value={form.channel_id} onChange={(e) => setForm({ ...form, channel_id: Number(e.target.value) })}>
                {channels.map((ch) => <option key={ch.id} value={ch.id}>{ch.name}（{ch.code}）</option>)}
              </select>
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
    notify("已排發文，worker 跑完後到「貼文與留言」看");
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
function PostsTab({ posts, communityById, reload, notify, fail }: {
  posts: Post[] | null; communityById: Map<number, Community>; reload: () => Promise<void>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [selected, setSelected] = useState<Post | null>(null);
  const [comments, setComments] = useState<Comment[] | null>(null);
  const [busy, setBusy] = useState<number | null>(null);

  const loadComments = useCallback(async (post: Post) => {
    const { data, error } = await getSupabase().from("line_note_comments").select("*").eq("post_id", post.id).order("commented_at", { ascending: true }).order("id");
    if (error) fail(error); else setComments((data ?? []) as Comment[]);
  }, [fail]);
  useEffect(() => { if (selected) void loadComments(selected); else setComments(null); }, [selected, loadComments]);

  const retry = async (c: Comment) => {
    setBusy(c.id);
    const { data, error } = await getSupabase().rpc("rpc_line_note_apply_comment", { p_comment_id: c.id });
    setBusy(null);
    if (error) return fail(error);
    const r = (Array.isArray(data) ? data[0] : data) as { out_status?: string; out_error?: string } | null;
    notify(r?.out_status === "ordered" ? "已加單" : `結果：${COMMENT_STATUS[(r?.out_status ?? "error") as Comment["status"]] ?? r?.out_status}${r?.out_error ? "：" + r.out_error : ""}`);
    if (selected) await loadComments(selected);
  };
  const setStatus = async (c: Comment, status: Comment["status"]) => {
    setBusy(c.id);
    const { error } = await getSupabase().from("line_note_comments").update({ status, error: null }).eq("id", c.id);
    setBusy(null);
    if (error) return fail(error);
    if (selected) await loadComments(selected);
  };
  const readNow = async (p: Post) => {
    const c = communityById.get(p.community_id);
    if (!c) return;
    setBusy(p.id);
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", { p_kind: "read", p_account_id: c.account_id, p_community_id: c.id, p_post_id: p.id });
    setBusy(null);
    if (error) return fail(error);
    notify("已排讀取這篇");
  };

  const summary = useMemo(() => {
    if (!comments) return null;
    const n = (s: Comment["status"]) => comments.filter((c) => c.status === s).length;
    return { ordered: n("ordered"), pending: n("pending"), unmatched: n("unmatched"), error: n("error"), no_order: n("no_order"), ignored: n("ignored") };
  }, [comments]);

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-zinc-500">點一篇貼文看底下留言與加單結果。「找不到會員」「錯誤」可以修正後按「重試」，或標「忽略」。</p>
        <button type="button" className={btn} onClick={() => void reload()}>重新整理</button>
      </div>
      <Table>
        <THead><Tr><Th>團</Th><Th>社群</Th><Th>狀態</Th><Th>發文時間</Th><Th>最後讀取</Th><Th align="right">留言數</Th><Th align="right">操作</Th></Tr></THead>
        <TBody>
          {posts === null ? <LoadingRow colSpan={7} /> : posts.length === 0 ? <EmptyRow colSpan={7}>還沒有貼文</EmptyRow> : posts.map((p) => {
            const c = communityById.get(p.community_id);
            return (
              <Tr key={p.id} onClick={() => setSelected(p)} className={selected?.id === p.id ? "bg-zinc-100 dark:bg-zinc-800" : ""}>
                <Td>
                  <div>{p.group_buy_campaigns?.name ?? p.campaign_id}</div>
                  <div className="text-xs text-zinc-500">{p.group_buy_campaigns?.campaign_no}（{p.group_buy_campaigns?.status}）</div>
                </Td>
                <Td>{c?.home_name || c?.home_id || p.community_id}</Td>
                <Td>
                  <Badge tone={p.status === "posted" ? "green" : p.status === "queued" ? "amber" : p.status === "failed" ? "red" : "gray"}>{POST_STATUS[p.status]}</Badge>
                  {p.last_error && <div className="max-w-xs truncate text-xs text-red-600" title={p.last_error}>{p.last_error}</div>}
                </Td>
                <Td>{fmt(p.posted_at)}</Td>
                <Td>{fmt(p.last_read_at)}</Td>
                <Td align="right">{p.comment_count}</Td>
                <Td align="right">
                  {p.status === "posted" && (
                    <SpinButton type="button" className={btn} loading={busy === p.id} onClick={(e) => { e.stopPropagation(); void readNow(p); }}>立即讀取</SpinButton>
                  )}
                </Td>
              </Tr>
            );
          })}
        </TBody>
      </Table>

      {selected && (
        <div className="space-y-2 rounded border border-zinc-200 p-3 dark:border-zinc-800">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="font-medium">留言：{selected.group_buy_campaigns?.name}</h2>
            {summary && (
              <div className="flex flex-wrap gap-1 text-xs">
                <Badge tone="green">已加單 {summary.ordered}</Badge>
                <Badge tone="amber">待處理 {summary.pending}</Badge>
                <Badge tone="red">找不到會員 {summary.unmatched}</Badge>
                <Badge tone="red">錯誤 {summary.error}</Badge>
                <Badge tone="gray">非下單 {summary.no_order}</Badge>
                <Badge tone="gray">忽略 {summary.ignored}</Badge>
              </div>
            )}
          </div>
          {selected.text && <details className="text-xs text-zinc-500"><summary>貼文內容</summary><pre className="whitespace-pre-wrap">{selected.text}</pre></details>}
          <Table>
            <THead><Tr><Th>時間</Th><Th>留言者</Th><Th>留言</Th><Th>會員編號</Th><Th>解析</Th><Th>狀態</Th><Th align="right">操作</Th></Tr></THead>
            <TBody>
              {comments === null ? <LoadingRow colSpan={7} /> : comments.length === 0 ? <EmptyRow colSpan={7}>還沒讀到留言</EmptyRow> : comments.map((c) => (
                <Tr key={c.id}>
                  <Td className="whitespace-nowrap text-xs">{fmt(c.commented_at)}</Td>
                  <Td><div>{c.commenter_name ?? "—"}</div><div className="font-mono text-[10px] text-zinc-400">{c.commenter_id}</div></Td>
                  <Td className="max-w-sm whitespace-pre-wrap text-sm">{c.text}</Td>
                  <Td className="font-mono">{c.member_no_hint ?? "—"}</Td>
                  <Td className="font-mono text-xs">{(c.parsed ?? []).map((o, i) => <div key={i}>{o.cancel ? "取消 " : ""}{o.code ?? "(單品)"} ×{o.qty}</div>)}</Td>
                  <Td>
                    <Badge tone={c.status === "ordered" ? "green" : c.status === "pending" ? "amber" : c.status === "unmatched" || c.status === "error" ? "red" : "gray"}>{COMMENT_STATUS[c.status]}</Badge>
                    {c.error && <div className="max-w-xs text-xs text-red-600">{c.error}</div>}
                    {c.customer_order_id && <div className="text-xs text-zinc-500">訂單 #{c.customer_order_id}</div>}
                  </Td>
                  <Td align="right">
                    <div className="flex justify-end gap-1">
                      {c.status !== "ordered" && c.status !== "ignored" && <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => retry(c)}>重試</SpinButton>}
                      {c.status !== "ordered" && c.status !== "ignored" && <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => setStatus(c, "ignored")}>忽略</SpinButton>}
                      {c.status === "ignored" && <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => setStatus(c, "pending")}>取消忽略</SpinButton>}
                    </div>
                  </Td>
                </Tr>
              ))}
            </TBody>
          </Table>
        </div>
      )}
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
