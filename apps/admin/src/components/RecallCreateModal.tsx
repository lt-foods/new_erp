"use client";

// 召回開單：從「總倉收件匣 → 撿貨單 → 已完成」那一列發起。
//
// 掃描該張撿貨單每一格 (店 × 品項) 的狀態分佈，讓倉管逐格填要召回多少。
// 三個桶（在途 / 店裡未取 / 客人已取）就是回收難度，也是之後對帳的基準：
//   在途   → 總倉可整張攔截
//   店裡   → 店端出貨退回總倉
//   客人   → 要聯繫客人拿回來
// 見 supabase/migrations/20260808000100_recall_schema.sql 與 docs/PRD-召回模組.md。

import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Modal } from "@/components/Modal";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { orderStatusLabel } from "@/lib/orderStatus";

export type RecallCell = {
  store_id: number;
  store_name: string;
  sku_id: number;
  sku_code: string;
  sku_name: string;
  campaign_id: number | null;
  campaign_count: number;
  transfer_id: number | null;
  transfer_no: string | null;
  transfer_status: string | null;
  wave_qty: number;
  qty_shipped: number;
  qty_in_transit: number;
  qty_received: number;
  qty_cancelled: number;
  qty_unpicked: number;
  qty_picked_up: number;
  order_count: number;
  order_match: "wave" | "store_sku";
  qty_returned: number;
  qty_pending_recall: number;
  store_on_hand: number;
  qty_recallable: number;
};

type ScanResult = {
  wave_id: number;
  wave_code: string;
  wave_date: string;
  wave_status: string;
  cells: RecallCell[];
};

type OrderRow = {
  item_id: number;
  order_id: number;
  order_no: string;
  customer: string | null;
  order_status: string;
  item_status: string;
  qty: number;
  wallet_paid: number;
  created_at: string;
};

const REASON_OPTIONS: { value: string; label: string }[] = [
  { value: "wrong_sku", label: "派錯商品" },
  { value: "wrong_qty", label: "派錯數量（多派）" },
  { value: "wrong_store", label: "派錯分店" },
  { value: "quality", label: "品質異常 / 破損" },
  { value: "expiry", label: "效期問題" },
  { value: "supplier_recall", label: "供應商召回" },
  { value: "other", label: "其他" },
];

const num = (v: unknown) => Number(v ?? 0);
const cellKey = (c: { store_id: number; sku_id: number }) => `${c.store_id}-${c.sku_id}`;

export function RecallCreateModal({
  open,
  waveId,
  waveCode,
  onClose,
}: {
  open: boolean;
  waveId: number | null;
  waveCode: string;
  onClose: () => void;
}) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [scan, setScan] = useState<ScanResult | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [reasonCode, setReasonCode] = useState("wrong_sku");
  const [reason, setReason] = useState("");
  const [notes, setNotes] = useState("");
  const [expanded, setExpanded] = useState<string | null>(null);
  const [orders, setOrders] = useState<Record<string, OrderRow[]>>({});
  const [issueNow, setIssueNow] = useState(true);

  const load = useCallback(async () => {
    if (!waveId) return;
    setLoading(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_recall_scan_wave", { p_wave_id: waveId });
      if (error) throw error;
      setScan(data as ScanResult);
      setQty({});
    } catch (e) {
      setErr(translateRpcError(e));
    } finally {
      setLoading(false);
    }
  }, [waveId]);

  useEffect(() => {
    if (open) void load();
    else {
      setScan(null);
      setQty({});
      setExpanded(null);
      setOrders({});
      setErr(null);
    }
  }, [open, load]);

  // useMemo：`scan?.cells ?? []` 每次 render 都是新陣列，下面兩個 useMemo 會白算
  const cells = useMemo(() => scan?.cells ?? [], [scan]);

  const totals = useMemo(() => {
    let target = 0;
    let inTransit = 0;
    let unpicked = 0;
    let pickedUp = 0;
    for (const c of cells) {
      const t = Number(qty[cellKey(c)] ?? 0);
      if (!t || t <= 0) continue;
      target += t;
      // 與後端 rpc_create_recall 同一套瀑布：在途 → 店裡未取 → 客人已取
      let left = t;
      const a = Math.min(left, num(c.qty_in_transit));
      left -= a;
      const b = Math.min(left, Math.max(num(c.qty_unpicked), 0));
      left -= b;
      const cQty = Math.min(left, Math.max(num(c.qty_picked_up), 0));
      left -= cQty;
      inTransit += a;
      unpicked += b + left; // 多派的部分沒有訂單對應，一樣是店端退回
      pickedUp += cQty;
    }
    return { target, inTransit, unpicked, pickedUp };
  }, [cells, qty]);

  const selectedCount = useMemo(
    () => cells.filter((c) => Number(qty[cellKey(c)] ?? 0) > 0).length,
    [cells, qty],
  );

  function setAll(mode: "all" | "unpicked" | "clear") {
    const next: Record<string, string> = {};
    if (mode !== "clear") {
      for (const c of cells) {
        const v =
          mode === "all"
            ? num(c.qty_recallable)
            : Math.min(num(c.qty_recallable), num(c.qty_in_transit) + num(c.qty_unpicked));
        if (v > 0) next[cellKey(c)] = String(v);
      }
    }
    setQty(next);
  }

  async function toggleOrders(c: RecallCell) {
    const k = cellKey(c);
    if (expanded === k) {
      setExpanded(null);
      return;
    }
    setExpanded(k);
    if (orders[k]) return;
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_recall_scan_orders", {
        p_wave_id: waveId,
        p_store_id: c.store_id,
        p_sku_id: c.sku_id,
      });
      if (error) throw error;
      setOrders((prev) => ({ ...prev, [k]: (data ?? []) as OrderRow[] }));
    } catch (e) {
      setErr(translateRpcError(e));
    }
  }

  async function submit() {
    if (!waveId) return;
    const lines = cells
      .map((c) => ({ store_id: c.store_id, sku_id: c.sku_id, qty: Number(qty[cellKey(c)] ?? 0) }))
      .filter((l) => l.qty > 0);
    if (lines.length === 0) {
      setErr("請至少填一格要召回的數量");
      return;
    }
    setErr(null);
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_create_recall", {
        p_wave_id: waveId,
        p_reason_code: reasonCode,
        p_reason: reason || null,
        p_lines: lines,
        p_notes: notes || null,
      });
      if (error) throw error;
      const recallId = (data as { recall_id: number }).recall_id;

      if (issueNow) {
        const { error: e2 } = await sb.rpc("rpc_issue_recall", { p_recall_id: recallId });
        if (e2) {
          // 建單成功、發布失敗：不要吞掉，帶使用者去明細頁自己按發布
          setErr(`召回單已建立，但發布失敗：${translateRpcError(e2)}`);
          router.push(`/recalls/detail?id=${recallId}`);
          return;
        }
      }
      onClose();
      router.push(`/recalls/detail?id=${recallId}`);
    } catch (e) {
      setErr(translateRpcError(e));
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`🚨 發起召回 — ${waveCode}`} maxWidth="max-w-7xl">
      {loading ? (
        <div className="flex justify-center py-10">
          <Spinner />
        </div>
      ) : (
        <div className="space-y-4">
          {err && (
            <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-300">
              {err}
            </div>
          )}

          <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-xs leading-relaxed text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
            召回會依「回收難易」把數量分成三桶：
            <b className="mx-1">在途</b>（貨還沒到店，總倉可整張攔截）、
            <b className="mx-1">店裡未取</b>（會取消 / 拆分對應的顧客訂單品項，客人不會被收這筆錢）、
            <b className="mx-1">客人已取</b>（要聯繫客人拿回來）。
            送出後可在召回單明細頁比對「要召回 vs 實際回來」。
          </div>

          {/* 原因 */}
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="text-sm">
              <span className="mb-1 block text-zinc-600 dark:text-zinc-400">召回原因</span>
              <select
                value={reasonCode}
                onChange={(e) => setReasonCode(e.target.value)}
                className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
              >
                {REASON_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-sm sm:col-span-2">
              <span className="mb-1 block text-zinc-600 dark:text-zinc-400">說明（會顯示在召回單上）</span>
              <input
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="例：G00123-05 派成 G00123-06"
                className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
              />
            </label>
          </div>

          {/* 快捷 */}
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <span className="text-zinc-500">快速填入：</span>
            <SpinButton
              onClick={() => setAll("all")}
              className="rounded border border-red-300 bg-red-50 px-2 py-1 font-medium text-red-700 hover:bg-red-100 dark:border-red-800 dark:bg-red-950 dark:text-red-300"
            >
              全部召回
            </SpinButton>
            <SpinButton
              onClick={() => setAll("unpicked")}
              className="rounded border border-amber-300 bg-amber-50 px-2 py-1 font-medium text-amber-700 hover:bg-amber-100 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300"
            >
              只召回還沒被客人取走的
            </SpinButton>
            <SpinButton
              onClick={() => setAll("clear")}
              className="rounded border border-zinc-300 bg-white px-2 py-1 text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400"
            >
              清空
            </SpinButton>
          </div>

          {/* 矩陣 */}
          <div className="overflow-x-auto rounded border border-zinc-200 dark:border-zinc-800">
            <table className="w-full min-w-[980px] text-sm">
              <thead className="bg-zinc-50 text-xs text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
                <tr>
                  <th className="px-3 py-2 text-left">分店</th>
                  <th className="px-3 py-2 text-left">品項</th>
                  <th className="px-2 py-2 text-right">派出</th>
                  <th className="px-2 py-2 text-right" title="派貨單還是「運送中」，店家還沒收貨">
                    在途
                  </th>
                  <th className="px-2 py-2 text-right" title="已到店、顧客訂單還沒取貨">
                    店裡未取
                  </th>
                  <th className="px-2 py-2 text-right" title="客人已經領走，要聯繫客人拿回">
                    客人已取
                  </th>
                  <th className="px-2 py-2 text-right" title="店端庫存帳上現有數">
                    店端庫存
                  </th>
                  <th className="px-2 py-2 text-right">已退回</th>
                  <th className="px-2 py-2 text-right">可召回</th>
                  <th className="px-3 py-2 text-right">召回數量</th>
                  <th className="px-2 py-2" />
                </tr>
              </thead>
              <tbody>
                {cells.length === 0 && (
                  <tr>
                    <td colSpan={11} className="px-3 py-6 text-center text-zinc-500">
                      這張撿貨單沒有可召回的品項
                    </td>
                  </tr>
                )}
                {cells.map((c) => {
                  const k = cellKey(c);
                  const v = qty[k] ?? "";
                  const over = Number(v || 0) > num(c.qty_recallable);
                  const rows = orders[k];
                  return (
                    <Fragment key={k}>
                      <tr className="border-t border-zinc-200 dark:border-zinc-800">
                        <td className="px-3 py-1.5 whitespace-nowrap">
                          {c.store_name}
                          {c.transfer_no && (
                            <span className="ml-1 text-[11px] text-zinc-400">{c.transfer_no}</span>
                          )}
                        </td>
                        <td className="px-3 py-1.5">
                          <span className="font-mono text-xs">{c.sku_code}</span>
                          <span className="ml-1 text-zinc-500">{c.sku_name}</span>
                          {c.order_match === "store_sku" && (
                            <span
                              className="ml-1 rounded bg-amber-100 px-1 text-[10px] text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                              title="這一格對不到開團，訂單量是用「店 + 品項」推的約略值，可能含其他團的訂單"
                            >
                              約略
                            </span>
                          )}
                        </td>
                        <td className="px-2 py-1.5 text-right tabular-nums">{num(c.qty_shipped)}</td>
                        <td className="px-2 py-1.5 text-right tabular-nums">
                          {num(c.qty_in_transit) > 0 ? (
                            <span className="rounded bg-sky-100 px-1.5 font-semibold text-sky-800 dark:bg-sky-950 dark:text-sky-300">
                              {num(c.qty_in_transit)}
                            </span>
                          ) : (
                            <span className="text-zinc-300">0</span>
                          )}
                        </td>
                        <td className="px-2 py-1.5 text-right tabular-nums">{num(c.qty_unpicked)}</td>
                        <td className="px-2 py-1.5 text-right tabular-nums">
                          {num(c.qty_picked_up) > 0 ? (
                            <span className="rounded bg-rose-100 px-1.5 font-semibold text-rose-800 dark:bg-rose-950 dark:text-rose-300">
                              {num(c.qty_picked_up)}
                            </span>
                          ) : (
                            <span className="text-zinc-300">0</span>
                          )}
                        </td>
                        <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">
                          {num(c.store_on_hand)}
                        </td>
                        <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">
                          {num(c.qty_returned)}
                        </td>
                        <td className="px-2 py-1.5 text-right font-semibold tabular-nums">
                          {num(c.qty_recallable)}
                        </td>
                        <td className="px-3 py-1.5 text-right">
                          <input
                            type="number"
                            min={0}
                            max={num(c.qty_recallable)}
                            value={v}
                            onChange={(e) => setQty((p) => ({ ...p, [k]: e.target.value }))}
                            className={`w-20 rounded border px-2 py-1 text-right text-sm tabular-nums ${
                              over
                                ? "border-red-500 bg-red-50 dark:bg-red-950"
                                : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900"
                            }`}
                          />
                        </td>
                        <td className="px-2 py-1.5">
                          <SpinButton
                            onClick={() => toggleOrders(c)}
                            className="rounded border border-zinc-300 px-1.5 py-0.5 text-[11px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400"
                            title="看這一格背後有哪些顧客訂單"
                          >
                            {expanded === k ? "收合" : `訂單 ${num(c.order_count)}`}
                          </SpinButton>
                        </td>
                      </tr>
                      {expanded === k && (
                        <tr className="bg-zinc-50 dark:bg-zinc-950">
                          <td colSpan={11} className="px-6 py-2">
                            {!rows ? (
                              <Spinner />
                            ) : rows.length === 0 ? (
                              <div className="text-xs text-zinc-500">沒有對應的顧客訂單（總倉多派的量）</div>
                            ) : (
                              <table className="w-full text-xs">
                                <thead className="text-zinc-500">
                                  <tr>
                                    <th className="py-1 text-left">訂單</th>
                                    <th className="py-1 text-left">客人</th>
                                    <th className="py-1 pr-3 text-right">數量</th>
                                    <th className="py-1 pl-3 text-left">品項狀態</th>
                                    <th className="py-1 text-left">訂單狀態</th>
                                    <th className="py-1 text-right">已用儲值金</th>
                                  </tr>
                                </thead>
                                <tbody>
                                  {rows.map((o) => (
                                    <tr key={o.item_id} className="border-t border-zinc-200 dark:border-zinc-800">
                                      <td className="py-1 font-mono">{o.order_no}</td>
                                      <td className="py-1">{o.customer ?? "—"}</td>
                                      <td className="py-1 pr-3 text-right tabular-nums">{num(o.qty)}</td>
                                      <td className="py-1 pl-3">
                                        {o.item_status === "picked_up" ? (
                                          <span className="rounded bg-rose-100 px-1 text-rose-800 dark:bg-rose-950 dark:text-rose-300">
                                            已取走
                                          </span>
                                        ) : (
                                          <span className="text-zinc-500">未取</span>
                                        )}
                                      </td>
                                      <td className="py-1 text-zinc-500">{orderStatusLabel(o.order_status)}</td>
                                      <td className="py-1 text-right tabular-nums">
                                        {num(o.wallet_paid) > 0 ? (
                                          <span className="font-semibold text-amber-700 dark:text-amber-400">
                                            {num(o.wallet_paid)}
                                          </span>
                                        ) : (
                                          <span className="text-zinc-300">0</span>
                                        )}
                                      </td>
                                    </tr>
                                  ))}
                                </tbody>
                              </table>
                            )}
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* 合計 */}
          <div className="flex flex-wrap items-center gap-4 rounded border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm dark:border-zinc-800 dark:bg-zinc-900">
            <span>
              共 <b>{selectedCount}</b> 格 · 召回總量{" "}
              <b className="text-red-700 dark:text-red-400">{totals.target}</b>
            </span>
            <span className="text-xs text-zinc-500">
              在途攔截 {totals.inTransit} · 店端退回 {totals.unpicked} · 待客人歸還{" "}
              <b className={totals.pickedUp > 0 ? "text-rose-600 dark:text-rose-400" : ""}>
                {totals.pickedUp}
              </b>
            </span>
          </div>

          <label className="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              checked={issueNow}
              onChange={(e) => setIssueNow(e.target.checked)}
              className="mt-1"
            />
            <span>
              建立後立即發布
              <span className="ml-1 text-xs text-zinc-500">
                （發布會取消 / 拆分「店裡未取」的顧客訂單品項；不勾則先存成草稿，之後可再修改）
              </span>
            </span>
          </label>

          <label className="block text-sm">
            <span className="mb-1 block text-zinc-600 dark:text-zinc-400">內部備註</span>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
            />
          </label>

          <div className="flex justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
            <SpinButton
              onClick={onClose}
              className="rounded border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              取消
            </SpinButton>
            <SpinButton
              onClick={submit}
              disabled={totals.target <= 0}
              className="rounded bg-red-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
            >
              {issueNow ? `建立並發布召回（共 ${totals.target}）` : `建立草稿（共 ${totals.target}）`}
            </SpinButton>
          </div>
        </div>
      )}
    </Modal>
  );
}

export default RecallCreateModal;
