"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";

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
};

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

export default function CommunityCandidatesPage() {
  const [rows, setRows] = useState<Candidate[] | null>(null);
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
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

  const highlightRowRef = useRef<HTMLTableRowElement | null>(null);

  useEffect(() => {
    const id = Number(new URLSearchParams(window.location.search).get("highlight"));
    if (Number.isFinite(id) && id > 0) {
      setHighlightId(id);
      setTab("all");
    }
  }, []);

  useEffect(() => {
    const t = setTimeout(() => setQuery(queryDraft), 300);
    return () => clearTimeout(t);
  }, [queryDraft]);

  useEffect(() => {
    if (highlightId && highlightRowRef.current) {
      highlightRowRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [highlightId, rows]);

  const reload = async () => {
    let q = getSupabase()
      .from("community_product_candidates")
      .select(
        "id, product_name_hint, raw_text, source_user_id, source_user_name, source_channel, system_status, owner_action, scheduled_open_at, scheduled_sort_order, created_at, adopted_supplier_name, adopted_cost, adopted_sale_price"
      )
      .order("created_at", { ascending: false })
      .limit(200);

    if (tab === "pending") q = q.eq("owner_action", "none");
    else if (tab === "collected") q = q.eq("owner_action", "collected");
    else if (tab === "scheduled") q = q.eq("owner_action", "scheduled");
    else if (tab === "ignored") q = q.eq("owner_action", "ignored");
    else if (tab === "adopted") q = q.eq("owner_action", "adopted");

    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`product_name_hint.ilike.%${safe}%,raw_text.ilike.%${safe}%`);
    }

    const { data, error: err } = await q;
    if (err) setError(err.message);
    else {
      setError(null);
      setRows((data as Candidate[]) ?? []);
    }
  };

  useEffect(() => {
    reload();
  }, [query, tab]);

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
      // 呼叫 rpc_schedule_candidate：建 draft product + sku + campaign + items + 標 candidate scheduled
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

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">選品候選池</h1>
          <p className="mt-0.5 text-sm text-zinc-500">LINE #選品 進來的商品候選</p>
        </div>
        <button
          onClick={() => reload()}
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        >
          重新整理
        </button>
      </header>

      {/* Tabs */}
      <div className="flex gap-0 border-b border-zinc-200 dark:border-zinc-800">
        {TABS.map(({ key, label }) => (
          <button
            key={key}
            onClick={() => setTab(key)}
            className={
              tab === key
                ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {label}
          </button>
        ))}
      </div>

      {/* Search */}
      <div className="flex gap-2">
        <input
          className="flex-1 rounded-md border border-zinc-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
          placeholder="搜尋商品名稱或文案…"
          value={queryDraft}
          onChange={(e) => setQueryDraft(e.target.value)}
        />
        {queryDraft && (
          <button
            onClick={() => setQueryDraft("")}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
          >
            清除
          </button>
        )}
      </div>

      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {rows === null ? (
        <div className="text-sm text-zinc-400">載入中…</div>
      ) : rows.length === 0 ? (
        <div className="rounded-lg border border-zinc-200 p-8 text-center text-sm text-zinc-400 dark:border-zinc-800">
          沒有符合的資料
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-zinc-200 dark:border-zinc-800">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
              <tr>
                <th className="px-3 py-2 text-left font-medium">時間</th>
                <th className="px-3 py-2 text-left font-medium">商品名稱</th>
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
                  ref={r.id === highlightId ? highlightRowRef : null}
                  className={`hover:bg-zinc-50 dark:hover:bg-zinc-900/50 ${
                    r.id === highlightId
                      ? "bg-amber-50 ring-2 ring-amber-300 dark:bg-amber-950/30 dark:ring-amber-700"
                      : ""
                  }`}
                >
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
                  </td>
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
                  <td className="px-3 py-3">
                    {editingInfo === r.id ? (
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
                          <button
                            onClick={() => handleFillSubmit(r.id)}
                            disabled={busy}
                            className="rounded bg-blue-600 px-2 py-0.5 text-xs text-white hover:bg-blue-700 disabled:opacity-50"
                          >
                            {busy ? "儲存中…" : "儲存"}
                          </button>
                          <button
                            onClick={() => { setEditingInfo(null); setAdoptSupplier(""); setAdoptCost(""); setAdoptSalePrice(""); }}
                            disabled={busy}
                            className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
                          >
                            取消
                          </button>
                        </div>
                      </div>
                    ) : scheduling === r.id ? (
                      <div className="flex flex-col gap-1.5">
                        <div className="flex gap-1">
                          {[
                            { label: "明天", date: localDateStr(1) },
                            { label: "後天", date: localDateStr(2) },
                            { label: "下週一", date: nextWeekMonday() },
                          ].map(({ label, date }) => (
                            <button
                              key={label}
                              onClick={() => handleQuickSchedule(r.id, date)}
                              disabled={busy}
                              className="rounded bg-amber-500 px-2 py-0.5 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
                            >
                              {label}
                            </button>
                          ))}
                        </div>
                        <div className="flex items-center gap-1">
                          <input
                            type="date"
                            value={scheduleDate}
                            onChange={(e) => setScheduleDate(e.target.value)}
                            className="rounded border border-zinc-300 px-1.5 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
                          />
                          <button
                            onClick={() => handleSchedule(r.id)}
                            disabled={!scheduleDate || busy}
                            className="rounded bg-amber-500 px-2 py-0.5 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
                          >
                            確定
                          </button>
                          <button
                            onClick={() => {
                              setScheduling(null);
                              setScheduleDate("");
                            }}
                            disabled={busy}
                            className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
                          >
                            取消
                          </button>
                        </div>
                      </div>
                    ) : (
                      <div className="flex flex-wrap items-center gap-1">
                        <button
                          onClick={() => {
                            setEditingInfo(r.id);
                            setAdoptSupplier(r.adopted_supplier_name ?? "");
                            setAdoptCost(r.adopted_cost !== null ? String(r.adopted_cost) : "");
                            setAdoptSalePrice(r.adopted_sale_price !== null ? String(r.adopted_sale_price) : extractPrice(r.raw_text));
                            setScheduling(null);
                          }}
                          disabled={busy}
                          className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400 disabled:opacity-50"
                        >
                          {r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null ? "修改資料" : "補資料"}
                        </button>
                        {r.owner_action !== "adopted" && (
                          <button
                            onClick={() => {
                              const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
                              if (!complete && !window.confirm("廠商、成本、售價尚未完整，確定要採用嗎？")) return;
                              handleAdopt(r.id);
                            }}
                            disabled={busy}
                            className="rounded border border-green-400 px-2 py-0.5 text-xs text-green-700 hover:bg-green-50 dark:border-green-700 dark:text-green-400 dark:hover:bg-green-950/30 disabled:opacity-50"
                          >
                            採用
                          </button>
                        )}
                        {r.owner_action !== "collected" && r.owner_action !== "adopted" && (
                          <button
                            onClick={() => handleCollect(r.id)}
                            disabled={busy}
                            className="rounded border border-blue-300 px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-400 disabled:opacity-50"
                          >
                            收藏
                          </button>
                        )}
                        {r.owner_action !== "scheduled" && r.owner_action !== "adopted" && (
                          <button
                            onClick={() => {
                              setScheduling(r.id);
                              setScheduleDate("");
                            }}
                            disabled={busy}
                            className="rounded border border-amber-300 px-2 py-0.5 text-xs text-amber-600 hover:bg-amber-50 dark:border-amber-800 dark:text-amber-400 disabled:opacity-50"
                          >
                            排日期
                          </button>
                        )}
                        {r.owner_action !== "ignored" && r.owner_action !== "adopted" && (
                          <button
                            onClick={() => handleIgnore(r.id)}
                            disabled={busy}
                            className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
                          >
                            忽略
                          </button>
                        )}
                        {(r.owner_action === "collected" ||
                          r.owner_action === "scheduled" ||
                          r.owner_action === "ignored") && (
                          <button
                            onClick={() => handleRestore(r.id)}
                            disabled={busy}
                            className="rounded border border-zinc-200 px-2 py-0.5 text-xs text-zinc-400 hover:bg-zinc-50 dark:border-zinc-800 disabled:opacity-50"
                          >
                            還原
                          </button>
                        )}
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="text-xs text-zinc-400">共 {rows?.length ?? 0} 筆（最多 200）</div>
    </div>
  );
}
