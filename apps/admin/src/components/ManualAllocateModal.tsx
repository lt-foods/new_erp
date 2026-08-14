"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { orderListHref } from "@/lib/orderStatus";
import {
  fanoutPickupNotifications,
  pushArrivalNotifications,
  type NotifyTarget,
} from "@/lib/pickupNotify";

// 手動配貨：補貨到店數量不夠分給所有訂單時，由店家自己勾「這批配給誰」。
//
// 兩種模式（見 20260813000000 / 20260813010000 / 20260814000000 migration）：
// - receive：收貨前開（「✋ 收貨·手動配」按鈕）。列出**這批到貨單對到的訂單**，
//   勾完按「確認收貨」才一次完成收貨＋配單（同一交易；取消＝什麼都沒發生）。
//   「已確認」（等貨中）和「派貨中」（波次出貨時已配給他）都列：派貨中預設
//   勾選，取消勾選＝把該單拉回「已確認」、這批貨讓給別人（下批到貨可再配）。
// - store：收完貨之後想（再）配時用（「✋ 手動配單」常駐入口）。列出全店
//   貨已到齊、還沒配的訂單，勾選配單。
//
// 可配量算法跟自動配單（_advance_arrived_confirmed_orders）同一套：整單每個
// 品項都裝得下才能配、不拆單。送出時伺服端會再驗一次，勾了但裝不下的單會被
// 跳過並回報，不會硬推。例外：派貨中的單本來就是這批貨的主人，重勾不受
// 額度擋（伺服端與收貨邏輯 C 同樣不驗量）。

export type ReceiveLine = { transfer_item_id: number; qty_received: number };

export type AllocModalMode =
  | { kind: "store"; storeId: number }
  | {
      kind: "receive";
      transferIds: number[];
      // 調整彈窗轉過來的實收數量 / 備註（只支援單張；全收時為 null）
      lines?: ReceiveLine[] | null;
      note?: string | null;
    };

type BudgetRow = {
  sku_id: number;
  sku_code: string | null;
  name: string;
  cap: number; // 可配上限（receive 模式 = 既有可配 + 本次到貨；原始值可為負時已含在內）
};

type IncomingRow = { sku_id: number; sku_code: string | null; name: string; qty: number };

type CandidateOrder = {
  order_id: number;
  order_no: string;
  member_id: number | null;
  customer: string | null;
  campaign_name: string | null;
  created_at: string;
  // 單頭狀態（receive 模式伺服端回傳；store 模式候選必為 confirmed 且閘門已過）
  status: string;
  arrived: boolean;
  items: Array<{ sku_id: number; qty: number }>;
};

// 「客人看到」欄：判定對齊會員端 apps/member OrderCard.orderPhase ——
// 取貨閘門放行＝待取貨；派貨中＝運送中；其餘＝待到貨。
function customerStatusLabel(o: Pick<CandidateOrder, "status" | "arrived">): string {
  if (o.arrived) return "待取貨";
  if (o.status === "shipping") return "運送中";
  return "待到貨";
}

type Data = {
  budget: BudgetRow[];
  incoming: IncomingRow[];
  orders: CandidateOrder[];
  waiting_count: number;
};

type AllocResult = {
  advanced: number;
  orders: Array<{ order_id: number; order_no: string; customer: string | null }>;
  skipped: Array<{ order_id: number; order_no: string | null; reason: string }>;
  notify: NotifyTarget[];
};

type ManualReceiveResult = {
  transfers_received?: number;
  pulled_back?: number;
  pullback_skipped?: Array<{ order_id: number; order_no: string | null; status: string }>;
  shipping_advanced?: number;
  allocation?: AllocResult | null;
};

const SKIP_REASON_LABEL: Record<string, string> = {
  not_found: "找不到訂單",
  not_eligible: "已被別人配走或狀態已變",
  not_arrived: "貨還沒到齊",
  insufficient_stock: "可配量不夠整張單",
};

const skipNoteOf = (skipped: AllocResult["skipped"]) =>
  skipped.length > 0
    ? `\n⚠ ${skipped.length} 張沒配成：\n` +
      skipped
        .slice(0, 5)
        .map(
          (s) => `  ${s.order_no ?? `#${s.order_id}`}：${SKIP_REASON_LABEL[s.reason] ?? s.reason}`,
        )
        .join("\n") +
      (skipped.length > 5 ? `\n  …（還有 ${skipped.length - 5} 張）` : "")
    : "";

export function ManualAllocateModal({
  mode,
  storeName,
  notifyMembers,
  onClose,
  onSaved,
}: {
  mode: AllocModalMode;
  storeName: string;
  // 收貨待辦頁的「收貨後通知會員」開關，當本彈窗通知選項的預設值
  notifyMembers: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [data, setData] = useState<Data | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [notify, setNotify] = useState(notifyMembers);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const sb = getSupabase();
    if (mode.kind === "store") {
      const { data: d, error: e } = await sb.rpc("rpc_get_manual_allocation_candidates", {
        p_store_id: mode.storeId,
      });
      if (e) throw new Error(e.message);
      const raw = d as {
        budget: Array<{ sku_id: number; sku_code: string | null; name: string; available: number }>;
        orders: CandidateOrder[];
        waiting_count: number;
      };
      setData({
        budget: (raw.budget ?? []).map((b) => ({ ...b, cap: Number(b.available) })),
        incoming: [],
        orders: (raw.orders ?? []).map((o) => ({
          ...o,
          // store 模式候選 = confirmed 且閘門已過（伺服端定義），標籤固定「待取貨」
          status: "confirmed",
          arrived: true,
          items: (o.items ?? []).map((i) => ({ sku_id: i.sku_id, qty: Number(i.qty) })),
        })),
        waiting_count: Number(raw.waiting_count) || 0,
      });
      setSelected(new Set());
    } else {
      const { data: d, error: e } = await sb.rpc("rpc_get_transfer_allocation_preview", {
        p_transfer_ids: mode.transferIds,
        p_lines: mode.lines && mode.lines.length > 0 ? mode.lines : null,
      });
      if (e) throw new Error(e.message);
      const raw = d as {
        store_id: number | null;
        incoming: IncomingRow[];
        budget: Array<{ sku_id: number; sku_code: string | null; name: string; available: number }>;
        orders: CandidateOrder[];
      };
      const incoming = (raw.incoming ?? []).map((r) => ({ ...r, qty: Number(r.qty) }));
      const incMap = new Map(incoming.map((r) => [r.sku_id, r.qty]));
      const orders = (raw.orders ?? []).map((o) => ({
        ...o,
        status: o.status ?? "confirmed",
        arrived: Boolean(o.arrived),
        items: (o.items ?? []).map((i) => ({ sku_id: i.sku_id, qty: Number(i.qty) })),
      }));
      setData({
        // 可配上限 = 既有可配（可能為負；伺服端已把畫面上的派貨中單從「已承諾」
        // 排除）+ 本次到貨 —— 跟確認收貨後伺服端算出的預算一致
        budget: (raw.budget ?? []).map((b) => ({
          sku_id: b.sku_id,
          sku_code: b.sku_code,
          name: b.name,
          cap: Number(b.available) + (incMap.get(b.sku_id) ?? 0),
        })),
        incoming,
        orders,
        waiting_count: 0,
      });
      // 派貨中的單＝這批貨出貨時就配給他的，預設勾選；取消勾選＝拉回讓貨
      setSelected(new Set(orders.filter((o) => o.status === "shipping").map((o) => o.order_id)));
    }
  }, [mode]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await load();
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [load]);

  const budgetMap = useMemo(() => {
    const m = new Map<number, BudgetRow>();
    for (const b of data?.budget ?? []) m.set(b.sku_id, b);
    return m;
  }, [data]);

  // 已勾選訂單佔掉的量（sku_id → qty）
  const usedMap = useMemo(() => {
    const m = new Map<number, number>();
    for (const o of data?.orders ?? []) {
      if (!selected.has(o.order_id)) continue;
      for (const it of o.items) m.set(it.sku_id, (m.get(it.sku_id) ?? 0) + it.qty);
    }
    return m;
  }, [data, selected]);

  const remaining = useCallback(
    (skuId: number) => (budgetMap.get(skuId)?.cap ?? 0) - (usedMap.get(skuId) ?? 0),
    [budgetMap, usedMap],
  );

  // 沒勾的單還裝不裝得下（整單每個品項都要在剩餘額度內，與伺服端同規則）
  const fits = useCallback(
    (o: CandidateOrder) => o.items.every((it) => it.qty <= remaining(it.sku_id)),
    [remaining],
  );

  function toggle(o: CandidateOrder) {
    setSelected((cur) => {
      const next = new Set(cur);
      if (next.has(o.order_id)) next.delete(o.order_id);
      // 派貨中的單本來就是這批貨的主人：重勾不受剩餘額度擋
      //（伺服端與收貨邏輯 C 同樣不對它驗量），取消勾選過的人才能反悔
      else if (fits(o) || o.status === "shipping") next.add(o.order_id);
      return next;
    });
  }

  // 依訂單時間由早到晚勾滿為止 —— 跟自動配單同一套結果，店家可再手動增減
  function presetByTime() {
    if (!data) return;
    const used = new Map<number, number>();
    const next = new Set<number>();
    for (const o of data.orders) {
      const ok = o.items.every(
        (it) => it.qty <= (budgetMap.get(it.sku_id)?.cap ?? 0) - (used.get(it.sku_id) ?? 0),
      );
      if (!ok) continue;
      next.add(o.order_id);
      for (const it of o.items) used.set(it.sku_id, (used.get(it.sku_id) ?? 0) + it.qty);
    }
    setSelected(next);
  }

  // 只顯示候選訂單有用到的 SKU（budget 種子是聯集，會多）
  const visibleBudget = useMemo(() => {
    if (!data) return [] as BudgetRow[];
    const refd = new Set<number>();
    for (const o of data.orders) for (const it of o.items) refd.add(it.sku_id);
    return data.budget.filter((b) => refd.has(b.sku_id));
  }, [data]);

  const selectedCount = selected.size;
  const isReceive = mode.kind === "receive";

  async function save() {
    if (!data || busy) return;
    if (!isReceive && selectedCount === 0) return;

    // 沒勾的「派貨中」訂單＝拉回：這批貨不配給他，單頭退回「已確認」
    const pullbackIds = isReceive
      ? data.orders
          .filter((o) => o.status === "shipping" && !selected.has(o.order_id))
          .map((o) => o.order_id)
      : [];

    const notifyLine = notify
      ? "📩 完成後會推播「商品到貨」給可取貨的客人。"
      : "🔕 不會推播通知，請自行聯繫客人。";
    const pullbackLine =
      pullbackIds.length > 0
        ? `⤺ 沒勾的 ${pullbackIds.length} 張「運送中」訂單會退回「已確認」，這批貨不配給他們` +
          `（客人畫面變回「待到貨」，下一批貨到時可再配）。\n`
        : "";
    const msg = isReceive
      ? `確認收貨並配單？\n\n` +
        (selectedCount > 0
          ? `勾選的 ${selectedCount} 張訂單會標成「可取貨」，沒勾的維持原狀（下一批貨到時可再配）。\n`
          : `沒有勾選訂單 — 只收貨不配單，之後可從「✋ 手動配單」再配。\n`) +
        pullbackLine +
        notifyLine
      : `確認把勾選的 ${selectedCount} 張訂單標成「可取貨」？\n\n沒勾的訂單維持原狀，下一批貨到時可再配。\n` +
        notifyLine;
    if (!confirm(msg)) return;

    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");

      if (isReceive && mode.kind === "receive") {
        // 一段式：收貨＋配單同一交易，失敗整包回滾（＝沒收貨）
        const { data: res, error: e } = await sb.rpc("rpc_receive_transfer_manual", {
          p_transfer_ids: mode.transferIds,
          p_operator: operator,
          p_order_ids: selectedCount > 0 ? Array.from(selected) : null,
          p_notes: mode.note ?? null,
          p_lines: mode.lines && mode.lines.length > 0 ? mode.lines : null,
          p_pullback_order_ids: pullbackIds.length > 0 ? pullbackIds : null,
        });
        if (e) throw new Error(translateRpcError(e));
        const r = (res ?? {}) as ManualReceiveResult;
        let pushNote = "";
        if (notify) {
          const pushed = await fanoutPickupNotifications(mode.transferIds).catch((err) => {
            console.warn("push fanout error:", err);
            return 0;
          });
          if (pushed > 0) pushNote = `\n📩 已推播 ${pushed} 位顧客`;
        }
        const alloc = r.allocation;
        // 配單總數 = 派貨中保留勾選推進的 + confirmed 走配額守衛推進的
        const advancedTotal = (r.shipping_advanced ?? 0) + (alloc?.advanced ?? 0);
        const pullSkipped = r.pullback_skipped ?? [];
        alert(
          `✅ 收貨完成：${r.transfers_received ?? mode.transferIds.length} 單` +
            (advancedTotal > 0 ? `，配單 ${advancedTotal} 張訂單已可取貨` : "，未配單") +
            ((r.pulled_back ?? 0) > 0 ? `，${r.pulled_back} 張退回「已確認」等下批` : "") +
            pushNote +
            skipNoteOf(alloc?.skipped ?? []) +
            (pullSkipped.length > 0
              ? `\n⚠ ${pullSkipped.length} 張拉不回（狀態已變）：` +
                pullSkipped.map((s) => s.order_no ?? `#${s.order_id}`).join("、")
              : ""),
        );
        onSaved();
        onClose();
        return;
      }

      // store 模式：純配單（貨已在店）
      if (mode.kind !== "store") return;
      const { data: res, error: e } = await sb.rpc("rpc_manual_allocate_confirmed_orders", {
        p_store_id: mode.storeId,
        p_order_ids: Array.from(selected),
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as AllocResult;

      let pushNote = "";
      if (notify && (r.notify ?? []).length > 0) {
        const pushed = await pushArrivalNotifications(r.notify).catch((err) => {
          console.warn("push arrival error:", err);
          return 0;
        });
        if (pushed > 0) pushNote = `\n📩 已推播 ${pushed} 位顧客`;
      }
      const skipped = r.skipped ?? [];
      alert(`✅ 配單完成：${r.advanced ?? 0} 張訂單已可取貨${pushNote}${skipNoteOf(skipped)}`);
      onSaved();
      if (skipped.length > 0) {
        // 有跳過的單就留在彈窗讓店家重看（額度已變，重載）
        await load();
      } else {
        onClose();
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open
      onClose={onClose}
      title={isReceive ? `✋ 收貨·手動配 — ${storeName}` : `✋ 手動配單 — ${storeName}`}
      maxWidth="max-w-4xl"
    >
      <div className="space-y-3">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {data === null && !error && (
          <div className="flex items-center justify-center gap-2 py-8 text-sm text-zinc-500">
            <Spinner size={16} /> 載入訂單…
          </div>
        )}

        {data && (
          <>
            {isReceive && data.incoming.length > 0 && (
              <div className="flex flex-wrap items-center gap-2 rounded-md border border-blue-200 bg-blue-50/60 px-3 py-2 text-sm dark:border-blue-900 dark:bg-blue-950/30">
                <span className="font-medium text-blue-800 dark:text-blue-300">📦 本次到貨</span>
                {data.incoming.map((r) => (
                  <span
                    key={r.sku_id}
                    className="inline-flex items-center gap-1 rounded-md border border-blue-200 bg-white px-2 py-0.5 text-xs dark:border-blue-800 dark:bg-zinc-900"
                    title={r.sku_code ?? undefined}
                  >
                    {r.name} <b className="tabular-nums">× {r.qty}</b>
                  </span>
                ))}
              </div>
            )}

            <p className="text-sm text-zinc-600 dark:text-zinc-300">
              {isReceive
                ? "勾選要配到貨的訂單，按「確認收貨」才會完成收貨；關閉視窗則不收貨。" +
                  "「運送中」的訂單出貨時就是配給他的、已預先勾好 — 取消勾選會把該單" +
                  "退回「已確認」，把這批貨讓給別人。"
                : "勾選要先拿到貨的訂單 — 沒勾的維持原狀，下一批貨到時再配即可。"}
            </p>

            {/* 各 SKU 剩餘可配量 */}
            {visibleBudget.length > 0 && (
              <div className="flex flex-wrap gap-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900/60">
                {visibleBudget.map((b) => {
                  const rem = b.cap - (usedMap.get(b.sku_id) ?? 0);
                  return (
                    <span
                      key={b.sku_id}
                      className="inline-flex items-center gap-1 rounded-md border border-zinc-200 bg-white px-2 py-0.5 dark:border-zinc-700 dark:bg-zinc-800"
                      title={b.sku_code ?? undefined}
                    >
                      {b.name}
                      <b
                        className={
                          rem > 0 ? "text-emerald-700 dark:text-emerald-400" : "text-zinc-400"
                        }
                      >
                        剩 {Math.max(0, rem)}
                      </b>
                    </span>
                  );
                })}
                <SpinButton
                  onClick={presetByTime}
                  className="ml-auto rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-semibold text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900"
                  title="依下單時間由早到晚勾滿為止（跟自動配單同一套結果），可再手動增減"
                >
                  ⏱ 依訂單時間選好
                </SpinButton>
              </div>
            )}

            <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
              <table className="w-full min-w-[680px] text-sm">
                <thead>
                  <tr className="border-b border-zinc-200 bg-zinc-50 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                    <th className="w-10 px-3 py-2" />
                    <th className="px-3 py-2 text-left font-medium">訂單編號</th>
                    <th className="px-3 py-2 text-left font-medium">顧客</th>
                    <th className="px-3 py-2 text-left font-medium">客人看到</th>
                    <th className="px-3 py-2 text-left font-medium">商品</th>
                    <th className="px-3 py-2 text-left font-medium">下單時間</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {data.orders.map((o) => {
                    const checked = selected.has(o.order_id);
                    const canCheck = checked || fits(o) || o.status === "shipping";
                    return (
                      <tr
                        key={o.order_id}
                        onClick={() => canCheck && !busy && toggle(o)}
                        className={
                          checked
                            ? "cursor-pointer bg-emerald-50/70 dark:bg-emerald-950/20"
                            : canCheck
                            ? "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-950"
                            : "opacity-50"
                        }
                        title={canCheck ? undefined : "剩餘可配量不夠整張單，先取消別張才能勾"}
                      >
                        <td className="px-3 py-2">
                          <input
                            type="checkbox"
                            checked={checked}
                            disabled={!canCheck || busy}
                            onChange={() => toggle(o)}
                            onClick={(e) => e.stopPropagation()}
                            className="cursor-pointer"
                          />
                        </td>
                        <td className="px-3 py-2 font-mono text-xs">
                          <Link
                            href={orderListHref(o.order_no, o.status)}
                            target="_blank"
                            rel="noopener noreferrer"
                            onClick={(e) => e.stopPropagation()}
                            className="text-blue-600 hover:underline dark:text-blue-400"
                            title="開新分頁查看這張訂單（配單中的勾選不會遺失）"
                          >
                            {o.order_no} ↗
                          </Link>
                        </td>
                        <td className="max-w-[180px] truncate px-3 py-2" title={o.customer ?? ""}>
                          {o.customer || "—"}
                          {o.campaign_name && (
                            <div
                              className="max-w-[180px] truncate text-[10px] text-zinc-400"
                              title={o.campaign_name}
                            >
                              {o.campaign_name}
                            </div>
                          )}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2">
                          <span
                            className={
                              "inline-flex rounded-md border px-1.5 py-0.5 text-[11px] " +
                              (o.status === "shipping"
                                ? "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-400"
                                : "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300")
                            }
                            title={
                              o.status === "shipping"
                                ? "出貨時已配給這張單；取消勾選會退回「已確認」（客人畫面變回「待到貨」）"
                                : "客人在會員端目前看到的狀態"
                            }
                          >
                            {customerStatusLabel(o)}
                          </span>
                        </td>
                        <td className="px-3 py-2 text-xs">
                          {o.items.map((it) => (
                            <div key={it.sku_id} className="whitespace-nowrap">
                              {budgetMap.get(it.sku_id)?.name ?? `#${it.sku_id}`}{" "}
                              <b className="tabular-nums">× {it.qty}</b>
                            </div>
                          ))}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-500">
                          {new Date(o.created_at).toLocaleString("zh-TW", {
                            dateStyle: "short",
                            timeStyle: "short",
                          })}
                        </td>
                      </tr>
                    );
                  })}
                  {data.orders.length === 0 && (
                    <tr>
                      <td colSpan={6} className="px-3 py-6 text-center text-zinc-500">
                        {isReceive
                          ? "這批貨對不到任何等貨中的訂單 — 可直接確認收貨入庫。"
                          : "目前沒有可配的訂單。"}
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            {!isReceive && data.waiting_count > 0 && (
              <p className="text-[11px] text-zinc-500">
                另有 {data.waiting_count} 張已成立的訂單因為貨還沒到齊（或店內帳上沒庫存）
                暫時配不了，下一批貨收進來會出現在這裡。
              </p>
            )}

            <div className="flex flex-wrap items-center gap-3">
              <label
                className="flex cursor-pointer items-center gap-1.5 text-xs text-zinc-600 dark:text-zinc-300"
                title="開啟：完成後推播「您的商品到貨」給可取貨的客人（不通知名單會自動排除）。"
              >
                <input
                  type="checkbox"
                  checked={notify}
                  onChange={(e) => setNotify(e.target.checked)}
                  className="cursor-pointer"
                />
                {notify ? "📩 完成後通知客人到貨" : "🔕 完成後不通知客人"}
              </label>
              <SpinButton
                onClick={save}
                disabled={busy || (!isReceive && selectedCount === 0)}
                className="ml-auto rounded-md bg-emerald-600 px-5 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {busy
                  ? "處理中…"
                  : isReceive
                  ? `✓ 確認收貨${selectedCount > 0 ? `·配單 ${selectedCount} 張` : ""}`
                  : `✓ 配單${selectedCount > 0 ? ` (${selectedCount} 張)` : ""}`}
              </SpinButton>
            </div>
            <p className="text-[11px] text-zinc-500">
              {isReceive
                ? "按「確認收貨」會一次完成入庫與配單（同一筆交易，失敗即整筆取消、不會收到一半）。" +
                  "配好的訂單會標成「可取貨」，並從【內部】店現貨池扣掉相應數量；" +
                  "沒勾的「運送中」訂單退回「已確認」，下一批貨到時可再配。" +
                  "伺服端會再驗一次可配量，裝不下的單會被跳過並告知，不會硬配。"
                : "配好的訂單會標成「可取貨」，取貨頁就能發貨；同時會從【內部】店現貨池" +
                  "扣掉相應數量，避免同一批貨再被轉單給別人。伺服端送出時會再驗一次可配量，" +
                  "若同時有別人在配、裝不下的單會被跳過並告知，不會硬配。"}
            </p>
          </>
        )}
      </div>
    </Modal>
  );
}

export default ManualAllocateModal;
