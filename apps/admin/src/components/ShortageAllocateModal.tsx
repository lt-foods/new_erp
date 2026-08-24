"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import Spinner from "@/components/Spinner";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import Link from "next/link";
import { orderStatusLabel, orderListHref } from "@/lib/orderStatus";
import { translateRpcError } from "@/lib/rpcError";

// 少發配貨：到貨量不夠分給所有訂單時，由收貨的人決定這批配給誰。
// 沒配到的標成「待補貨」（customer_order_items.backorder_at），在補到之前不可取貨
// —— 取貨閘門 is_order_item_pickup_ready 會擋，rpc_record_pickup 也擋得住。
// 見 20260805000060_shortage_allocation.sql。
//
// 店內有現貨時可開「庫存減抵單」：把待補貨的品項改用店內現貨直接交貨結案 ——
// 開單當下扣店倉庫存、品項標已取貨、訂單結案（與到店取貨同一套帳）。
// 開單前店倉帳上要有現貨（庫存總覽可依商品新增庫存），伺服端會檢查可用量。
// 見 20260805000170_inventory_deduction_notes.sql。

type Candidate = {
  item_id: number;
  order_id: number;
  order_no: string;
  customer: string | null;
  order_status: string;
  qty: number;
  backorder: boolean;
  created_at: string;
};

type DeductionNote = {
  id: number;
  note_no: string;
  qty: number;
  reason: string | null;
  created_at: string;
  // note = 庫存減抵單（已交貨結案）；offset = 抵減單（order_kind='offset' 負數訂單，
  // 開團時就宣告用店內現貨、已抵掉採購，客人照正常流程取貨）
  kind?: "note" | "offset";
};

// 已領走的品項行：唯讀對帳用（那 N 件是誰領走的），不參與配貨
type PickedRow = {
  item_id: number;
  order_id: number;
  order_no: string;
  customer: string | null;
  order_status: string;
  item_status: string;
  qty: number;
  picked_at: string | null;
  created_at: string;
};

type Payload = {
  store_id: number;
  campaign_id: number;
  supplied: number;
  covered: number;
  picked: number;
  available: number;
  store_on_hand: number;
  notes: DeductionNote[];
  items: Candidate[];
  picked_items?: PickedRow[];
};

export function ShortageAllocateModal({
  transferId,
  skuId,
  skuName,
  onClose,
  onSaved,
}: {
  transferId: number;
  skuId: number;
  skuName: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [data, setData] = useState<Payload | null>(null);
  // item_id → 配到的數量（可小於該行的量＝拆行：部分可取、部分待補）
  const [alloc, setAlloc] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // 減抵單數量輸入（預設 = 目前缺口，load 時帶入）
  const [deductQty, setDeductQty] = useState(0);

  const load = useCallback(async () => {
    const sb = getSupabase();
    const { data: d, error: e } = await sb.rpc("rpc_get_allocation_candidates", {
      p_transfer_id: transferId,
      p_sku_id: skuId,
    });
    if (e) throw new Error(e.message);
    const raw = d as Payload;
    const payload: Payload = {
      ...raw,
      supplied: Number(raw.supplied),
      covered: Number(raw.covered) || 0,
      picked: Number(raw.picked),
      available: Number(raw.available),
      store_on_hand: Number(raw.store_on_hand) || 0,
      notes: (raw.notes ?? []).map((n) => ({ ...n, qty: Number(n.qty) })),
      items: (raw.items ?? []).map((r) => ({ ...r, qty: Number(r.qty) })),
      picked_items: (raw.picked_items ?? []).map((r) => ({ ...r, qty: Number(r.qty) })),
    };
    setData(payload);
    // 進來時先反映現況：沒被標待補貨的整行都算配到
    setAlloc(
      new Map(
        payload.items.map((r) => [r.item_id, r.backorder ? 0 : r.qty] as [number, number]),
      ),
    );
    // 減抵輸入預設帶 min(待補貨總量, 店倉可用現貨) —— 帳上只有 1 件就不能選超過 1
    //（Alex 2026-08-24）。伺服端 rpc_create_inventory_deduction 還會再驗一次。
    setDeductQty(
      Math.min(
        payload.items.reduce((s, r) => s + (r.backorder ? r.qty : 0), 0),
        Math.max(0, Math.floor(payload.store_on_hand)),
      ),
    );
    return payload;
  }, [transferId, skuId]);

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

  const allocatedQty = useMemo(
    () => (data?.items ?? []).reduce((s, r) => s + (alloc.get(r.item_id) ?? 0), 0),
    [data, alloc],
  );
  const backorderQty = useMemo(
    () => (data?.items ?? []).reduce((s, r) => s + (r.qty - (alloc.get(r.item_id) ?? 0)), 0),
    [data, alloc],
  );
  const over = data ? allocatedQty - data.available : 0;
  // 目前缺口 = 未取合計 − 可配額度；>0 時才需要開減抵單
  const gap = useMemo(
    () => (data ? Math.max(0, data.items.reduce((s, r) => s + r.qty, 0) - data.available) : 0),
    [data],
  );
  // DB 現況的待補貨總量（減抵單只能交已標待補貨的行；畫面上未儲存的調整不算）
  const backorderedDb = useMemo(
    () => (data?.items ?? []).reduce((s, r) => s + (r.backorder ? r.qty : 0), 0),
    [data],
  );
  // 現貨交貨的上限 = min(待補貨, 店倉帳上可用) —— 帳上 1 件就不能選超過 1
  const deductCap = useMemo(
    () => Math.min(backorderedDb, Math.max(0, Math.floor(data?.store_on_hand ?? 0))),
    [backorderedDb, data],
  );

  // 依訂單時間配貨：候選已由後端依 created_at, order_no 排好，
  // 由早到晚配滿為止。會拆行 —— 額度只剩 1 件而該筆要 3 件時，給他 1 件、剩 2 件待補，
  // 額度不浪費（原本整行為單位時會整筆跳過，架上的貨就白放著）。
  function allocByTime(payload: Payload) {
    let left = payload.available;
    const next = new Map<number, number>();
    for (const r of payload.items) {
      const give = Math.max(0, Math.min(r.qty, left));
      next.set(r.item_id, give);
      left -= give;
    }
    return next;
  }

  function autoAllocateByTime() {
    if (!data) return;
    setAlloc(allocByTime(data));
  }

  // 開庫存減抵單：把待補貨的品項改用店內現貨「直接交貨結案」。
  // 依下單時間由早到晚挑待補貨的行，湊滿 deductQty 件（可拆行部分交）。
  async function createDeduction() {
    if (!data || deductQty <= 0) return;
    // 從 DB 現況（backorder 旗標）挑要交貨的行 — 畫面上未儲存的配貨調整不算
    const allocations: Record<string, number> = {};
    let left = deductQty;
    for (const r of data.items) {
      if (!r.backorder || left <= 0) continue;
      const give = Math.min(r.qty, left);
      allocations[String(r.item_id)] = give;
      left -= give;
    }
    const total = deductQty - left;
    if (total <= 0) return;
    if (
      !confirm(
        `用店內現貨交貨 ${total} 件（${Object.keys(allocations).length} 筆待補貨訂單）？\n\n` +
          `會立刻扣店內庫存、品項標成已取貨、訂單結案 — 跟客人到店取貨同一套帳。\n` +
          `店倉帳上可用現貨：${data.store_on_hand} 件。開錯只能走退貨流程沖回，請確認。`,
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
      const { data: res, error: e } = await sb.rpc("rpc_create_inventory_deduction", {
        p_store_id: data.store_id,
        p_campaign_id: data.campaign_id,
        p_sku_id: skuId,
        p_allocations: allocations,
        p_reason: null,
        p_operator: operator,
        p_transfer_id: transferId,
      });
      if (e) throw new Error(translateRpcError(e));
      const note = (res ?? {}) as { note_no?: string; qty?: number; orders?: number };
      await load();
      alert(
        `✅ 減抵單 ${note.note_no ?? ""} 完成：已用店內現貨交貨 ${note.qty ?? total} 件、` +
          `${note.orders ?? "?"} 張訂單結案。`,
      );
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  function setRow(id: number, v: number, max: number) {
    const q = Number.isFinite(v) ? Math.max(0, Math.min(Math.floor(v), max)) : 0;
    setAlloc((cur) => new Map(cur).set(id, q));
  }

  async function save() {
    if (!data) return;
    if (over > 0) return;
    const partial = data.items.filter((r) => {
      const a = alloc.get(r.item_id) ?? 0;
      return a > 0 && a < r.qty;
    }).length;
    if (
      !confirm(
        `確認配貨？\n\n配出 ${allocatedQty} 件、待補貨 ${backorderQty} 件。\n` +
          (partial > 0 ? `其中 ${partial} 筆訂單是部分配到（該筆會拆成可取與待補兩行）。\n` : "") +
          `\n待補貨的部分在補到貨之前不能取貨。不會通知客人，請店家自行聯繫。`,
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
      const { data: res, error: e } = await sb.rpc("rpc_allocate_shortage", {
        p_transfer_id: transferId,
        p_sku_id: skuId,
        p_allocations: Object.fromEntries(alloc),
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as { backordered?: number; freed?: number; split?: number };
      alert(
        `✅ 配貨完成：待補貨 ${r.backordered ?? 0} 筆、解除 ${r.freed ?? 0} 筆` +
          (r.split ? `、拆行 ${r.split} 筆` : ""),
      );
      onSaved();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  // 確定補不到 → 沿用斷貨語意取消（品項 cancelled + stockout_at）
  async function cancelBackorders() {
    if (!data) return;
    const ids = data.items.filter((r) => r.backorder).map((r) => r.item_id);
    if (ids.length === 0) return;
    if (
      !confirm(
        `把目前 ${ids.length} 筆「待補貨」直接取消？\n\n` +
          `會把這些品項標成斷貨取消，若整張訂單品項都沒了且沒收過錢，訂單也會一併取消；\n` +
          `已取走一部分的訂單則直接結單（不會再卡在「部分取貨」）。\n` +
          `此動作不可復原。`,
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
      const { data: res, error: e } = await sb.rpc("rpc_cancel_backorder_items", {
        p_item_ids: ids,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as {
        items_cancelled?: number;
        orders_cancelled?: number;
        orders_completed?: number;
      };
      alert(
        `已取消 ${r.items_cancelled ?? 0} 個品項、${r.orders_cancelled ?? 0} 張訂單` +
          // 已取走一部分的單不會被取消，剩下的取消掉就結單（20260808000000）
          (r.orders_completed ? `，${r.orders_completed} 張已取完的訂單結單` : ""),
      );
      await load();
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const hasBackordered = (data?.items ?? []).some((r) => r.backorder);

  return (
    <Modal open onClose={onClose} title={`⚖️ 少發配貨 — ${skuName}`} maxWidth="max-w-4xl">
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
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm dark:border-zinc-800 dark:bg-zinc-900/60">
              <span>
                到貨 <b>{data.supplied}</b> 件
                {data.covered > 0 && (
                  <span
                    className="text-violet-700 dark:text-violet-400"
                    title="店內現貨減抵：缺口由店內現貨吸收，計入可配額度"
                  >
                    {" "}
                    ＋現貨減抵 <b>{data.covered}</b>
                  </span>
                )}
                {data.picked > 0 && <span className="text-zinc-500">（已領走 {data.picked}）</span>}
              </span>
              <span>
                可配 <b className="text-emerald-700 dark:text-emerald-400">{data.available}</b> 件
              </span>
              <span>
                已配 <b className={over > 0 ? "text-rose-600" : ""}>{allocatedQty}</b> 件
              </span>
              <span>
                待補貨 <b className="text-amber-700 dark:text-amber-400">{backorderQty}</b> 件
              </span>
              <SpinButton
                onClick={autoAllocateByTime}
                className="ml-auto rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-semibold text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900"
                title="依下單時間由早到晚配，配滿為止（同時間以訂單編號先後為準）"
              >
                ⏱ 依訂單時間自動配
              </SpinButton>
            </div>

            {over > 0 && (
              <div className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300">
                已配 {allocatedQty} 件超過可配的 {data.available} 件，請減掉 {over} 件。
              </div>
            )}

            {/* 庫存減抵單：待補貨的品項可改用店內現貨直接交貨結案 */}
            {(backorderedDb > 0 || gap > 0 || data.notes.length > 0) && (
              <div className="space-y-2 rounded-md border border-violet-200 bg-violet-50/60 px-3 py-2 text-sm dark:border-violet-900 dark:bg-violet-950/30">
                {backorderedDb > 0 ? (
                  <>
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium text-violet-800 dark:text-violet-300">
                        🏬 店內有現貨？
                      </span>
                      <span className="text-zinc-600 dark:text-zinc-300">
                        待補貨 <b>{backorderedDb}</b> 件可改用店內現貨直接交貨結案
                        <span className="ml-1 text-xs text-zinc-500">
                          （店倉帳上可用 {data.store_on_hand} 件）
                        </span>
                      </span>
                      <div className="ml-auto flex items-center gap-1.5">
                        <input
                          type="number"
                          min={1}
                          max={deductCap}
                          value={deductQty}
                          onChange={(e) => {
                            const v = Math.floor(Number(e.target.value));
                            setDeductQty(
                              Number.isFinite(v) ? Math.max(0, Math.min(v, deductCap)) : 0,
                            );
                          }}
                          className="w-16 rounded-md border border-zinc-300 px-1.5 py-1 text-right text-sm tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                        />
                        <span className="text-xs text-zinc-500">件</span>
                        <SpinButton
                          onClick={createDeduction}
                          disabled={busy || deductQty <= 0 || deductCap <= 0}
                          className="rounded-md bg-violet-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-violet-700 disabled:opacity-50"
                          title="依下單時間由早到晚交貨。開單當下扣店庫存、訂單結案（與到店取貨同一套帳）。"
                        >
                          用現貨交貨
                        </SpinButton>
                      </div>
                    </div>
                    {deductCap < backorderedDb && (
                      <div className="text-xs text-amber-700 dark:text-amber-400">
                        ⚠ 店倉帳上只夠交 {deductCap} 件（待補 {backorderedDb} 件）— 要交更多請先到
                        <Link href="/inventory" target="_blank" className="mx-1 underline">
                          庫存總覽
                        </Link>
                        對這個商品「新增庫存」把現貨入帳，再回來開減抵單。
                      </div>
                    )}
                  </>
                ) : gap > 0 ? (
                  <div className="text-xs text-zinc-600 dark:text-zinc-300">
                    店內有現貨想直接交貨？請先按「儲存配貨」把沒配到的標成待補貨，再回這裡開減抵單。
                  </div>
                ) : (
                  <div className="text-xs text-zinc-600 dark:text-zinc-300">
                    缺口已由店內現貨減抵交貨完畢。
                  </div>
                )}
                {data.notes.map((n) => (
                  <div
                    key={`${n.kind ?? "note"}-${n.id}`}
                    className="flex flex-wrap items-center gap-2 border-t border-violet-200/70 pt-2 text-xs dark:border-violet-900/50"
                  >
                    <span className="font-mono text-violet-800 dark:text-violet-300">{n.note_no}</span>
                    <span title={n.kind === "offset" ? "開團時開的負數訂單，已抵掉採購量；這幾件客人照正常流程取貨" : undefined}>
                      {n.kind === "offset" ? "抵減單（開團時已抵採購）" : "現貨減抵交貨"}{" "}
                      <b>{n.qty}</b> 件
                    </span>
                    <span className="text-zinc-500">
                      {new Date(n.created_at).toLocaleString("zh-TW", {
                        dateStyle: "short",
                        timeStyle: "short",
                      })}
                    </span>
                    {n.reason && <span className="max-w-[360px] truncate text-zinc-500" title={n.reason}>{n.reason}</span>}
                  </div>
                ))}
              </div>
            )}

            <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
              <table className="w-full min-w-[600px] text-sm">
                <thead>
                  <tr className="border-b border-zinc-200 bg-zinc-50 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
                    <th className="w-24 px-3 py-2">配貨數量</th>
                    <th className="px-3 py-2 text-left font-medium">訂單編號</th>
                    <th className="px-3 py-2 text-left font-medium">顧客</th>
                    <th className="px-3 py-2 text-left font-medium">下單時間</th>
                    <th className="px-3 py-2 text-right font-medium">數量</th>
                    <th className="px-3 py-2 text-right font-medium">狀態</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {data.items.map((r) => {
                    const give = alloc.get(r.item_id) ?? 0;
                    const short = r.qty - give;
                    return (
                      <tr
                        key={r.item_id}
                        className={short <= 0 ? "" : "bg-amber-50/60 dark:bg-amber-950/20"}
                      >
                        <td className="px-3 py-2">
                          <div className="flex items-center gap-1">
                            <input
                              type="number"
                              min={0}
                              max={r.qty}
                              value={give}
                              onChange={(e) => setRow(r.item_id, Number(e.target.value), r.qty)}
                              className="w-14 rounded-md border border-zinc-300 px-1.5 py-1 text-right text-sm tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                            />
                            <span className="text-[10px] text-zinc-400">/ {r.qty}</span>
                          </div>
                        </td>
                        <td className="px-3 py-2 font-mono text-xs">
                          <Link
                            href={orderListHref(r.order_no, r.order_status)}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="text-blue-600 hover:underline dark:text-blue-400"
                            title="開新分頁查看這張訂單（配貨中的內容不會遺失）"
                          >
                            {r.order_no} ↗
                          </Link>
                        </td>
                        <td className="max-w-[220px] truncate px-3 py-2" title={r.customer ?? ""}>
                          {r.customer || "—"}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2 text-xs text-zinc-500">
                          {new Date(r.created_at).toLocaleString("zh-TW", {
                            dateStyle: "short",
                            timeStyle: "short",
                          })}
                        </td>
                        <td className="px-3 py-2 text-right font-semibold tabular-nums">{r.qty}</td>
                        <td className="whitespace-nowrap px-3 py-2 text-right text-xs">
                          {short <= 0 ? (
                            <span className="text-zinc-500">{orderStatusLabel(r.order_status)}</span>
                          ) : give > 0 ? (
                            <span className="font-medium text-amber-700 dark:text-amber-400">
                              部分待補 {short}
                            </span>
                          ) : (
                            <span className="font-medium text-amber-700 dark:text-amber-400">待補貨</span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                  {data.items.length === 0 && (
                    <tr>
                      <td colSpan={6} className="px-3 py-6 text-center text-zinc-500">
                        沒有未取的訂單 — 這批不需要配貨。
                      </td>
                    </tr>
                  )}
                  {(data.picked_items ?? []).length > 0 && (
                    <>
                      <tr className="border-t border-zinc-200 bg-zinc-100/80 dark:border-zinc-800 dark:bg-zinc-900">
                        <td colSpan={6} className="px-3 py-1.5 text-[11px] font-medium text-zinc-500">
                          已領走 {data.picked} 件（唯讀，僅供對帳 — 這些貨已經被領走，不能重新配）
                        </td>
                      </tr>
                      {(data.picked_items ?? []).map((r) => (
                        <tr key={`picked-${r.item_id}`} className="text-zinc-400 dark:text-zinc-500">
                          <td className="px-3 py-2 text-center">—</td>
                          <td className="px-3 py-2 font-mono text-xs">
                            <Link
                              href={orderListHref(r.order_no, r.order_status)}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="hover:underline"
                              title="開新分頁查看這張訂單"
                            >
                              {r.order_no} ↗
                            </Link>
                          </td>
                          <td className="max-w-[220px] truncate px-3 py-2" title={r.customer ?? ""}>
                            {r.customer || "—"}
                          </td>
                          <td className="whitespace-nowrap px-3 py-2 text-xs">
                            {new Date(r.created_at).toLocaleString("zh-TW", {
                              dateStyle: "short",
                              timeStyle: "short",
                            })}
                          </td>
                          <td className="px-3 py-2 text-right tabular-nums">{r.qty}</td>
                          <td
                            className="whitespace-nowrap px-3 py-2 text-right text-xs"
                            title={
                              r.picked_at
                                ? `領走時間 ${new Date(r.picked_at).toLocaleString("zh-TW", {
                                    dateStyle: "short",
                                    timeStyle: "short",
                                  })}`
                                : undefined
                            }
                          >
                            {r.item_status === "partially_picked_up" ? "部分領走" : "已領走"}
                          </td>
                        </tr>
                      ))}
                    </>
                  )}
                </tbody>
              </table>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {hasBackordered && (
                <SpinButton
                  onClick={cancelBackorders}
                  disabled={busy}
                  className="rounded-md border border-rose-300 px-3 py-1.5 text-xs text-rose-700 hover:bg-rose-50 disabled:opacity-50 dark:border-rose-800 dark:text-rose-400 dark:hover:bg-rose-950"
                  title="確定補不到貨時，把待補貨的品項直接標成斷貨取消"
                >
                  ✕ 補不到了，把待補貨轉取消
                </SpinButton>
              )}
              <SpinButton
                onClick={save}
                disabled={busy || over > 0 || data.items.length === 0}
                className="ml-auto rounded-md bg-emerald-600 px-5 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
              >
                {busy ? "處理中…" : "儲存配貨"}
              </SpinButton>
            </div>
            <p className="text-[11px] text-zinc-500">
              沒配到的量會標成「待補貨」，在補到貨之前取貨頁不會讓它取走。部分配到的訂單會拆成
              「可取」與「待補」兩行，客人可以先領到手的部分。不會發通知給客人；下一批到貨時再開
              這個視窗把數量補上去就會解除。店內有現貨的話可開「減抵單」把待補貨直接交貨結案
              （會扣店庫存，與到店取貨同一套帳）。
            </p>
          </>
        )}
      </div>
    </Modal>
  );
}

export default ShortageAllocateModal;
