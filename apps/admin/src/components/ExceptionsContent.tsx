"use client";

// ⚠️ 異常處理 — 抽離自舊 /wms/exceptions 頁,目前由 /hq/inbox?source=exception 內嵌使用
// 集中顯示倉儲全鏈路異常:
//   1. 進貨短少 — PO fully_received 但 gr_qty < qty_ordered
//   2. 進貨破損 — GR qty_damaged > 0
//   3. 過量進貨 — GR cumulative qty_received > qty_ordered
//   4. 收貨短少 — Transfer received 但 qty_received < qty_shipped
//   5. 訂單短少 — v_order_shortage 聚合到 order 維度
//
// 資料與分頁:全部走 server-side。rpc_hq_exceptions(type, page, page_size)
// 後端 union 5 來源(v_hq_exceptions)做真分頁,一次回傳 { total, counts(各 tab), rows(當前頁) }。

import Link from "next/link";
import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "./SpinButton";
import { TransferShortageResolveModal, type ShortageContext } from "./TransferShortageResolveModal";

type Tab = "all" | "po_shortage" | "po_damage" | "po_over" | "transfer_short" | "customer_shortage";

const TAB_LABEL: Record<Tab, string> = {
  all: "全部",
  po_shortage: "進貨短少",
  po_damage: "進貨破損",
  po_over: "過量進貨",
  transfer_short: "收貨短少",
  customer_shortage: "訂單短少",
};

// 與 /hq/inbox 其他來源一致的每頁筆數
const PAGE_SIZE = 20;

type ExceptionType = "po_shortage" | "po_damage" | "po_over" | "transfer_short" | "customer_shortage";

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
  shortage_ctx?: ShortageContext;
  // customer_shortage 用
  customer_order_id?: number;
  shortage_resolution?: string | null;
};

// rpc_hq_exceptions 回傳的單列(= v_hq_exceptions 扁平欄位)
type ViewRow = {
  type: ExceptionType;
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
};

type ExceptionCounts = Record<Tab, number>;

const EMPTY_COUNTS: ExceptionCounts = {
  all: 0, po_shortage: 0, po_damage: 0, po_over: 0, transfer_short: 0, customer_shortage: 0,
};

function docLinkFor(r: ViewRow): string {
  if (r.type === "customer_shortage") return `/orders?id=${r.customer_order_id}`;
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
  const [rows, setRows] = useState<ExceptionRow[] | null>(null);
  const [counts, setCounts] = useState<ExceptionCounts | null>(null);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("all");
  const [resolveCtx, setResolveCtx] = useState<ShortageContext | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [busy, setBusy] = useState<number | null>(null);
  const [page, setPage] = useState(1);
  const [prevTab, setPrevTab] = useState<Tab>(tab);

  async function handleCustomerShortageAction(
    orderId: number,
    action: "notified" | "cancelled" | "waiting_next_po" | "reallocated",
  ) {
    const labelMap: Record<typeof action, string> = {
      notified: "通知客戶(標記已通知)",
      cancelled: "取消(請去訂單頁正式取消退款)",
      waiting_next_po: "等下批 PO 補貨",
      reallocated: "改派(從其他店調貨)",
    };
    if (!confirm(`確定:${labelMap[action]}?`)) return;
    setBusy(orderId);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: err } = await sb.rpc("rpc_handle_shortage_order", {
        p_order_id: orderId,
        p_action: action,
        p_operator: operator,
      });
      if (err) throw err;
      setReloadTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  // 切換分頁籤 → 回第 1 頁(render 階段調整 state,非 effect → 不觸發 set-state-in-effect,也不會 flash 舊頁)
  if (prevTab !== tab) {
    setPrevTab(tab);
    setPage(1);
  }

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

        const mapped: ExceptionRow[] = (resp.rows ?? []).map((r) => ({
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
          customer_order_id: r.customer_order_id ?? undefined,
          shortage_resolution: r.shortage_resolution,
        }));

        const cnts: ExceptionCounts = {
          all: resp.counts?.all ?? 0,
          po_shortage: resp.counts?.po_shortage ?? 0,
          po_damage: resp.counts?.po_damage ?? 0,
          po_over: resp.counts?.po_over ?? 0,
          transfer_short: resp.counts?.transfer_short ?? 0,
          customer_shortage: resp.counts?.customer_shortage ?? 0,
        };

        setRows(mapped);
        setTotal(resp.total ?? 0);
        setCounts(cnts);
        setError(null);
        if (onCountChange) onCountChange(cnts.all);

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
            {counts === null ? "載入中…" : `共 ${c.all} 筆異常 · 進貨短少 ${c.po_shortage} / 進貨破損 ${c.po_damage} / 過量 ${c.po_over} / 收貨短少 ${c.transfer_short} / 訂單短少 ${c.customer_shortage}`}
          </p>
        </header>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {(["all", "po_shortage", "po_damage", "po_over", "transfer_short", "customer_shortage"] as const).map((t) => {
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

      {/* 分頁 — 表格上方(手機優先看得到) */}
      {paginationBar}

      <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">類型</th>
              <th className="px-3 py-2">單號</th>
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
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={8} className="p-6 text-center text-zinc-500">沒有異常,系統運作正常 ✓</td></tr>
            ) : rows.map((r) => (
              <tr key={r.key} className="hover:bg-zinc-50 dark:hover:bg-zinc-950">
                <td className="px-3 py-2 whitespace-nowrap">
                  <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ${
                    r.type === "po_shortage" ? "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300" :
                    r.type === "po_damage" ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300" :
                    r.type === "po_over" ? "bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300" :
                    r.type === "transfer_short" ? "bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300" :
                    "bg-fuchsia-100 text-fuchsia-800 dark:bg-fuchsia-950 dark:text-fuchsia-300"
                  }`}>{TAB_LABEL[r.type]}</span>
                </td>
                <td className="px-3 py-2 font-mono text-xs whitespace-nowrap">{r.doc_no}</td>
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
                  {r.type === "transfer_short" && r.shortage_ctx ? (
                    <SpinButton
                      onClick={() => setResolveCtx(r.shortage_ctx ?? null)}
                      className="rounded-md bg-blue-600 px-3 py-1 text-xs font-semibold text-white hover:bg-blue-700"
                    >
                      處理
                    </SpinButton>
                  ) : r.type === "customer_shortage" && r.customer_order_id ? (
                    r.shortage_resolution ? (
                      <Link href={r.doc_link} className="text-blue-600 hover:underline dark:text-blue-400">看訂單 →</Link>
                    ) : (
                      <div className="flex flex-nowrap justify-end gap-1">
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "notified")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-blue-300 bg-blue-50 px-2 py-0.5 text-[11px] text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
                        >
                          通知客戶
                        </SpinButton>
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "waiting_next_po")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-amber-300 bg-amber-50 px-2 py-0.5 text-[11px] text-amber-700 hover:bg-amber-100 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300"
                        >
                          等下批
                        </SpinButton>
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "reallocated")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-emerald-300 bg-emerald-50 px-2 py-0.5 text-[11px] text-emerald-700 hover:bg-emerald-100 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
                        >
                          改派
                        </SpinButton>
                        <SpinButton
                          onClick={() => handleCustomerShortageAction(r.customer_order_id!, "cancelled")}
                          disabled={busy === r.customer_order_id}
                          className="rounded border border-rose-300 bg-rose-50 px-2 py-0.5 text-[11px] text-rose-700 hover:bg-rose-100 dark:border-rose-700 dark:bg-rose-950 dark:text-rose-300"
                        >
                          取消退款
                        </SpinButton>
                      </div>
                    )
                  ) : (
                    <Link href={r.doc_link} className="text-blue-600 hover:underline dark:text-blue-400">前往 →</Link>
                  )}
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
    </div>
  );
}
