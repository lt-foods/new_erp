"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";

type Candidate = {
  id: number;
  product_name_hint: string | null;
  raw_text: string;
  source_user_id: string | null;
  source_user_name: string | null;
  source_channel: string | null;
  system_status: string;
  owner_action: string;
  scheduled_open_at: string | null;
  scheduled_sort_order: number | null;
  created_at: string;
  adopted_supplier_name: string | null;
  adopted_cost: number | null;
  adopted_sale_price: number | null;
  /** 廠商群組記事本解析出來的（20261101000040）；其他來源是 null */
  parsed: SupplierParsed | null;
  similarity_score: number | null;
  /** 廠商群組來源：{ market_post_id, ... }；用來反查貼文圖片 */
  raw: { market_post_id?: number } | null;
};

const imageUrl = (path: string) => getSupabase().storage.from("products").getPublicUrl(path).data.publicUrl;

/** 廠商貼文的圖（worker 讀貼文時一起抓下來的），點了開原圖 */
function SupplierImages({ paths }: { paths: string[] | undefined }) {
  if (!paths?.length) return null;
  return (
    <div className="mt-1 flex flex-wrap gap-1">
      {paths.slice(0, 4).map((p) => (
        <a key={p} href={imageUrl(p)} target="_blank" rel="noreferrer">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={imageUrl(p)} alt="" loading="lazy"
               className="h-12 w-12 rounded border border-zinc-200 object-cover dark:border-zinc-700" />
        </a>
      ))}
      {paths.length > 4 && <span className="self-center text-[10px] text-zinc-400">+{paths.length - 4}</span>}
    </div>
  );
}

type SupplierMatch = { product_id: number; name: string; score: number; campaigns: number; buyers: number; last_start: string | null };
type SupplierParsed = {
  /** 剛讀到、還沒拆品項（整篇先進候選池）；幾分鐘內 market-ai（Cloudflare）會換成正式品項 */
  pending?: boolean;
  price: number | null; price_text: string | null; spec: string | null; deadline_text: string | null;
  supplier: string | null; comment_count: number | null; matches: SupplierMatch[] | null;
};

/** 廠商報價＋「我們賣過嗎」：向量相似度 ≥ 0.85 才算賣過（20261101000130），其餘對到的標「類似」 */
/** 廠商報價那一行（價格・規格・截止・+1）；待整理的顯示暫定說明 */
function SupplierInfo({ p }: { p: SupplierParsed | null }) {
  if (!p) return null;
  if (p.pending) {
    return (
      <div className="mt-1 text-[11px] font-normal text-zinc-500 dark:text-zinc-400">
        <span className="mr-1 rounded bg-sky-100 px-1 text-[10px] text-sky-700 dark:bg-sky-900/40 dark:text-sky-300">待整理</span>
        {p.price != null && `廠商價約 $${Number(p.price).toLocaleString("zh-TW")}・`}品名是暫定的（抓貼文第一行），幾分鐘內 AI 看完圖文會整理成正式品名、價格，並標出我們有沒有賣過
      </div>
    );
  }
  const facts = [
    p.price != null ? `廠商價 $${Number(p.price).toLocaleString("zh-TW")}` : null,
    p.spec, p.deadline_text ? `截止 ${p.deadline_text}` : null,
    p.comment_count ? `+1 ${p.comment_count}` : null,
  ].filter(Boolean);
  if (facts.length === 0) return null;
  return <div className="mt-1 text-[11px] font-normal text-zinc-500 dark:text-zinc-400">{facts.join("・")}</div>;
}

/**
 * 「我們賣過嗎」：向量相似度 ≥ 0.85 才算賣過（20261101000130），其餘對到的標「類似」。
 * 非廠商群組來的候選（parsed 是 null）不顯示；待整理的還沒比對。
 */
function SoldInfo({ p }: { p: SupplierParsed | null }) {
  if (!p) return <span className="text-zinc-300 dark:text-zinc-600">—</span>;
  if (p.pending) return <span className="text-[11px] text-zinc-400">比對中</span>;
  const m = p.matches?.[0];
  if (!m) {
    return <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[11px] text-amber-700 dark:bg-amber-900/40 dark:text-amber-300">沒賣過</span>;
  }
  const sold = m.score >= 0.85;
  return (
    <div className="space-y-0.5 text-[11px] text-zinc-500 dark:text-zinc-400">
      {sold ? (
        <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-[11px] font-medium text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300">賣過</span>
      ) : (
        <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">類似</span>
      )}
      <div className="text-zinc-700 dark:text-zinc-300" title={m.name}>{m.name.slice(0, 22)}</div>
      <div>{m.campaigns} 團・{m.buyers} 人{m.last_start ? `・最後 ${m.last_start.slice(5)}` : ""}</div>
    </div>
  );
}

type Tab = "pending" | "collected" | "scheduled" | "ignored" | "adopted" | "all";

const TABS: { key: Tab; label: string }[] = [
  { key: "pending", label: "未處理" },
  { key: "collected", label: "已收藏" },
  { key: "scheduled", label: "已排程" },
  { key: "ignored", label: "已忽略" },
  { key: "adopted", label: "已採用" },
  { key: "all", label: "全部" },
];

const ACTION_LABEL: Record<string, string> = {
  none: "未處理",
  collected: "已收藏",
  scheduled: "已排程",
  adopted: "已採用",
  ignored: "已忽略",
};

const ACTION_COLOR: Record<string, string> = {
  none: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400",
  collected: "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300",
  scheduled: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300",
  adopted: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300",
  ignored: "bg-zinc-200 text-zinc-500 dark:bg-zinc-700 dark:text-zinc-400",
};

// 候選池只留兩個禮拜（20261101000070 每天清掉超過 14 天沒處理／已忽略的），列表也只看 14 天；
// 收藏、已採用全部顯示（老闆的決定紀錄），排程看排程日（建立很久但排在未來的不能藏起來）
const PAGE_SIZE = 50;
const KEEP_DAYS = 14;

export default function CommunityCandidatesPage() {
  const [rows, setRows] = useState<Candidate[] | null>(null);
  const [page, setPage] = useState(0);
  const [total, setTotal] = useState(0);
  const [postImages, setPostImages] = useState<Record<number, string[]>>({});
  const reqSeq = useRef(0);
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [tab, setTab] = useState<Tab>("pending");
  const [error, setError] = useState<string | null>(null);
  const [scheduling, setScheduling] = useState<number | null>(null);
  const [scheduleDate, setScheduleDate] = useState("");
  const [busy, setBusy] = useState(false);
  const [editingInfo, setEditingInfo] = useState<number | null>(null);
  const [adoptSupplier, setAdoptSupplier] = useState("");
  const [adoptCost, setAdoptCost] = useState("");
  const [adoptSalePrice, setAdoptSalePrice] = useState("");
  const [highlightId, setHighlightId] = useState<number | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [bulkDate, setBulkDate] = useState("");

  const highlightRowRef = useRef<HTMLElement | null>(null);

  const isSelectable = (r: Candidate) => r.owner_action !== "scheduled";

  const toggleOne = (id: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const clearSelected = () => setSelected(new Set());

  useEffect(() => {
    const id = Number(new URLSearchParams(window.location.search).get("highlight"));
    if (Number.isFinite(id) && id > 0) {
      setHighlightId(id);
      setTab("all");
    }
  }, []);

  useEffect(() => {
    // 打字內容與已送出的 query 不同 → 有一筆 reload 待觸發，轉圈圈到 reload 結束才停
    if (queryDraft !== query) setSearching(true);
    const t = setTimeout(() => {
      if (queryDraft !== query) setPage(0);
      setQuery(queryDraft);
    }, 300);
    return () => clearTimeout(t);
  }, [queryDraft, query]);

  useEffect(() => {
    if (highlightId && highlightRowRef.current) {
      highlightRowRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [highlightId, rows]);

  const reload = async () => {
    const seq = ++reqSeq.current;
    const sinceMs = Date.now() - KEEP_DAYS * 86400_000;
    let q = getSupabase()
      .from("community_product_candidates")
      .select(
        "id, product_name_hint, raw_text, source_user_id, source_user_name, source_channel, system_status, owner_action, scheduled_open_at, scheduled_sort_order, created_at, adopted_supplier_name, adopted_cost, adopted_sale_price, parsed, similarity_score, raw",
        { count: "exact" }
      )
      .order("created_at", { ascending: false })
      .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);

    if (tab === "scheduled") q = q.gte("scheduled_open_at", new Date(sinceMs).toISOString().slice(0, 10));
    else if (tab !== "collected" && tab !== "adopted") q = q.gte("created_at", new Date(sinceMs).toISOString());

    if (tab === "pending") q = q.eq("owner_action", "none");
    else if (tab === "collected") q = q.eq("owner_action", "collected");
    else if (tab === "scheduled") q = q.eq("owner_action", "scheduled");
    else if (tab === "ignored") q = q.eq("owner_action", "ignored");
    else if (tab === "adopted") q = q.eq("owner_action", "adopted");

    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`product_name_hint.ilike.%${safe}%,raw_text.ilike.%${safe}%`);
    }

    try {
      const { data, error: err, count } = await q;
      if (seq !== reqSeq.current) return; // 換頁／換分頁太快，舊的回應晚到就丟掉
      if (err) setError(err.message);
      else {
        setError(null);
        const list = (data as Candidate[]) ?? [];
        setRows(list);
        setTotal(count ?? 0);
        // 廠商群組來的候選：一次把這一頁用到的貼文圖撈回來
        const postIds = [...new Set(list.map((r) => r.raw?.market_post_id).filter((x): x is number => typeof x === "number"))];
        if (postIds.length) {
          const { data: imgs } = await getSupabase().from("line_note_market_posts").select("id,image_paths").in("id", postIds);
          if (seq === reqSeq.current) {
            setPostImages(Object.fromEntries((imgs ?? []).map((x: { id: number; image_paths: string[] | null }) => [x.id, x.image_paths ?? []])));
          }
        }
      }
    } finally {
      setSearching(false);
    }
  };

  useEffect(() => {
    reload();
    clearSelected();
  }, [query, tab, page]);

  const patch = async (id: number, updates: Record<string, unknown>) => {
    setBusy(true);
    try {
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({ ...updates, updated_at: new Date().toISOString() })
        .eq("id", id);
      if (err) throw err;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const handleCollect = (id: number) =>
    patch(id, { owner_action: "collected", scheduled_open_at: null, scheduled_sort_order: null });
  const handleIgnore = (id: number) =>
    patch(id, { owner_action: "ignored", scheduled_open_at: null, scheduled_sort_order: null });
  const handleRestore = (id: number) =>
    patch(id, { owner_action: "none", scheduled_open_at: null, scheduled_sort_order: null });

  const nextSortOrderForDay = async (date: string): Promise<number> => {
    const { data, error: err } = await getSupabase()
      .from("community_product_candidates")
      .select("scheduled_sort_order")
      .eq("scheduled_open_at", date)
      .not("scheduled_sort_order", "is", null)
      .order("scheduled_sort_order", { ascending: false })
      .limit(1);
    if (err) throw err;
    const max = (data?.[0]?.scheduled_sort_order as number | null) ?? 0;
    return max + 1;
  };

  const deriveProductName = (row: Candidate): string => {
    const hint = (row.product_name_hint ?? "").trim();
    if (hint) return hint.slice(0, 60);
    const raw = (row.raw_text ?? "").trim().replace(/\s+/g, " ");
    if (raw) return raw.slice(0, 30);
    return `候選 #${row.id}`;
  };

  const scheduleAt = async (id: number, dateStr: string) => {
    const row = rows?.find((r) => r.id === id);
    if (!row) {
      setError("找不到該候選資料，請重新整理後再試");
      return;
    }
    const productName = deriveProductName(row);

    setBusy(true);
    try {
      const sb = getSupabase();
      // 呼叫 rpc_schedule_candidate：建 draft product + sku + 標 candidate scheduled
      // （不再自動建開團；開團改由商品編輯頁「建立新開團」按鈕觸發）
      const { error: rpcErr } = await sb.rpc("rpc_schedule_candidate", {
        p_candidate_id: id,
        p_scheduled_date: dateStr,
        p_product_name: productName,
      });
      if (rpcErr) throw rpcErr;

      // RPC 不負責 scheduled_sort_order（行事曆排序遺留欄位），補一下
      const nextOrder = await nextSortOrderForDay(dateStr);
      await sb
        .from("community_product_candidates")
        .update({ scheduled_sort_order: nextOrder })
        .eq("id", id);

      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const handleSchedule = async (id: number) => {
    if (!scheduleDate) return;
    await scheduleAt(id, scheduleDate);
    setScheduling(null);
    setScheduleDate("");
  };

  const formatLocalDate = (d: Date): string => {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  };

  const localDateStr = (daysFromNow: number): string => {
    const d = new Date();
    d.setDate(d.getDate() + daysFromNow);
    return formatLocalDate(d);
  };

  const nextWeekMonday = (): string => {
    const d = new Date();
    const day = d.getDay();
    const daysUntil = day === 0 ? 1 : 8 - day;
    d.setDate(d.getDate() + daysUntil);
    return formatLocalDate(d);
  };

  const handleQuickSchedule = async (id: number, dateStr: string) => {
    await scheduleAt(id, dateStr);
    setScheduling(null);
    setScheduleDate("");
  };

  const handleBulkSchedule = async (dateStr: string) => {
    if (!dateStr || selected.size === 0) return;
    const ids = [...selected].filter((id) => {
      const r = rows?.find((x) => x.id === id);
      return r && isSelectable(r);
    });
    if (ids.length === 0) {
      setError("沒有可排程的候選（已排程的會略過）");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      // 順序執行：每一筆建 product/sku 再補 sort_order，避免 sort 撞號（不建開團）
      for (const id of ids) {
        const row = rows?.find((r) => r.id === id);
        if (!row) continue;
        const productName = deriveProductName(row);
        const { error: rpcErr } = await sb.rpc("rpc_schedule_candidate", {
          p_candidate_id: id,
          p_scheduled_date: dateStr,
          p_product_name: productName,
        });
        if (rpcErr) throw rpcErr;
        const nextOrder = await nextSortOrderForDay(dateStr);
        await sb
          .from("community_product_candidates")
          .update({ scheduled_sort_order: nextOrder })
          .eq("id", id);
      }
      clearSelected();
      setBulkDate("");
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const extractPrice = (text: string): string => {
    const patterns = [
      /\$(\d+(?:\.\d+)?)/,
      /(\d+(?:\.\d+)?)元/,
      /售價\s*(\d+(?:\.\d+)?)/,
      /特價\s*(\d+(?:\.\d+)?)/,
      /一組\s*(\d+(?:\.\d+)?)/,
    ];
    for (const p of patterns) {
      const m = text.match(p);
      if (m) return m[1];
    }
    return "";
  };

  const handleFillSubmit = async (id: number) => {
    setBusy(true);
    try {
      const costVal = adoptCost.trim() ? Number(adoptCost) : null;
      if (costVal !== null && (isNaN(costVal) || costVal < 0)) {
        setError("成本不可為負數");
        return;
      }
      const salePriceVal = adoptSalePrice.trim() ? Number(adoptSalePrice) : null;
      if (salePriceVal !== null && (isNaN(salePriceVal) || salePriceVal < 0)) {
        setError("售價不可為負數");
        return;
      }
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({
          adopted_supplier_name: adoptSupplier.trim() || null,
          adopted_cost: costVal,
          adopted_sale_price: salePriceVal,
          updated_at: new Date().toISOString(),
        })
        .eq("id", id);
      if (err) throw err;
      setEditingInfo(null);
      setAdoptSupplier("");
      setAdoptCost("");
      setAdoptSalePrice("");
      setError(null);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const handleAdopt = async (id: number) => {
    setBusy(true);
    try {
      const { data: { user } } = await getSupabase().auth.getUser();
      if (!user) {
        setError("無法取得登入資訊，請重新整理後再試");
        return;
      }
      const now = new Date().toISOString();
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({
          owner_action: "adopted",
          adopted_at: now,
          adopted_by: user.id,
          updated_at: now,
        })
        .eq("id", id);
      if (err) throw err;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const fmt = (s: string) =>
    new Date(s).toLocaleString("zh-TW", {
      month: "numeric",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });

  function renderActions(r: Candidate) {
    if (editingInfo === r.id) {
      return (
        <div className="flex flex-col gap-2">
          <input
            autoFocus
            placeholder="廠商（選填）"
            value={adoptSupplier}
            onChange={(e) => setAdoptSupplier(e.target.value)}
            className="rounded border border-zinc-300 px-2 py-1 text-xs focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
          <input
            type="number"
            min={0}
            step="1"
            placeholder="成本（選填）"
            value={adoptCost}
            onChange={(e) => setAdoptCost(e.target.value)}
            className="rounded border border-zinc-300 px-2 py-1 text-xs focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
          <input
            type="number"
            min={0}
            step="1"
            placeholder="售價（選填）"
            value={adoptSalePrice}
            onChange={(e) => setAdoptSalePrice(e.target.value)}
            className="rounded border border-zinc-300 px-2 py-1 text-xs focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
          <div className="flex gap-1">
            <SpinButton
              onClick={() => handleFillSubmit(r.id)}
              disabled={busy}
              className="rounded bg-blue-600 px-2 py-0.5 text-xs text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {busy ? "儲存中…" : "儲存"}
            </SpinButton>
            <SpinButton
              onClick={() => { setEditingInfo(null); setAdoptSupplier(""); setAdoptCost(""); setAdoptSalePrice(""); }}
              disabled={busy}
              className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
            >
              取消
            </SpinButton>
          </div>
        </div>
      );
    }
    if (scheduling === r.id) {
      return (
        <div className="flex flex-col gap-1.5">
          <div className="flex flex-wrap gap-1">
            {[
              { label: "明天", date: localDateStr(1) },
              { label: "後天", date: localDateStr(2) },
              { label: "下週一", date: nextWeekMonday() },
            ].map(({ label, date }) => (
              <SpinButton
                key={label}
                onClick={() => handleQuickSchedule(r.id, date)}
                disabled={busy}
                className="rounded bg-amber-500 px-2 py-0.5 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
              >
                {label}
              </SpinButton>
            ))}
          </div>
          <div className="flex flex-wrap items-center gap-1">
            <DatePicker
              value={scheduleDate}
              onChange={setScheduleDate}
              className="rounded border border-zinc-300 bg-white px-1.5 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
            />
            <SpinButton
              onClick={() => handleSchedule(r.id)}
              disabled={!scheduleDate || busy}
              className="rounded bg-amber-500 px-2 py-0.5 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
            >
              確定
            </SpinButton>
            <SpinButton
              onClick={() => {
                setScheduling(null);
                setScheduleDate("");
              }}
              disabled={busy}
              className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
            >
              取消
            </SpinButton>
          </div>
        </div>
      );
    }
    return (
      <div className="flex flex-wrap items-center gap-1">
        <SpinButton
          onClick={() => {
            setEditingInfo(r.id);
            // 廠商群組來的：廠商名、廠商報價（＝我們的成本）直接帶；售價留給老闆填，
            // 不要再從文案抓數字（抓到的就是廠商價，會把成本當售價）
            setAdoptSupplier(r.adopted_supplier_name ?? r.parsed?.supplier ?? "");
            setAdoptCost(r.adopted_cost !== null ? String(r.adopted_cost) : (r.parsed?.price != null && !r.parsed.pending ? String(r.parsed.price) : ""));
            setAdoptSalePrice(r.adopted_sale_price !== null ? String(r.adopted_sale_price) : (r.parsed ? "" : extractPrice(r.raw_text)));
            setScheduling(null);
          }}
          disabled={busy}
          className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400 disabled:opacity-50"
        >
          {r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null ? "修改資料" : "補資料"}
        </SpinButton>
        {r.owner_action !== "adopted" && (
          <SpinButton
            onClick={() => {
              const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
              if (!complete && !window.confirm("廠商、成本、售價尚未完整，確定要採用嗎？")) return;
              handleAdopt(r.id);
            }}
            disabled={busy}
            className="rounded border border-green-400 px-2 py-0.5 text-xs text-green-700 hover:bg-green-50 dark:border-green-700 dark:text-green-400 dark:hover:bg-green-950/30 disabled:opacity-50"
          >
            採用
          </SpinButton>
        )}
        {r.owner_action !== "collected" && r.owner_action !== "adopted" && (
          <SpinButton
            onClick={() => handleCollect(r.id)}
            disabled={busy}
            className="rounded border border-blue-300 px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-400 disabled:opacity-50"
          >
            收藏
          </SpinButton>
        )}
        {r.owner_action !== "scheduled" && (
          <SpinButton
            onClick={() => {
              setScheduling(r.id);
              setScheduleDate("");
            }}
            disabled={busy}
            className="rounded border border-amber-300 px-2 py-0.5 text-xs text-amber-600 hover:bg-amber-50 dark:border-amber-800 dark:text-amber-400 disabled:opacity-50"
          >
            排日期
          </SpinButton>
        )}
        {r.owner_action !== "ignored" && r.owner_action !== "adopted" && (
          <SpinButton
            onClick={() => handleIgnore(r.id)}
            disabled={busy}
            className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
          >
            忽略
          </SpinButton>
        )}
        {(r.owner_action === "collected" ||
          r.owner_action === "scheduled" ||
          r.owner_action === "ignored") && (
          <SpinButton
            onClick={() => handleRestore(r.id)}
            disabled={busy}
            className="rounded border border-zinc-200 px-2 py-0.5 text-xs text-zinc-400 hover:bg-zinc-50 dark:border-zinc-800 disabled:opacity-50"
          >
            還原
          </SpinButton>
        )}
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">選品候選池</h1>
          <p className="mt-0.5 text-sm text-zinc-500">LINE #選品 進來的商品候選</p>
        </div>
        <SpinButton
          onClick={() => reload()}
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        >
          重新整理
        </SpinButton>
      </header>

      {/* Tabs */}
      <div className="flex gap-0 border-b border-zinc-200 dark:border-zinc-800">
        {TABS.map(({ key, label }) => (
          <SpinButton
            key={key}
            onClick={() => { setTab(key); setPage(0); }}
            className={
              tab === key
                ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {label}
          </SpinButton>
        ))}
      </div>

      {/* Search */}
      <div className="flex gap-2">
        <div className="relative flex-1">
          <input
            className="w-full rounded-md border border-zinc-300 px-3 py-1.5 pr-8 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
            placeholder="搜尋商品名稱或文案…"
            value={queryDraft}
            onChange={(e) => setQueryDraft(e.target.value)}
          />
          <SearchSpinner active={searching} />
        </div>
        {queryDraft && (
          <SpinButton
            onClick={() => setQueryDraft("")}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
          >
            清除
          </SpinButton>
        )}
      </div>

      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* 批次排日期工具列 */}
      {selected.size > 0 && (
        <div className="sticky top-0 z-10 flex flex-wrap items-center gap-2 rounded-md border border-amber-300 bg-amber-50 p-2.5 text-sm dark:border-amber-700 dark:bg-amber-950/40">
          <span className="font-medium text-amber-800 dark:text-amber-200">
            已選 {selected.size} 筆
          </span>
          <div className="flex flex-wrap items-center gap-1">
            {[
              { label: "明天", date: localDateStr(1) },
              { label: "後天", date: localDateStr(2) },
              { label: "下週一", date: nextWeekMonday() },
            ].map(({ label, date }) => (
              <SpinButton
                key={label}
                onClick={() => handleBulkSchedule(date)}
                disabled={busy}
                className="rounded bg-amber-500 px-2.5 py-1 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
              >
                {label}
              </SpinButton>
            ))}
          </div>
          <DatePicker
            value={bulkDate}
            onChange={setBulkDate}
            className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
          />
          <SpinButton
            onClick={() => handleBulkSchedule(bulkDate)}
            disabled={!bulkDate || busy}
            className="rounded bg-amber-600 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
          >
            {busy ? "排程中…" : "📅 批次排日期"}
          </SpinButton>
          <SpinButton
            onClick={clearSelected}
            disabled={busy}
            className="ml-auto rounded border border-zinc-300 px-2.5 py-1 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800 disabled:opacity-50"
          >
            清除選取
          </SpinButton>
        </div>
      )}

      {rows === null ? (
        <div className="text-sm text-zinc-400">載入中…</div>
      ) : rows.length === 0 ? (
        <div className="rounded-lg border border-zinc-200 p-8 text-center text-sm text-zinc-400 dark:border-zinc-800">
          沒有符合的資料
        </div>
      ) : (
        <>
        <div className="hidden overflow-x-auto rounded-lg border border-zinc-200 md:block dark:border-zinc-800">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
              <tr>
                <th className="w-8 px-2 py-2 text-left">
                  {(() => {
                    const selectables = (rows ?? []).filter(isSelectable);
                    const allSelected = selectables.length > 0 && selectables.every((r) => selected.has(r.id));
                    return (
                      <input
                        type="checkbox"
                        checked={allSelected}
                        disabled={selectables.length === 0}
                        onChange={(e) => {
                          if (e.target.checked) {
                            setSelected(new Set(selectables.map((r) => r.id)));
                          } else {
                            clearSelected();
                          }
                        }}
                        title="全選可排程的候選"
                        className="h-4 w-4 cursor-pointer"
                      />
                    );
                  })()}
                </th>
                <th className="px-3 py-2 text-left font-medium">時間</th>
                <th className="px-3 py-2 text-left font-medium">商品名稱</th>
                <th className="px-3 py-2 text-left font-medium">賣過嗎</th>
                <th className="px-3 py-2 text-left font-medium">文案</th>
                <th className="px-3 py-2 text-left font-medium">來源</th>
                <th className="px-3 py-2 text-left font-medium">狀態</th>
                <th className="px-3 py-2 text-left font-medium">排程日</th>
                <th className="px-3 py-2 text-left font-medium">動作</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {rows.map((r) => (
                <tr
                  key={r.id}
                  ref={(el) => {
                    if (r.id === highlightId) highlightRowRef.current = el;
                  }}
                  className={`hover:bg-zinc-50 dark:hover:bg-zinc-900/50 ${
                    r.id === highlightId
                      ? "bg-amber-50 ring-2 ring-amber-300 dark:bg-amber-950/30 dark:ring-amber-700"
                      : ""
                  }`}
                >
                  <td className="px-2 py-3">
                    <input
                      type="checkbox"
                      checked={selected.has(r.id)}
                      disabled={!isSelectable(r)}
                      onChange={() => toggleOne(r.id)}
                      className="h-4 w-4 cursor-pointer disabled:cursor-not-allowed disabled:opacity-30"
                      title={isSelectable(r) ? "選取" : "已排程,不可重複排程"}
                    />
                  </td>
                  <td className="whitespace-nowrap px-3 py-3 text-zinc-500">{fmt(r.created_at)}</td>
                  <td className="px-3 py-3 font-medium">
                    {r.product_name_hint ?? "—"}
                    {(() => {
                      const any = r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null;
                      const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
                      if (complete) return <span className="ml-1.5 inline-flex rounded-full bg-teal-100 px-1.5 py-0.5 text-[10px] font-medium text-teal-700 dark:bg-teal-900/30 dark:text-teal-300">已補資料</span>;
                      if (any) return <span className="ml-1.5 inline-flex rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">資料未完整</span>;
                      return null;
                    })()}
                    <SupplierInfo p={r.parsed} />
                    <SupplierImages paths={r.raw?.market_post_id != null ? postImages[r.raw.market_post_id] : undefined} />
                  </td>
                  <td className="w-44 px-3 py-3 align-top"><SoldInfo p={r.parsed} /></td>
                  <td className="max-w-xs px-3 py-3 text-zinc-600 dark:text-zinc-300">
                    <span title={r.raw_text}>
                      {r.raw_text.slice(0, 80)}
                      {r.raw_text.length > 80 ? "…" : ""}
                    </span>
                    {(r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null) && (
                      <div className="mt-1 space-y-0.5 text-xs text-zinc-500 dark:text-zinc-400">
                        {r.adopted_supplier_name && <div>廠商：{r.adopted_supplier_name}</div>}
                        {r.adopted_cost !== null && <div>成本：{r.adopted_cost}</div>}
                        {r.adopted_sale_price !== null && <div>售價：{r.adopted_sale_price}</div>}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-3 text-zinc-500">
                    {r.source_user_name ?? r.source_user_id ?? "—"}
                    {r.source_channel && (
                      <div className="text-xs text-zinc-400">{r.source_channel}</div>
                    )}
                  </td>
                  <td className="px-3 py-3">
                    <span
                      className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none}`}
                    >
                      {ACTION_LABEL[r.owner_action] ?? r.owner_action}
                    </span>
                  </td>
                  <td className="whitespace-nowrap px-3 py-3 text-zinc-500">
                    {r.scheduled_open_at ?? "—"}
                  </td>
                  <td className="px-3 py-3">{renderActions(r)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Mobile card list */}
        <div className="space-y-2 md:hidden">
          {rows.map((r) => {
            const any = r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null;
            const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
            return (
              <div
                key={r.id}
                ref={(el) => {
                  if (r.id === highlightId) highlightRowRef.current = el;
                }}
                className={`rounded-lg border p-3 transition ${
                  r.id === highlightId
                    ? "border-amber-300 bg-white ring-2 ring-amber-300 dark:border-amber-700 dark:bg-zinc-900 dark:ring-amber-700"
                    : selected.has(r.id)
                    ? "border-amber-400 bg-amber-50/60 ring-1 ring-amber-300 dark:border-amber-700 dark:bg-amber-950/20 dark:ring-amber-800"
                    : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
                }`}
              >
                <div className="flex items-center justify-between gap-2">
                  {isSelectable(r) ? (
                    <label className="-m-1.5 flex min-w-0 flex-1 cursor-pointer items-center gap-2 rounded-md p-1.5 active:bg-amber-50 dark:active:bg-amber-950/30">
                      <input
                        type="checkbox"
                        checked={selected.has(r.id)}
                        onChange={() => toggleOne(r.id)}
                        className="h-5 w-5 shrink-0 cursor-pointer accent-amber-600"
                      />
                      <span className="shrink-0 text-xs font-medium text-zinc-500 dark:text-zinc-400">
                        {selected.has(r.id) ? "已選取" : "選取"}
                      </span>
                      <span
                        className={`inline-flex shrink-0 rounded-full px-2 py-0.5 text-[10px] font-medium ${ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none}`}
                      >
                        {ACTION_LABEL[r.owner_action] ?? r.owner_action}
                      </span>
                    </label>
                  ) : (
                    <span
                      className={`inline-flex rounded-full px-2 py-0.5 text-[10px] font-medium ${ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none}`}
                      title="已排程，不可重複排程"
                    >
                      {ACTION_LABEL[r.owner_action] ?? r.owner_action}
                    </span>
                  )}
                  <span className="shrink-0 text-[11px] text-zinc-400">{fmt(r.created_at)}</span>
                </div>

                <div className="mt-2 flex items-baseline gap-1.5">
                  <span className="text-sm font-medium leading-snug">
                    {r.product_name_hint ?? "—"}
                  </span>
                  {complete && (
                    <span className="inline-flex shrink-0 rounded-full bg-teal-100 px-1.5 py-0.5 text-[10px] font-medium text-teal-700 dark:bg-teal-900/30 dark:text-teal-300">
                      已補資料
                    </span>
                  )}
                  {any && !complete && (
                    <span className="inline-flex shrink-0 rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                      資料未完整
                    </span>
                  )}
                </div>
                <SupplierInfo p={r.parsed} />
                {r.parsed && <div className="mt-1.5"><SoldInfo p={r.parsed} /></div>}
                <SupplierImages paths={r.raw?.market_post_id != null ? postImages[r.raw.market_post_id] : undefined} />

                <p className="mt-1 whitespace-pre-line text-xs text-zinc-600 dark:text-zinc-300">
                  {r.raw_text.slice(0, 140)}
                  {r.raw_text.length > 140 ? "…" : ""}
                </p>

                {any && (
                  <div className="mt-1.5 space-y-0.5 text-[11px] text-zinc-500 dark:text-zinc-400">
                    {r.adopted_supplier_name && <div>廠商：{r.adopted_supplier_name}</div>}
                    {r.adopted_cost !== null && <div>成本：{r.adopted_cost}</div>}
                    {r.adopted_sale_price !== null && <div>售價：{r.adopted_sale_price}</div>}
                  </div>
                )}

                <div className="mt-2 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-zinc-500">
                  <span>來源：{r.source_user_name ?? r.source_user_id ?? "—"}</span>
                  {r.source_channel && <span className="text-zinc-400">{r.source_channel}</span>}
                  {r.scheduled_open_at && <span>排程日：{r.scheduled_open_at}</span>}
                </div>

                <div className="mt-2 border-t border-zinc-100 pt-2 dark:border-zinc-800">
                  {renderActions(r)}
                </div>
              </div>
            );
          })}
        </div>
        </>
      )}

      <div className="flex flex-wrap items-center gap-3 text-xs text-zinc-500">
        <span>
          共 {total} 筆・第 {total === 0 ? 0 : page + 1} / {Math.max(1, Math.ceil(total / PAGE_SIZE))} 頁
          <span className="ml-2 text-zinc-400">
            只顯示最近 {KEEP_DAYS} 天（收藏、已採用全部顯示，排程看排程日）；超過 {KEEP_DAYS} 天沒處理或已忽略的每天自動清掉
          </span>
        </span>
        <span className="ml-auto flex gap-2">
          <button type="button" disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}
                  className="rounded border border-zinc-300 px-2 py-1 disabled:opacity-40 dark:border-zinc-700">上一頁</button>
          <button type="button" disabled={(page + 1) * PAGE_SIZE >= total} onClick={() => setPage((p) => p + 1)}
                  className="rounded border border-zinc-300 px-2 py-1 disabled:opacity-40 dark:border-zinc-700">下一頁</button>
        </span>
      </div>
    </div>
  );
}
