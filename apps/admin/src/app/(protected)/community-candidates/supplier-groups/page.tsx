"use client";

// 廠商群組 —— 設定機器人（小幫手）要讀哪些廠商群組的記事本。
// 讀到的貼文幾分鐘內由 market-ai（Cloudflare Workers AI）拆成商品，直接進候選池（附價格、規格、我們賣過嗎）。
// 資料：rpc_line_note_crawl_homes / rpc_line_note_set_crawl（20261101000040）、
//       rpc_line_note_enqueue('list_homes') 讀帳號所在的群組（跟 LINE 記事本頁同一條路）。

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ChartCard, num } from "@/components/ChartKit";
import SourceTabs from "../SourceTabs";

type Account = { id: number; label: string; status: string; display_name: string | null };
type LineHome = { homeId: string; name: string; kind: string };
type CrawlHome = {
  id: number; home_id: string; home_name: string; home_kind: string;
  account_id: number | null; account_label: string | null; account_status: string | null;
  crawl_enabled: boolean; crawl_supplier_id: number | null; supplier_name: string | null;
  crawl_last_at: string | null; posts: number; candidates: number;
  last_job: { status: string; error: string | null; at: string; result: { listed?: number; new?: number } | null } | null;
};
type Supplier = { id: number; name: string };

const KIND_LABEL: Record<string, string> = { group: "群組", square: "社群", square_chat: "社群聊天室" };
const fmtTime = (s: string | null) =>
  s ? new Date(s).toLocaleString("zh-TW", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "—";

function kickWorker() {
  void getSupabase().functions.invoke("line-note-worker", { body: { action: "run" } }).catch(() => {});
}

export default function SupplierGroupsPage() {
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [accountId, setAccountId] = useState<number | "">("");
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [crawl, setCrawl] = useState<CrawlHome[]>([]);
  const [lineHomes, setLineHomes] = useState<LineHome[] | null>(null);
  const [loadingHomes, setLoadingHomes] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  const loadCrawl = useCallback(async () => {
    const { data, error: err } = await getSupabase().rpc("rpc_line_note_crawl_homes");
    if (err) { setError(translateRpcError(err)); return; }
    // 讀成功就把上一次讀取失敗的紅字收掉（不然修好之後還一直掛著）
    setError((prev) => (prev && /rpc_line_note_crawl_homes|line_note_accounts/.test(prev) ? null : prev));
    setCrawl((data ?? []) as CrawlHome[]);
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data: a, error: e1 }, { data: s, error: e2 }] = await Promise.all([
        sb.from("v_line_note_accounts").select("id,label,status,display_name").order("id"),
        sb.from("suppliers").select("id,name").eq("is_active", true).order("name"),
      ]);
      if (cancelled) return;
      if (e1 || e2) { setError(translateRpcError((e1 ?? e2)!)); return; }
      const list = (a ?? []) as Account[];
      setAccounts(list);
      setSuppliers((s ?? []) as Supplier[]);
      // 預設選「小幫手」開頭、已登入的帳號
      const pick = list.find((x) => x.status === "active" && /^小幫手/.test(x.label)) ?? list.find((x) => x.status === "active");
      if (pick) setAccountId(pick.id);
      await loadCrawl();
    })();
    return () => { cancelled = true; };
  }, [loadCrawl]);

  // 「重新讀取」之後輪詢一下正在跑的爬取工作，讀完自動刷新
  useEffect(() => {
    if (!crawl.some((c) => c.last_job && ["queued", "running"].includes(c.last_job.status))) return;
    const t = setTimeout(() => { void loadCrawl(); }, 5000);
    return () => clearTimeout(t);
  }, [crawl, loadCrawl]);

  const crawlByHome = useMemo(() => new Map(crawl.map((c) => [c.home_id, c])), [crawl]);

  async function readAccountHomes() {
    if (accountId === "") return;
    setLoadingHomes(true); setError(null); setNotice(null);
    try {
      const sb = getSupabase();
      const { data: jobId, error: err } = await sb.rpc("rpc_line_note_enqueue", { p_kind: "list_homes", p_account_id: accountId });
      if (err) throw err;
      kickWorker();
      for (let i = 0; i < 40; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        const { data } = await sb.from("line_note_jobs").select("status,result,error").eq("id", jobId).single();
        if (data?.status === "done") {
          setLineHomes((((data.result as { homes?: LineHome[] })?.homes) ?? []).filter((h) => h.homeId));
          return;
        }
        if (data?.status === "failed") throw new Error(data.error ?? "機器人回報失敗");
      }
      throw new Error("等太久沒回應：這個帳號登入了嗎？到「LINE 記事本 → 帳號」看一下。");
    } catch (e) {
      setError(e instanceof Error ? e.message : translateRpcError(e as never));
    } finally {
      setLoadingHomes(false);
    }
  }

  async function setCrawlFor(
    home: { home_id: string; name: string; kind: string },
    opts: { enabled: boolean; supplier: number | null; account: number | null; now?: boolean },
  ) {
    if (opts.account == null) { setError("先選一個機器人帳號"); return; }
    setBusy(home.home_id); setError(null); setNotice(null);
    const { data, error: err } = await getSupabase().rpc("rpc_line_note_set_crawl", {
      p_account_id: opts.account, p_home_id: home.home_id, p_home_name: home.name, p_home_kind: home.kind,
      p_enabled: opts.enabled, p_supplier_id: opts.supplier, p_crawl_now: opts.now ?? false,
    });
    setBusy(null);
    if (err) { setError(translateRpcError(err)); return; }
    if ((data as { job_id?: number | null })?.job_id) {
      kickWorker();
      setNotice(`「${home.name}」讀取中，幾秒後新貼文就會出現在候選池（標「待整理」），幾分鐘內 AI 會拆成品項、比對賣過沒。`);
    }
    await loadCrawl();
  }

  const shownLineHomes = (lineHomes ?? []).filter((h) => !filter || h.name.includes(filter));
  const enabled = crawl.filter((c) => c.crawl_enabled);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <SourceTabs />
      <header>
        <h1 className="text-xl font-semibold">廠商群組（LINE）</h1>
        <p className="text-sm text-zinc-500">
          選機器人帳號、勾要讀的廠商群組。讀到的新貼文馬上進
          <Link href="/community-candidates" className="mx-1 text-blue-600 hover:underline dark:text-blue-400">候選池</Link>
          （標「待整理」），幾分鐘內 AI（Cloudflare）看圖文拆成品項，附團購價、規格，以及我們有沒有賣過。
          每天 01:13 自動讀近兩個禮拜的記事本，也可以按「立即讀取」。只讀貼文，不留言、不按讚。
        </p>
      </header>

      {error && <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">{error}</div>}
      {notice && <div className="rounded border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700 dark:border-emerald-900 dark:bg-emerald-950/40 dark:text-emerald-300">{notice}</div>}

      {/* 1. 正在讀的群組 */}
      <ChartCard title="正在讀的廠商群組" subtitle={`${enabled.length} 個`}>
        <div className="overflow-x-auto">
          <table className="min-w-full text-xs">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">群組</th>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">機器人帳號</th>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">廠商</th>
                <th className="px-2 py-1.5 text-left font-medium text-zinc-500">上次讀取</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">貼文</th>
                <th className="px-2 py-1.5 text-right font-medium text-zinc-500">進候選池</th>
                <th className="px-2 py-1.5"></th>
              </tr>
            </thead>
            <tbody>
              {enabled.map((c) => {
                const h = { home_id: c.home_id, name: c.home_name, kind: c.home_kind };
                const running = c.last_job && ["queued", "running"].includes(c.last_job.status);
                return (
                  <tr key={c.id} className={`border-t border-zinc-100 dark:border-zinc-800 ${busy === c.home_id ? "opacity-50" : ""}`}>
                    <td className="max-w-[260px] px-2 py-1.5">
                      <div className="truncate" title={c.home_name}>{c.home_name}</div>
                      <div className="text-[11px] text-zinc-400">{KIND_LABEL[c.home_kind] ?? c.home_kind}</div>
                    </td>
                    <td className="px-2 py-1.5">
                      <select className="max-w-[130px] rounded border border-zinc-300 bg-white px-1 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
                              value={c.account_id ?? ""} disabled={busy === c.home_id}
                              onChange={(e) => setCrawlFor(h, { enabled: true, supplier: c.crawl_supplier_id, account: Number(e.target.value) })}>
                        {accounts.map((a) => <option key={a.id} value={a.id}>{a.label}{a.status !== "active" ? "（未登入）" : ""}</option>)}
                      </select>
                    </td>
                    <td className="px-2 py-1.5">
                      <SupplierSelect suppliers={suppliers} value={c.crawl_supplier_id} disabled={busy === c.home_id}
                                      onChange={(v) => setCrawlFor(h, { enabled: true, supplier: v, account: c.account_id })} />
                    </td>
                    <td className="whitespace-nowrap px-2 py-1.5 text-zinc-500">
                      {running ? <span className="text-blue-600">讀取中…</span> : fmtTime(c.crawl_last_at)}
                      {c.last_job?.status === "failed" && (
                        <div className="max-w-[220px] truncate text-red-600" title={c.last_job.error ?? ""}>失敗：{c.last_job.error}</div>
                      )}
                    </td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{num(c.posts)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{num(c.candidates)}</td>
                    <td className="whitespace-nowrap px-2 py-1.5 text-right">
                      <button type="button" className="mr-2 text-blue-600 hover:underline disabled:opacity-50 dark:text-blue-400"
                              disabled={busy === c.home_id || !!running}
                              onClick={() => setCrawlFor(h, { enabled: true, supplier: c.crawl_supplier_id, account: c.account_id, now: true })}>
                        立即讀取
                      </button>
                      <button type="button" className="text-zinc-500 hover:underline disabled:opacity-50"
                              disabled={busy === c.home_id}
                              onClick={() => setCrawlFor(h, { enabled: false, supplier: c.crawl_supplier_id, account: c.account_id })}>
                        停用
                      </button>
                    </td>
                  </tr>
                );
              })}
              {enabled.length === 0 && (
                <tr><td colSpan={7} className="px-2 py-4 text-center text-zinc-400">還沒有在讀的群組，從下面加。</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </ChartCard>

      {/* 2. 從機器人帳號加群組 */}
      <ChartCard
        title="從機器人帳號加群組"
        subtitle="小幫手先在 LINE 上加入廠商群組，再到這裡按「讀取群組清單」，勾要讀的那幾個。"
        actions={
          <>
            <select className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
                    value={accountId} onChange={(e) => { setAccountId(e.target.value ? Number(e.target.value) : ""); setLineHomes(null); }}>
              <option value="">選機器人帳號</option>
              {accounts.map((a) => <option key={a.id} value={a.id}>{a.label}{a.status !== "active" ? "（未登入）" : ""}</option>)}
            </select>
            <button type="button" disabled={accountId === "" || loadingHomes} onClick={readAccountHomes}
                    className="rounded bg-zinc-900 px-3 py-1 text-xs text-white disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900">
              {loadingHomes ? "讀取中…" : "讀取群組清單"}
            </button>
          </>
        }
        footer="勾起來會馬上讀一次。之前在「LINE 記事本」刪掉（隱藏）的群組，在這裡勾起來也會加回來，但不會開監聽、不會自動發文。"
      >
        {lineHomes == null ? (
          <div className="py-4 text-center text-xs text-zinc-400">選好帳號後按「讀取群組清單」。</div>
        ) : (
          <>
            <input className="mb-2 w-full max-w-xs rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
                   placeholder="搜尋群組名稱" value={filter} onChange={(e) => setFilter(e.target.value)} />
            <div className="overflow-x-auto">
              <table className="min-w-full text-xs">
                <thead className="bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <th className="px-2 py-1.5 text-left font-medium text-zinc-500">讀</th>
                    <th className="px-2 py-1.5 text-left font-medium text-zinc-500">群組 / 社群</th>
                    <th className="px-2 py-1.5 text-left font-medium text-zinc-500">類型</th>
                    <th className="px-2 py-1.5 text-left font-medium text-zinc-500">廠商</th>
                  </tr>
                </thead>
                <tbody>
                  {shownLineHomes.map((lh) => {
                    const c = crawlByHome.get(lh.homeId);
                    const on = !!c?.crawl_enabled;
                    const h = { home_id: lh.homeId, name: lh.name, kind: lh.kind };
                    return (
                      <tr key={lh.homeId} className={`border-t border-zinc-100 dark:border-zinc-800 ${busy === lh.homeId ? "opacity-50" : ""}`}>
                        <td className="px-2 py-1.5">
                          <input type="checkbox" checked={on} disabled={busy === lh.homeId}
                                 onChange={(e) => setCrawlFor(h, {
                                   enabled: e.target.checked, supplier: c?.crawl_supplier_id ?? null,
                                   account: accountId === "" ? null : accountId, now: e.target.checked,
                                 })} />
                        </td>
                        <td className="max-w-[320px] truncate px-2 py-1.5" title={lh.name}>{lh.name || "（沒有名稱）"}</td>
                        <td className="px-2 py-1.5 text-zinc-500">{KIND_LABEL[lh.kind] ?? lh.kind}</td>
                        <td className="px-2 py-1.5">
                          {on ? (
                            <SupplierSelect suppliers={suppliers} value={c?.crawl_supplier_id ?? null} disabled={busy === lh.homeId}
                                            onChange={(v) => setCrawlFor(h, { enabled: true, supplier: v, account: accountId === "" ? null : accountId })} />
                          ) : <span className="text-zinc-300">—</span>}
                        </td>
                      </tr>
                    );
                  })}
                  {shownLineHomes.length === 0 && (
                    <tr><td colSpan={4} className="px-2 py-4 text-center text-zinc-400">這個帳號沒有加入任何群組／社群。</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </>
        )}
      </ChartCard>
    </div>
  );
}

// 廠商下拉：廠商上百家，原生 <select> 翻不到；改成可搜尋（打名稱篩）。
// 清單用 portal 固定定位到視窗 —— 表格包在 overflow-x-auto 裡，absolute 會被裁掉。
function SupplierSelect({ suppliers, value, disabled, onChange }: {
  suppliers: Supplier[]; value: number | null; disabled?: boolean; onChange: (v: number | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [pos, setPos] = useState<{ top: number; left: number; width: number } | null>(null);
  const anchorRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const close = useCallback(() => { setOpen(false); setQuery(""); }, []);

  useEffect(() => {
    if (!open) return;
    const place = () => {
      const r = anchorRef.current?.getBoundingClientRect();
      if (r) setPos({ top: r.bottom + 4, left: r.left, width: Math.max(r.width, 220) });
    };
    place();
    inputRef.current?.focus();
    const onClickAway = (e: MouseEvent) => {
      const t = e.target as Node;
      if (anchorRef.current?.contains(t) || listRef.current?.contains(t)) return;
      close();
    };
    document.addEventListener("mousedown", onClickAway);
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      document.removeEventListener("mousedown", onClickAway);
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open, close]);

  const selected = value != null ? suppliers.find((s) => s.id === value) ?? null : null;
  const q = query.trim().toLowerCase();
  const filtered = q ? suppliers.filter((s) => s.name.toLowerCase().includes(q)) : suppliers;

  const pick = (v: number | null) => { onChange(v); close(); };
  const boxCls = "max-w-[160px] rounded border border-zinc-300 bg-white px-1 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-900";

  return (
    <div ref={anchorRef} className="relative inline-block min-w-[120px]">
      {!open ? (
        <button type="button" disabled={disabled} onClick={() => setOpen(true)}
                className={`${boxCls} flex w-full items-center justify-between gap-1 text-left disabled:opacity-50`}>
          <span className={`truncate ${selected ? "" : "text-zinc-400"}`}>{selected ? selected.name : "（不指定廠商）"}</span>
          <span className="shrink-0 text-zinc-400">▾</span>
        </button>
      ) : (
        <input ref={inputRef} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="搜尋廠商名稱"
               className={`${boxCls} w-full focus:border-zinc-500 focus:outline-none`}
               onKeyDown={(e) => {
                 if (e.key === "Escape") close();
                 else if (e.key === "Enter") { e.preventDefault(); if (filtered.length > 0) pick(filtered[0].id); }
               }} />
      )}
      {open && pos && typeof document !== "undefined" && createPortal(
        <div ref={listRef} style={{ position: "fixed", top: pos.top, left: pos.left, width: pos.width }}
             className="z-50 max-h-64 overflow-y-auto rounded-md border border-zinc-200 bg-white text-xs shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
          <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => pick(null)}
                  className={`block w-full border-b border-zinc-200 px-2 py-1.5 text-left text-zinc-500 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800 ${value == null ? "bg-blue-50 dark:bg-blue-950" : ""}`}>
            （不指定廠商）
          </button>
          {filtered.length === 0 ? (
            <p className="px-2 py-1.5 text-zinc-500">{q ? "找不到符合的廠商" : "尚無廠商"}</p>
          ) : filtered.map((s) => (
            <button key={s.id} type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => pick(s.id)}
                    className={`block w-full truncate px-2 py-1.5 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800 ${s.id === value ? "bg-blue-50 dark:bg-blue-950" : ""}`}>
              {s.name}
            </button>
          ))}
        </div>,
        document.body,
      )}
    </div>
  );
}
