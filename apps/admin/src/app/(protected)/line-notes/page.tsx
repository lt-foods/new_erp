"use client";

// LINE 記事本：帳號（備用 LINE 帳號登入）→ 社群設定 → 開團自動發文 → 定時讀留言加單。
// 真正跟 LINE 講話的是地端 worker（tools/line-note-scraper/src/worker.mjs），
// 這頁只做設定、丟工作（line_note_jobs）、看結果。

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { translateRpcError } from "@/lib/rpcError";
import { CAMPAIGN_STATUSES, campaignStatusBadge, campaignStatusLabel } from "@/lib/campaignStatus";
import { Modal as SharedModal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import { OrderEntryView } from "@/components/OrderEntryView";
import {
  COMMENT_STATUS_LABEL, HOME_KIND_LABEL, POST_STATUS_LABEL, commentStats, fmtNoteTime, isTodoComment,
} from "@/lib/lineNoteStatus";
import { deleteLineNotePost } from "@/lib/lineNoteDelete";
import { canOperateLineNotes, useRole } from "@/lib/role";
import { useHasStaffPerm } from "@/lib/staffPerms";

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
  auto_post_on_open: boolean; post_template: string | null; read_days: number; react_on_confirm: boolean;
  sales_channels: string[] | null;
  last_read_at: string | null; last_error: string | null;
};
type Post = {
  id: number; community_id: number; campaign_id: number | null; line_post_id: string | null; text: string | null;
  status: "queued" | "posted" | "failed" | "closed" | "unlinked"; posted_at: string | null; last_read_at: string | null;
  comment_count: number; last_error: string | null; created_at: string;
  closed_at: string | null; closed_reason: string | null; closed_comment_id: number | null;
  group_buy_campaigns: { id: number; campaign_no: string; name: string; status: string } | null;
};
type Comment = {
  id: number; line_comment_id: string; commenter_id: string | null; commenter_name: string | null; text: string;
  commented_at: string | null; member_no_hint: string | null; parsed: { code: string | null; qty: number; cancel: boolean }[];
  status: "pending" | "ordered" | "unmatched" | "no_order" | "error" | "ignored" | "resolved" | "duplicate";
  member_id: number | null; customer_order_id: number | null; error: string | null; reacted_at: string | null;
  resolved_at: string | null; resolution_note: string | null;
};
type Row = Comment & { line_note_posts: { community_id: number; campaign_id: number; group_buy_campaigns: { id: number; name: string; campaign_no: string } | null } | null };
type OrderInfo = { id: number; order_no: string; store_name: string | null };
type PostStat = ReturnType<typeof commentStats>;
type Home = { kind: string; homeId: string; name: string };
type Campaign = { id: number; campaign_no: string; name: string; status: string; sales_channel: string | null };

const ACCOUNT_STATUS: Record<Account["status"], string> = {
  logged_out: "未登入", pending_qr: "等待掃 QR", active: "已登入", error: "錯誤",
};
// 狀態文字 / 留言統計 / 時間格式都在 @/lib/lineNoteStatus —— 開團的「LINE 記事本」
// 彈窗（LineNotePostsModal）畫同一批東西，兩邊各寫一份就會出現徽章數字對不起來。
const POST_STATUS = POST_STATUS_LABEL;
const COMMENT_STATUS = COMMENT_STATUS_LABEL;
const KIND_LABEL = HOME_KIND_LABEL;
const fmt = fmtNoteTime;
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

// 點訂單號開的明細彈窗（整頁共用一個；比照 CampaignOrdersPanel / MemberDetail 的用法）
type OrderPopup = { id: number; no: string };
const OrderPopupContext = createContext<((o: OrderPopup) => void) | null>(null);
function useOpenOrder() { return useContext(OrderPopupContext); }

/** 訂單號連結：點了開明細彈窗 */
function OrderLink({ id, no }: { id: number; no: string }) {
  const open = useOpenOrder();
  return (
    <button type="button" className="font-mono text-sky-700 underline hover:text-sky-900 dark:text-sky-400 dark:hover:text-sky-200"
      onClick={(e) => { e.stopPropagation(); open?.({ id, no }); }}>
      {no}
    </button>
  );
}

type Tab = "accounts" | "communities" | "comments" | "posts";

export default function LineNotesPage() {
  // 唯讀模式：非總部角色、但被個別授予 line_notes_view 功能權限（員工管理 → 功能權限）。
  // 只有「留言加單」「貼文」兩個分頁、沒有任何操作按鈕；帳號 / 社群設定不給看
  // （v_line_note_accounts 本來就只放總部角色，讀回來會是空的）。
  // 寬嚴由 DB 決定（20260918000000 的 SELECT policy）；這裡只是不畫按下去必定失敗的按鈕。
  const role = useRole();
  const canOperate = role !== null && canOperateLineNotes(role);
  const hasViewPerm = useHasStaffPerm("line_notes_view");
  const readOnly = !canOperate;
  // 留言加單的處理鈕（重試／指定會員／已解決／忽略）perm 持有者也能按 —— DB 端 20260918020000
  // 有對應的 UPDATE policy 與 RPC gate；貼文分頁的「指定團」也開給 perm 持有者
  //（20260919000000，rpc_line_note_post_link 改走 _line_note_require_post_access）。
  // 立即讀取／恢復讀取／刪除仍只有總部。
  const canProcessComments = canOperate || hasViewPerm;
  const [tab, setTab] = useState<Tab>("accounts");
  const [orderPopup, setOrderPopup] = useState<OrderPopup | null>(null);
  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [communities, setCommunities] = useState<Community[] | null>(null);
  // 貼文清單改由 PostsTab 自己分頁抓（伺服端分頁 + 篩選），這裡只負責叫它重抓
  const [postsTick, setPostsTick] = useState(0);
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
  const reloadPosts = useCallback(async () => { setPostsTick((t) => t + 1); }, []);

  // 帳號清單只有總部讀得到；唯讀模式不抓、也不輪詢
  useEffect(() => { if (canOperate) void loadAccounts(); void loadCommunities(); }, [canOperate, loadAccounts, loadCommunities]);

  // 帳號狀態每 3 秒刷新（登入中 / worker 有沒有在跑）
  useEffect(() => {
    if (!canOperate) return;
    const t = setInterval(() => { void loadAccounts(); }, 3000);
    return () => clearInterval(t);
  }, [canOperate, loadAccounts]);

  // 唯讀模式沒有帳號 / 社群設定分頁：停在那兩頁就改看貼文
  const shownTab: Tab = readOnly && (tab === "accounts" || tab === "communities") ? "posts" : tab;

  const accountById = useMemo(() => new Map((accounts ?? []).map((a) => [a.id, a])), [accounts]);
  const storeById = useMemo(() => new Map(stores.map((s) => [s.id, s])), [stores]);
  const communityById = useMemo(() => new Map((communities ?? []).map((c) => [c.id, c])), [communities]);

  if (role === null) {
    return <div className="p-6 text-sm text-zinc-500">讀取權限中…</div>;
  }
  if (readOnly && !hasViewPerm) {
    return (
      <div className="p-6 text-sm text-zinc-500">
        沒有檢視 LINE 記事本的權限。請負責人 / 管理員到「員工管理 → 功能權限」勾選「LINE 記事本：可檢視」（勾完需重新登入）。
      </div>
    );
  }

  const tabs: ReadonlyArray<readonly [Tab, string]> = readOnly
    ? [["comments", "留言加單"], ["posts", "貼文"]]
    : [["accounts", "帳號"], ["communities", "社群設定"], ["comments", "留言加單"], ["posts", "貼文"]];

  return (
    <OrderPopupContext.Provider value={setOrderPopup}>
    <div className="flex flex-1 flex-col gap-4 p-6">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">LINE 記事本</h1>
          <p className="text-sm text-zinc-500">
            {readOnly
              ? "可看社群貼文與留言加單狀況，並處理留言（重試／指定會員／已解決／忽略）。發文、讀留言由總部操作。"
              : <>備用 LINE 帳號登入 → 綁社群 → 開團自動發文 → 定時讀留言，留言裡的「會員編號 6 碼 ＋ A+1」自動加單。
                到設定的讀取時間自動跑（Supabase 排程），不用另外開程式。</>}
          </p>
        </div>
        <nav className="flex gap-1 rounded-lg bg-zinc-100 p-1 dark:bg-zinc-800">
          {tabs.map(([k, l]) => (
            <button key={k} type="button" onClick={() => setTab(k)}
              className={`rounded-md px-3 py-1 text-sm ${shownTab === k ? "bg-white shadow dark:bg-zinc-900" : "text-zinc-600 dark:text-zinc-300"}`}>
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

      {shownTab === "accounts" && !readOnly && (
        <AccountsTab accounts={accounts} reload={loadAccounts} notify={notify} fail={fail} />
      )}
      {shownTab === "communities" && !readOnly && (
        <CommunitiesTab
          communities={communities} accounts={accounts ?? []} stores={stores}
          accountById={accountById} storeById={storeById}
          reload={loadCommunities} reloadPosts={reloadPosts} notify={notify} fail={fail}
        />
      )}
      {shownTab === "comments" && (
        <CommentsTab communityById={communityById} notify={notify} fail={fail} readOnly={!canProcessComments} />
      )}
      {shownTab === "posts" && (
        <PostsTab communities={communities ?? []} communityById={communityById} tick={postsTick} notify={notify} fail={fail} readOnly={readOnly} canLink={canProcessComments} />
      )}

      <SharedModal
        open={orderPopup !== null}
        onClose={() => setOrderPopup(null)}
        title={`訂單明細 ${orderPopup?.no ?? ""}`}
        maxWidth="max-w-4xl"
      >
        {orderPopup && (
          <OrderDetail orderId={orderPopup.id} onNavigate={(id, no) => setOrderPopup({ id, no })} />
        )}
      </SharedModal>
    </div>
    </OrderPopupContext.Provider>
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
  // 刪帳號會連底下的社群 → 貼文 → 留言一路 CASCADE 掉，所以先把數量算給他看：
  // 「會一起刪掉」講得太輕，真的按下去是一次刪掉上千筆留言紀錄。
  const remove = async (a: Account) => {
    setBusy(a.id);
    const sb = getSupabase();
    const { data: cs } = await sb.from("line_note_communities").select("id").eq("account_id", a.id);
    const ids = (cs ?? []).map((c) => c.id);
    let posts = 0, comments = 0;
    if (ids.length) {
      const { count: pc } = await sb.from("line_note_posts").select("id", { count: "exact", head: true }).in("community_id", ids);
      posts = pc ?? 0;
      const { data: ps } = await sb.from("line_note_posts").select("id").in("community_id", ids);
      const pids = (ps ?? []).map((x) => x.id);
      if (pids.length) {
        const { count: cc } = await sb.from("line_note_comments").select("id", { count: "exact", head: true }).in("post_id", pids);
        comments = cc ?? 0;
      }
    }
    setBusy(null);
    const scale = ids.length === 0 ? "底下沒有社群設定。"
      : `會一起刪掉：社群設定 ${ids.length} 個、貼文紀錄 ${posts} 篇、留言紀錄 ${comments} 則。`;
    if (!window.confirm(
      `刪除帳號「${a.label}」？\n\n${scale}\n已經加出來的訂單不會動。\n\n` +
      `只是要換帳號的話請按「登出」，不用刪除。`)) return;
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
  react_on_confirm: boolean; sales_channels: string[];
};
const EMPTY_FORM: CommunityForm = {
  id: null, account_id: "", store_id: "", home_id: "", home_name: "",
  listen_enabled: true, read_times: "12:00", auto_post_on_open: true, post_template: "", read_days: 3,
  react_on_confirm: true, sales_channels: ["main"],
};
// 這個社群收哪幾類的團（group_buy_campaigns.sales_channel）。DB 那邊是
// line_note_communities.sales_channels + _line_note_takes_channel()（20260921020000），
// 三支發文 RPC 與開團自動發文的 trigger 都吃它，這裡只是把同一份設定畫出來。
const CHANNEL_OPTIONS: { value: string; label: string }[] = [
  { value: "main", label: "一般商城" },
  { value: "piaopiao", label: "漂漂館" },
];
const channelLabels = (chs: string[] | null | undefined) =>
  (chs && chs.length ? chs : ["main"]).map((c) => CHANNEL_OPTIONS.find((o) => o.value === c)?.label ?? c);

function CommunitiesTab({ communities, accounts, stores, accountById, storeById, reload, reloadPosts, notify, fail }: {
  communities: Community[] | null; accounts: Account[]; stores: Store[];
  accountById: Map<number, Account>; storeById: Map<number, Store>;
  reload: () => Promise<void>; reloadPosts: () => Promise<void>; notify: (m: string) => void; fail: (e: unknown) => void;
}) {
  const [form, setForm] = useState<CommunityForm | null>(null);
  const [busy, setBusy] = useState<number | "save" | "homes" | "sync" | null>(null);
  const [homes, setHomes] = useState<Home[] | null>(null);
  // 新增時可以一次勾好幾個社群／群組，共用同一份設定（編輯時只認一個，所以不用）
  const [picked, setPicked] = useState<Home[]>([]);
  const [postFor, setPostFor] = useState<Community | null>(null);

  // 新增模式下勾了社群 = 批次建立；編輯模式永遠是單一社群
  const multi = form?.id === null && picked.length > 0;

  const openNew = () => { setHomes(null); setPicked([]); setForm({ ...EMPTY_FORM, account_id: accounts[0]?.id ?? "" }); };
  const openEdit = (c: Community) => {
    setHomes(null); setPicked([]);
    setForm({ id: c.id, account_id: c.account_id, store_id: c.store_id ?? "", home_id: c.home_id, home_name: c.home_name ?? "",
      listen_enabled: c.listen_enabled, read_times: c.read_times.join(", "), auto_post_on_open: c.auto_post_on_open, post_template: c.post_template ?? "", read_days: c.read_days ?? 3, react_on_confirm: c.react_on_confirm ?? true,
      sales_channels: c.sales_channels?.length ? c.sales_channels : ["main"] });
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

  // 勾了好幾個社群就一個一個建（同一份設定）。一個失敗不影響其他個，
  // 最後把失敗的社群名字一起講清楚，不要只說「儲存失敗」讓人不知道是哪一個。
  const save = async () => {
    if (!form) return;
    const targets = multi
      ? picked.map((h) => ({ home_id: h.homeId, home_name: h.name }))
      : [{ home_id: form.home_id.trim(), home_name: form.home_name.trim() || null }];
    if (targets.some((t) => !t.home_id)) return fail(new Error("請選擇社群"));
    // 一種都沒勾 = 這個社群什麼團都收不到（DB 也會擋），先在這裡講清楚
    if (form.sales_channels.length === 0) return fail(new Error("請至少勾一種要發的團（一般商城／漂漂館）"));

    setBusy("save");
    const sb = getSupabase();
    const shared = {
      p_account_id: form.account_id || null, p_store_id: form.store_id || null,
      p_listen_enabled: form.listen_enabled,
      p_read_times: form.read_times.split(/[,\s，、]+/).map((s) => s.trim()).filter(Boolean),
      p_auto_post_on_open: form.auto_post_on_open, p_post_template: form.post_template || null,
      p_read_days: Math.min(30, Math.max(1, Math.round(form.read_days || 3))),
      p_react_on_confirm: form.react_on_confirm,
      p_sales_channels: form.sales_channels,
    };
    const failed: string[] = [];
    for (const t of targets) {
      const { error } = await sb.rpc("rpc_line_note_community_upsert", {
        ...shared, p_id: multi ? null : form.id,
        p_home_id: t.home_id, p_home_name: t.home_name, p_home_kind: kindOf(t.home_id),
      });
      if (error) failed.push(`${t.home_name || t.home_id}：${translateRpcError(error)}`);
    }
    setBusy(null);
    await reload();
    if (failed.length) return fail(new Error(failed.join("\n")));
    notify(targets.length > 1 ? `已儲存 ${targets.length} 個社群` : "已儲存");
    setForm(null);
    setPicked([]);
  };
  const remove = async (c: Community) => {
    if (!window.confirm(`刪除社群「${c.home_name || c.home_id}」的設定？\n\n之後同步也不會再自動把它加回來（要的話用「＋ 新增社群」再選一次）。`)) return;
    setBusy(c.id);
    const { error } = await getSupabase().rpc("rpc_line_note_community_delete", { p_id: c.id });
    setBusy(null);
    if (error) return fail(error);
    await reload();
  };
  // 跟每個登入中的帳號要一次群組清單；worker 收到後會把沒看過的社群長出來（一律停用）
  const syncAll = async () => {
    const live = accounts.filter((a) => a.status === "active");
    if (live.length === 0) return fail(new Error("沒有已登入的帳號，請先到「帳號」分頁登入"));
    setBusy("sync");
    const sb = getSupabase();
    try {
      const ids: number[] = [];
      for (const a of live) {
        const { data, error } = await sb.rpc("rpc_line_note_enqueue", { p_kind: "list_homes", p_account_id: a.id });
        if (error) throw error;
        ids.push(data as number);
      }
      kickWorker();
      // 等 worker 跑完再刷新，不然畫面上還是舊的清單
      for (let i = 0; i < 40; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        const { data } = await sb.from("line_note_jobs").select("id,status").in("id", ids);
        if ((data ?? []).every((j) => j.status === "done" || j.status === "failed")) break;
      }
      await reload();
      notify("已同步；新出現的社群都是停用的，要哪幾個自己開監聽");
    } catch (e) { fail(e); } finally { setBusy(null); }
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
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-zinc-500">
          清單跟著帳號走：帳號加入的群組／社群會自己出現在這裡，一開始都是<b>停用</b>的，要哪幾個自己開監聽。
          總部開的團會發到所有開自動發文的社群；店家自開的團只發到標了那家店的社群。加單的取貨店一律跟會員自己設定的店。
          每個社群還要選<b>收哪一類的團</b>：漂漂館的團只發得到有勾「漂漂館」的社群，一般商城的團同理。
        </p>
        <div className="flex shrink-0 gap-2">
          <SpinButton type="button" className={btn} loading={busy === "sync"} onClick={syncAll}
            disabled={accounts.length === 0}>同步社群</SpinButton>
          <button type="button" className={btnPrimary} onClick={openNew} disabled={accounts.length === 0}>＋ 新增社群</button>
        </div>
      </div>
      <Table>
        <THead><Th>社群</Th><Th>帳號</Th><Th>店家</Th><Th>收哪類團</Th><Th>監聽</Th><Th>讀取時間</Th><Th>開團自動發文</Th><Th>最後讀取</Th><Th align="right">操作</Th></THead>
        <TBody>
          {communities === null ? <LoadingRow colSpan={9} /> : communities.length === 0 ? <EmptyRow colSpan={9}>還沒有社群</EmptyRow> : communities.map((c) => {
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
                <Td>
                  <div className="flex flex-wrap gap-1">
                    {channelLabels(c.sales_channels).map((l) => (
                      <Badge key={l} tone={l === "漂漂館" ? "blue" : "gray"}>{l}</Badge>
                    ))}
                  </div>
                </Td>
                <Td><Badge tone={c.listen_enabled ? "green" : "gray"}>{c.listen_enabled ? "監聽中" : "停用"}</Badge></Td>
                <Td className="font-mono text-xs">{c.read_times.join(" ")}<div className="text-zinc-400">近 {c.read_days} 天</div></Td>
                <Td>{c.auto_post_on_open ? "是" : "否"}</Td>
                <Td>{fmt(c.last_read_at)}</Td>
                <Td align="right">
                  <div className="flex justify-end gap-1 whitespace-nowrap">
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
        <Modal title={form.id ? "編輯社群" : picked.length > 1 ? `新增 ${picked.length} 個社群` : "新增社群"}
          onClose={() => setForm(null)} wide>
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
                  <input className={`${input} font-mono`} value={multi ? `已勾選 ${picked.length} 個` : form.home_id}
                    placeholder="m… / c… / s…" disabled={multi}
                    onChange={(e) => setForm({ ...form, home_id: e.target.value })} />
                </label>
                <SpinButton type="button" className={btn} loading={busy === "homes"} onClick={loadHomes}>從帳號載入清單</SpinButton>
              </div>
              {homes && homes.length === 0 && (
                <p className="mt-2 text-sm text-zinc-500">這個帳號沒有加入任何群組／社群</p>
              )}
              {homes && homes.length > 0 && form.id === null && (
                <>
                  <div className="mt-2 flex items-center justify-between text-xs text-zinc-500">
                    <span>勾幾個就建幾個，下面的設定會一起套用（已設定過的會被覆蓋成這裡的設定）</span>
                    <button type="button" className={btn}
                      onClick={() => setPicked(picked.length === homes.length ? [] : homes)}>
                      {picked.length === homes.length ? "全部取消" : "全選"}
                    </button>
                  </div>
                  <ul className="mt-1 max-h-60 divide-y divide-zinc-200 overflow-auto rounded border border-zinc-300 dark:divide-zinc-800 dark:border-zinc-700">
                    {homes.map((h) => {
                      const done = (communities ?? []).some((c) => c.home_id === h.homeId);
                      return (
                        <li key={h.homeId}>
                          <label className="flex cursor-pointer items-center gap-2 px-2 py-1.5 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800">
                            <input type="checkbox" checked={picked.some((x) => x.homeId === h.homeId)}
                              onChange={(e) => setPicked(e.target.checked
                                ? [...picked, h]
                                : picked.filter((x) => x.homeId !== h.homeId))} />
                            <span className="shrink-0 text-xs text-zinc-500">[{KIND_LABEL[h.kind] ?? h.kind}]</span>
                            <span className="min-w-0 flex-1 truncate">{h.name}</span>
                            {done && <Badge tone="gray">已設定</Badge>}
                          </label>
                        </li>
                      );
                    })}
                  </ul>
                </>
              )}
              {homes && homes.length > 0 && form.id !== null && (
                <select className={`${input} mt-2`} size={Math.min(8, Math.max(2, homes.length))}
                  onChange={(e) => {
                    const h = homes.find((x) => x.homeId === e.target.value);
                    if (h) setForm({ ...form, home_id: h.homeId, home_name: h.name });
                  }}>
                  {homes.map((h) => (
                    <option key={h.homeId} value={h.homeId}>
                      [{KIND_LABEL[h.kind] ?? h.kind}] {h.name} — {h.homeId}
                    </option>
                  ))}
                </select>
              )}
              <p className="mt-1 text-xs text-zinc-500">社群記事本先選「社群聊天室」（m…）；不行再試「社群」（s…）。群組用 c…。</p>
            </div>
            <label className="text-sm">顯示名稱
              <input className={input} disabled={multi} value={multi ? "各自沿用社群名稱" : form.home_name}
                onChange={(e) => setForm({ ...form, home_name: e.target.value })} />
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
            <div className="text-sm md:col-span-2">
              收哪一類的團（漂漂館的團只發得到有勾漂漂館的社群）
              <div className="mt-1 flex flex-wrap gap-4">
                {CHANNEL_OPTIONS.map((o) => (
                  <label key={o.value} className="flex items-center gap-2">
                    <input type="checkbox" checked={form.sales_channels.includes(o.value)}
                      onChange={(e) => setForm({
                        ...form,
                        sales_channels: e.target.checked
                          ? [...form.sales_channels, o.value]
                          : form.sales_channels.filter((c) => c !== o.value),
                      })} /> {o.label}
                  </label>
                ))}
              </div>
              {form.sales_channels.length === 0 && (
                <div className="mt-1 text-xs text-red-600">至少要勾一種，不然這個社群什麼團都收不到。</div>
              )}
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={form.auto_post_on_open} onChange={(e) => setForm({ ...form, auto_post_on_open: e.target.checked })} /> 開團（狀態變「開團中」）時自動發文
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={form.react_on_confirm} onChange={(e) => setForm({ ...form, react_on_confirm: e.target.checked })} /> 收到單後在客人留言上按 😄，讓他知道收到了
            </label>
            <label className="text-sm md:col-span-2">發文模板（留空用預設；可用 {"{{title}} {{items}} {{deadline}} {{description}} {{howto}} {{link}} {{tag}} {{name}} {{end_at}} {{pickup_deadline}}"}）
              <textarea className={`${input} h-40 font-mono text-xs`} value={form.post_template} onChange={(e) => setForm({ ...form, post_template: e.target.value })}
                placeholder={"{{title}}\n\n{{items}}\n\n{{deadline}}\n\n{{description}}\n\n{{howto}}\n{{link}}\n#開團\n{{tag}}"} />
            </label>
          </div>
          <div className="mt-4 flex justify-end gap-2">
            <button type="button" className={btn} onClick={() => setForm(null)}>取消</button>
            <SpinButton type="button" className={btnPrimary} loading={busy === "save"} onClick={save}>儲存</SpinButton>
          </div>
        </Modal>
      )}

      {postFor && (
        <PostCampaignModal community={postFor} communities={communities ?? []} accountById={accountById}
          onClose={() => setPostFor(null)} notify={notify} fail={fail} reloadPosts={reloadPosts} />
      )}
    </div>
  );
}

// 同一個機器人帳號常常同時顧好幾個社群，一團要發到哪幾個由人自己勾。
// 預設只勾按下去的那一個 —— 預設全勾會讓人不小心把測試團發到所有客人面前。
function PostCampaignModal({ community, communities, accountById, onClose, notify, fail, reloadPosts }: {
  community: Community; communities: Community[]; accountById: Map<number, Account>;
  onClose: () => void; notify: (m: string) => void; fail: (e: unknown) => void; reloadPosts: () => Promise<void>;
}) {
  const [targets, setTargets] = useState<number[]>([community.id]);
  const [campaigns, setCampaigns] = useState<Campaign[] | null>(null);
  const [campaignId, setCampaignId] = useState<number | "">("");
  const [busy, setBusy] = useState(false);
  // 貼文是發給整個社群看的，發出去才發現版型不對就來不及了（只能刪掉重發，客人已經看到）。
  // 所以先把「等一下真的會貼出去的字」原封不動叫回來給人看 —— 渲染是 worker 那一份，不是另外寫的。
  const [preview, setPreview] = useState<{ text: string; images: string[] } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  useEffect(() => {
    void (async () => {
      // 只列這個社群收得了的團（一般商城／漂漂館，見 20260921020000）——
      // 列出來卻發不了的，按下去只會拿到「這個社群沒有開放…」。
      const { data, error } = await getSupabase().from("group_buy_campaigns")
        .select("id,campaign_no,name,status,sales_channel")
        .in("status", ["open", "closed"])
        .in("sales_channel", community.sales_channels?.length ? community.sales_channels : ["main"])
        .order("id", { ascending: false }).limit(50);
      if (error) fail(error); else { setCampaigns((data ?? []) as Campaign[]); setCampaignId((data?.[0] as Campaign | undefined)?.id ?? ""); }
    })();
  }, [fail, community.sales_channels]);

  // 同帳號的其他社群也只列收得了這一團的（跟上面同一條規則，DB 那層照樣會擋）
  const pickedCampaign = (campaigns ?? []).find((c) => c.id === campaignId);
  const campaignChannel = pickedCampaign?.sales_channel ?? "main";
  const sameAccount = communities.filter((c) => c.account_id === community.account_id
    && (c.sales_channels?.length ? c.sales_channels : ["main"]).includes(campaignChannel));
  // 換了團之後，原本勾的社群可能已經不在名單上 —— 送出前濾掉，不要送出去拿錯誤
  const picked = targets.filter((id) => sameAccount.some((c) => c.id === id));
  const previewFor = picked[0] ?? community.id;
  useEffect(() => {
    if (campaignId === "") { setPreview(null); return; }
    let dead = false;
    setPreviewing(true); setPreview(null);
    void (async () => {
      const { data, error } = await getSupabase().functions.invoke("line-note-worker", {
        body: { action: "preview", community_id: previewFor, campaign_id: campaignId },
      });
      if (dead) return;
      setPreviewing(false);
      if (error || (data as { error?: string })?.error) return;   // 預覽拿不到就不擋發文
      setPreview(data as { text: string; images: string[] });
    })();
    return () => { dead = true; };
  }, [campaignId, previewFor]);

  const submit = async () => {
    if (campaignId === "" || picked.length === 0) return;
    setBusy(true);
    const sb = getSupabase();
    const failed: string[] = [];
    let queued = 0;
    for (const id of picked) {
      const c = communities.find((x) => x.id === id);
      const { error } = await sb.rpc("rpc_line_note_queue_post", { p_community_id: id, p_campaign_id: campaignId });
      if (error) failed.push(`${c?.home_name || c?.home_id || id}：${translateRpcError(error)}`);
      else queued++;
    }
    setBusy(false);
    if (queued) kickWorker();
    await reloadPosts();
    // 一個社群失敗不影響其他個，但要講清楚是哪一個 —— 不然人會以為整批都沒發
    if (failed.length) return fail(new Error(`${queued} 個社群已排入發文，以下失敗：\n${failed.join("\n")}`));
    notify(picked.length > 1 ? `已開始發到 ${picked.length} 個社群，幾秒後到「貼文」看` : "已開始發文，幾秒後到「貼文」看");
    onClose();
  };
  return (
    <Modal title={`用「${accountById.get(community.account_id)?.label ?? "機器人"}」發文`} onClose={onClose} wide>
      <label className="text-sm">選擇要發的團（開團中／已收單）
        <select className={input} value={campaignId} onChange={(e) => setCampaignId(Number(e.target.value))}>
          {(campaigns ?? []).map((c) => <option key={c.id} value={c.id}>{c.campaign_no} {c.name}（{c.status}）</option>)}
        </select>
      </label>
      {campaigns !== null && campaigns.length === 0 && (
        <p className="mt-1 text-xs text-amber-600">
          這個社群收「{(community.sales_channels?.length ? community.sales_channels : ["main"]).map((c) => c === "piaopiao" ? "漂漂館" : "一般商城").join("、")}」的團，
          目前沒有開團中／已收單的這類團可以發。
        </p>
      )}

      <div className="mt-3 text-sm">
        <div className="mb-1 flex items-center justify-between text-zinc-500">
          <span>要發到哪些社群</span>
          {sameAccount.length > 1 && (
            <button type="button" className={btn}
              onClick={() => setTargets(picked.length === sameAccount.length ? [community.id] : sameAccount.map((c) => c.id))}>
              {picked.length === sameAccount.length ? "只留原本那個" : "全選"}
            </button>
          )}
        </div>
        <ul className="max-h-40 divide-y divide-zinc-200 overflow-auto rounded border border-zinc-300 dark:divide-zinc-800 dark:border-zinc-700">
          {sameAccount.map((c) => (
            <li key={c.id}>
              <label className="flex cursor-pointer items-center gap-2 px-2 py-1.5 hover:bg-zinc-50 dark:hover:bg-zinc-800">
                <input type="checkbox" checked={targets.includes(c.id)}
                  onChange={(e) => setTargets(e.target.checked ? [...targets, c.id] : targets.filter((x) => x !== c.id))} />
                <span className="min-w-0 flex-1 truncate">{c.home_name || c.home_id}</span>
                {c.post_template && <Badge tone="gray">自訂模板</Badge>}
              </label>
            </li>
          ))}
        </ul>
        {picked.length > 1 && sameAccount.filter((c) => picked.includes(c.id)).some((c) => c.post_template) && (
          <p className="mt-1 text-xs text-amber-600">有社群設了自訂模板，實際貼出去的內容會跟下面的預覽不一樣。</p>
        )}
      </div>

      <div className="mt-3 text-sm">
        <div className="mb-1 flex items-center justify-between text-zinc-500">
          <span>會貼出去的內容{picked.length > 1 && <>（以「{communities.find((c) => c.id === previewFor)?.home_name ?? ""}」為例）</>}</span>
          {preview && <span className="text-xs">{preview.images.length} 張圖</span>}
        </div>
        {previewing ? <div className="rounded border border-zinc-200 p-3 text-zinc-400 dark:border-zinc-800">產生預覽中…</div>
          : !preview ? <div className="rounded border border-zinc-200 p-3 text-zinc-400 dark:border-zinc-800">預覽拿不到（帳號沒登入？）—— 還是可以直接發</div>
          : (
          <div className="space-y-2">
            <div className="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
              {preview.text}
            </div>
            {preview.images.length > 0 && (
              <div className="flex gap-1.5 overflow-x-auto pb-1">
                {preview.images.map((u) => (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img key={u} src={u} alt="" className="h-16 w-16 shrink-0 rounded border border-zinc-200 object-cover dark:border-zinc-800" />
                ))}
              </div>
            )}
          </div>
        )}
        <p className="mt-1 text-xs text-zinc-500">文案取自這個團的說明，商品和價格取自團裡的品項，圖片取自商品圖。要改內容請去改團／商品。</p>
      </div>

      <div className="mt-4 flex justify-end gap-2">
        <button type="button" className={btn} onClick={onClose}>取消</button>
        <SpinButton type="button" className={btnPrimary} loading={busy}
          disabled={campaignId === "" || picked.length === 0} onClick={submit}>
          {picked.length > 1 ? `發到 ${picked.length} 個社群` : "發文"}
        </SpinButton>
      </div>
    </Modal>
  );
}

// ── 貼文與留言 ───────────────────────────────────────────────────────────────
type Filter = "todo" | "ordered" | "ignored" | "all";
const isTodo = isTodoComment;

// ── 留言加單：一張表，一則留言一列 ─────────────────────────────────────────
function CommentsTab({ communityById, notify, fail, readOnly }: {
  communityById: Map<number, Community>; notify: (m: string) => void; fail: (e: unknown) => void; readOnly: boolean;
}) {
  const [filter, setFilter] = useState<Filter>("todo");
  // 社群篩選（Alex 2026-09-18：留言要能分社群看）。篩選下推到查詢（!inner + eq），
  // 不是撈 300 則再前端過濾 —— 大社群一天就能把 300 則吃光，小社群的留言會被擠掉。
  const [communityId, setCommunityId] = useState<number | "">("");
  const [rows, setRows] = useState<Row[] | null>(null);
  const [orders, setOrders] = useState<Map<number, OrderInfo>>(new Map());
  const [busy, setBusy] = useState<number | null>(null);
  const communityOptions = useMemo(() =>
    [...communityById.values()].sort((a, b) => (a.home_name ?? a.home_id).localeCompare(b.home_name ?? b.home_id, "zh-Hant")),
    [communityById]);
  // 「指定會員」：撞號／認不出人的留言，店員選一次是誰 → DB 記住這位留言者，之後自動對上
  const [assignFor, setAssignFor] = useState<Comment | null>(null);
  // 點「團」欄 → 直接在這頁開加單彈窗（機器人看不懂的留言本來就得人工加，
  // 換頁再回來會掉篩選跟捲動位置）。用的是整頁版同一個元件。
  const [entryFor, setEntryFor] = useState<Row | null>(null);

  const load = useCallback(async () => {
    const sb = getSupabase();
    let q = sb.from("line_note_comments")
      .select(`*,line_note_posts${communityId === "" ? "" : "!inner"}(community_id,campaign_id,group_buy_campaigns(id,name,campaign_no))`);
    if (communityId !== "") q = q.eq("line_note_posts.community_id", communityId);
    const { data, error } = await q.order("commented_at", { ascending: false }).limit(300);
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
  }, [fail, communityId]);
  useEffect(() => { void load(); }, [load]);

  const retry = async (c: Comment) => {
    setBusy(c.id);
    const { data, error } = await getSupabase().rpc("rpc_line_note_apply_comment", { p_comment_id: c.id, p_force: true });
    setBusy(null);
    if (error) return fail(error);
    const r = (Array.isArray(data) ? data[0] : data) as { out_status?: string; out_error?: string } | null;
    notify(r?.out_status === "ordered" ? "已加單" : `${COMMENT_STATUS[(r?.out_status ?? "error") as Comment["status"]] ?? r?.out_status}${r?.out_error ? "：" + r.out_error : ""}`);
    await load();
  };
  // 回傳「有沒有真的改到」—— 加單彈窗要靠它決定關不關（取消輸入框就別把彈窗收掉）
  const setStatus = async (c: Comment, status: Comment["status"]): Promise<boolean> => {
    let note: string | null = null;
    if (status === "resolved") {
      note = window.prompt("怎麼處理的？（選填）", c.resolution_note ?? "");
      if (note === null) return false;
    }
    // 已經加成單的退回未處理：訂單不會跟著取消，先講清楚
    if (status === "pending" && (c.status === "ordered" || c.status === "duplicate") && c.customer_order_id) {
      if (!window.confirm("退回未處理不會取消已經加好的訂單，只是把這則留言放回待處理清單。\n要取消訂單請到訂單那邊操作。\n\n確定退回？")) return false;
    }
    setBusy(c.id);
    const body = status === "resolved"
      ? { status, resolved_at: new Date().toISOString(), resolution_note: note || null }
      : status === "pending"
        ? { status, error: null, processed_at: null }   // 退回＝重新來過，舊的錯誤訊息清掉
        : { status };
    const { error } = await getSupabase().from("line_note_comments").update(body).eq("id", c.id);
    setBusy(null);
    if (error) { fail(error); return false; }
    // 按「已解決」＝ 這則確實處理掉了，客人要收到笑臉（跟機器人自己加成單同一個待遇）。
    // 真正去按的是 worker（只有它有 LINE session），這裡只是順手叫一下，不用等下一分鐘的排程。
    // 已經按過的（reacted_at 有值）不叫 —— worker 那邊也會再擋一次，不會重按。
    // 叫不動也沒關係（分店帳號打 Edge Function 會 401）：pg_cron 每分鐘的 tick 一樣會補按。
    if (status === "resolved" && !c.reacted_at) kickWorker();
    await load();
    return true;
  };

  const shown = useMemo(() => {
    if (!rows) return null;
    if (filter === "todo") return rows.filter(isTodo);
    if (filter === "ordered") return rows.filter((c) => c.status === "ordered" || c.status === "duplicate");
    if (filter === "ignored") return rows.filter((c) => c.status === "ignored" || c.status === "resolved");
    return rows;
  }, [rows, filter]);
  const todoCount = rows?.filter(isTodo).length ?? 0;
  const ignoredCount = rows?.filter((c) => c.status === "ignored" || c.status === "resolved").length ?? 0;

  // 已經在 LINE 那則留言上按過笑臉的標一下，沒按到的看得出來
  const reacted = (c: Comment) =>
    c.reacted_at ? <span title={`已在 LINE 留言上按 😄（${fmt(c.reacted_at)}）`}>😄</span> : null;

  // 團欄：認得出團就做成按鈕，點了在這頁開加單彈窗
  const campaignCell = (c: Row) => {
    const camp = c.line_note_posts?.group_buy_campaigns ?? null;
    if (!camp) return <div className="truncate">—</div>;
    if (readOnly) return <div className="truncate" title={camp.name}>{camp.name}</div>;
    return (
      <button type="button" title={`${camp.name}（點開加單）`} onClick={() => setEntryFor(c)}
        className="block w-full truncate text-left text-sky-700 underline decoration-dotted underline-offset-2 hover:text-sky-900 dark:text-sky-400 dark:hover:text-sky-200">
        {camp.name}
      </button>
    );
  };

  // 結果欄：一個徽章 + 一句話
  const result = (c: Comment) => {
    const o = c.customer_order_id ? orders.get(c.customer_order_id) : null;
    const orderCell = o
      ? <><span className="text-zinc-600 dark:text-zinc-300">{o.store_name ?? "？店"}</span>{" "}<OrderLink id={o.id} no={o.order_no} /></>
      : c.customer_order_id ? <span>訂單 #{c.customer_order_id}</span> : null;
    switch (c.status) {
      case "ordered":   return <><Badge tone="green">已加單</Badge>{orderCell}{reacted(c)}</>;
      case "duplicate": return <><Badge tone="blue">已有訂單</Badge>{orderCell}{reacted(c)}</>;
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
    if (readOnly) return null;
    // 「退回未處理」每一種狀態都給 —— 小幫手自己判斷要不要重新處理這則。
    // 已加單的退回不會動到訂單（setStatus 會先確認）。
    const back = (
      <SpinButton type="button" className={btn} loading={busy === c.id}
        onClick={() => setStatus(c, "pending")}>退回未處理</SpinButton>
    );
    // 認不出是誰（撞號 / 找不到號碼 / 沒寫號碼）→ 指定一次，之後這位留言者都會自動對上
    const assign = (
      <button type="button" className={`${btn} text-sky-700 dark:text-sky-300`} disabled={busy === c.id}
        onClick={() => setAssignFor(c)}>指定會員</button>
    );
    // 已加成單的不給「重試」：重跑只會判成重複，沒有意義；要重加請先退回未處理。
    if (c.status === "ordered") return <div className="flex justify-end gap-1">{back}</div>;
    // 忽略／已解決／已有訂單還能直接重跑（RPC 帶 p_force）：當初對不到人、或先前那張單已經取消
    if (c.status === "ignored" || c.status === "resolved" || c.status === "duplicate") {
      return (
        <div className="flex justify-end gap-1">
          <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => retry(c)}>重試</SpinButton>
          {assign}
          {back}
        </div>
      );
    }
    return (
      <div className="flex justify-end gap-1">
        <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => retry(c)}>重試</SpinButton>
        {assign}
        <SpinButton type="button" className={`${btn} text-emerald-700`} loading={busy === c.id} onClick={() => setStatus(c, "resolved")}>已解決</SpinButton>
        <SpinButton type="button" className={btn} loading={busy === c.id} onClick={() => setStatus(c, "ignored")}>忽略</SpinButton>
      </div>
    );
  };

  return (
    <div className="space-y-3">
      <p className="text-sm text-zinc-500">
        「找不到會員」「錯誤」修正後按「重試」；小幫手自己加完單按「已解決」。
        標成忽略／已解決的之後還是可以按「重試」重跑。
        按「已解決」會順手去客人那則留言按笑臉 😄（已經按過的不會重按）。
      </p>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-1 rounded-lg bg-zinc-100 p-1 dark:bg-zinc-800">
          {([["todo", `待處理 ${todoCount}`], ["ordered", "已加單"], ["ignored", `忽略 ${ignoredCount}`], ["all", "全部"]] as const).map(([k, l]) => (
            <button key={k} type="button" onClick={() => setFilter(k)}
              className={`rounded-md px-3 py-1 text-sm ${filter === k ? "bg-white shadow dark:bg-zinc-900" : "text-zinc-600 dark:text-zinc-300"}`}>
              {l}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <select className={`${input} w-auto max-w-[16rem]`} value={communityId} aria-label="社群"
            onChange={(e) => { setRows(null); setCommunityId(e.target.value ? Number(e.target.value) : ""); }}>
            <option value="">全部社群</option>
            {communityOptions.map((c) => (
              <option key={c.id} value={c.id}>{c.home_name || c.home_id}</option>
            ))}
          </select>
          <button type="button" className={btn} onClick={() => void load()}>重新整理</button>
        </div>
      </div>

      <Table>
        <THead><Th>時間</Th><Th>留言者</Th><Th>留言</Th><Th>團</Th><Th>結果</Th><Th align="right"></Th></THead>
        <TBody>
          {shown === null ? <LoadingRow colSpan={6} /> : shown.length === 0 ? (
            <EmptyRow colSpan={6}>{filter === "todo" ? (communityId === "" ? "沒有要處理的留言 🎉" : "這個社群沒有要處理的留言 🎉") : "沒有留言"}</EmptyRow>
          ) : shown.map((c) => (
            <Tr key={c.id} className={isTodo(c) ? "bg-amber-50/60 dark:bg-amber-950/20" : ""}>
              <Td className="whitespace-nowrap text-sm text-zinc-500">{fmt(c.commented_at)}</Td>
              <Td className="whitespace-nowrap font-medium">{c.commenter_name ?? "—"}</Td>
              <Td className="max-w-xs whitespace-pre-wrap text-base">{c.text}</Td>
              <Td className="max-w-[12rem] text-sm">
                {campaignCell(c)}
                <div className="truncate text-xs text-zinc-500">{communityById.get(c.line_note_posts?.community_id ?? -1)?.home_name ?? ""}</div>
              </Td>
              <Td><div className="flex flex-wrap items-center gap-2 text-sm">{result(c)}</div></Td>
              <Td align="right" className="whitespace-nowrap">{actions(c)}</Td>
            </Tr>
          ))}
        </TBody>
      </Table>
      {assignFor && (
        <AssignMemberModal
          comment={assignFor}
          onClose={() => setAssignFor(null)}
          onDone={async (msg) => { setAssignFor(null); notify(msg); await load(); }}
          fail={fail}
        />
      )}
      {entryFor && (
        <CommentOrderEntryModal
          comment={entryFor}
          busy={busy === entryFor.id}
          onClose={() => setEntryFor(null)}
          onCreated={() => void load()}
          onResolve={async () => { if (await setStatus(entryFor, "resolved")) setEntryFor(null); }}
        />
      )}
    </div>
  );
}

// 未認出團的貼文沒有團名可以顯示，退而用內文第一行當標題
function postFirstLine(text: string | null) {
  const line = String(text ?? "").split("\n").map((s) => s.trim()).find(Boolean);
  return line ? (line.length > 40 ? `${line.slice(0, 40)}…` : line) : "（沒有內文）";
}

// ── 貼文：以「團」為軸（同一團發到幾個社群就收成一張卡），展開看各社群的加單 ──
//
// 為什麼不以貼文為軸：一團常常同時發到 4、5 個社群，每個社群一張卡的話同一團散成
// 好幾張、加單數字也各自為政，小幫手要自己心算。而社群 ↔ 店不是一對一（有的群整合
// 4-5 家店、有的群只有一家），所以每則加單要寫清楚「哪個群來的、加到哪間店」。
// 未認出團的貼文沒有團可掛，仍然一篇一張卡。
type PostGroup = { key: string; campaignId: number | null; campaign: Post["group_buy_campaigns"]; posts: Post[] };

// 一頁幾張卡（一張卡 = 一團）。線上 437 組、光「開團中」就 200 出頭，
// 一次全畫出來就是老闆說的「太多了看不了」。
const POSTS_PAGE_SIZE = 20;

function PostsTab({ communities, communityById, tick, notify, fail, readOnly, canLink }: {
  communities: Community[]; communityById: Map<number, Community>;
  // 別的分頁做完事要重抓時 +1（社群設定那邊發完文）
  tick: number;
  notify: (m: string) => void; fail: (e: unknown) => void;
  readOnly: boolean;
  // 「指定團」比其他操作鈕寬：line_notes_view perm 持有者（分店店長）也能指定，
  // 不然未認出團的貼文只能等總部來綁、留言加單那邊什麼都動不了。DB gate 見 20260919000000。
  canLink: boolean;
}) {
  const [busy, setBusy] = useState<number | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  // 展開過的留言（快取，依貼文 id；收合再展開不用重抓）
  const [detail, setDetail] = useState<Map<number, Comment[]>>(new Map());
  const [orders, setOrders] = useState<Map<number, OrderInfo>>(new Map());
  const [loadingKey, setLoadingKey] = useState<string | null>(null);
  // 展開的那一團目前看哪個社群（null = 全部）
  const [pickCommunity, setPickCommunity] = useState<number | null>(null);
  // 每篇貼文的留言統計。收合時也要看得到，所以一次把清單上所有貼文的留言狀態撈回來自己數
  // （只取 post_id + status + member_no_hint 三欄，比逐篇展開才查省很多）。
  const [counts, setCounts] = useState<Map<number, PostStat>>(new Map());
  const [q, setQ] = useState("");
  const [linkFor, setLinkFor] = useState<Post | null>(null);

  // ── 伺服端分頁 / 篩選 ────────────────────────────────────────────────────
  // 分頁的單位是「組」（＝畫面上的一張卡），不是貼文列：同一團發到 3 個社群是 3 列，
  // 對列分頁會把同一團切成兩張卡掉在不同頁。所以先跟 v_line_note_post_groups
  // （20260921030000）要這一頁有哪幾組，再去抓那幾組的貼文本體。
  const [posts, setPosts] = useState<Post[] | null>(null);
  const [keyOrder, setKeyOrder] = useState<Map<string, number>>(new Map());
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [communityId, setCommunityId] = useState<number | "">("");
  // 預設只看「開團中」的團（還在收單的才需要顧）＋未認出團的（那種要人去指定團）。
  // 已鎖定之後的團不會再加單，不要洗版。
  const [onlyOpen, setOnlyOpen] = useState(true);
  const [qApplied, setQApplied] = useState("");
  // 打字邊打邊查會太吵，停 0.4 秒才送；換關鍵字一律回第 1 頁
  // （換條件不回第 1 頁 = 停在不存在的頁碼、畫面整片空白）
  useEffect(() => {
    const t = setTimeout(() => { setQApplied(q.trim()); setPage(1); }, 400);
    return () => clearTimeout(t);
  }, [q]);

  const load = useCallback(async () => {
    const sb = getSupabase();
    let gq = sb.from("v_line_note_post_groups")
      .select("group_key,campaign_id,unlinked_post_id", { count: "exact" })
      .order("latest_at", { ascending: false })
      .range((page - 1) * POSTS_PAGE_SIZE, page * POSTS_PAGE_SIZE - 1);
    if (communityId !== "") gq = gq.contains("community_ids", [communityId]);
    // campaign_status 是 NULL = 未認出團，那種一定要看得到
    if (onlyOpen) gq = gq.or("campaign_status.eq.open,campaign_status.is.null");
    if (qApplied) gq = gq.ilike("search_text", `%${qApplied}%`);
    const { data: gs, error, count } = await gq;
    if (error) return fail(error);
    const rows = (gs ?? []) as { group_key: string; campaign_id: number | null; unlinked_post_id: number | null }[];
    setTotal(count ?? 0);
    setKeyOrder(new Map(rows.map((r, i) => [r.group_key, i])));
    // 刪到這一頁空了（或條件變嚴）就退回第 1 頁，不要停在空白畫面
    if (rows.length === 0) { setPosts([]); if (page > 1 && (count ?? 0) > 0) setPage(1); return; }

    const campIds = rows.map((r) => r.campaign_id).filter((x): x is number => x != null);
    const unIds = rows.map((r) => r.unlinked_post_id).filter((x): x is number => x != null);
    const ors = [
      campIds.length ? `campaign_id.in.(${campIds.join(",")})` : null,
      unIds.length ? `id.in.(${unIds.join(",")})` : null,
    ].filter(Boolean).join(",");
    let pq = sb.from("line_note_posts")
      .select("*,group_buy_campaigns(id,campaign_no,name,status)")
      .or(ors)
      .order("created_at", { ascending: false });
    // 篩了社群就只畫那個社群那幾列，不然卡片裡還是會出現別的群組
    if (communityId !== "") pq = pq.eq("community_id", communityId);
    const { data, error: pe } = await pq;
    if (pe) return fail(pe);
    setPosts((data ?? []) as Post[]);
  }, [page, communityId, onlyOpen, qApplied, fail]);

  useEffect(() => { void load(); }, [load, tick]);
  const reload = load;
  const pageCount = Math.max(1, Math.ceil(total / POSTS_PAGE_SIZE));

  // 同一團的貼文收成一組；未認出團的各自一組。順序照最新貼文（posts 已是 created_at desc）。
  const groups = useMemo<PostGroup[]>(() => {
    const out: PostGroup[] = [];
    const byCampaign = new Map<number, PostGroup>();
    for (const p of posts ?? []) {
      if (!p.campaign_id) { out.push({ key: `u${p.id}`, campaignId: null, campaign: null, posts: [p] }); continue; }
      let g = byCampaign.get(p.campaign_id);
      if (!g) { g = { key: `c${p.campaign_id}`, campaignId: p.campaign_id, campaign: p.group_buy_campaigns, posts: [] }; byCampaign.set(p.campaign_id, g); out.push(g); }
      g.posts.push(p);
    }
    // 順序以「這一頁的組」為準（依最新貼文時間），不要靠貼文列的順序推
    out.sort((a, b) => (keyOrder.get(a.key) ?? 0) - (keyOrder.get(b.key) ?? 0));
    return out;
  }, [posts, keyOrder]);

  // 搜尋 / 篩選 / 分頁都在伺服端做（v_line_note_post_groups），這裡直接畫
  const shown = groups;

  const loadCounts = useCallback(async () => {
    const ids = (posts ?? []).map((p) => p.id);
    if (ids.length === 0) { setCounts(new Map()); return; }
    const { data, error } = await getSupabase().from("line_note_comments")
      .select("post_id,status,member_no_hint").in("post_id", ids);
    if (error) return;   // 統計拿不到就不顯示，不要擋住整頁
    const byPost = new Map<number, { status: string; member_no_hint: string | null }[]>();
    for (const r of (data ?? []) as { post_id: number; status: Comment["status"]; member_no_hint: string | null }[]) {
      const cur = byPost.get(r.post_id);
      if (cur) cur.push(r); else byPost.set(r.post_id, [r]);
    }
    setCounts(new Map([...byPost].map(([pid, rows]) => [pid, commentStats(rows)])));
  }, [posts]);
  useEffect(() => { void loadCounts(); }, [loadCounts]);

  const groupStat = (g: PostGroup): PostStat => {
    const s: PostStat = { total: 0, ordered: 0, duplicate: 0, todo: 0 };
    for (const p of g.posts) {
      const st = counts.get(p.id);
      if (!st) { s.total += p.comment_count; continue; }
      s.total += st.total; s.ordered += st.ordered; s.duplicate += st.duplicate; s.todo += st.todo;
    }
    return s;
  };

  const toggle = async (g: PostGroup) => {
    if (open === g.key) { setOpen(null); return; }
    setOpen(g.key);
    setPickCommunity(null);
    const need = g.posts.filter((p) => !detail.has(p.id)).map((p) => p.id);
    if (need.length === 0) return;
    setLoadingKey(g.key);
    const { data, error } = await getSupabase().from("line_note_comments").select("*")
      .in("post_id", need).order("commented_at", { ascending: true }).order("id");
    setLoadingKey(null);
    if (error) return fail(error);
    const cs = (data ?? []) as (Comment & { post_id: number })[];
    setDetail((m) => {
      const n = new Map(m);
      for (const pid of need) n.set(pid, cs.filter((c) => c.post_id === pid));
      return n;
    });
    // 有加到單的補查單號＋取貨店：社群跟店不是一對一，「加到哪間店」要看訂單才知道
    const ids = [...new Set(cs.map((c) => c.customer_order_id).filter((x): x is number => !!x))];
    if (ids.length === 0) return;
    const { data: od } = await getSupabase().from("customer_orders")
      .select("id,order_no,stores!customer_orders_pickup_store_id_fkey(name)").in("id", ids);
    setOrders((m) => {
      const n = new Map(m);
      for (const o of (od ?? []) as unknown as { id: number; order_no: string; stores: { name: string } | null }[]) {
        n.set(o.id, { id: o.id, order_no: o.order_no, store_name: o.stores?.name ?? null });
      }
      return n;
    });
  };

  const readNow = async (p: Post) => {
    const c = communityById.get(p.community_id);
    if (!c) return;
    setBusy(p.id);
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", { p_kind: "read", p_account_id: c.account_id, p_community_id: c.id, p_post_id: p.id });
    setBusy(null);
    if (error) return fail(error);
    kickWorker();
    setDetail((m) => { const n = new Map(m); n.delete(p.id); return n; });
    notify("已開始讀取，留言幾秒後會出現在「留言加單」");
    setTimeout(() => { void loadCounts(); }, 6000);   // worker 跑完大概這個時間，順手把統計刷新
  };

  // 預設連 LINE 上那篇一起刪（貼錯團 / 貼錯價格時才救得回來）；
  // 刪不掉會問要不要只清後台紀錄。流程在 @/lib/lineNoteDelete，跟開團彈窗共用。
  const removePost = async (p: Post) => {
    setBusy(p.id);
    const r = await deleteLineNotePost({
      id: p.id, line_post_id: p.line_post_id,
      label: p.group_buy_campaigns?.name ?? postFirstLine(p.text),
    });
    setBusy(null);
    if (r.kind === "cancelled") return;
    if (r.kind === "failed") return fail(new Error(r.error));
    setDetail((m) => { const n = new Map(m); n.delete(p.id); return n; });
    notify(r.kind === "deleted" ? "已從 LINE 記事本刪除，紀錄也清掉了" : "已清掉後台紀錄（LINE 上那篇還在）");
    await reload();
  };

  // 誤判結單時一鍵恢復：那則留言會被標成「不是結單」，下次讀留言不會再關掉
  const reopenPost = async (p: Post) => {
    setBusy(p.id);
    const { error } = await getSupabase().rpc("rpc_line_note_post_reopen", { p_id: p.id });
    setBusy(null);
    if (error) return fail(error);
    notify("已恢復讀取，那則留言不會再被當成結單");
    await reload();
  };

  const statBadges = (st: PostStat | undefined, compact = false) => {
    if (!st || st.total === 0) return null;   // 卡片上留空就好，不要多一條「—」
    return (
      <span className="inline-flex flex-wrap items-center gap-1">
        {st.ordered > 0 && <Badge tone="green">已加單 {st.ordered}</Badge>}
        {st.duplicate > 0 && <Badge tone="blue">已有訂單 {st.duplicate}</Badge>}
        {st.todo > 0 && <Badge tone="red">待處理 {st.todo}</Badge>}
        {st.ordered === 0 && st.duplicate === 0 && st.todo === 0 && !compact && <span className="text-xs text-zinc-400">無下單</span>}
      </span>
    );
  };
  const communityName = (id: number) => {
    const c = communityById.get(id);
    return c?.home_name || c?.home_id || `社群 #${id}`;
  };
  const tone = (s: Comment["status"]) =>
    s === "ordered" || s === "resolved" ? "green" : s === "duplicate" ? "blue" : s === "pending" ? "amber"
    : s === "unmatched" || s === "error" ? "red" : "gray";

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <input className={`${input} min-w-0 flex-1 sm:max-w-xs`} value={q} onChange={(e) => setQ(e.target.value)}
          placeholder="搜尋團名 / 團號 / 社群 / 貼文內容" />
        <select className={input} value={communityId}
          onChange={(e) => { setCommunityId(e.target.value === "" ? "" : Number(e.target.value)); setPage(1); }}>
          <option value="">全部社群</option>
          {communities.map((c) => <option key={c.id} value={c.id}>{c.home_name || c.home_id}</option>)}
        </select>
        <select className={input} value={onlyOpen ? "open" : "all"} onChange={(e) => { setOnlyOpen(e.target.value === "open"); setPage(1); }}>
          <option value="open">只看開團中</option>
          <option value="all">全部狀態</option>
        </select>
        <button type="button" className={btn} onClick={() => void reload()}>重新整理</button>
        <span className="ml-auto flex items-center gap-1.5 text-sm text-zinc-500">
          <span className="tabular-nums">{total} 團・第 {page}/{pageCount} 頁</span>
          <button type="button" className={btn} disabled={page <= 1} onClick={() => setPage((n) => Math.max(1, n - 1))}>上一頁</button>
          <button type="button" className={btn} disabled={page >= pageCount} onClick={() => setPage((n) => Math.min(pageCount, n + 1))}>下一頁</button>
        </span>
      </div>
      <p className="text-sm text-zinc-500">
        一團一張卡：同一團發到幾個社群都收在同一張，展開看每個社群加了誰、加到哪間店
        （社群跟店不是一對一，取貨店看的是會員自己設定的店）。
        認不出是哪一團的會標<b>「未認出團」</b>，指定團之後才會開始讀留言加單
        （指到<b>已結單</b>的團只是把貼文歸檔標上團名，不會再加單）。
        <br />預設<b>只列開團中的團</b>（還在收單的才要顧）與未認出團的貼文；已鎖定之後的舊團切「全部狀態」才會出現。
        <br />要<b>補發某一團</b>的話從「開團」列表那一團的「LINE 記事本」按鈕比較快 —— 可以一次勾好幾個群組。
      </p>

      {posts === null ? <div className="py-8 text-center text-sm text-zinc-400">讀取中…</div>
        : shown.length === 0 ? (
          <div className="py-8 text-center text-sm text-zinc-400">
            {qApplied || communityId !== "" ? "沒有符合的貼文" : onlyOpen ? "沒有開團中的團的貼文（要看舊的請切「全部狀態」）" : "還沒有貼文"}
          </div>
        ) : (
        <ul className="space-y-2">
          {shown.map((g) => {
            const expanded = open === g.key;
            const unlinked = !g.campaignId;
            const first = g.posts[0];
            const cs = g.campaign?.status;
            const title = g.campaign?.name ?? (unlinked ? postFirstLine(first.text) : `#${first.id}`);
            const gst = groupStat(g);
            const multi = g.posts.length > 1;
            const loaded = g.posts.every((p) => detail.has(p.id));
            const allComments = loaded
              ? g.posts.flatMap((p) => (detail.get(p.id) ?? []).map((c) => ({ ...c, post: p })))
                  .sort((a, b) => (Date.parse(a.commented_at ?? "") || 0) - (Date.parse(b.commented_at ?? "") || 0) || a.id - b.id)
              : null;
            const visible = allComments?.filter((c) => pickCommunity === null || c.post.community_id === pickCommunity) ?? null;
            // 這團加到了哪幾間店（依取貨店數已加單），一眼看得出「4 個群 → 2 家店」
            const storeTally = new Map<string, number>();
            for (const c of allComments ?? []) {
              if (c.status !== "ordered" || !c.customer_order_id) continue;
              const s = orders.get(c.customer_order_id)?.store_name ?? "（未知店）";
              storeTally.set(s, (storeTally.get(s) ?? 0) + 1);
            }
            return (
              <li key={g.key} className="overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
                {/* 標題列：整塊可點，手機上一樣好按 */}
                <button type="button" onClick={() => void toggle(g)}
                  className="flex w-full items-start gap-2 p-3 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800/50">
                  <span className="mt-0.5 shrink-0 text-zinc-400">{expanded ? "▾" : "▸"}</span>
                  <div className="min-w-0 flex-1 space-y-1.5">
                    <div className="flex items-start justify-between gap-2">
                      <span className="min-w-0 flex-1 font-medium leading-snug">{title}</span>
                      <span className="shrink-0 text-xs tabular-nums text-zinc-500">
                        {multi && `${g.posts.length} 個社群・`}{gst.total} 則留言
                      </span>
                    </div>
                    <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-zinc-500">
                      {unlinked
                        ? <Badge tone="amber">未認出團</Badge>
                        : <>
                            {cs && <span className={`rounded px-1.5 py-0.5 ${campaignStatusBadge(cs)}`}>{campaignStatusLabel(cs)}</span>}
                            <span className="font-mono">{g.campaign?.campaign_no}</span>
                          </>}
                      {unlinked && (
                        <>
                          <span className="font-mono">#{first.id}</span>
                          {first.line_post_id && <span className="font-mono" title="LINE 記事本的貼文 id">LINE {first.line_post_id}</span>}
                          <span className="truncate">{communityName(first.community_id)}</span>
                          <span>發文 {fmt(first.posted_at)}</span>
                        </>
                      )}
                    </div>
                    {statBadges(gst)}
                    {storeTally.size > 0 && (
                      <div className="text-xs text-zinc-500">
                        加到：{[...storeTally].map(([s, n]) => `${s} ${n}`).join("、")}
                      </div>
                    )}
                  </div>
                </button>

                {/* 每個社群一列：發文／讀取時間、這個群的統計、動作按鈕都跟著那一篇貼文走 */}
                <ul className="divide-y divide-zinc-100 border-t border-zinc-100 dark:divide-zinc-800 dark:border-zinc-800">
                  {g.posts.map((p) => (
                    <li key={p.id} className="flex flex-wrap items-center gap-x-2 gap-y-1 px-3 py-2 text-xs text-zinc-500">
                      <span className="min-w-0 flex-1 basis-full sm:basis-auto">
                        {!unlinked && <span className="font-medium text-zinc-800 dark:text-zinc-200">{communityName(p.community_id)}</span>}
                        {p.status !== "posted" && !unlinked && <Badge tone={p.status === "failed" ? "red" : "gray"}>{POST_STATUS[p.status]}</Badge>}
                        {/* 兩個 id 都寫出來：#id 是後台這一列，LINE 那串才是記事本上那一篇
                            —— 跟客服對答案時只有後者認得出是哪一篇貼文 */}
                        {!unlinked && <span className="ml-2 font-mono">#{p.id}</span>}
                        {!unlinked && p.line_post_id && <span className="ml-2 font-mono" title="LINE 記事本的貼文 id">LINE {p.line_post_id}</span>}
                        {!unlinked && <span className="ml-2">發文 {fmt(p.posted_at)}</span>}
                        {p.last_read_at && <span className="ml-2">讀取 {fmt(p.last_read_at)}</span>}
                        {multi && <span className="ml-2">{statBadges(counts.get(p.id), true)}</span>}
                        {p.closed_reason && <div className="text-zinc-500">讀到結單留言：{p.closed_reason}</div>}
                        {p.last_error && <div className="text-red-600">{p.last_error}</div>}
                      </span>
                      {(!readOnly || canLink) && <span className="flex flex-wrap gap-1.5">
                        {unlinked && canLink && (
                          <button type="button" className={btnPrimary} onClick={() => setLinkFor(p)}>指定團</button>
                        )}
                        {!readOnly && p.status === "posted" && (
                          <SpinButton type="button" className={btn} loading={busy === p.id} onClick={() => void readNow(p)}>立即讀取</SpinButton>
                        )}
                        {!readOnly && p.status === "closed" && p.closed_comment_id && (
                          <SpinButton type="button" className={btn} loading={busy === p.id} onClick={() => void reopenPost(p)}>恢復讀取</SpinButton>
                        )}
                        {!readOnly && (
                          <SpinButton type="button" className={`${btn} text-red-600`} loading={busy === p.id}
                            onClick={() => void removePost(p)}
                            title={p.line_post_id ? "連 LINE 記事本上那篇一起刪掉" : "只清後台紀錄（這篇沒發到 LINE）"}>
                            {p.line_post_id ? "刪除貼文" : "刪除紀錄"}
                          </SpinButton>
                        )}
                      </span>}
                    </li>
                  ))}
                </ul>

                {expanded && (
                  <div className="border-t border-zinc-100 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900/50">
                    {loadingKey === g.key || !visible ? <div className="text-sm text-zinc-400">讀取中…</div>
                      : (
                      <>
                        {/* 多個社群才出分頁：全部 / 各社群，數字是該群的留言數 */}
                        {multi && (
                          <div className="mb-2 flex flex-wrap gap-1">
                            {[null, ...g.posts.map((p) => p.community_id)].map((cid) => {
                              const n = cid === null ? allComments!.length : allComments!.filter((c) => c.post.community_id === cid).length;
                              const on = pickCommunity === cid;
                              return (
                                <button key={cid ?? "all"} type="button" onClick={() => setPickCommunity(cid)}
                                  className={`rounded-full border px-2.5 py-0.5 text-xs ${on
                                    ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                                    : "border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"}`}>
                                  {cid === null ? "全部" : communityName(cid)} {n}
                                </button>
                              );
                            })}
                          </div>
                        )}
                        {visible.length === 0 ? <div className="text-sm text-zinc-400">還沒讀到留言</div> : (
                          <ul className="divide-y divide-zinc-200 rounded border border-zinc-200 bg-white dark:divide-zinc-800 dark:border-zinc-800 dark:bg-zinc-900">
                            {visible.map((cm) => {
                              const o = cm.customer_order_id ? orders.get(cm.customer_order_id) : undefined;
                              return (
                                <li key={cm.id} className="px-3 py-2 text-sm">
                                  {/* 手機：留言人 + 狀態一行，內容一行；桌機自然排成一列 */}
                                  <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                                    <span className="font-medium">{cm.commenter_name ?? "—"}</span>
                                    <span className="text-xs text-zinc-500">{fmt(cm.commented_at)}</span>
                                    {multi && pickCommunity === null && (
                                      <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                                        {communityName(cm.post.community_id)}
                                      </span>
                                    )}
                                    <Badge tone={tone(cm.status)}>{COMMENT_STATUS[cm.status]}</Badge>
                                    {o && (
                                      <span className="inline-flex items-center gap-1">
                                        <OrderLink id={o.id} no={o.order_no} />
                                        {o.store_name && <span className="text-xs text-zinc-600 dark:text-zinc-300">→ {o.store_name}</span>}
                                      </span>
                                    )}
                                  </div>
                                  <div className="mt-0.5 whitespace-pre-wrap break-words text-zinc-700 dark:text-zinc-300">{cm.text}</div>
                                  {cm.error && <div className="mt-0.5 text-xs text-red-600 dark:text-red-400">{cm.error}</div>}
                                </li>
                              );
                            })}
                          </ul>
                        )}
                      </>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}

      {/* 底部也放一組：一頁 20 張卡，看到最後不用再捲回去換頁 */}
      {pageCount > 1 && (
        <div className="flex items-center justify-center gap-1.5 pt-1 text-sm text-zinc-500">
          <button type="button" className={btn} disabled={page <= 1} onClick={() => setPage((n) => Math.max(1, n - 1))}>上一頁</button>
          <span className="tabular-nums">第 {page}/{pageCount} 頁</span>
          <button type="button" className={btn} disabled={page >= pageCount} onClick={() => setPage((n) => Math.min(pageCount, n + 1))}>下一頁</button>
        </div>
      )}

      {linkFor && (
        <LinkCampaignModal post={linkFor} onClose={() => setLinkFor(null)}
          onDone={async () => { setLinkFor(null); notify(readOnly ? "已指定，下次排程讀取就會開始加單" : "已指定，按「立即讀取」就會開始加單"); await reload(); }}
          fail={fail} />
      )}
    </div>
  );
}

// ── 點「團」開的加單彈窗 ─────────────────────────────────────────────────────
//
// 機器人看不懂的留言（「A,B 各1」「白+1」）本來就得人工加單。以前要另開
// /campaigns/order-entry?id=…，回來時篩選、捲動位置全掉；改成原地彈窗，
// 留言原文就擺在表單上面照著 key。畫面本體用整頁版同一個 OrderEntryView，
// 不要為了彈窗再抄一份（抄了下次只會修到其中一邊）。
function CommentOrderEntryModal({ comment, busy, onClose, onCreated, onResolve }: {
  comment: Row; busy: boolean; onClose: () => void; onCreated: () => void; onResolve: () => void | Promise<void>;
}) {
  const [created, setCreated] = useState(false);
  const camp = comment.line_note_posts?.group_buy_campaigns ?? null;
  if (!camp) return null;
  return (
    <SharedModal open onClose={onClose} title={`加單 · ${camp.name}`} maxWidth="max-w-6xl">
      <div className="mb-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 dark:border-amber-900 dark:bg-amber-950/40">
        <div className="flex flex-wrap items-baseline gap-x-3 text-sm">
          <span className="font-medium">{comment.commenter_name ?? "—"}</span>
          <span className="text-xs text-zinc-500">{fmt(comment.commented_at)}</span>
        </div>
        <div className="whitespace-pre-wrap break-words text-base">{comment.text}</div>
      </div>

      <OrderEntryView
        campaignId={camp.id}
        embedded
        initialMemberTerm={comment.member_no_hint ?? undefined}
        onCreated={() => { setCreated(true); onCreated(); }}
      />

      <div className="mt-4 flex flex-wrap items-center justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
        {created && <span className="mr-auto text-sm text-emerald-700 dark:text-emerald-400">加好了就標成已解決 —— 這則才會離開待處理，客人那則留言也才會收到笑臉 😄。</span>}
        <button type="button" className={btn} onClick={onClose}>關閉</button>
        <SpinButton type="button" className={`${btn} text-emerald-700 dark:text-emerald-400`} loading={busy}
          onClick={() => void onResolve()}>標成已解決並關閉</SpinButton>
      </div>
    </SharedModal>
  );
}

// ── 指定團：認不出來的貼文由小幫手自己選是哪一團 ────────────────────────────
type CampaignPick = { id: number; campaign_no: string; name: string; status: string };
// 草稿（還沒開）與已取消以外都能指定
const LINKABLE_CAMPAIGN_STATUSES: string[] =
  CAMPAIGN_STATUSES.filter((s) => s !== "draft" && s !== "cancelled");

// ── 指定會員：搜會員 → rpc_line_note_assign_member（記住留言者 + 立刻重跑那則） ────────
type MemberHit = { id: number; member_no: string; name: string; phone: string | null; home_store_name: string | null };

function AssignMemberModal({ comment, onClose, onDone, fail }: {
  comment: Comment; onClose: () => void; onDone: (msg: string) => Promise<void>; fail: (e: unknown) => void;
}) {
  const [term, setTerm] = useState(comment.member_no_hint ?? "");
  const [hits, setHits] = useState<MemberHit[]>([]);
  const [searching, setSearching] = useState(false);
  const [busy, setBusy] = useState<number | null>(null);

  useEffect(() => {
    const q = term.trim();
    if (q.length < 2) { return; }
    let cancelled = false;
    const t = setTimeout(async () => {
      setSearching(true);
      const { data } = await getSupabase().rpc("rpc_search_members", { p_term: q, p_limit: 10 });
      if (!cancelled) { setHits((data as MemberHit[]) ?? []); setSearching(false); }
    }, 250);
    return () => { cancelled = true; clearTimeout(t); };
  }, [term]);

  const pick = async (m: MemberHit) => {
    if (!window.confirm(`把「${comment.commenter_name ?? "這位留言者"}」指定為 ${m.name}（${m.member_no}${m.home_store_name ? "・" + m.home_store_name : ""}）？\n之後這位留言者的留言都會直接對到這位會員，並立刻重跑這則留言。`)) return;
    setBusy(m.id);
    const { data, error } = await getSupabase().rpc("rpc_line_note_assign_member", { p_comment_id: comment.id, p_member_id: m.id });
    setBusy(null);
    if (error) return fail(error);
    const r = (Array.isArray(data) ? data[0] : data) as { out_status?: string; out_error?: string } | null;
    await onDone(r?.out_status === "ordered" ? "已指定並加單"
      : `已指定，${COMMENT_STATUS[(r?.out_status ?? "error") as Comment["status"]] ?? r?.out_status}${r?.out_error ? "：" + r.out_error : ""}`);
  };

  const shown = term.trim().length >= 2 ? hits : [];
  return (
    <Modal title="這則留言是哪位會員？" onClose={onClose}>
      <div className="mb-2 rounded bg-zinc-50 px-3 py-2 text-sm dark:bg-zinc-800/60">
        <div className="font-medium">{comment.commenter_name ?? "—"}</div>
        <div className="whitespace-pre-wrap break-words text-zinc-600 dark:text-zinc-300">{comment.text}</div>
      </div>
      <input className={input} autoFocus value={term} onChange={(e) => setTerm(e.target.value)}
        placeholder="會員編號 / 姓名 / 手機（至少 2 個字）" />
      <div className="mt-2 max-h-72 overflow-y-auto">
        {searching && <div className="p-2 text-sm text-zinc-400">搜尋中…</div>}
        {!searching && shown.length === 0 && term.trim().length >= 2 && <div className="p-2 text-sm text-zinc-400">找不到會員</div>}
        <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
          {shown.map((m) => (
            <li key={m.id}>
              <button type="button" disabled={busy !== null} onClick={() => void pick(m)}
                className="flex w-full items-center justify-between gap-2 px-2 py-2 text-left text-sm hover:bg-zinc-100 disabled:opacity-50 dark:hover:bg-zinc-800">
                <span className="truncate">{m.name}</span>
                <span className="shrink-0 text-xs text-zinc-500">{m.member_no}{m.home_store_name ? ` · ${m.home_store_name}` : ""}{busy === m.id ? " …" : ""}</span>
              </button>
            </li>
          ))}
        </ul>
      </div>
      <p className="mt-2 text-xs text-zinc-500">指定一次就記住這位留言者；下次留言不管寫不寫號碼、在哪個群，都直接對到這位會員。</p>
    </Modal>
  );
}

function LinkCampaignModal({ post, onClose, onDone, fail }: {
  post: Post; onClose: () => void; onDone: () => Promise<void>; fail: (e: unknown) => void;
}) {
  const [kw, setKw] = useState("");
  const [rows, setRows] = useState<CampaignPick[] | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let dead = false;
    const t = setTimeout(async () => {
      const k = kw.trim();
      // 草稿與已取消以外都能指定 —— 只列開團中／已收單的話，**已經結單（已鎖定，
      // 線上九成的團都在這個狀態）的貼文根本指不了**，永遠卡在「未認出團」
      // （2026-09-21 三峽 50 則 / 松山 36 則就是這樣堆起來的）。
      // 指到已結單的團 = 把貼文歸檔標名字，不會再讀留言加單（rpc 會直接收成「已結束」）。
      let query = getSupabase().from("group_buy_campaigns")
        .select("id,campaign_no,name,status").in("status", LINKABLE_CAMPAIGN_STATUSES)
        .order("id", { ascending: false }).limit(30);
      if (k) query = query.or(`name.ilike.%${k}%,campaign_no.ilike.%${k}%`);
      const { data } = await query;
      if (!dead) setRows((data ?? []) as CampaignPick[]);
    }, 250);
    return () => { dead = true; clearTimeout(t); };
  }, [kw]);

  const pick = async (id: number) => {
    setBusy(true);
    const { error } = await getSupabase().rpc("rpc_line_note_post_link", { p_id: post.id, p_campaign_id: id });
    setBusy(false);
    if (error) return fail(error);
    await onDone();
  };

  return (
    <Modal title="這則貼文是哪一團？" onClose={onClose}>
      <div className="space-y-3">
        <div className="max-h-32 overflow-auto whitespace-pre-wrap rounded border border-zinc-200 bg-zinc-50 p-2 text-sm dark:border-zinc-800 dark:bg-zinc-900">
          {post.text || "（沒有內文）"}
        </div>
        <input className={input} value={kw} onChange={(e) => setKw(e.target.value)} placeholder="搜尋團名或團號" autoFocus />
        {rows === null ? <div className="text-sm text-zinc-400">讀取中…</div>
          : rows.length === 0 ? <div className="text-sm text-zinc-400">沒有符合的團（草稿與已取消的團不列）</div> : (
          <ul className="max-h-72 divide-y divide-zinc-200 overflow-auto rounded border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
            {rows.map((r) => (
              <li key={r.id}>
                <button type="button" disabled={busy} onClick={() => void pick(r.id)}
                  className="flex w-full flex-col items-start gap-0.5 px-3 py-2 text-left text-sm hover:bg-zinc-50 disabled:opacity-50 dark:hover:bg-zinc-800">
                  <span className="font-medium">{r.name}</span>
                  <span className="flex items-center gap-2 text-xs text-zinc-500">
                    <span className={`rounded px-1.5 py-0.5 ${campaignStatusBadge(r.status)}`}>{campaignStatusLabel(r.status)}</span>
                    <span className="font-mono">{r.campaign_no}</span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Modal>
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
