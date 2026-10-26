"use client";

// 開團「推廣文」：替這一團另外寫一段文字，機器人一個社群一個社群送到聊天室，
// 後面接這團在該社群的記事本貼文卡片（客人點進去就能 +1）。從 LineNotePostsModal 開。
//
// 真正送的是 line-note-worker 的 jobPromo，走 line_note_jobs 的節流（帳號暫停、每分鐘額度、
// 跟結單提醒共用「每帳號每 N 分鐘一則」）—— 不要改成在這裡逐一呼叫，LINE 會鎖帳號
// （CLAUDE.md「LINE 社群：分享到聊天室不能爆量」）。
// 範圍規則（自開團不發、社群要收這一類的團、帳號要登入）的正主是 rpc_line_note_queue_promo；
// 這裡的勾選清單只是先把一定會被擋的灰掉。

import { useCallback, useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { fmtNoteTime } from "@/lib/lineNoteStatus";

export type PromoTarget = {
  community_id: number; home_id: string; home_name: string | null;
  account_label: string; account_status: string;
  auto_post_on_open: boolean; in_scope: boolean;
  post_status: string | null; line_post_id: string | null;
};

type Send = {
  job_id: number; community_id: number | null; home_name: string;
  status: "queued" | "running" | "done" | "failed"; error: string | null;
  result: { promoted?: boolean; card?: boolean; noPost?: boolean; cardError?: string; skipped?: string } | null;
  finished_at: string | null;
};
type Promo = { promo_id: number; text: string; with_card: boolean; with_link: boolean; created_at: string; sends: Send[] };
type QueueResult = { out_community_id: number; out_job_id: number | null; out_status: string; out_error: string | null };

type Props = {
  open: boolean;
  campaignId: number | null;
  campaignNo?: string | null;
  campaignName?: string | null;
  targets: PromoTarget[];
  onClose: () => void;
};

const MAX_LEN = 2000;
const btn = "rounded border border-zinc-300 px-2.5 py-1 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800";
const btnPrimary = "rounded bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";

const TONE = {
  gray: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  green: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300",
  amber: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
  red: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300",
} as const;
function Pill({ tone, children }: { tone: keyof typeof TONE; children: React.ReactNode }) {
  return <span className={`inline-block whitespace-nowrap rounded px-1.5 py-0.5 text-xs font-medium ${TONE[tone]}`}>{children}</span>;
}

const hasPost = (t: PromoTarget) => t.post_status === "posted" && !!t.line_post_id;
const canSend = (t: PromoTarget) => t.in_scope && t.account_status === "active";

function fmtEnd(iso: string): string {
  return new Date(iso).toLocaleString("zh-TW", {
    timeZone: "Asia/Taipei", hour12: false, month: "numeric", day: "numeric", weekday: "short", hour: "2-digit", minute: "2-digit",
  });
}

function draftText(name: string, endAt: string | null): string {
  return [
    `📣 ${name}`,
    ...(endAt ? [`⏰ 收單到 ${fmtEnd(endAt)}`] : []),
    "還沒跟到的好鄰居，記得到記事本留言「+數量」喔！🙏",
  ].join("\n");
}

const SKIP_LABEL: Record<string, string> = {
  "campaign ended": "團已過收單時間", "community deleted": "社群已刪除", "promo deleted": "推廣文已刪除",
};
function sendState(s: Send): { tone: keyof typeof TONE; label: string; note?: string } {
  if (s.status === "queued") {
    return s.error ? { tone: "amber", label: "等 LINE 解除暫緩", note: "LINE 要求慢一點，系統會自己重送" } : { tone: "amber", label: "排隊中" };
  }
  if (s.status === "running") return { tone: "amber", label: "送出中" };
  if (s.status === "failed") return { tone: "red", label: "失敗", note: s.error ?? undefined };
  const r = s.result ?? {};
  if (r.skipped) {
    return { tone: "gray", label: "略過", note: SKIP_LABEL[r.skipped] ?? (r.skipped.startsWith("campaign") ? "團已不是開團中" : r.skipped) };
  }
  if (r.cardError) return { tone: "amber", label: "已送出文字", note: `貼文卡片沒送出：${r.cardError}` };
  return { tone: "green", label: r.card ? "已送出＋卡片" : "已送出", note: r.noPost ? "這個社群沒有這團的貼文，只送了文字" : undefined };
}

function kickWorker() {
  void getSupabase().functions.invoke("line-note-worker", { body: { action: "run" } }).catch(() => {});
}

// 父層只在要開的時候才掛它（{promoOpen && …}），每次開窗都是新的 state，不用在 effect 裡重設
export default function LineNotePromoModal({ open, campaignId, campaignNo, campaignName, targets, onClose }: Props) {
  const [text, setText] = useState("");
  const [withCard, setWithCard] = useState(true);
  const [withLink, setWithLink] = useState(true);
  // 預設勾「平常就會自動發這類團」的社群＋這團已經發過貼文的社群；備用帳號身上的私人群組不勾
  const [picked, setPicked] = useState<Set<number>>(
    () => new Set(targets.filter((t) => canSend(t) && (t.auto_post_on_open || hasPost(t))).map((t) => t.community_id)));
  const [history, setHistory] = useState<Promo[] | null>(null);
  const [results, setResults] = useState<QueueResult[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const list = useMemo(() => targets.filter((t) => t.in_scope), [targets]);
  const sendable = useMemo(() => list.filter(canSend), [list]);

  const loadHistory = useCallback(async () => {
    if (!campaignId) return;
    const { data, error } = await getSupabase().rpc("rpc_line_note_campaign_promos", { p_campaign_id: campaignId });
    if (error) { setHistory([]); setError(translateRpcError(error)); return; }
    setHistory((data ?? []) as Promo[]);
  }, [campaignId]);

  useEffect(() => {
    if (!open || !campaignId) return;
    void loadHistory();
    let dead = false;
    void (async () => {
      const { data } = await getSupabase().from("group_buy_campaigns")
        .select("name,customer_end_at,end_at").eq("id", campaignId).maybeSingle();
      if (dead) return;
      const g = data as { name: string; customer_end_at: string | null; end_at: string | null } | null;
      setText((cur) => cur || draftText(g?.name ?? campaignName ?? "", g?.customer_end_at ?? g?.end_at ?? null));
    })();
    return () => { dead = true; };
  }, [open, campaignId, campaignName, loadHistory]);

  const toggle = (id: number) => setPicked((prev) => {
    const next = new Set(prev);
    if (next.has(id)) next.delete(id); else next.add(id);
    return next;
  });

  const trimmed = text.trim();
  const send = async () => {
    if (!campaignId || picked.size === 0 || !trimmed) return;
    if (!window.confirm(`確定要把這則推廣文送到 ${picked.size} 個社群？\n送出去之後收不回來。`)) return;
    setBusy(true); setError(null); setResults(null);
    const { data, error } = await getSupabase().rpc("rpc_line_note_queue_promo", {
      p_campaign_id: campaignId, p_text: trimmed, p_with_card: withCard, p_with_link: withLink,
      p_community_ids: [...picked],
    });
    setBusy(false);
    if (error) { setError(translateRpcError(error)); return; }
    const rows = (data ?? []) as QueueResult[];
    setResults(rows);
    const queued = rows.filter((r) => r.out_status === "queued").length;
    if (queued > 0) {
      kickWorker();
      setToast(`已排 ${queued} 個社群，機器人會一個一個送`);
      setTimeout(() => setToast(null), 3000);
      setTimeout(() => { void loadHistory(); }, 8000);
    }
    await loadHistory();
  };

  const nameOf = (id: number) => {
    const t = targets.find((x) => x.community_id === id);
    return t?.home_name || t?.home_id || `社群 #${id}`;
  };

  return (
    <Modal open={open} onClose={onClose} title={`📣 推廣文｜${campaignNo ? `${campaignNo} ` : ""}${campaignName ?? ""}`} maxWidth="max-w-5xl">
      <div className="space-y-4">
        {error && (
          <div className="flex items-start justify-between rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
            <span className="whitespace-pre-wrap">{error}</span>
            <button type="button" className="ml-3 shrink-0 text-xs underline" onClick={() => setError(null)}>關閉</button>
          </div>
        )}
        {toast && <div className="rounded bg-emerald-600 px-3 py-2 text-sm text-white">{toast}</div>}

        <div className="grid gap-4 lg:grid-cols-2">
          <section className="space-y-3">
            <div>
              <div className="mb-1 flex items-center justify-between text-sm">
                <h3 className="font-semibold">推廣文</h3>
                <span className={`text-xs tabular-nums ${trimmed.length > MAX_LEN ? "text-red-600" : "text-zinc-500"}`}>{trimmed.length}/{MAX_LEN}</span>
              </div>
              <textarea
                className="h-48 w-full rounded border border-zinc-300 bg-white p-2 text-sm dark:border-zinc-700 dark:bg-zinc-950"
                value={text} onChange={(e) => setText(e.target.value)} disabled={busy}
                placeholder="寫給社群的推廣文字，例如：今天最後一天！還沒跟到的好鄰居快來 +1" />
            </div>
            <label className="flex items-start gap-2 text-sm">
              <input type="checkbox" className="mt-1" checked={withCard} onChange={(e) => setWithCard(e.target.checked)} disabled={busy} />
              <span>後面附上這團的記事本貼文卡片<span className="block text-xs text-zinc-500">客人點卡片就進到貼文留言 +1；該社群還沒有這團的貼文就只送文字</span></span>
            </label>
            <label className="flex items-start gap-2 text-sm">
              <input type="checkbox" className="mt-1" checked={withLink} onChange={(e) => setWithLink(e.target.checked)} disabled={busy} />
              <span>文末自動帶這團的商城連結<span className="block text-xs text-zinc-500">「🛒 商城下單：…」跟記事本貼文同一條；沒上架商城的團不會帶</span></span>
            </label>

            <div>
              <div className="mb-1.5 flex items-center justify-between">
                <h3 className="text-sm font-semibold">送到哪幾個社群（{picked.size}/{sendable.length}）</h3>
                <button type="button" className={btn} disabled={sendable.length === 0 || busy}
                  onClick={() => setPicked(picked.size === sendable.length ? new Set() : new Set(sendable.map((t) => t.community_id)))}>
                  {picked.size === sendable.length && sendable.length > 0 ? "全部取消" : "全選"}
                </button>
              </div>
              {list.length === 0 ? (
                <div className="rounded border border-zinc-200 p-3 text-sm text-zinc-400 dark:border-zinc-800">沒有收這一類團的社群</div>
              ) : (
                <ul className="divide-y divide-zinc-200 overflow-hidden rounded border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
                  {list.map((t) => (
                    <li key={t.community_id} className={canSend(t) ? "" : "bg-zinc-50 dark:bg-zinc-900/40"}>
                      <label className={`flex items-start gap-2 px-2.5 py-2 text-sm ${canSend(t) ? "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-800/60" : ""}`}>
                        <input type="checkbox" className="mt-1" checked={picked.has(t.community_id)}
                          disabled={!canSend(t) || busy} onChange={() => toggle(t.community_id)} />
                        <span className="min-w-0 flex-1">
                          <span className="flex flex-wrap items-center gap-1.5">
                            <span className="font-medium">{t.home_name || t.home_id}</span>
                            {t.account_status !== "active" ? <Pill tone="red">帳號未登入</Pill>
                              : hasPost(t) ? <Pill tone="green">有這團的貼文</Pill>
                              : <Pill tone="gray">沒有這團的貼文（只送文字）</Pill>}
                          </span>
                          <span className="mt-0.5 block text-xs text-zinc-500">{t.account_label}</span>
                        </span>
                      </label>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            {results && results.some((r) => r.out_status !== "queued") && (
              <ul className="space-y-1 rounded border border-zinc-200 p-2 text-xs dark:border-zinc-800">
                {results.filter((r) => r.out_status !== "queued").map((r) => (
                  <li key={r.out_community_id} className="flex flex-wrap items-center gap-1.5">
                    <Pill tone="red">不能送</Pill><span>{nameOf(r.out_community_id)}</span>
                    {r.out_error && <span className="text-red-600 dark:text-red-400">{r.out_error}</span>}
                  </li>
                ))}
              </ul>
            )}

            <p className="text-xs text-zinc-500">
              機器人會一個社群一個社群慢慢送（每個帳號每幾分鐘一則，跟結單提醒同一條隊伍），不會一次全部出去 —— 一口氣送太多 LINE 會鎖帳號。
            </p>
            <div className="flex justify-end">
              <SpinButton className={btnPrimary} loading={busy}
                disabled={picked.size === 0 || !trimmed || trimmed.length > MAX_LEN} onClick={send}>
                送到 {picked.size} 個社群
              </SpinButton>
            </div>
          </section>

          <section>
            <div className="mb-1.5 flex items-center justify-between">
              <h3 className="text-sm font-semibold">這團送過的推廣文</h3>
              <button type="button" className={btn} onClick={() => void loadHistory()}>重新整理</button>
            </div>
            {history === null ? (
              <div className="py-8 text-center text-sm text-zinc-400">載入中…</div>
            ) : history.length === 0 ? (
              <div className="rounded border border-zinc-200 py-8 text-center text-sm text-zinc-400 dark:border-zinc-800">還沒送過</div>
            ) : (
              <ul className="space-y-2">
                {history.map((p) => (
                  <li key={p.promo_id} className="rounded-lg border border-zinc-200 bg-white p-2.5 dark:border-zinc-800 dark:bg-zinc-900">
                    <div className="mb-1 flex items-center justify-between gap-2 text-xs text-zinc-500">
                      <span>{fmtNoteTime(p.created_at)}</span>
                      <span>{[p.with_card && "附卡片", p.with_link && "附商城連結"].filter(Boolean).join("・")}</span>
                    </div>
                    <div className="max-h-24 overflow-auto whitespace-pre-wrap break-words text-sm">{p.text}</div>
                    <div className="mt-1.5 flex justify-end">
                      <button type="button" className="text-xs text-sky-700 underline dark:text-sky-400" disabled={busy}
                        onClick={() => { setText(p.text); setWithCard(p.with_card); setWithLink(p.with_link); }}>
                        用這則再寫一次
                      </button>
                    </div>
                    <ul className="mt-1.5 space-y-1 border-t border-zinc-100 pt-1.5 text-xs dark:border-zinc-800">
                      {p.sends.map((s) => {
                        const st = sendState(s);
                        return (
                          <li key={s.job_id} className="flex flex-wrap items-center gap-1.5">
                            <Pill tone={st.tone}>{st.label}</Pill>
                            <span>{s.home_name}</span>
                            {s.finished_at && s.status === "done" && <span className="text-zinc-500">{fmtNoteTime(s.finished_at)}</span>}
                            {st.note && <span className={st.tone === "red" ? "text-red-600 dark:text-red-400" : "text-zinc-500"}>{st.note}</span>}
                          </li>
                        );
                      })}
                    </ul>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>
      </div>
    </Modal>
  );
}
