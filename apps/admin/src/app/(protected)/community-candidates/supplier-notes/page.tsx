"use client";

// 廠商新品 —— 機器人每天讀廠商群組的記事本，Claude 半夜把每篇拆成商品，
// 這頁列出來並標「我們賣過嗎、當時賣多少」。
// 資料：rpc_market_note_items / rpc_line_note_crawl_homes / rpc_line_note_set_crawl（20261101000040）。

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { ChartCard, Seg, num } from "@/components/ChartKit";

type Match = {
  product_id: number; name: string; score: number; same_tag: boolean;
  campaigns: number; last_start: string | null; buyers: number;
};
type Item = {
  id: number; post_id: number; posted_at: string | null; author: string | null;
  community_id: number; community: string; supplier: string | null;
  item_name: string; norm_name: string | null; price: number | null; price_text: string | null;
  spec: string | null; deadline_text: string | null; tags: string[]; matches: Match[];
  comment_count: number; comment_prev: number | null; text: string;
};
type ItemsResp = { posts_total: number; posts_unparsed: number; items: Item[] };
type Home = {
  id: number; home_name: string; home_kind: string; account_label: string | null; account_status: string | null;
  crawl_enabled: boolean; crawl_supplier_id: number | null; supplier_name: string | null;
  crawl_last_at: string | null; posts: number;
  last_job: { status: string; error: string | null; at: string } | null;
};
type Supplier = { id: number; name: string };

const SOLD_SCORE = 0.75; // 二字詞命中 ≥ 75% 才算「賣過」，0.5～0.75 只標「可能相似」

const fmtTime = (s: string | null) =>
  s ? new Date(s).toLocaleString("zh-TW", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "—";
const fmtDate = (s: string | null) => (s ? new Date(s).toLocaleDateString("zh-TW", { month: "numeric", day: "numeric" }) : "—");

export default function SupplierNotesPage() {
  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">廠商新品</h1>
        <p className="text-sm text-zinc-500">
          機器人每天凌晨讀一次廠商群組的記事本，Claude 再把每篇拆成商品，並比對我們有沒有賣過、當時賣多少。
        </p>
      </header>
      <ItemsCard />
      <HomesCard />
    </div>
  );
}

// ────────────────────────────── 商品列表 ──────────────────────────────

function ItemsCard() {
  const [days, setDays] = useState(14);
  const [community, setCommunity] = useState<number | "">("");
  const [onlyNew, setOnlyNew] = useState(false);
  const [data, setData] = useState<ItemsResp | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      const { data: rows, error: err } = await getSupabase().rpc("rpc_market_note_items", {
        p_days: days, p_community_id: community === "" ? null : community,
      });
      if (cancelled) return;
      setLoading(false);
      if (err) { setError(translateRpcError(err)); return; }
      setError(null);
      setData(rows as ItemsResp);
    })();
    return () => { cancelled = true; };
  }, [days, community]);

  const communities = useMemo(() => {
    const m = new Map<number, string>();
    for (const it of data?.items ?? []) m.set(it.community_id, it.supplier ?? it.community);
    return [...m.entries()];
  }, [data]);

  const items = useMemo(() => {
    const list = data?.items ?? [];
    return onlyNew ? list.filter((it) => !(it.matches?.[0] && it.matches[0].score >= SOLD_SCORE)) : list;
  }, [data, onlyNew]);

  return (
    <ChartCard
      title="廠商貼的商品"
      subtitle={data ? `近 ${days} 天 ${num(data.posts_total)} 篇貼文、拆出 ${num(data.items.length)} 個商品${data.posts_unparsed ? `；還有 ${num(data.posts_unparsed)} 篇等今晚解析` : ""}` : undefined}
      actions={
        <>
          <Seg options={[7, 14, 30].map((d) => ({ key: String(d), label: `${d} 天` }))}
               value={String(days)} onChange={(v) => setDays(Number(v))} />
          <select className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
                  value={community} onChange={(e) => setCommunity(e.target.value ? Number(e.target.value) : "")}>
            <option value="">全部廠商</option>
            {communities.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
          </select>
          <label className="flex items-center gap-1 text-xs text-zinc-600 dark:text-zinc-300">
            <input type="checkbox" checked={onlyNew} onChange={(e) => setOnlyNew(e.target.checked)} />
            只看沒賣過
          </label>
        </>
      }
      footer="「賣過」= 品名關鍵字有七成五以上對得上我們的商品；買家數是那個商品所有開團的不重複下單人數。+1 是廠商貼文底下的留言數，括號是比昨天多幾則。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}
      <div className="overflow-x-auto">
        <table className={`min-w-full text-xs ${loading ? "opacity-50" : ""}`}>
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">發文</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">廠商</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">商品</th>
              <th className="px-2 py-1.5 text-right font-medium text-zinc-500">價格</th>
              <th className="px-2 py-1.5 text-right font-medium text-zinc-500">+1</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">我們賣過嗎</th>
              <th className="px-2 py-1.5"></th>
            </tr>
          </thead>
          <tbody>
            {items.map((it) => {
              const m = it.matches?.[0];
              const sold = m && m.score >= SOLD_SCORE;
              const delta = it.comment_prev == null ? null : it.comment_count - it.comment_prev;
              return (
                <FragmentRow key={it.id} open={open === it.id} text={it.text}>
                  <td className="whitespace-nowrap px-2 py-1.5 text-zinc-500">{fmtTime(it.posted_at)}</td>
                  <td className="max-w-[140px] truncate px-2 py-1.5" title={it.community}>{it.supplier ?? it.community}</td>
                  <td className="px-2 py-1.5">
                    <div className="font-medium">{it.item_name}</div>
                    {(it.spec || it.deadline_text) && (
                      <div className="text-[11px] text-zinc-500">{[it.spec, it.deadline_text].filter(Boolean).join("・")}</div>
                    )}
                  </td>
                  <td className="whitespace-nowrap px-2 py-1.5 text-right tabular-nums" title={it.price_text ?? ""}>
                    {it.price != null ? `$${num(it.price)}` : <span className="text-zinc-400">—</span>}
                  </td>
                  <td className="whitespace-nowrap px-2 py-1.5 text-right tabular-nums">
                    {num(it.comment_count)}
                    {delta != null && delta > 0 && <span className="ml-1 text-red-600 dark:text-red-400">(+{delta})</span>}
                  </td>
                  <td className="px-2 py-1.5">
                    {sold ? (
                      <span>
                        <span className="mr-1 rounded bg-emerald-100 px-1 text-[10px] text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300">賣過</span>
                        {m.name.slice(0, 26)}
                        <span className="ml-1 text-zinc-500">（{num(m.campaigns)} 團・{num(m.buyers)} 人・最後 {fmtDate(m.last_start)}）</span>
                      </span>
                    ) : m ? (
                      <span className="text-zinc-500">
                        <span className="mr-1 rounded bg-zinc-100 px-1 text-[10px] dark:bg-zinc-800">可能相似</span>
                        {m.name.slice(0, 26)}（{num(m.buyers)} 人）
                      </span>
                    ) : (
                      <span className="rounded bg-amber-100 px-1 text-[10px] text-amber-700 dark:bg-amber-900/40 dark:text-amber-300">沒賣過</span>
                    )}
                  </td>
                  <td className="px-2 py-1.5 text-right">
                    <button type="button" className="text-blue-600 hover:underline dark:text-blue-400"
                            onClick={() => setOpen(open === it.id ? null : it.id)}>
                      {open === it.id ? "收起" : "原文"}
                    </button>
                  </td>
                </FragmentRow>
              );
            })}
            {!loading && items.length === 0 && (
              <tr><td colSpan={7} className="px-2 py-6 text-center text-zinc-400">
                還沒有資料。機器人每天 01:13 讀取、Claude 02:53 解析；剛勾選的群組可以在下面按「立即讀取」。
              </td></tr>
            )}
          </tbody>
        </table>
      </div>
    </ChartCard>
  );
}

function FragmentRow({ open, text, children }: { open: boolean; text: string; children: React.ReactNode }) {
  return (
    <>
      <tr className="border-t border-zinc-100 align-top dark:border-zinc-800">{children}</tr>
      {open && (
        <tr className="bg-zinc-50 dark:bg-zinc-900/60">
          <td colSpan={7} className="whitespace-pre-wrap px-3 py-2 text-xs text-zinc-600 dark:text-zinc-300">{text}</td>
        </tr>
      )}
    </>
  );
}

// ────────────────────────────── 要爬的群組 ──────────────────────────────

function HomesCard() {
  const [homes, setHomes] = useState<Home[] | null>(null);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<number | null>(null);
  const [showAll, setShowAll] = useState(false);

  const load = useCallback(async () => {
    const sb = getSupabase();
    const [{ data: h, error: e1 }, { data: s, error: e2 }] = await Promise.all([
      sb.rpc("rpc_line_note_crawl_homes"),
      sb.from("suppliers").select("id,name").eq("is_active", true).order("name"),
    ]);
    if (e1 || e2) { setError(translateRpcError((e1 ?? e2)!)); return; }
    setError(null);
    setHomes((h ?? []) as Home[]);
    setSuppliers((s ?? []) as Supplier[]);
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => { if (!cancelled) await load(); })();
    return () => { cancelled = true; };
  }, [load]);

  async function save(h: Home, patch: { enabled?: boolean; supplier?: number | null; now?: boolean }) {
    setBusy(h.id);
    const { error: err } = await getSupabase().rpc("rpc_line_note_set_crawl", {
      p_community_id: h.id,
      p_enabled: patch.enabled ?? h.crawl_enabled,
      p_supplier_id: patch.supplier !== undefined ? patch.supplier : h.crawl_supplier_id,
      p_crawl_now: patch.now ?? false,
    });
    setBusy(null);
    if (err) { setError(translateRpcError(err)); return; }
    await load();
  }

  const shown = (homes ?? []).filter((h) => showAll || h.crawl_enabled);

  return (
    <ChartCard
      title="要讀哪些廠商群組"
      subtitle="機器人帳號加入的群組／社群。勾起來的每天凌晨讀最近 3 天的貼文；只讀貼文，不留言、不按讚。"
      actions={
        <label className="flex items-center gap-1 text-xs text-zinc-600 dark:text-zinc-300">
          <input type="checkbox" checked={showAll} onChange={(e) => setShowAll(e.target.checked)} />
          顯示全部群組
        </label>
      }
      footer="群組要先在「LINE 記事本」讓機器人帳號同步出來才會出現在這裡。"
    >
      {error && <div className="mb-2 text-sm text-red-600 dark:text-red-400">{error}</div>}
      <div className="overflow-x-auto">
        <table className="min-w-full text-xs">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">讀</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">群組 / 社群</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">機器人帳號</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">廠商</th>
              <th className="px-2 py-1.5 text-left font-medium text-zinc-500">上次讀取</th>
              <th className="px-2 py-1.5 text-right font-medium text-zinc-500">貼文</th>
              <th className="px-2 py-1.5"></th>
            </tr>
          </thead>
          <tbody>
            {shown.map((h) => (
              <tr key={h.id} className={`border-t border-zinc-100 dark:border-zinc-800 ${busy === h.id ? "opacity-50" : ""}`}>
                <td className="px-2 py-1.5">
                  <input type="checkbox" checked={h.crawl_enabled} disabled={busy === h.id}
                         onChange={(e) => save(h, { enabled: e.target.checked })} />
                </td>
                <td className="max-w-[280px] truncate px-2 py-1.5" title={h.home_name}>{h.home_name}</td>
                <td className="px-2 py-1.5 text-zinc-500">
                  {h.account_label ?? "—"}
                  {h.account_status && h.account_status !== "active" && <span className="ml-1 text-red-600">（{h.account_status}）</span>}
                </td>
                <td className="px-2 py-1.5">
                  <select className="max-w-[160px] rounded border border-zinc-300 bg-white px-1 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
                          value={h.crawl_supplier_id ?? ""} disabled={busy === h.id}
                          onChange={(e) => save(h, { supplier: e.target.value ? Number(e.target.value) : null })}>
                    <option value="">（不指定）</option>
                    {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </select>
                </td>
                <td className="whitespace-nowrap px-2 py-1.5 text-zinc-500">
                  {fmtTime(h.crawl_last_at)}
                  {h.last_job?.status === "failed" && <div className="max-w-[220px] truncate text-red-600" title={h.last_job.error ?? ""}>失敗：{h.last_job.error}</div>}
                  {h.last_job && ["queued", "running"].includes(h.last_job.status) && <div className="text-blue-600">讀取中…</div>}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums">{num(h.posts)}</td>
                <td className="px-2 py-1.5 text-right">
                  {h.crawl_enabled && (
                    <button type="button" className="text-blue-600 hover:underline disabled:opacity-50 dark:text-blue-400"
                            disabled={busy === h.id} onClick={() => save(h, { now: true })}>
                      立即讀取
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {homes && shown.length === 0 && (
              <tr><td colSpan={7} className="px-2 py-4 text-center text-zinc-400">還沒有勾選任何群組，打開「顯示全部群組」來選。</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </ChartCard>
  );
}
