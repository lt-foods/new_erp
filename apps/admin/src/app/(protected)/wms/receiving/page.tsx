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
  expected_date: string | null;
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  total_qty_ordered: number;
  total_qty_received: number;
  line_count: number;
  is_restock: boolean;
};

type Filter = "today" | "this_week" | "all";

export default function ReceivingWorkbenchPage() {
  const [rows, setRows] = useState<PORow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>("this_week");
  const [statusFilter, setStatusFilter] = useState<"pending" | "all">("pending");
  const [detailPoId, setDetailPoId] = useState<number | null>(null);
  const [detailPoNo, setDetailPoNo] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: poData, error: e } = await sb
          .from("purchase_orders")
          .select("id, po_no, status, sent_at, expected_date, supplier_id")
          .in("status", ["sent", "partially_received", "fully_received"])
          .order("sent_at", { ascending: false, nullsFirst: false })
          .limit(200);
        if (e) throw new Error(e.message);
        const pos = (poData ?? []) as Array<Pick<PORow, "id" | "po_no" | "status" | "sent_at" | "expected_date" | "supplier_id">>;

        if (pos.length === 0) {
          if (!cancelled) { setRows([]); setError(null); }
          return;
        }

        const poIds = pos.map((p) => p.id);
        const supplierIds = Array.from(new Set(pos.map((p) => p.supplier_id)));

        const [{ data: supRows }, { data: poiRows }, { data: griRows }] = await Promise.all([
          sb.from("suppliers").select("id, code, name").in("id", supplierIds),
          sb.from("purchase_order_items").select("id, po_id, qty_ordered").in("po_id", poIds),
          sb.from("goods_receipt_items")
            .select("po_item_id, qty_received, gr:goods_receipts!inner(po_id, status)")
            .in("gr.po_id", poIds)
            .eq("gr.status", "confirmed"),
        ]);
        // 偵測 restock-sourced
        const { data: restockPos } = await sb
          .from("restock_requests")
          .select("linked_pr_id")
          .not("linked_pr_id", "is", null);
        const restockPrIds = new Set(((restockPos ?? []) as { linked_pr_id: number }[]).map((r) => r.linked_pr_id));
        const { data: priRows } = await sb
          .from("purchase_request_items")
          .select("po_item_id, pr_id")
          .in("po_item_id", (poiRows ?? []).map((p: { id: number }) => p.id));
        const restockPoItemIds = new Set(
          ((priRows ?? []) as { po_item_id: number | null; pr_id: number }[])
            .filter((r) => r.po_item_id !== null && restockPrIds.has(r.pr_id))
            .map((r) => r.po_item_id as number),
        );

        const supMap = new Map<number, { code: string | null; name: string }>();
        for (const s of (supRows ?? []) as { id: number; code: string | null; name: string }[]) supMap.set(s.id, { code: s.code, name: s.name });

        const poiByPo = new Map<number, { id: number; qty_ordered: number }[]>();
        for (const it of (poiRows ?? []) as { id: number; po_id: number; qty_ordered: number }[]) {
          const arr = poiByPo.get(it.po_id) ?? [];
          arr.push(it);
          poiByPo.set(it.po_id, arr);
        }

        const grByPoItem = new Map<number, number>();
        for (const it of ((griRows ?? []) as Array<{ po_item_id: number; qty_received: number }>)) {
          grByPoItem.set(it.po_item_id, (grByPoItem.get(it.po_item_id) ?? 0) + Number(it.qty_received));
        }

        const result: PORow[] = pos.map((po) => {
          const items = poiByPo.get(po.id) ?? [];
          const totalOrdered = items.reduce((s, i) => s + Number(i.qty_ordered), 0);
          const totalReceived = items.reduce((s, i) => s + (grByPoItem.get(i.id) ?? 0), 0);
          const isRestock = items.some((i) => restockPoItemIds.has(i.id));
          const sup = supMap.get(po.supplier_id);
          return {
            id: po.id,
            po_no: po.po_no,
            status: po.status as POStatus,
            sent_at: po.sent_at,
            expected_date: po.expected_date,
            supplier_id: po.supplier_id,
            supplier_name: sup?.name ?? `#${po.supplier_id}`,
            supplier_code: sup?.code ?? null,
            total_qty_ordered: totalOrdered,
            total_qty_received: totalReceived,
            line_count: items.length,
            is_restock: isRestock,
          };
        });

        if (!cancelled) {
          setRows(result);
          setError(null);
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const filtered = useMemo(() => {
    if (!rows) return [];
    const now = new Date();
    const today = now.toISOString().slice(0, 10);
    const weekAgo = new Date(now);
    weekAgo.setDate(weekAgo.getDate() - 7);
    const weekAgoStr = weekAgo.toISOString().slice(0, 10);

    return rows.filter((r) => {
      if (statusFilter === "pending" && r.status === "fully_received") return false;
      if (filter === "today") {
        const dateRef = r.sent_at?.slice(0, 10) ?? "";
        if (dateRef !== today) return false;
      }
      if (filter === "this_week") {
        const dateRef = r.sent_at?.slice(0, 10) ?? "";
        if (!dateRef || dateRef < weekAgoStr) return false;
      }
      return true;
    });
  }, [rows, filter, statusFilter]);

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

  // 「明天到貨」:還沒全收(sent/partial)且預計到貨日 = 明天
  const tomorrowSummary = useMemo(() => {
    if (!rows) return { poCount: 0, itemCount: 0, remainingQty: 0 };
    const tomorrow = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    const tomorrowStr = tomorrow.toLocaleDateString("sv-SE");
    return rows.reduce(
      (acc, r) => {
        if (r.status === "fully_received") return acc;
        if (r.expected_date !== tomorrowStr) return acc;
        acc.poCount += 1;
        acc.itemCount += r.line_count;
        acc.remainingQty += Math.max(0, r.total_qty_ordered - r.total_qty_received);
        return acc;
      },
      { poCount: 0, itemCount: 0, remainingQty: 0 },
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
          採購訂單列表 →
        </Link>
      </header>

      {/* KPI bar */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="🔴 未收" value={counts.sent} accent="text-rose-700 dark:text-rose-400" />
        <Stat label="⏳ 部分收" value={counts.partial} accent="text-amber-700 dark:text-amber-400" />
        <Stat label="✓ 全收" value={counts.full} accent="text-emerald-700 dark:text-emerald-400" />
        <Stat label="🔁 補貨來源" value={counts.restock} accent="text-indigo-700 dark:text-indigo-400" />
      </div>

      {/* 明天到貨摘要 */}
      <div className="flex flex-wrap items-center gap-3 rounded-md border border-blue-200 bg-blue-50 px-3 py-2 text-sm dark:border-blue-900 dark:bg-blue-950/40">
        <span className="font-medium text-blue-900 dark:text-blue-200">🚚 明天到貨</span>
        {tomorrowSummary.poCount === 0 ? (
          <span className="text-zinc-500 dark:text-zinc-400">無</span>
        ) : (
          <>
            <span className="text-blue-900 dark:text-blue-200">
              <span className="font-mono font-semibold">{tomorrowSummary.poCount}</span> 張 PO
            </span>
            <span className="text-blue-900 dark:text-blue-200">
              <span className="font-mono font-semibold">{tomorrowSummary.itemCount}</span> 樣品項
            </span>
            <span className="text-blue-900 dark:text-blue-200">
              待收 <span className="font-mono font-semibold">{tomorrowSummary.remainingQty}</span> 件
            </span>
          </>
        )}
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
        <span className="ml-3 text-xs text-zinc-500">狀態:</span>
        {(["pending", "all"] as const).map((s) => (
          <SpinButton
            key={s}
            onClick={() => setStatusFilter(s)}
            className={`rounded-full border px-3 py-1 text-xs ${
              statusFilter === s
                ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300"
            }`}
          >
            {s === "pending" ? "待收(未收+部分收)" : "全部含已全收"}
          </SpinButton>
        ))}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* List */}
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

      <Modal
        open={detailPoId !== null}
        onClose={() => setDetailPoId(null)}
        title={`採購單到貨進度 ${detailPoNo}`}
        maxWidth="max-w-4xl"
      >
        {detailPoId !== null && <POReceiptTimeline poId={detailPoId} />}
      </Modal>
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
