"use client";

// 進貨待辦 (Receiving Workbench)
// 列出所有 sent / partially_received PO,以及最近 fully_received 的,顯示到貨進度。
// 點「收貨」跳到既有 /purchase/orders/receive 頁。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { Modal } from "@/components/Modal";
import { POReceiptTimeline } from "@/components/POReceiptTimeline";
import { PO_TERM_ZH } from "@/lib/poStatus";

type POStatus = "draft" | "sent" | "partially_received" | "fully_received" | "cancelled";

const STATUS_LABEL: Record<POStatus, string> = {
  draft: "草稿",
  sent: "🔴 未收",
  partially_received: "⏳ 部分收",
  fully_received: "✓ 全收",
  cancelled: "已取消",
};

const STATUS_COLOR: Record<POStatus, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  sent: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
  partially_received: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  fully_received: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-400",
};

type PORow = {
  id: number;
  po_no: string;
  status: POStatus;
  sent_at: string | null;
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  total_qty_ordered: number;
  total_qty_received: number;
  line_count: number;
  is_restock: boolean;
  // 該 PO 所有品項的商品名（供搜尋用；RPC 已 DISTINCT 且濾掉 NULL）
  product_names: string[];
};

type Filter = "today" | "this_week" | "all";
type ReceiveTab = "unreceived" | "received";
// 檢視：清單(現況,預設) / 依廠商分組
type ViewMode = "list" | "supplier";

// 分組檢視下,一張單先只顯示幾個商品名（其餘用「＋還有 N 項」展開,不把版面撐爆）
const PRODUCT_NAME_PREVIEW = 8;

// 搜尋命中的廠商在這個數量以內就全部自動展開,超過就全部收合。
// 不做「只展開前 N 家」——那會讓人以為只有那幾家有貨,比全收合更糟。
const AUTO_EXPAND_MAX_SUPPLIERS = 3;

// 已收 = 全收；未收 = sent + 部分收
const isReceived = (r: PORow) => r.status === "fully_received";

// 廠商分組：一組 = 一個供應商,底下掛該廠商的每張 PO
// 註：RPC 只帶回每張 PO 的商品名字串陣列,沒有品項層數量,
//     所以這裡只聚合到「廠商 → 單 → 商品名」,數量只有單層與廠商合計。
type SupplierGroup = {
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  pos: PORow[];
  total_qty_ordered: number;
  total_qty_received: number;
  // 「還沒到」與「已全收但短少」是兩件事,不能加在一起叫「未到」：
  // 前者貨還會來,後者貨不會來了。比照單列既有的 diff 判定（琥珀 vs 紅字 ⚠）。
  // 兩者都逐單 clamp 到 0,所以某張單超收不會去抵消別張單的短少,也不會出現負數。
  qty_pending: number;
  qty_short: number;
};

export default function ReceivingWorkbenchPage() {
  const [rows, setRows] = useState<PORow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>("this_week");
  const [search, setSearch] = useState("");
  // 分頁：未收(sent+部分收) / 已收(全收)，預設未收
  const [tab, setTab] = useState<ReceiveTab>("unreceived");
  // 檢視：預設清單（辦公室現在的操作習慣不變）
  const [viewMode, setViewMode] = useState<ViewMode>("list");
  // 分組檢視的展開狀態；沒被手動點過的廠商，搜尋中一律預設展開（搜到了就直接看得到）
  const [expandedSup, setExpandedSup] = useState<Record<number, boolean>>({});
  const [detailPoId, setDetailPoId] = useState<number | null>(null);
  const [detailPoNo, setDetailPoNo] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        // 單一伺服端聚合 RPC（取代之前瀏覽器端跨 6 表 client join + 撈整張
        // restock_requests）。回傳已算好的 PORow[]，一次 round-trip。
        const sb = getSupabase();
        const { data, error: e } = await sb.rpc("rpc_receiving_workbench");
        if (e) throw new Error(e.message);
        if (!cancelled) {
          setRows(((data ?? []) as Array<Record<string, unknown>>).map((r) => ({
            id: Number(r.id),
            po_no: String(r.po_no),
            status: r.status as POStatus,
            sent_at: (r.sent_at as string | null) ?? null,
            supplier_id: Number(r.supplier_id),
            supplier_name: String(r.supplier_name),
            supplier_code: (r.supplier_code as string | null) ?? null,
            total_qty_ordered: Number(r.total_qty_ordered),
            total_qty_received: Number(r.total_qty_received),
            line_count: Number(r.line_count),
            is_restock: Boolean(r.is_restock),
            product_names: Array.isArray(r.product_names)
              ? (r.product_names as unknown[]).map((n) => String(n))
              : [],
          })));
          setError(null);
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // 先套期間 + 搜尋 filter（分頁數量與列表都基於同一份集合）
  const periodFiltered = useMemo(() => {
    if (!rows) return [];
    const now = new Date();
    const today = now.toISOString().slice(0, 10);
    const weekAgo = new Date(now);
    weekAgo.setDate(weekAgo.getDate() - 7);
    const weekAgoStr = weekAgo.toISOString().slice(0, 10);
    const q = search.trim().toLowerCase();

    return rows.filter((r) => {
      if (filter === "today") {
        const dateRef = r.sent_at?.slice(0, 10) ?? "";
        if (dateRef !== today) return false;
      }
      if (filter === "this_week") {
        const dateRef = r.sent_at?.slice(0, 10) ?? "";
        if (!dateRef || dateRef < weekAgoStr) return false;
      }
      if (q) {
        const haystack = [r.po_no, r.supplier_name, r.supplier_code ?? "", r.product_names.join(" ")]
          .join(" ")
          .toLowerCase();
        if (!haystack.includes(q)) return false;
      }
      return true;
    });
  }, [rows, filter, search]);

  // 分頁數量（反映目前期間）
  const tabCounts = useMemo(() => {
    let unreceived = 0;
    let received = 0;
    for (const r of periodFiltered) {
      if (isReceived(r)) received += 1;
      else unreceived += 1;
    }
    return { unreceived, received };
  }, [periodFiltered]);

  // 再套分頁：未收(非全收) / 已收(全收)
  const filtered = useMemo(
    () => periodFiltered.filter((r) => (tab === "received" ? isReceived(r) : !isReceived(r))),
    [periodFiltered, tab],
  );

  // 廠商分組：直接吃 filtered（期間 + 搜尋 + 未收/已收 都已套用），
  // 分組只是換一種呈現，不另外做一套過濾邏輯。
  // 比照 purchase/orders 的 pivotGroups：Map 聚合 → Array.from().sort()。
  const supplierGroups: SupplierGroup[] = useMemo(() => {
    const bySup = new Map<number, SupplierGroup>();
    for (const r of filtered) {
      let g = bySup.get(r.supplier_id);
      if (!g) {
        g = {
          supplier_id: r.supplier_id,
          supplier_name: r.supplier_name,
          supplier_code: r.supplier_code,
          pos: [],
          total_qty_ordered: 0,
          total_qty_received: 0,
          qty_pending: 0,
          qty_short: 0,
        };
        bySup.set(r.supplier_id, g);
      }
      g.pos.push(r);
      g.total_qty_ordered += r.total_qty_ordered;
      g.total_qty_received += r.total_qty_received;
      const diff = Math.max(0, r.total_qty_ordered - r.total_qty_received);
      if (isReceived(r)) g.qty_short += diff;
      else g.qty_pending += diff;
    }
    return Array.from(bySup.values()).sort((a, b) =>
      a.supplier_name.localeCompare(b.supplier_name, "zh-Hant"),
    );
  }, [filtered]);

  const searchQuery = search.trim().toLowerCase();
  // 沒手動點過的廠商用這個預設值：搜尋命中家數少(≤3)才自動全展開。
  // 命中一大票時（例如打「肉」）全展開會把 iPad 整頁撐爆，一律收合，
  // 由組頭的「命中 N 張單」讓人自己決定點哪家。
  const autoExpand = searchQuery !== "" && supplierGroups.length <= AUTO_EXPAND_MAX_SUPPLIERS;
  const isSupOpen = (supplierId: number) => expandedSup[supplierId] ?? autoExpand;

  function changeSearch(value: string) {
    setSearch(value);
    // 換搜尋條件就把手動展開/收合清掉，讓新命中的廠商自動展開
    setExpandedSup({});
  }

  const counts = useMemo(() => {
    if (!rows) return { sent: 0, partial: 0, full: 0, restock: 0 };
    return rows.reduce(
      (acc, r) => {
        if (r.status === "sent") acc.sent += 1;
        if (r.status === "partially_received") acc.partial += 1;
        if (r.status === "fully_received") acc.full += 1;
        if (r.is_restock) acc.restock += 1;
        return acc;
      },
      { sent: 0, partial: 0, full: 0, restock: 0 },
    );
  }, [rows]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">📥 進貨待辦</h1>
          <p className="text-sm text-zinc-500">
            {rows === null
              ? "載入中…"
              : `共 ${rows.length} 張 PO · 未收 ${counts.sent} · 部分收 ${counts.partial} · 全收 ${counts.full}`}
            {counts.restock > 0 ? ` · 含 ${counts.restock} 張補貨單` : ""}
          </p>
        </div>
        <Link
          href="/purchase/orders"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          {PO_TERM_ZH}列表 →
        </Link>
      </header>

      {/* KPI bar */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="🔴 未收" value={counts.sent} accent="text-rose-700 dark:text-rose-400" />
        <Stat label="⏳ 部分收" value={counts.partial} accent="text-amber-700 dark:text-amber-400" />
        <Stat label="✓ 全收" value={counts.full} accent="text-emerald-700 dark:text-emerald-400" />
        <Stat label="🔁 補貨來源" value={counts.restock} accent="text-indigo-700 dark:text-indigo-400" />
      </div>

      {/* 分頁：未收 / 已收（預設未收） */}
      <div className="flex items-center gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {([
          { value: "unreceived", label: "未收", count: tabCounts.unreceived },
          { value: "received", label: "已收", count: tabCounts.received },
        ] as const).map((t) => {
          const active = tab === t.value;
          return (
            <SpinButton
              key={t.value}
              onClick={() => setTab(t.value)}
              className={`relative px-4 py-2 text-sm font-medium transition-colors ${
                active
                  ? "text-zinc-900 dark:text-zinc-100"
                  : "text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
              }`}
            >
              {t.label}
              <span className={`ml-1.5 ${active ? "" : "text-zinc-400 dark:text-zinc-500"}`}>
                ({t.count})
              </span>
              {active && (
                <span className="absolute -bottom-px left-0 right-0 h-0.5 bg-zinc-900 dark:bg-zinc-100" />
              )}
            </SpinButton>
          );
        })}
      </div>

      {/* 搜尋 */}
      <input
        value={search}
        onChange={(e) => changeSearch(e.target.value)}
        placeholder="🔍 搜尋 單號 / 供應商 / 商品"
        className="w-full min-w-[180px] rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
      />

      {/* 檢視切換：清單(預設) / 依廠商 */}
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs text-zinc-500">檢視:</span>
        {([
          { value: "list", label: "清單" },
          { value: "supplier", label: "依廠商" },
        ] as const).map((v) => (
          <SpinButton
            key={v.value}
            onClick={() => setViewMode(v.value)}
            /* 觸控目標 ≥ 44px：樓下是用 iPad 單手點的。
               touch-manipulation = touch-action: manipulation，關掉 double-tap-to-zoom
               在這顆鈕上造成的 ~350ms click 延遲（iOS 會先等第二下）。 */
            className={`inline-flex min-h-[44px] items-center rounded-full border px-4 text-xs touch-manipulation ${
              viewMode === v.value
                ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300"
            }`}
          >
            {v.label}
          </SpinButton>
        ))}
      </div>

      {/* Filter */}
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs text-zinc-500">期間:</span>
        {(["today", "this_week", "all"] as const).map((f) => (
          <SpinButton
            key={f}
            onClick={() => setFilter(f)}
            className={`rounded-full border px-3 py-1 text-xs ${
              filter === f
                ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300"
            }`}
          >
            {f === "today" ? "今日" : f === "this_week" ? "近 7 天" : "全部"}
          </SpinButton>
        ))}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* List */}
      {viewMode === "list" && (
      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">PO 編號</th>
              <th className="px-3 py-2">供應商</th>
              <th className="px-3 py-2">送單日</th>
              <th className="px-3 py-2 text-right">品項</th>
              <th className="px-3 py-2 text-right">訂購</th>
              <th className="px-3 py-2 text-right">已到</th>
              <th className="px-3 py-2 text-right">差</th>
              <th className="px-3 py-2">狀態</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : filtered.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">目前沒有資料</td></tr>
            ) : filtered.map((r) => {
              const diff = r.total_qty_ordered - r.total_qty_received;
              return (
                <tr
                  key={r.id}
                  className="cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-950"
                  onClick={(e) => {
                    // 只在不是點 link/button 時觸發
                    const target = e.target as HTMLElement;
                    if (target.closest("a") || target.closest("button")) return;
                    setDetailPoId(r.id);
                    setDetailPoNo(r.po_no);
                  }}
                >
                  <td className="px-3 py-2 font-mono text-xs">
                    <SpinButton
                      type="button"
                      onClick={() => { setDetailPoId(r.id); setDetailPoNo(r.po_no); }}
                      className="text-blue-600 hover:underline dark:text-blue-400"
                    >
                      {r.po_no}
                    </SpinButton>
                    {r.is_restock && <span className="ml-2 inline-block rounded bg-indigo-100 px-1 py-0.5 text-[10px] text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300" title="此 PO 來自補貨申請,到貨後可從派貨工作台或 HQ Inbox 派出">🔁 補貨</span>}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <div>{r.supplier_name}</div>
                    {r.supplier_code && <div className="font-mono text-[10px] text-zinc-400">{r.supplier_code}</div>}
                  </td>
                  <td className="px-3 py-2 text-xs text-zinc-500">
                    {r.sent_at ? new Date(r.sent_at).toLocaleDateString("zh-TW") : "—"}
                  </td>
                  <td className="px-3 py-2 text-right font-mono text-xs">{r.line_count}</td>
                  <td className="px-3 py-2 text-right font-mono text-xs">{r.total_qty_ordered}</td>
                  <td className="px-3 py-2 text-right font-mono text-xs font-semibold">{r.total_qty_received}</td>
                  <td className={`px-3 py-2 text-right font-mono text-xs ${diff > 0 && r.status === "fully_received" ? "font-bold text-rose-600" : diff > 0 ? "text-amber-600" : "text-zinc-400"}`}>
                    {diff > 0 ? `${diff}${r.status === "fully_received" ? " ⚠" : ""}` : "—"}
                  </td>
                  <td className="px-3 py-2">
                    <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span>
                  </td>
                  <td className="px-3 py-2 text-right">
                    {r.status !== "fully_received" ? (
                      <Link
                        href={`/purchase/orders/receive?po=${r.id}`}
                        className="rounded bg-blue-600 px-2 py-1 text-xs font-semibold text-white hover:bg-blue-700"
                      >
                        收貨
                      </Link>
                    ) : (
                      <Link
                        href={`/purchase/orders/edit?id=${r.id}`}
                        className="rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                      >
                        明細
                      </Link>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      )}

      {/* 依廠商分組 */}
      {viewMode === "supplier" && (
        <div className="flex flex-col gap-3">
          {rows === null ? (
            <div className="rounded-md border border-zinc-200 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800">
              載入中…
            </div>
          ) : supplierGroups.length === 0 ? (
            <div className="rounded-md border border-zinc-200 p-6 text-center text-sm text-zinc-500 dark:border-zinc-800">
              目前沒有資料
            </div>
          ) : (
            <>
              <div className="text-xs text-zinc-500">
                {supplierGroups.length} 家廠商 · {filtered.length} 張 PO
              </div>
              {/* 🔁 補貨 badge 的意思寫在畫面上（不是只有 tooltip —— iPad 沒有 hover）。
                  只在這批結果真的有補貨單時才出現，免得每次都佔一行。 */}
              {filtered.some((r) => r.is_restock) && (
                <div className="text-[11px] text-zinc-500">
                  🔁 補貨 = 這張單來自補貨申請，到貨後可從派貨工作台或 HQ Inbox 派出
                </div>
              )}
              {supplierGroups.map((g) => {
                const open = isSupOpen(g.supplier_id);
                return (
                  <div
                    key={g.supplier_id}
                    className="overflow-hidden rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
                  >
                    <SpinButton
                      type="button"
                      onClick={() =>
                        setExpandedSup((prev) => ({ ...prev, [g.supplier_id]: !open }))
                      }
                      className="flex w-full flex-wrap items-baseline justify-between gap-2 bg-zinc-50 px-3 py-2 text-left hover:bg-zinc-100 dark:bg-zinc-900 dark:hover:bg-zinc-800"
                    >
                      <span className="text-sm font-semibold">
                        <span className="mr-1.5 inline-block text-zinc-400">{open ? "▾" : "▸"}</span>
                        {g.supplier_name}
                        {g.supplier_code && (
                          <span className="ml-2 font-mono text-[10px] font-normal text-zinc-400">
                            {g.supplier_code}
                          </span>
                        )}
                        <span className="ml-2 text-xs font-normal text-zinc-500">
                          {searchQuery ? "命中 " : ""}{g.pos.length} 張單
                        </span>
                      </span>
                      <span className="text-xs text-zinc-500">
                        訂購 {g.total_qty_ordered} · 已到 {g.total_qty_received} ·{" "}
                        <span className={g.qty_pending > 0 ? "text-amber-600 dark:text-amber-400" : ""}>
                          未到 {g.qty_pending}
                        </span>
                        {g.qty_short > 0 && (
                          <span className="ml-2 font-bold text-rose-600">
                            已全收但差 {g.qty_short} ⚠
                          </span>
                        )}
                      </span>
                    </SpinButton>

                    {open && (
                      <ul className="divide-y divide-zinc-100 dark:divide-zinc-800/60">
                        {g.pos.map((r) => {
                          const diff = r.total_qty_ordered - r.total_qty_received;
                          return (
                            <li key={r.id} className="px-3 py-2">
                              <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                                <SpinButton
                                  type="button"
                                  onClick={() => { setDetailPoId(r.id); setDetailPoNo(r.po_no); }}
                                  className="font-mono text-xs text-blue-600 hover:underline dark:text-blue-400"
                                >
                                  {r.po_no}
                                </SpinButton>
                                {r.is_restock && <span className="inline-block rounded bg-indigo-100 px-1 py-0.5 text-[10px] text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300" title="此 PO 來自補貨申請,到貨後可從派貨工作台或 HQ Inbox 派出">🔁 補貨</span>}
                                <span className="text-xs text-zinc-500">
                                  {r.sent_at ? new Date(r.sent_at).toLocaleDateString("zh-TW") : "—"}
                                </span>
                                <span className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${STATUS_COLOR[r.status]}`}>{STATUS_LABEL[r.status]}</span>
                                <span className="font-mono text-xs text-zinc-500">
                                  訂購 {r.total_qty_ordered} · 已到{" "}
                                  <span className="font-semibold text-zinc-800 dark:text-zinc-200">{r.total_qty_received}</span>
                                  {" · "}
                                  <span className={diff > 0 && r.status === "fully_received" ? "font-bold text-rose-600" : diff > 0 ? "text-amber-600" : "text-zinc-400"}>
                                    未到 {diff > 0 ? `${diff}${r.status === "fully_received" ? " ⚠" : ""}` : "—"}
                                  </span>
                                </span>
                                <span className="ml-auto">
                                  {r.status !== "fully_received" ? (
                                    <Link
                                      href={`/purchase/orders/receive?po=${r.id}`}
                                      className="rounded bg-blue-600 px-2 py-1 text-xs font-semibold text-white hover:bg-blue-700"
                                    >
                                      收貨
                                    </Link>
                                  ) : (
                                    <Link
                                      href={`/purchase/orders/edit?id=${r.id}`}
                                      className="rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                                    >
                                      明細
                                    </Link>
                                  )}
                                </span>
                              </div>
                              <ProductNames
                                key={`${r.id}:${searchQuery}`}
                                names={r.product_names}
                                query={searchQuery}
                              />
                            </li>
                          );
                        })}
                      </ul>
                    )}
                  </div>
                );
              })}
            </>
          )}
        </div>
      )}

      <Modal
        open={detailPoId !== null}
        onClose={() => setDetailPoId(null)}
        title={`${PO_TERM_ZH}到貨進度 ${detailPoNo}`}
        maxWidth="max-w-4xl"
      >
        {detailPoId !== null && <POReceiptTimeline poId={detailPoId} />}
      </Modal>
    </div>
  );
}

// 分組檢視下顯示一張 PO 的商品名。
// 太多時只先出 PRODUCT_NAME_PREVIEW 個,其餘用「＋還有 N 項」按鈕展開（不是藏起來）。
// 搜尋中會把命中的商品名排到最前面,免得員工搜到的那個剛好被截斷。
function ProductNames({ names, query }: { names: string[]; query: string }) {
  const [showAll, setShowAll] = useState(false);

  if (names.length === 0) {
    return <div className="mt-1 text-[11px] text-zinc-400">（此單無商品資料）</div>;
  }

  const ordered = query
    ? [...names].sort(
        (a, b) =>
          (a.toLowerCase().includes(query) ? 0 : 1) - (b.toLowerCase().includes(query) ? 0 : 1),
      )
    : names;
  const shown = showAll ? ordered : ordered.slice(0, PRODUCT_NAME_PREVIEW);
  const rest = ordered.length - shown.length;

  return (
    <div className="mt-1 flex flex-wrap items-center gap-1">
      {shown.map((n, i) => (
        <span
          key={`${n}#${i}`}
          className="rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
        >
          {n}
        </span>
      ))}
      {(rest > 0 || showAll) && (
        <SpinButton
          type="button"
          onClick={() => setShowAll((v) => !v)}
          /* 觸控目標 ≥ 44px：這顆是 iPad 上看完整商品名的關鍵按鈕。
             touch-manipulation 關掉 double-tap-to-zoom 造成的 ~350ms click 延遲。 */
          className="inline-flex min-h-[44px] items-center px-2 text-[11px] text-blue-600 touch-manipulation hover:underline dark:text-blue-400"
        >
          {showAll ? "收合" : `＋還有 ${rest} 項`}
        </SpinButton>
      )}
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: number; accent: string }) {
  return (
    <div className="rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`text-2xl font-semibold ${accent}`}>{value}</div>
    </div>
  );
}
