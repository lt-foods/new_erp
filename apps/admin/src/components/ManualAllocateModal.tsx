"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Modal } from "@/components/Modal";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { orderListHref } from "@/lib/orderStatus";
import { pushArrivalNotifications, type NotifyTarget } from "@/lib/pickupNotify";

// 手動配單：補貨到店數量不夠分給所有團購訂單時，由店家自己勾「這批配給誰」，
// 取代自動配單（依訂單時間由早到晚）替店家做的決定。
//
// 候選與可配量都來自 rpc_get_manual_allocation_candidates —— 算法跟自動配單
// （_advance_arrived_confirmed_orders）同一套：整單每個品項都裝得下才能配，
// 不拆單。送出走 rpc_manual_allocate_confirmed_orders，伺服端會再驗一次
// 可配量與到貨閘門，勾了但裝不下的單會被跳過並回報，不會硬推。
// 見 20260813000000_receive_manual_allocation_mode.sql。

type BudgetRow = {
  sku_id: number;
  sku_code: string | null;
  name: string;
  available: number; // 原始值可能為負（帳差），顯示時夾 0、計算時用原始值
};

type CandidateOrder = {
  order_id: number;
  order_no: string;
  member_id: number | null;
  customer: string | null;
  campaign_name: string | null;
  created_at: string;
  items: Array<{ sku_id: number; qty: number }>;
};

type Payload = {
  store_id: number;
  budget: BudgetRow[];
  orders: CandidateOrder[];
  waiting_count: number;
};

type AllocResult = {
  advanced: number;
  orders: Array<{ order_id: number; order_no: string; customer: string | null }>;
  skipped: Array<{ order_id: number; order_no: string | null; reason: string }>;
  notify: NotifyTarget[];
};

const SKIP_REASON_LABEL: Record<string, string> = {
  not_found: "找不到訂單",
  not_eligible: "已被別人配走或狀態已變",
  not_arrived: "貨還沒到齊",
  insufficient_stock: "可配量不夠整張單",
};

export function ManualAllocateModal({
  storeId,
  storeName,
  notifyMembers,
  onClose,
  onSaved,
}: {
  storeId: number;
  storeName: string;
  // 收貨待辦頁的「收貨後通知會員」開關，當本彈窗通知選項的預設值
  notifyMembers: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [data, setData] = useState<Payload | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [notify, setNotify] = useState(notifyMembers);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const sb = getSupabase();
    const { data: d, error: e } = await sb.rpc("rpc_get_manual_allocation_candidates", {
      p_store_id: storeId,
    });
    if (e) throw new Error(e.message);
    const raw = d as Payload;
    const payload: Payload = {
      ...raw,
      budget: (raw.budget ?? []).map((b) => ({ ...b, available: Number(b.available) })),
      orders: (raw.orders ?? []).map((o) => ({
        ...o,
        items: (o.items ?? []).map((i) => ({ sku_id: i.sku_id, qty: Number(i.qty) })),
      })),
      waiting_count: Number(raw.waiting_count) || 0,
    };
    setData(payload);
    setSelected(new Set());
    return payload;
  }, [storeId]);

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
    (skuId: number) => (budgetMap.get(skuId)?.available ?? 0) - (usedMap.get(skuId) ?? 0),
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
      else if (fits(o)) next.add(o.order_id);
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
        (it) => it.qty <= (budgetMap.get(it.sku_id)?.available ?? 0) - (used.get(it.sku_id) ?? 0),
      );
      if (!ok) continue;
      next.add(o.order_id);
      for (const it of o.items) used.set(it.sku_id, (used.get(it.sku_id) ?? 0) + it.qty);
    }
    setSelected(next);
  }

  // 只顯示候選訂單有用到的 SKU（budget 種子是全店 confirmed 單的聯集，會多）
  const visibleBudget = useMemo(() => {
    if (!data) return [] as BudgetRow[];
    const refd = new Set<number>();
    for (const o of data.orders) for (const it of o.items) refd.add(it.sku_id);
    return data.budget.filter((b) => refd.has(b.sku_id));
  }, [data]);

  const selectedCount = selected.size;

  async function save() {
    if (!data || selectedCount === 0) return;
    if (
      !confirm(
        `確認把勾選的 ${selectedCount} 張訂單標成「可取貨」？\n\n` +
          `沒勾的訂單維持原狀，下一批貨到時可再配。\n` +
          (notify
            ? "📩 配單完成後會推播「商品到貨」給這幾位客人。"
            : "🔕 不會推播通知，請自行聯繫客人。"),
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_manual_allocate_confirmed_orders", {
        p_store_id: storeId,
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
      const skipNote =
        skipped.length > 0
          ? `\n⚠ ${skipped.length} 張沒配成：\n` +
            skipped
              .slice(0, 5)
              .map(
                (s) =>
                  `  ${s.order_no ?? `#${s.order_id}`}：${SKIP_REASON_LABEL[s.reason] ?? s.reason}`,
              )
              .join("\n") +
            (skipped.length > 5 ? `\n  …（還有 ${skipped.length - 5} 張）` : "")
          : "";
      alert(`✅ 配單完成：${r.advanced ?? 0} 張訂單已可取貨${pushNote}${skipNote}`);
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
    <Modal open onClose={onClose} title={`✋ 手動配單 — ${storeName}`} maxWidth="max-w-4xl">
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
            <p className="text-sm text-zinc-600 dark:text-zinc-300">
              勾選要先拿到貨的訂單 — 整張單每個品項都裝得下才能勾；沒勾的維持原狀，
              下一批貨到時再配即可。
            </p>

            {/* 各 SKU 剩餘可配量 */}
            {visibleBudget.length > 0 && (
              <div className="flex flex-wrap gap-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs dark:border-zinc-800 dark:bg-zinc-900/60">
                {visibleBudget.map((b) => {
                  const rem = b.available - (usedMap.get(b.sku_id) ?? 0);
                  return (
                    <span
                      key={b.sku_id}
                      className="inline-flex items-center gap-1 rounded-md border border-zinc-200 bg-white px-2 py-0.5 dark:border-zinc-700 dark:bg-zinc-800"
                      title={b.sku_code ?? undefined}
                    >
                      {b.name}
                      <b
                        className={
                          rem > 0
                            ? "text-emerald-700 dark:text-emerald-400"
                            : "text-zinc-400"
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
              <table className="w-full min-w-[600px] text-sm">
                <thead>
                  <tr className="border-b border-zinc-200 bg-zinc-50 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                    <th className="w-10 px-3 py-2" />
                    <th className="px-3 py-2 text-left font-medium">訂單編號</th>
                    <th className="px-3 py-2 text-left font-medium">顧客</th>
                    <th className="px-3 py-2 text-left font-medium">商品</th>
                    <th className="px-3 py-2 text-left font-medium">下單時間</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {data.orders.map((o) => {
                    const checked = selected.has(o.order_id);
                    const canCheck = checked || fits(o);
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
                            href={orderListHref(o.order_no, "confirmed")}
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
                      <td colSpan={5} className="px-3 py-6 text-center text-zinc-500">
                        目前沒有可配的訂單。
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            {data.waiting_count > 0 && (
              <p className="text-[11px] text-zinc-500">
                另有 {data.waiting_count} 張已成立的訂單因為貨還沒到齊（或店內帳上沒庫存）
                暫時配不了，下一批貨收進來會出現在這裡。
              </p>
            )}

            <div className="flex flex-wrap items-center gap-3">
              <label
                className="flex cursor-pointer items-center gap-1.5 text-xs text-zinc-600 dark:text-zinc-300"
                title="開啟：配單完成後推播「您的商品到貨」給勾選的客人（不通知名單會自動排除）。"
              >
                <input
                  type="checkbox"
                  checked={notify}
                  onChange={(e) => setNotify(e.target.checked)}
                  className="cursor-pointer"
                />
                {notify ? "📩 配單後通知客人到貨" : "🔕 配單後不通知客人"}
              </label>
              <SpinButton
                onClick={save}
                disabled={busy || selectedCount === 0}
                className="ml-auto rounded-md bg-emerald-600 px-5 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {busy ? "處理中…" : `✓ 配單${selectedCount > 0 ? ` (${selectedCount} 張)` : ""}`}
              </SpinButton>
            </div>
            <p className="text-[11px] text-zinc-500">
              配好的訂單會標成「可取貨」，取貨頁就能發貨；同時會從【內部】店現貨池
              扣掉相應數量，避免同一批貨再被轉單給別人。伺服端送出時會再驗一次可配量，
              若同時有別人在配、裝不下的單會被跳過並告知，不會硬配。
            </p>
          </>
        )}
      </div>
    </Modal>
  );
}

export default ManualAllocateModal;
