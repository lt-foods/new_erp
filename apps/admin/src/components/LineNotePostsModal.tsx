"use client";

// 開團列表每一團的「LINE 記事本」彈窗：勾群組 → 看預覽 → 一次發出去，
// 同一個彈窗下半部就是這團爬回來的貼文與留言（爬過的歷史紀錄）。
//
// 為什麼不是把人送去 /line-notes：那頁是以「社群」為軸（一個社群一列，逐個按發文），
// 一團要發三個群組就得開三次彈窗、還得自己記得哪個發過了。開團才是小幫手的工作單位。
// /line-notes 的「貼文」分頁留著 —— 未認出團的貼文沒有團可掛，只能在那邊指定。
//
// 群組清單與「能不能發」一律問 rpc_line_note_campaign_targets（20260910020000），
// 不要在這裡自己接 line_note_communities 再算一次店家範圍 ——
// 那條規則的正主是開團自動發文的 trigger，散成三份就會走鐘。

import { useCallback, useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { OrderDetail } from "@/components/OrderDetail";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { withBasePath } from "@/lib/basePath";
import {
  COMMENT_STATUS_LABEL, HOME_KIND_LABEL, POST_STATUS_LABEL, commentStats, fmtNoteTime, isTodoComment,
  type LineNoteCommentStatus, type LineNotePostStatus,
} from "@/lib/lineNoteStatus";

type Target = {
  community_id: number; home_id: string; home_name: string | null; home_kind: string;
  store_id: number | null; store_name: string | null;
  account_id: number; account_label: string; account_status: string;
  auto_post_on_open: boolean; listen_enabled: boolean;
  in_scope: boolean; can_post: boolean; blocked_reason: string | null;
  post_id: number | null; post_status: LineNotePostStatus | null; line_post_id: string | null;
  post_text: string | null; posted_at: string | null; last_read_at: string | null;
  closed_reason: string | null; post_error: string | null;
  comment_total: number | null; comment_ordered: number | null;
  comment_duplicate: number | null; comment_todo: number | null;
};

type Comment = {
  id: number; line_comment_id: string; commenter_name: string | null; text: string;
  commented_at: string | null; member_no_hint: string | null;
  status: LineNoteCommentStatus; customer_order_id: number | null; error: string | null;
  reacted_at: string | null; resolution_note: string | null;
};

type QueueResult = { out_community_id: number; out_post_id: number | null; out_status: string; out_error: string | null };

type Props = {
  open: boolean;
  campaignId: number | null;
  campaignNo?: string | null;
  campaignName?: string | null;
  campaignStatus?: string | null;
  onClose: () => void;
};

const btn = "rounded border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800";
const btnPrimary = "rounded bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";
const CAN_POST_STATUS = ["open", "closed"];

function Badge({ tone, children }: { tone: "gray" | "green" | "amber" | "red" | "blue"; children: React.ReactNode }) {
  const cls = {
    gray: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
    green: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300",
    amber: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
    red: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300",
    blue: "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
  }[tone];
  return <span className={`inline-block whitespace-nowrap rounded px-1.5 py-0.5 text-xs font-medium ${cls}`}>{children}</span>;
}

// Edge Function line-note-worker：排程每分鐘會自己跑；按了按鈕就順手叫一下，不用等下一分鐘
function kickWorker(body: Record<string, unknown> = { action: "run" }) {
  void getSupabase().functions.invoke("line-note-worker", { body }).catch(() => {});
}

export default function LineNotePostsModal({
  open, campaignId, campaignNo, campaignName, campaignStatus, onClose,
}: Props) {
  const [targets, setTargets] = useState<Target[] | null>(null);
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [busy, setBusy] = useState<"send" | number | null>(null);
  const [results, setResults] = useState<QueueResult[] | null>(null);

  // 預覽：worker 那一份 renderTemplate 渲染出來的「等一下真的會貼出去的字」。
  // 模板是掛在社群上的，所以預覽要指定看哪個群組的。
  const [previewFor, setPreviewFor] = useState<number | null>(null);
  const [preview, setPreview] = useState<{ text: string; images: string[] } | null>(null);
  const [previewing, setPreviewing] = useState(false);

  // 爬回來的留言（點貼文展開）
  const [openPost, setOpenPost] = useState<number | null>(null);
  const [comments, setComments] = useState<Map<number, Comment[]>>(new Map());
  const [orderNos, setOrderNos] = useState<Map<number, string>>(new Map());
  const [loadingPost, setLoadingPost] = useState<number | null>(null);
  const [orderPopup, setOrderPopup] = useState<{ id: number; no: string } | null>(null);

  const fail = useCallback((e: unknown) => setError(translateRpcError(e)), []);
  const notify = useCallback((m: string) => { setToast(m); setTimeout(() => setToast(null), 3000); }, []);

  const load = useCallback(async (keepPicked = false) => {
    if (!campaignId) return;
    const { data, error } = await getSupabase().rpc("rpc_line_note_campaign_targets", { p_campaign_id: campaignId });
    if (error) { setTargets([]); return fail(error); }
    const rows = (data ?? []) as Target[];
    setTargets(rows);
    // 「預設全選」= 全部發得出去的群組。已經發過的不勾（重發會在 LINE 上多一篇，
    // 而舊那篇的 line_post_id 被覆蓋掉之後留言就再也讀不回來了）。
    if (!keepPicked) setPicked(new Set(rows.filter((t) => t.can_post).map((t) => t.community_id)));
    setPreviewFor((cur) => (cur && rows.some((t) => t.community_id === cur)
      ? cur
      : (rows.find((t) => t.can_post) ?? rows[0])?.community_id ?? null));
  }, [campaignId, fail]);

  useEffect(() => {
    if (!open || !campaignId) return;
    setTargets(null); setPicked(new Set()); setResults(null); setError(null);
    setOpenPost(null); setComments(new Map()); setOrderNos(new Map());
    void load();
  }, [open, campaignId, load]);

  // 預覽：換群組就重新問一次（不同群組可能有不同模板）
  useEffect(() => {
    if (!open || !campaignId || previewFor == null) { setPreview(null); return; }
    let dead = false;
    setPreviewing(true); setPreview(null);
    void (async () => {
      const { data, error } = await getSupabase().functions.invoke("line-note-worker", {
        body: { action: "preview", community_id: previewFor, campaign_id: campaignId },
      });
      if (dead) return;
      setPreviewing(false);
      if (error || (data as { error?: string })?.error) return;   // 預覽拿不到不擋發文
      setPreview(data as { text: string; images: string[] });
    })();
    return () => { dead = true; };
  }, [open, campaignId, previewFor]);

  const postable = useMemo(() => (targets ?? []).filter((t) => t.can_post), [targets]);
  const withPost = useMemo(() => (targets ?? []).filter((t) => t.post_id != null), [targets]);
  const canSendStatus = !campaignStatus || CAN_POST_STATUS.includes(campaignStatus);

  const toggle = (id: number) =>
    setPicked((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });

  const send = async () => {
    if (!campaignId || picked.size === 0) return;
    setBusy("send"); setError(null); setResults(null);
    const { data, error } = await getSupabase().rpc("rpc_line_note_queue_posts", {
      p_campaign_id: campaignId, p_community_ids: [...picked],
    });
    setBusy(null);
    if (error) return fail(error);
    const rows = (data ?? []) as QueueResult[];
    setResults(rows);
    const queued = rows.filter((r) => r.out_status === "queued").length;
    if (queued > 0) { kickWorker(); notify(`已排 ${queued} 個群組的發文，幾秒後下面就會出現貼文`); }
    // 排掉的取消勾選，**只留下這次失敗的**（那些多半是帳號掉線，修好再按一次就好）。
    // 不整批重新預設全選：排隊中的貼文 can_post 還是 true（worker 掛掉時要留一條重排的路），
    // 全選回來就會誘導人再按一次「發文」。
    const done = new Set(rows.filter((r) => r.out_status !== "error").map((r) => r.out_community_id));
    setPicked((prev) => new Set([...prev].filter((id) => !done.has(id))));
    await load(true);
    // worker 大概這個時間發完，順手把貼文狀態刷新一次
    if (queued > 0) setTimeout(() => { void load(true); }, 8000);
  };

  const toggleComments = async (t: Target) => {
    if (!t.post_id) return;
    if (openPost === t.post_id) { setOpenPost(null); return; }
    setOpenPost(t.post_id);
    if (comments.has(t.post_id)) return;
    setLoadingPost(t.post_id);
    const { data, error } = await getSupabase().from("line_note_comments")
      .select("id,line_comment_id,commenter_name,text,commented_at,member_no_hint,status,customer_order_id,error,reacted_at,resolution_note")
      .eq("post_id", t.post_id).order("commented_at", { ascending: true }).order("id");
    setLoadingPost(null);
    if (error) return fail(error);
    const cs = (data ?? []) as Comment[];
    setComments((m) => new Map(m).set(t.post_id!, cs));
    const ids = [...new Set(cs.map((c) => c.customer_order_id).filter((x): x is number => !!x))];
    if (ids.length === 0) return;
    const { data: od } = await getSupabase().from("customer_orders").select("id,order_no").in("id", ids);
    setOrderNos((m) => {
      const n = new Map(m);
      for (const o of (od ?? []) as { id: number; order_no: string }[]) n.set(o.id, o.order_no);
      return n;
    });
  };

  const readNow = async (t: Target) => {
    if (!t.post_id) return;
    setBusy(t.community_id);
    const { error } = await getSupabase().rpc("rpc_line_note_enqueue", {
      p_kind: "read", p_account_id: t.account_id, p_community_id: t.community_id, p_post_id: t.post_id,
    });
    setBusy(null);
    if (error) return fail(error);
    kickWorker();
    setComments((m) => { const n = new Map(m); n.delete(t.post_id!); return n; });
    notify("已開始讀留言，幾秒後重新整理就看得到");
    setTimeout(() => { void load(true); }, 8000);
  };

  const title = `LINE 記事本｜${campaignNo ? `${campaignNo} ` : ""}${campaignName ?? ""}`;

  return (
    <Modal open={open} onClose={onClose} title={title} maxWidth="max-w-6xl">
      {targets === null ? (
        <div className="py-10 text-center text-sm text-zinc-500">載入中…</div>
      ) : (
        <div className="space-y-4">
          {error && (
            <div className="flex items-start justify-between rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
              <span className="whitespace-pre-wrap">{error}</span>
              <button type="button" className="ml-3 shrink-0 text-xs underline" onClick={() => setError(null)}>關閉</button>
            </div>
          )}
          {toast && <div className="rounded bg-emerald-600 px-3 py-2 text-sm text-white">{toast}</div>}

          {targets.length === 0 && (
            <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
              沒有可以發文的社群。
              <ul className="ml-4 mt-1 list-disc space-y-0.5 text-xs">
                <li>店家自開的團只發到「標了那家店」的社群 —— 到「LINE 記事本 → 社群設定」把社群的店家設成那一家。</li>
                <li>總部的團會發到所有社群；一個都沒有的話請先在那頁登入帳號、同步社群。</li>
              </ul>
            </div>
          )}

          <div className="grid gap-4 lg:grid-cols-2">
            {/* ── 左：勾群組 + 預覽 + 發文 ───────────────────────────── */}
            {targets.length > 0 && (
            <section className="space-y-3">
              <div>
                <div className="mb-1.5 flex items-center justify-between">
                  <h3 className="text-sm font-semibold">發到哪幾個群組（{picked.size}/{postable.length}）</h3>
                  <button type="button" className={btn} disabled={postable.length === 0}
                    onClick={() => setPicked(picked.size === postable.length
                      ? new Set()
                      : new Set(postable.map((t) => t.community_id)))}>
                    {picked.size === postable.length && postable.length > 0 ? "全部取消" : "全選"}
                  </button>
                </div>
                <ul className="divide-y divide-zinc-200 overflow-hidden rounded border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
                  {targets.map((t) => {
                    const on = picked.has(t.community_id);
                    return (
                      <li key={t.community_id} className={t.can_post ? "" : "bg-zinc-50 dark:bg-zinc-900/40"}>
                        <label className={`flex items-start gap-2 px-2.5 py-2 text-sm ${t.can_post ? "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-800/60" : ""}`}>
                          <input type="checkbox" className="mt-1" checked={on} disabled={!t.can_post || busy === "send"}
                            onChange={() => toggle(t.community_id)} />
                          <span className="min-w-0 flex-1">
                            <span className="flex flex-wrap items-center gap-1.5">
                              <span className="font-medium">{t.home_name || t.home_id}</span>
                              <span className="text-xs text-zinc-500">{HOME_KIND_LABEL[t.home_kind] ?? t.home_kind}</span>
                              {t.post_id != null && (
                                t.post_status === "failed" ? <Badge tone="red">發文失敗</Badge>
                                : t.post_status === "queued" ? <Badge tone="amber">排隊中</Badge>
                                : <Badge tone="green">已發</Badge>
                              )}
                              {t.account_status !== "active" && <Badge tone="red">帳號未登入</Badge>}
                              {!t.in_scope && <Badge tone="gray">不在發送範圍</Badge>}
                            </span>
                            <span className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-zinc-500">
                              <span>{t.store_name ? `${t.store_name}` : "總部（全部團）"}</span>
                              <span>{t.account_label}</span>
                              {!t.can_post && t.blocked_reason && <span className="text-amber-700 dark:text-amber-400">{t.blocked_reason}</span>}
                            </span>
                          </span>
                          <button type="button"
                            className={`shrink-0 text-xs underline ${previewFor === t.community_id ? "text-sky-700 dark:text-sky-400" : "text-zinc-500"}`}
                            onClick={(e) => { e.preventDefault(); setPreviewFor(t.community_id); }}>
                            {previewFor === t.community_id ? "預覽中" : "看預覽"}
                          </button>
                        </label>
                      </li>
                    );
                  })}
                </ul>
              </div>

              <div>
                <div className="mb-1 flex items-center justify-between text-sm">
                  <h3 className="font-semibold">會貼出去的內容</h3>
                  {preview && <span className="text-xs text-zinc-500">{preview.images.length} 張圖</span>}
                </div>
                {previewing ? (
                  <div className="rounded border border-zinc-200 p-3 text-sm text-zinc-400 dark:border-zinc-800">產生預覽中…</div>
                ) : !preview ? (
                  <div className="rounded border border-zinc-200 p-3 text-sm text-zinc-400 dark:border-zinc-800">
                    預覽拿不到（LINE 帳號沒登入？）—— 還是可以直接發
                  </div>
                ) : (
                  <div className="space-y-2">
                    <div className="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
                      {preview.text}
                    </div>
                    {preview.images.length > 0 && (
                      <div className="flex gap-1.5 overflow-x-auto pb-1">
                        {preview.images.map((u) => (
                          // eslint-disable-next-line @next/next/no-img-element -- Supabase storage 公開網址，不走 next/image
                          <img key={u} src={u} alt="" className="h-16 w-16 shrink-0 rounded border border-zinc-200 object-cover dark:border-zinc-800" />
                        ))}
                      </div>
                    )}
                  </div>
                )}
                <p className="mt-1 text-xs text-zinc-500">
                  文案取自這個團的說明、商品與價格取自團裡的品項、圖片取自商品圖。要改內容請去改團／商品。
                  文末的「🔖 團號」是給系統認的章，爬回來時靠它認出是哪一團。
                </p>
              </div>

              {results && results.length > 0 && (
                <ul className="space-y-1 rounded border border-zinc-200 p-2 text-xs dark:border-zinc-800">
                  {results.map((r) => {
                    const t = targets.find((x) => x.community_id === r.out_community_id);
                    const name = t?.home_name || t?.home_id || `社群 #${r.out_community_id}`;
                    return (
                      <li key={r.out_community_id} className="flex flex-wrap items-center gap-1.5">
                        {r.out_status === "queued" ? <Badge tone="green">已排隊</Badge>
                          : r.out_status === "already_posted" ? <Badge tone="gray">已發過，跳過</Badge>
                          : <Badge tone="red">不能發</Badge>}
                        <span>{name}</span>
                        {r.out_error && <span className="text-red-600 dark:text-red-400">{r.out_error}</span>}
                      </li>
                    );
                  })}
                </ul>
              )}

              <div className="flex items-center justify-end gap-2">
                {!canSendStatus && (
                  <span className="text-xs text-amber-700 dark:text-amber-400">只有開團中／已收單的團可以發文</span>
                )}
                <SpinButton className={btnPrimary} loading={busy === "send"}
                  disabled={picked.size === 0 || !canSendStatus} onClick={send}>
                  發文到 {picked.size} 個群組
                </SpinButton>
              </div>
            </section>
            )}

            {/* ── 右：爬過的歷史紀錄 ─────────────────────────────────── */}
            <section className={targets.length > 0 ? "" : "lg:col-span-2"}>
              <div className="mb-1.5 flex items-center justify-between">
                <h3 className="text-sm font-semibold">爬過的歷史紀錄（{withPost.length} 篇貼文）</h3>
                <button type="button" className={btn} onClick={() => void load(true)}>重新整理</button>
              </div>
              {withPost.length === 0 ? (
                <div className="rounded border border-zinc-200 py-8 text-center text-sm text-zinc-400 dark:border-zinc-800">
                  這團還沒有貼文
                </div>
              ) : (
                <ul className="space-y-2">
                  {withPost.map((t) => {
                    const expanded = openPost === t.post_id;
                    const cs = t.post_id != null ? comments.get(t.post_id) : undefined;
                    return (
                      <li key={t.community_id} className="overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
                        <button type="button" onClick={() => void toggleComments(t)}
                          className="flex w-full items-start gap-2 p-2.5 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800/50">
                          <span className="mt-0.5 shrink-0 text-zinc-400">{expanded ? "▾" : "▸"}</span>
                          <div className="min-w-0 flex-1 space-y-1">
                            <div className="flex items-start justify-between gap-2">
                              <span className="min-w-0 flex-1 truncate text-sm font-medium">{t.home_name || t.home_id}</span>
                              <span className="shrink-0 text-xs tabular-nums text-zinc-500">{t.comment_total ?? 0} 則留言</span>
                            </div>
                            <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-zinc-500">
                              {/* 貼文 id：後台這一列的編號 + LINE 那邊的貼文 id，兩個都給 ——
                                  跟客服對答案時只有 LINE 的 id 認得出是哪一篇 */}
                              <span className="font-mono">貼文 #{t.post_id}</span>
                              {t.line_post_id && <span className="font-mono" title="LINE 記事本的貼文 id">LINE {t.line_post_id}</span>}
                              {t.post_status && t.post_status !== "posted" && (
                                <Badge tone={t.post_status === "failed" ? "red" : "gray"}>{POST_STATUS_LABEL[t.post_status]}</Badge>
                              )}
                              <span>發文 {fmtNoteTime(t.posted_at)}</span>
                              {t.last_read_at && <span>讀取 {fmtNoteTime(t.last_read_at)}</span>}
                            </div>
                            <div className="flex flex-wrap items-center gap-1">
                              {(t.comment_ordered ?? 0) > 0 && <Badge tone="green">已加單 {t.comment_ordered}</Badge>}
                              {(t.comment_duplicate ?? 0) > 0 && <Badge tone="blue">已有訂單 {t.comment_duplicate}</Badge>}
                              {(t.comment_todo ?? 0) > 0 && <Badge tone="red">待處理 {t.comment_todo}</Badge>}
                            </div>
                            {t.closed_reason && <div className="text-xs text-zinc-500">讀到結單留言：{t.closed_reason}</div>}
                            {t.post_error && <div className="text-xs text-red-600">{t.post_error}</div>}
                          </div>
                        </button>

                        <div className="flex flex-wrap gap-1.5 border-t border-zinc-100 px-2.5 py-1.5 dark:border-zinc-800">
                          {t.post_status === "posted" && (
                            <SpinButton className={btn} loading={busy === t.community_id} onClick={() => void readNow(t)}>
                              立即讀留言
                            </SpinButton>
                          )}
                          {/* 退回未處理 / 忽略 / 重試那些留言操作都在記事本頁，這裡只給入口，不再抄一份 */}
                          <a className={`${btn} ml-auto`} href={withBasePath("/line-notes")} target="_blank" rel="noreferrer">
                            到記事本頁處理留言
                          </a>
                        </div>

                        {expanded && (
                          <div className="border-t border-zinc-100 bg-zinc-50 p-2.5 dark:border-zinc-800 dark:bg-zinc-900/50">
                            {loadingPost === t.post_id ? <div className="text-sm text-zinc-400">讀取中…</div>
                              : !cs ? null
                              : cs.length === 0 ? <div className="text-sm text-zinc-400">還沒讀到留言</div> : (
                              <>
                                <div className="mb-1.5 text-xs text-zinc-500">
                                  {(() => { const s = commentStats(cs);
                                    return `共 ${s.total} 則：已加單 ${s.ordered}、已有訂單 ${s.duplicate}、待處理 ${s.todo}`; })()}
                                </div>
                                <ul className="divide-y divide-zinc-200 rounded border border-zinc-200 bg-white dark:divide-zinc-800 dark:border-zinc-800 dark:bg-zinc-900">
                                  {cs.map((cm) => (
                                    <li key={cm.id} className={`px-2.5 py-2 text-sm ${isTodoComment(cm) ? "bg-amber-50/60 dark:bg-amber-950/20" : ""}`}>
                                      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                                        <span className="font-medium">{cm.commenter_name ?? "—"}</span>
                                        <span className="text-xs text-zinc-500">{fmtNoteTime(cm.commented_at)}</span>
                                        <Badge tone={cm.status === "ordered" || cm.status === "resolved" ? "green"
                                          : cm.status === "duplicate" ? "blue"
                                          : cm.status === "pending" ? "amber"
                                          : cm.status === "unmatched" || cm.status === "error" ? "red" : "gray"}>
                                          {COMMENT_STATUS_LABEL[cm.status]}
                                        </Badge>
                                        {cm.customer_order_id != null && orderNos.has(cm.customer_order_id) && (
                                          <button type="button"
                                            className="font-mono text-xs text-sky-700 underline hover:text-sky-900 dark:text-sky-400"
                                            onClick={() => setOrderPopup({ id: cm.customer_order_id!, no: orderNos.get(cm.customer_order_id!)! })}>
                                            {orderNos.get(cm.customer_order_id)}
                                          </button>
                                        )}
                                        {cm.reacted_at && <span title={`已在 LINE 留言上按 😄（${fmtNoteTime(cm.reacted_at)}）`}>😄</span>}
                                      </div>
                                      <div className="mt-0.5 whitespace-pre-wrap break-words text-zinc-700 dark:text-zinc-300">{cm.text}</div>
                                      {cm.error && <div className="mt-0.5 text-xs text-red-600 dark:text-red-400">{cm.error}</div>}
                                    </li>
                                  ))}
                                </ul>
                              </>
                            )}
                          </div>
                        )}
                      </li>
                    );
                  })}
                </ul>
              )}
            </section>
          </div>
        </div>
      )}

      {/* 留言加出來的訂單：跟 CampaignOrdersPanel 一樣在彈窗裡再開一層 */}
      <Modal
        open={orderPopup !== null}
        onClose={() => setOrderPopup(null)}
        title={`訂單明細 ${orderPopup?.no ?? ""}`}
        maxWidth="max-w-4xl"
      >
        {orderPopup && <OrderDetail orderId={orderPopup.id} onNavigate={(id, no) => setOrderPopup({ id, no })} />}
      </Modal>
    </Modal>
  );
}
