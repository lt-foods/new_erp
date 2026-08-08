"use client";

// 召回單明細 / 對帳頁 —— 這頁就是「比對確認召回數量有沒有正確」的那個畫面。
//
// 每一格 (店 × 品項) 一列：
//   左半邊  目標量，以及開單當下的三桶快照（在途 / 店裡未取 / 客人已取）
//   右半邊  實際回收：攔截 + 店端退回（已被總倉收貨）+ 沖銷
//   差額    = 已回收 + 沖銷 − 目標。0 才是綠燈，負數紅字＝還沒回夠。
//
// 回收量全部是推導值（v_recall_line_progress），總倉照既有 /wms/inbound 收貨，
// 這頁的數字自己會動 —— 沒有需要人工按「已收到」的同步步驟。

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";
import { orderStatusLabel } from "@/lib/orderStatus";
import { REASON_LABEL } from "../page";

type Header = {
  recall_id: number;
  recall_no: string;
  source_wave_id: number | null;
  wave_code: string | null;
  wave_date: string | null;
  reason_code: string;
  reason: string | null;
  status: "draft" | "issued" | "completed" | "cancelled";
  issued_at: string | null;
  completed_at: string | null;
  notes: string | null;
  created_at: string;
  total_target: number;
  total_intercepted: number;
  total_returned: number;
  total_in_return: number;
  total_written_off: number;
  total_recovered: number;
  total_outstanding: number;
  total_customer_held: number;
  open_line_count: number;
  open_store_count: number;
  store_count: number;
  sku_count: number;
};

type Line = {
  line_id: number;
  store_id: number;
  store_name: string;
  sku_id: number;
  sku_code: string;
  sku_name: string;
  source_transfer_id: number | null;
  qty_dispatched: number;
  qty_target: number;
  snap_in_transit: number;
  snap_unpicked: number;
  snap_picked_up: number;
  qty_written_off: number;
  written_off_reason: string | null;
  settled_at: string | null;
  qty_intercepted: number;
  qty_returned_by_transfer: number;
  qty_in_return: number;
  qty_order_cancelled: number;
  qty_recovered: number;
  qty_diff: number;
};

type EventRow = {
  id: number;
  line_id: number | null;
  event_type: string;
  qty: number | null;
  ref_type: string | null;
  ref_id: number | null;
  payload: Record<string, unknown> | null;
  note: string | null;
  created_at: string;
};

type OrderRow = {
  order_id: number;
  order_no: string;
  store_id: number;
  store_name: string;
  customer: string | null;
  order_status: string;
  recalled_qty: number;
  sku_codes: string;
  wallet_paid: number;
  payment_status: string;
  needs_refund: boolean;
};

type Detail = {
  header: Header;
  lines: Line[];
  events: EventRow[];
  orders: OrderRow[];
  is_store: boolean;
};

const EVENT_LABEL: Record<string, string> = {
  created: "建立召回單",
  issued: "發布召回",
  order_cancelled: "取消訂單品項",
  order_split: "拆單（部分召回）",
  intercepted: "在途攔截",
  store_shipped: "店端出貨退回",
  customer_return: "客人歸還",
  written_off: "沖銷",
  completed: "結案",
  cancelled: "作廢",
  note: "備註",
};

const num = (v: unknown) => Number(v ?? 0);

export default function RecallDetailPage() {
  const [id, setId] = useState<number | null>(null);
  const [d, setD] = useState<Detail | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [shipQty, setShipQty] = useState<Record<number, string>>({});
  const [writeOff, setWriteOff] = useState<{ line: Line; qty: string; reason: string } | null>(null);
  const [showEvents, setShowEvents] = useState(false);

  useEffect(() => {
    const raw = new URLSearchParams(window.location.search).get("id");
    setId(raw ? Number(raw) : null);
  }, []);

  const load = useCallback(async () => {
    if (!id) return;
    setLoading(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data, error } = await sb.rpc("rpc_recall_detail", { p_recall_id: id });
      if (error) throw error;
      setD(data as Detail);
    } catch (e) {
      setErr(translateRpcError(e));
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    void load();
  }, [load]);

  async function call(fn: string, args: Record<string, unknown>, okMsg: string) {
    setErr(null);
    setMsg(null);
    try {
      const sb = getSupabase();
      const { error } = await sb.rpc(fn, args);
      if (error) throw error;
      setMsg(okMsg);
      await load();
    } catch (e) {
      setErr(translateRpcError(e));
    }
  }

  // 店端把某一格的貨出庫退回總倉。同一家店的多個品項合成一張退貨單送出。
  async function shipStore(storeId: number) {
    if (!d || !id) return;
    const lines = d.lines
      .filter((l) => l.store_id === storeId)
      .map((l) => ({ sku_id: l.sku_id, qty: Number(shipQty[l.line_id] ?? 0) }))
      .filter((l) => l.qty > 0);
    if (lines.length === 0) {
      setErr("請先填要退回的數量");
      return;
    }
    await call(
      "rpc_recall_store_ship",
      { p_recall_id: id, p_store_id: storeId, p_lines: lines, p_notes: null },
      "已建立退貨單，等總倉收貨後對帳數字會更新",
    );
    setShipQty({});
  }

  if (loading) {
    return (
      <div className="flex justify-center py-16">
        <Spinner />
      </div>
    );
  }
  if (!d) {
    return (
      <div className="p-6">
        <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-300">
          {err ?? "找不到召回單"}
        </div>
        <Link href="/recalls" className="mt-3 inline-block text-sm text-blue-600 underline dark:text-blue-400">
          ← 回召回單列表
        </Link>
      </div>
    );
  }

  const h = d.header;
  const stores = Array.from(new Set(d.lines.map((l) => l.store_id)));
  const canAct = h.status === "issued";
  const outstanding = num(h.total_outstanding);

  return (
    <div className="p-4 sm:p-6">
      <Link href="/recalls" className="text-sm text-blue-600 underline dark:text-blue-400">
        ← 召回單列表
      </Link>

      {/* 單頭 */}
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="flex items-center gap-2 text-lg font-semibold">
            🚨 {h.recall_no}
            <span
              className={`rounded px-2 py-0.5 text-xs font-medium ${
                h.status === "completed"
                  ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : h.status === "issued"
                    ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                    : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
              }`}
            >
              {h.status === "draft"
                ? "草稿"
                : h.status === "issued"
                  ? "回收中"
                  : h.status === "completed"
                    ? "已結案"
                    : "已作廢"}
            </span>
          </h1>
          <p className="mt-1 text-xs text-zinc-500">
            {REASON_LABEL[h.reason_code] ?? h.reason_code}
            {h.reason && ` · ${h.reason}`}
            {h.wave_code && ` · 來源撿貨單 ${h.wave_code}（${h.wave_date}）`}
          </p>
          {h.notes && <p className="mt-1 text-xs text-zinc-500">備註：{h.notes}</p>}
        </div>

        {!d.is_store && (
          <div className="flex flex-wrap gap-2">
            {h.status === "draft" && (
              <>
                <SpinButton
                  onClick={() => call("rpc_issue_recall", { p_recall_id: id }, "已發布召回")}
                  className="rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700"
                  title="會取消 / 拆分「店裡未取」的顧客訂單品項"
                >
                  發布召回
                </SpinButton>
                <SpinButton
                  onClick={() => call("rpc_cancel_recall", { p_recall_id: id, p_reason: null }, "已作廢")}
                  className="rounded border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  作廢草稿
                </SpinButton>
              </>
            )}
            {h.status === "issued" && (
              <SpinButton
                onClick={() => call("rpc_close_recall", { p_recall_id: id }, "召回單已結案")}
                disabled={outstanding > 0}
                title={outstanding > 0 ? `還有 ${outstanding} 件沒回收或沖銷` : "全部回收完成，結案"}
                className="rounded bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-40"
              >
                結案
              </SpinButton>
            )}
          </div>
        )}
      </div>

      {err && (
        <div className="mt-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-300">
          {err}
        </div>
      )}
      {msg && (
        <div className="mt-3 rounded border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          {msg}
        </div>
      )}

      {/* KPI */}
      <div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6">
        <Kpi label="召回目標" value={num(h.total_target)} tone="plain" />
        <Kpi label="在途攔截" value={num(h.total_intercepted)} tone="sky" />
        <Kpi label="已回總倉" value={num(h.total_returned)} tone="emerald" />
        <Kpi label="退貨在途" value={num(h.total_in_return)} tone="sky" hint="店端已出貨、總倉還沒收" />
        <Kpi label="沖銷" value={num(h.total_written_off)} tone="zinc" hint="追不回、人工結案" />
        <Kpi
          label="尚未回收"
          value={outstanding}
          tone={outstanding > 0 ? "red" : "emerald"}
          hint={outstanding > 0 ? `${num(h.open_store_count)} 家店還沒回完` : "全部回收完成"}
        />
      </div>

      {/* 對帳表 */}
      <h2 className="mt-6 mb-2 text-sm font-semibold">
        對帳明細
        <span className="ml-2 text-xs font-normal text-zinc-500">
          差額 = 攔截 + 已回總倉 + 沖銷 − 目標；0 才算回收完成
        </span>
      </h2>
      <div className="overflow-x-auto rounded border border-zinc-200 dark:border-zinc-800">
        <table className="w-full min-w-[1040px] text-sm">
          <thead className="bg-zinc-50 text-xs text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
            <tr>
              <th className="px-3 py-2 text-left">分店</th>
              <th className="px-3 py-2 text-left">品項</th>
              <th className="px-2 py-2 text-right">派出</th>
              <th className="px-2 py-2 text-right font-semibold">目標</th>
              <th className="border-l border-zinc-200 px-2 py-2 text-right dark:border-zinc-800" title="開單當下貨還在車上">
                快照·在途
              </th>
              <th className="px-2 py-2 text-right" title="開單當下已到店、訂單未取">
                快照·店裡
              </th>
              <th className="px-2 py-2 text-right" title="開單當下客人已領走">
                快照·客人
              </th>
              <th className="border-l border-zinc-200 px-2 py-2 text-right dark:border-zinc-800">攔截</th>
              <th className="px-2 py-2 text-right">已回總倉</th>
              <th className="px-2 py-2 text-right">在途</th>
              <th className="px-2 py-2 text-right">沖銷</th>
              <th className="px-2 py-2 text-right font-semibold">差額</th>
              {canAct && <th className="px-3 py-2 text-right">退回數量</th>}
              {canAct && !d.is_store && <th className="px-2 py-2" />}
            </tr>
          </thead>
          <tbody>
            {d.lines.map((l) => {
              const diff = num(l.qty_diff);
              const remaining =
                num(l.qty_target) - num(l.qty_recovered) - num(l.qty_written_off) - num(l.qty_in_return);
              return (
                <tr key={l.line_id} className="border-t border-zinc-200 dark:border-zinc-800">
                  <td className="px-3 py-1.5 whitespace-nowrap">{l.store_name}</td>
                  <td className="px-3 py-1.5">
                    <span className="font-mono text-xs">{l.sku_code}</span>
                    <span className="ml-1 text-zinc-500">{l.sku_name}</span>
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">{num(l.qty_dispatched)}</td>
                  <td className="px-2 py-1.5 text-right font-semibold tabular-nums">{num(l.qty_target)}</td>
                  <td className="border-l border-zinc-200 px-2 py-1.5 text-right tabular-nums text-zinc-500 dark:border-zinc-800">
                    {num(l.snap_in_transit) || "—"}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500">
                    {num(l.snap_unpicked) || "—"}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums">
                    {num(l.snap_picked_up) > 0 ? (
                      <span className="rounded bg-rose-100 px-1.5 font-semibold text-rose-800 dark:bg-rose-950 dark:text-rose-300">
                        {num(l.snap_picked_up)}
                      </span>
                    ) : (
                      <span className="text-zinc-400">—</span>
                    )}
                  </td>
                  <td className="border-l border-zinc-200 px-2 py-1.5 text-right tabular-nums dark:border-zinc-800">
                    {num(l.qty_intercepted) || <span className="text-zinc-300">0</span>}
                  </td>
                  <td className="px-2 py-1.5 text-right font-medium tabular-nums text-emerald-700 dark:text-emerald-400">
                    {num(l.qty_returned_by_transfer) || <span className="text-zinc-300">0</span>}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-sky-700 dark:text-sky-400">
                    {num(l.qty_in_return) || <span className="text-zinc-300">0</span>}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-zinc-500" title={l.written_off_reason ?? ""}>
                    {num(l.qty_written_off) || <span className="text-zinc-300">0</span>}
                  </td>
                  <td className="px-2 py-1.5 text-right font-semibold tabular-nums">
                    {diff === 0 ? (
                      <span className="text-emerald-600 dark:text-emerald-400">0 ✓</span>
                    ) : (
                      <span className={diff < 0 ? "text-red-600 dark:text-red-400" : "text-purple-600"}>
                        {diff > 0 ? `+${diff}` : diff}
                      </span>
                    )}
                  </td>
                  {canAct && (
                    <td className="px-3 py-1.5 text-right">
                      {remaining > 0 ? (
                        <input
                          type="number"
                          min={0}
                          max={remaining}
                          placeholder={String(remaining)}
                          value={shipQty[l.line_id] ?? ""}
                          onChange={(e) => setShipQty((p) => ({ ...p, [l.line_id]: e.target.value }))}
                          className="w-20 rounded border border-zinc-300 bg-white px-2 py-1 text-right text-sm tabular-nums dark:border-zinc-700 dark:bg-zinc-900"
                        />
                      ) : (
                        <span className="text-xs text-zinc-400">—</span>
                      )}
                    </td>
                  )}
                  {canAct && !d.is_store && (
                    <td className="px-2 py-1.5">
                      {diff < 0 && (
                        <SpinButton
                          onClick={() =>
                            setWriteOff({ line: l, qty: String(-diff), reason: "" })
                          }
                          className="rounded border border-zinc-300 px-1.5 py-0.5 text-[11px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400"
                          title="追不回，人工沖銷後這一格就算結案"
                        >
                          沖銷
                        </SpinButton>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* 每店動作 */}
      {canAct && (
        <div className="mt-3 flex flex-wrap gap-2">
          {stores.map((sid) => {
            const name = d.lines.find((l) => l.store_id === sid)?.store_name ?? `#${sid}`;
            const inTransitLine = d.lines.find(
              (l) => l.store_id === sid && num(l.snap_in_transit) > 0 && num(l.qty_intercepted) === 0,
            );
            return (
              <div key={sid} className="flex items-center gap-1 rounded border border-zinc-200 px-2 py-1 dark:border-zinc-800">
                <span className="text-xs text-zinc-600 dark:text-zinc-400">{name}</span>
                <SpinButton
                  onClick={() => shipStore(sid)}
                  className="rounded border border-blue-400 bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300"
                  title="把上面填的數量出庫、建一張退貨單回總倉"
                >
                  出貨退回總倉
                </SpinButton>
                {!d.is_store && inTransitLine?.source_transfer_id && (
                  <SpinButton
                    onClick={() =>
                      call(
                        "rpc_recall_intercept_transfer",
                        {
                          p_recall_id: id,
                          p_transfer_id: inTransitLine.source_transfer_id,
                          p_reason: h.reason ?? null,
                        },
                        "已攔截該張派貨單，貨帳退回總倉",
                      )
                    }
                    className="rounded border border-sky-400 bg-sky-50 px-2 py-0.5 text-xs font-medium text-sky-700 hover:bg-sky-100 dark:border-sky-700 dark:bg-sky-950 dark:text-sky-300"
                    title="貨還沒到店，整張派貨單攔截退回總倉（該張所有品項都要在召回範圍內）"
                  >
                    攔截在途派貨單
                  </SpinButton>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* 受影響訂單 */}
      {d.orders.length > 0 && (
        <>
          <h2 className="mt-6 mb-2 text-sm font-semibold">
            受影響的顧客訂單
            <span className="ml-2 text-xs font-normal text-zinc-500">
              被召回的品項已標為取消，不會跟客人收這筆錢
            </span>
          </h2>
          <div className="overflow-x-auto rounded border border-zinc-200 dark:border-zinc-800">
            <table className="w-full min-w-[760px] text-sm">
              <thead className="bg-zinc-50 text-xs text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
                <tr>
                  <th className="px-3 py-2 text-left">訂單</th>
                  <th className="px-3 py-2 text-left">分店</th>
                  <th className="px-3 py-2 text-left">客人</th>
                  <th className="px-3 py-2 text-left">品項</th>
                  <th className="px-2 py-2 text-right">召回數</th>
                  <th className="px-3 py-2 text-left">訂單狀態</th>
                  <th className="px-3 py-2 text-left">付款</th>
                </tr>
              </thead>
              <tbody>
                {d.orders.map((o) => (
                  <tr
                    key={o.order_id}
                    className={`border-t border-zinc-200 dark:border-zinc-800 ${
                      o.needs_refund ? "bg-amber-50/50 dark:bg-amber-950/20" : ""
                    }`}
                  >
                    <td className="px-3 py-1.5">
                      <Link
                        href={`/orders?id=${o.order_id}`}
                        className="font-mono text-xs text-blue-600 underline dark:text-blue-400"
                      >
                        {o.order_no}
                      </Link>
                    </td>
                    <td className="px-3 py-1.5 text-zinc-600 dark:text-zinc-400">{o.store_name}</td>
                    <td className="px-3 py-1.5">{o.customer ?? "—"}</td>
                    <td className="px-3 py-1.5 font-mono text-xs text-zinc-500">{o.sku_codes}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{num(o.recalled_qty)}</td>
                    <td className="px-3 py-1.5 text-zinc-600 dark:text-zinc-400">
                      {orderStatusLabel(o.order_status)}
                    </td>
                    <td className="px-3 py-1.5">
                      {o.needs_refund ? (
                        <span
                          className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                          title="這張單已收過錢或用過儲值金，被召回的部分要人工退款（系統不會自動退）"
                        >
                          需退款 {num(o.wallet_paid) > 0 ? `（儲值金 ${num(o.wallet_paid)}）` : ""}
                        </span>
                      ) : (
                        <span className="text-xs text-zinc-400">未收款</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* 事件時間軸 */}
      <div className="mt-6">
        <SpinButton
          onClick={() => setShowEvents((v) => !v)}
          className="text-sm text-blue-600 underline dark:text-blue-400"
        >
          {showEvents ? "收合" : "展開"}處理紀錄（{d.events.length}）
        </SpinButton>
        {showEvents && (
          <ul className="mt-2 space-y-1 text-xs">
            {d.events.map((e) => (
              <li key={e.id} className="flex flex-wrap gap-2 border-b border-zinc-100 py-1 dark:border-zinc-900">
                <span className="w-36 shrink-0 text-zinc-500">
                  {new Date(e.created_at).toLocaleString("zh-TW", {
                    dateStyle: "short",
                    timeStyle: "short",
                  })}
                </span>
                <span className="w-28 shrink-0 font-medium">{EVENT_LABEL[e.event_type] ?? e.event_type}</span>
                <span className="tabular-nums">{e.qty != null ? `${num(e.qty)} 件` : ""}</span>
                <span className="text-zinc-500">
                  {e.note ?? (e.payload ? JSON.stringify(e.payload) : "")}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* 沖銷確認列 */}
      {writeOff && (
        <div className="fixed inset-x-0 bottom-0 z-40 border-t border-amber-300 bg-amber-50 px-4 py-3 dark:border-amber-800 dark:bg-amber-950">
          <div className="mx-auto flex max-w-4xl flex-wrap items-center gap-2 text-sm">
            <span>
              沖銷 <b>{writeOff.line.store_name}</b> 的{" "}
              <b className="font-mono">{writeOff.line.sku_code}</b>
            </span>
            <input
              type="number"
              min={1}
              value={writeOff.qty}
              onChange={(e) => setWriteOff({ ...writeOff, qty: e.target.value })}
              className="w-20 rounded border border-zinc-300 bg-white px-2 py-1 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-900"
            />
            <input
              value={writeOff.reason}
              onChange={(e) => setWriteOff({ ...writeOff, reason: e.target.value })}
              placeholder="沖銷原因（必填），例：客人不願歸還"
              className="min-w-[240px] flex-1 rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-900"
            />
            <SpinButton
              onClick={async () => {
                await call(
                  "rpc_recall_write_off",
                  {
                    p_line_id: writeOff.line.line_id,
                    p_qty: Number(writeOff.qty),
                    p_reason: writeOff.reason,
                  },
                  "已沖銷",
                );
                setWriteOff(null);
              }}
              disabled={!writeOff.reason.trim() || Number(writeOff.qty) <= 0}
              className="rounded bg-amber-600 px-3 py-1 font-medium text-white hover:bg-amber-700 disabled:opacity-40"
            >
              確認沖銷
            </SpinButton>
            <SpinButton
              onClick={() => setWriteOff(null)}
              className="rounded border border-zinc-300 px-3 py-1 dark:border-zinc-700"
            >
              取消
            </SpinButton>
          </div>
        </div>
      )}
    </div>
  );
}

function Kpi({
  label,
  value,
  tone,
  hint,
}: {
  label: string;
  value: number;
  tone: "plain" | "sky" | "emerald" | "red" | "zinc";
  hint?: string;
}) {
  const cls: Record<string, string> = {
    plain: "text-zinc-900 dark:text-zinc-100",
    sky: "text-sky-700 dark:text-sky-400",
    emerald: "text-emerald-700 dark:text-emerald-400",
    red: "text-red-700 dark:text-red-400",
    zinc: "text-zinc-500",
  };
  return (
    <div className="rounded border border-zinc-200 bg-white px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="text-[11px] text-zinc-500">{label}</div>
      <div className={`text-xl font-semibold tabular-nums ${cls[tone]}`}>{value}</div>
      {hint && <div className="text-[10px] text-zinc-400">{hint}</div>}
    </div>
  );
}
