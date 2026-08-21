"use client";

// ⚠️ 異常處理 — 抽離自舊 /wms/exceptions 頁,目前由 /hq/inbox?source=exception 內嵌使用
// 集中顯示倉儲全鏈路異常:
//   1. 進貨短少 — PO fully_received 但 gr_qty < qty_ordered
//   2. 進貨破損 — GR qty_damaged > 0
//   3. 過量進貨 — GR cumulative qty_received > qty_ordered
//   4. 收貨短少 — Transfer received 但 qty_received < qty_shipped
//
// 「訂單短少」(customer_shortage) 於 2026-08-11 移除:它是前瞻推算
// (v_order_shortage),供應商短交後必然大量出現,實際短交已由
// 進貨短少/收貨短少覆蓋 → v_hq_exceptions 已不再回傳此來源
// (20260811020010),此處的分頁與批次處理 UI 一併拿掉。
//
// 資料與分頁:全部走 server-side。rpc_hq_exceptions(type, page, page_size)
// 後端 union 4 來源(v_hq_exceptions)做真分頁,一次回傳 { total, counts(各 tab), rows(當前頁) }。

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "./SpinButton";
import { TransferShortageResolveModal, type ShortageContext } from "./TransferShortageResolveModal";
import { ExceptionHistoryModal, type ExceptionCase, type ExceptionSubject } from "./ExceptionHistoryModal";
import { useRole } from "@/lib/role";

type Tab = "all" | "po_shortage" | "po_damage" | "po_over" | "transfer_short";

const TAB_LABEL: Record<Tab, string> = {
  all: "全部",
  po_shortage: "進貨短少",
  po_damage: "進貨破損",
  po_over: "過量進貨",
  transfer_short: "收貨短少",
};

// 與 /hq/inbox 其他來源一致的每頁筆數
const PAGE_SIZE = 20;

type ExceptionType = "po_shortage" | "po_damage" | "po_over" | "transfer_short";

type ExceptionRow = {
  key: string;
  type: ExceptionType;
  ts: string;
  doc_no: string;
  doc_link: string;
  sku_label: string;
  sku_code: string | null;
  expected: number;
  actual: number;
  diff: number;
  reason: string | null;
  extra: string;
  // 該筆異常的地點:PO/GR 收貨倉、收貨分店、取貨店(v_hq_exceptions.warehouse_name)
  warehouse_name: string | null;
  shortage_ctx?: ShortageContext;
};

// rpc_hq_exceptions 回傳的單列(= v_hq_exceptions 扁平欄位)
// type 保留 string:DB view 若尚未套 20260811020010,可能還會回 customer_shortage,
// 前端一律濾掉(見下方 filter)。
type ViewRow = {
  type: ExceptionType | string;
  row_key: string;
  ts: string | null;
  doc_no: string;
  sku_code: string | null;
  sku_label: string;
  expected: number | string;
  actual: number | string;
  diff: number | string;
  reason: string | null;
  extra: string;
  transfer_item_id: number | null;
  transfer_id: number | null;
  transfer_no: string | null;
  sku_id: number | null;
  qty_shipped: number | string | null;
  qty_received: number | string | null;
  shortage_qty: number | string | null;
  dest_location: number | null;
  dest_store_id: number | null;
  dest_store_name: string | null;
  customer_order_id: number | null;
  shortage_resolution: string | null;
  warehouse_name: string | null;
};

type ExceptionCounts = Record<Tab, number>;

const EMPTY_COUNTS: ExceptionCounts = {
  all: 0, po_shortage: 0, po_damage: 0, po_over: 0, transfer_short: 0,
};

function docLinkFor(r: ViewRow): string {
  if (r.type === "transfer_short") return `/wms/inbound`;
  return `/wms/receiving`;
}

export default function ExceptionsContent({
  showHeader = true,
  onCountChange,
}: {
  showHeader?: boolean;
  onCountChange?: (count: number) => void;
}) {
  const role = useRole();
  const canManageHistory = role === "owner" || role === "admin" || role === "hq_manager";
  const [rows, setRows] = useState<ExceptionRow[] | null>(null);
  const [counts, setCounts] = useState<ExceptionCounts | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("all");
  const [resolveCtx, setResolveCtx] = useState<ShortageContext | null>(null);
  const [historyCases, setHistoryCases] = useState<ExceptionCase[]>([]);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [historySubject, setHistorySubject] = useState<ExceptionSubject | null>(null);
  const [historyCase, setHistoryCase] = useState<ExceptionCase | undefined>(undefined);
  const [showResolved, setShowResolved] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);
  const [page, setPage] = useState(1);
  const [prevTab, setPrevTab] = useState<Tab>(tab);

  // 切換分頁籤 → 回第 1 頁(render 階段調整 state,非 effect → 不觸發 set-state-in-effect,也不會 flash 舊頁)
  if (prevTab !== tab) {
    setPrevTab(tab);
    setPage(1);
  }

  // 處理歷程與 live 異常分開抓：已結案後 live row 消失，歷程仍必須找得到。
  useEffect(() => {
    if (!canManageHistory) { setHistoryCases([]); setHistoryError(null); return; }
    let cancelled = false;
    getSupabase().rpc("rpc_hq_exception_cases", { p_status: "all" }).then(({ data, error: err }) => {
      if (cancelled) return;
      if (err) { setHistoryError(err.message); return; }
      setHistoryCases((data ?? []) as ExceptionCase[]);
      setHistoryError(null);
    });
    return () => { cancelled = true; };
  }, [canManageHistory, reloadTick]);

  // server-side 抓當前 tab + page(rpc_hq_exceptions 一次回 total / 各 tab counts / 當頁 rows)
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data, error: err } = await sb.rpc("rpc_hq_exceptions", {
          p_type: tab,
          p_page: page,
          p_page_size: PAGE_SIZE,
        });
        if (err) throw err;
        if (cancelled) return;

        const resp = (data ?? { total: 0, counts: {}, rows: [] }) as {
          total: number;
          counts: Partial<ExceptionCounts>;
          rows: ViewRow[];
        };

        const mapped: ExceptionRow[] = (resp.rows ?? [])
          // DB view 未套 20260811020010 前的防禦:customer_shortage 一律不顯示
          .filter((r): r is ViewRow & { type: ExceptionType } => r.type in TAB_LABEL && r.type !== "all")
          .map((r) => ({
          key: r.row_key,
          type: r.type,
          ts: r.ts ?? "—",
          doc_no: r.doc_no,
          doc_link: docLinkFor(r),
          sku_code: r.sku_code,
          sku_label: r.sku_label,
          expected: Number(r.expected),
          actual: Number(r.actual),
          diff: Number(r.diff),
          reason: r.reason,
          extra: r.extra,
          warehouse_name: r.warehouse_name,
          shortage_ctx:
            r.type === "transfer_short" && r.transfer_item_id != null
              ? {
                  transfer_item_id: r.transfer_item_id,
                  transfer_id: r.transfer_id ?? 0,
                  transfer_no: r.transfer_no ?? `#${r.transfer_id}`,
                  sku_id: r.sku_id ?? 0,
                  sku_code: r.sku_code,
                  sku_label: r.sku_label,
                  qty_shipped: Number(r.qty_shipped),
                  qty_received: Number(r.qty_received),
                  shortage_qty: Number(r.shortage_qty),
                  dest_location: r.dest_location ?? 0,
                  dest_store_id: r.dest_store_id,
                  dest_store_name: r.dest_store_name ?? `位置 #${r.dest_location ?? "?"}`,
                }
              : undefined,
        }));

        const cnts: ExceptionCounts = {
          all: resp.counts?.all ?? 0,
          po_shortage: resp.counts?.po_shortage ?? 0,
          po_damage: resp.counts?.po_damage ?? 0,
          po_over: resp.counts?.po_over ?? 0,
          transfer_short: resp.counts?.transfer_short ?? 0,
        };

        setRows(mapped);
        setTotal(resp.total ?? 0);
        setCounts(cnts);
        setError(null);
        // 處理掉項目後列表縮短 → 修正超出範圍的頁碼(在 async 內、非 effect body,不觸發 set-state-in-effect)
        if (mapped.length === 0 && page > 1 && (resp.total ?? 0) > 0) {
          setPage(Math.max(1, Math.ceil((resp.total ?? 0) / PAGE_SIZE)));
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [tab, page, reloadTick, onCountChange]);

  const c = counts ?? EMPTY_COUNTS;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const currentPage = Math.min(page, totalPages);
  const reopenedOnly = historyCases.filter((item) => item.status === "open" && !item.is_live);
  const resolvedCases = historyCases.filter((item) => item.status === "resolved");
  const caseFor = (rowKey: string) => historyCases.find((item) => item.row_key === rowKey);
  const subjectFor = (row: ExceptionRow): ExceptionSubject => ({
    rowKey: row.key, type: row.type, docNo: row.doc_no, skuCode: row.sku_code,
    skuLabel: row.sku_label, warehouseName: row.warehouse_name,
    expected: row.expected, actual: row.actual, diff: row.diff,
  });
  const subjectForCase = (item: ExceptionCase): ExceptionSubject => ({
    rowKey: item.row_key, type: item.type, docNo: item.snapshot.doc_no ?? "—",
    skuCode: item.snapshot.sku_code ?? null, skuLabel: item.snapshot.sku_label ?? "—",
    warehouseName: item.snapshot.warehouse_name ?? null, expected: Number(item.snapshot.expected ?? 0),
    actual: Number(item.snapshot.actual ?? 0), diff: Number(item.snapshot.diff ?? 0),
  });

  useEffect(() => {
    onCountChange?.((counts?.all ?? 0) + reopenedOnly.length);
  }, [counts, onCountChange, reopenedOnly.length]);

  // 分頁控制列 — server-side(rpc_hq_exceptions),表格上、下各放一份
  // (手機不用滑過整頁 20 列才能換頁),樣式對齊 /hq/inbox 其他來源
  const paginationBar = rows !== null && total > PAGE_SIZE ? (
    <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
      <span className="text-xs text-zinc-500">
        共 {total} 筆 · 顯示 {(currentPage - 1) * PAGE_SIZE + 1} - {Math.min(currentPage * PAGE_SIZE, total)}
      </span>
      <SpinButton onClick={() => setPage(1)} disabled={currentPage === 1}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        « 第一頁
      </SpinButton>
      <SpinButton onClick={() => setPage(currentPage - 1)} disabled={currentPage === 1}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        ‹ 上頁
      </SpinButton>
      <span className="text-xs text-zinc-500">{currentPage} / {totalPages}</span>
      <SpinButton onClick={() => setPage(currentPage + 1)} disabled={currentPage === totalPages}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        下頁 ›
      </SpinButton>
      <SpinButton onClick={() => setPage(totalPages)} disabled={currentPage === totalPages}
        className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
        最末頁 »
      </SpinButton>
    </div>
  ) : null;

  return (
    <div className="flex flex-1 flex-col gap-4">
      {showHeader && (
        <header>
          <h1 className="text-xl font-semibold">⚠️ 異常處理</h1>
          <p className="text-sm text-zinc-500">
            {showResolved ? `已結案 ${resolvedCases.length} 筆（仍保留處理經過）` : counts === null ? "載入中…" : `待處理 ${c.all + reopenedOnly.length} 筆 · 進貨短少 ${c.po_shortage} / 進貨破損 ${c.po_damage} / 過量 ${c.po_over} / 收貨短少 ${c.transfer_short}`}
          </p>
        </header>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}
      {historyError && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          處理歷程載入失敗：{historyError}
        </div>
      )}

      {canManageHistory && <div className="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
        <SpinButton onClick={() => setShowResolved(false)} className={`-mb-px border-b-2 px-3 py-2 text-sm ${!showResolved ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300" : "border-transparent text-zinc-500"}`}>待處理</SpinButton>
        <SpinButton onClick={() => setShowResolved(true)} className={`-mb-px border-b-2 px-3 py-2 text-sm ${showResolved ? "border-blue-600 font-semibold text-blue-700 dark:text-blue-300" : "border-transparent text-zinc-500"}`}>已結案歷程 <span className="ml-1 text-xs text-zinc-400">{resolvedCases.length}</span></SpinButton>
      </div>}

      {canManageHistory && showResolved ? (
        <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800"><thead className="bg-zinc-50 dark:bg-zinc-900"><tr className="text-left text-xs uppercase tracking-wide text-zinc-500"><th className="px-3 py-2">單號 / 品項</th><th className="px-3 py-2">最後結果</th><th className="px-3 py-2">結案時間</th><th className="px-3 py-2"></th></tr></thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">{resolvedCases.length === 0 ? <tr><td colSpan={4} className="p-6 text-center text-zinc-500">尚無已結案異常</td></tr> : resolvedCases.map((item) => <tr key={item.id}><td className="px-3 py-2"><div className="font-mono text-xs">{item.snapshot.doc_no ?? "—"}</div><div className="text-xs">{item.snapshot.sku_label ?? "—"}</div></td><td className="px-3 py-2 text-xs">{item.result}</td><td className="px-3 py-2 text-xs text-zinc-500">{item.resolved_at ? new Date(item.resolved_at).toLocaleString("zh-TW") : "—"}</td><td className="px-3 py-2"><SpinButton onClick={() => { setHistorySubject(subjectForCase(item)); setHistoryCase(item); }} className="min-h-[44px] rounded-md border border-zinc-300 px-3 text-xs dark:border-zinc-700">看歷程 / 重開</SpinButton></td></tr>)}</tbody>
          </table>
        </div>
      ) : <>

      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["all", "po_shortage", "po_damage", "po_over", "transfer_short"] as const).map((t) => {
          const active = tab === t;
          return (
            <SpinButton
              key={t}
              onClick={() => setTab(t)}
              className={`-mb-px border-b-2 px-3 py-2 text-sm ${
                active
                  ? "border-rose-600 font-semibold text-rose-700 dark:text-rose-300"
                  : "border-transparent text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
              }`}
            >
              {TAB_LABEL[t]} <span className="ml-1 text-xs text-zinc-400">{c[t]}</span>
            </SpinButton>
          );
        })}
      </div>

      {canManageHistory && reopenedOnly.length > 0 && (
        <div className="rounded-md border border-amber-200 bg-amber-50 p-3 dark:border-amber-900 dark:bg-amber-950/30">
          <div className="text-sm font-semibold text-amber-900 dark:text-amber-200">重新開啟追蹤（原本的異常已不在即時清單）</div>
          <div className="mt-2 flex flex-wrap gap-2">{reopenedOnly.map((item) => <SpinButton key={item.id} onClick={() => { setHistorySubject(subjectForCase(item)); setHistoryCase(item); }} className="min-h-[44px] rounded-md border border-amber-300 bg-white px-3 text-xs dark:border-amber-700 dark:bg-zinc-900">{item.snapshot.doc_no ?? "—"} · {item.snapshot.sku_label ?? "—"} → 繼續處理</SpinButton>)}</div>
        </div>
      )}

      {/* 分頁 — 表格上方(手機優先看得到) */}
      {paginationBar}

      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">類型</th>
              <th className="px-3 py-2">單號</th>
              <th className="px-3 py-2">地點</th>
              <th className="px-3 py-2">品項</th>
              <th className="px-3 py-2 text-right">預期</th>
              <th className="px-3 py-2 text-right">實際</th>
              <th className="px-3 py-2 text-right">差額</th>
              <th className="px-3 py-2">原因 / 備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={9} className="p-6 text-center text-zinc-500">沒有異常,系統運作正常 ✓</td></tr>
            ) : rows.map((r) => (
              <tr key={r.key} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                <td className="px-3 py-2 whitespace-nowrap">
                  <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${
                    r.type === "po_shortage" ? "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300" :
                    r.type === "po_damage" ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300" :
                    r.type === "po_over" ? "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300" :
                    "bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300"
                  }`}>{TAB_LABEL[r.type]}</span>
                </td>
                <td className="px-3 py-2 font-mono text-xs whitespace-nowrap">{r.doc_no}</td>
                <td className="px-3 py-2 text-xs whitespace-nowrap font-medium">{r.warehouse_name ?? "—"}</td>
                <td className="px-3 py-2 text-xs min-w-[220px]">
                  {r.sku_code && <div className="font-mono text-[10px] text-zinc-500">{r.sku_code}</div>}
                  <div>{r.sku_label}</div>
                </td>
                <td className="px-3 py-2 text-right font-mono text-xs whitespace-nowrap">{r.expected}</td>
                <td className="px-3 py-2 text-right font-mono text-xs whitespace-nowrap">{r.actual}</td>
                <td className="px-3 py-2 text-right font-mono text-xs font-bold text-rose-600 whitespace-nowrap">{r.diff > 0 ? `-${r.diff}` : `+${Math.abs(r.diff)}`}</td>
                <td className="px-3 py-2 text-xs text-zinc-500">
                  {r.reason && <div className="text-amber-700 dark:text-amber-400 whitespace-nowrap">⚠ {r.reason}</div>}
                  <div className="whitespace-nowrap">{r.extra}</div>
                </td>
                <td className="px-3 py-2 text-xs whitespace-nowrap">
                  <div className="flex items-center gap-2">
                  {r.type === "transfer_short" && r.shortage_ctx ? (
                    <SpinButton
                      onClick={() => setResolveCtx(r.shortage_ctx ?? null)}
                      className="rounded-md bg-blue-600 px-3 py-1 text-xs font-semibold text-white hover:bg-blue-700"
                    >
                      處理
                    </SpinButton>
                  ) : (
                    <Link href={r.doc_link} className="text-blue-600 hover:underline dark:text-blue-400">前往 →</Link>
                  )}
                    {canManageHistory && <SpinButton onClick={() => { setHistorySubject(subjectFor(r)); setHistoryCase(caseFor(r.key)); }} className="min-h-[44px] rounded-md border border-zinc-300 px-2 text-xs dark:border-zinc-700">處理歷程</SpinButton>}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* 分頁 — 表格下方再放一份 */}
      {paginationBar}

      {resolveCtx && (
        <TransferShortageResolveModal
          ctx={resolveCtx}
          onClose={() => setResolveCtx(null)}
          onSubmitted={() => {
            setResolveCtx(null);
            setReloadTick((t) => t + 1);
          }}
        />
      )}
      {canManageHistory && historySubject && (
        <ExceptionHistoryModal subject={historySubject} caseRecord={historyCases.find((item) => item.id === historyCase?.id) ?? historyCase} onClose={() => { setHistorySubject(null); setHistoryCase(undefined); }} onChanged={() => setReloadTick((tick) => tick + 1)} />
      )}
      </>}
    </div>
  );
}
