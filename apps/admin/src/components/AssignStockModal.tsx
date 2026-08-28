"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

// 從庫存配貨：把取貨門市的現貨指派給這張單的這一個品項。
// 見 20260824070000 migration。
//
// 與旁邊兩條路的分工（不要混用）：
//   - 這一支：客人還沒來 → 只開 DN 覆蓋（取貨閘門 Path D 放行）＋清待補貨旗標，
//     **不扣庫存、不結案**。客人到店在「取貨」頁完成交貨才扣帳。
//   - 庫存減抵單（/inventory/deductions）：客人就在現場 → 開單當下扣庫存、
//     品項標已取貨、訂單結案。
//   - 現貨直配（庫存總覽「🤝 配給客人」）：沒有既有訂單，開一張新的 SP- 單。
//
// 可配量走伺服端 _order_item_stock_budget：**不扣 waiting** —— 這一行自己就是
// 「還在等貨」的需求之一，扣了會自己擋自己。已到貨的【內部】店現貨池算可配，
// 配掉時 RPC 會同步從池子扣。

type Budget = {
  order_no: string;
  store_name: string;
  location_id: number | null;
  sku_id: number | null;
  sku_label: string;
  item_qty: number;
  assigned: number;
  backordered: boolean;
  on_hand: number;
  committed: number;
  waiting: number;
  pool: number;
  pool_arrived: number;
  assignable: number;
  assignable_with_pool: number;
  gate_ready: boolean;
};

const num = (v: unknown) => (v == null ? 0 : Number(v));

export function AssignStockModal({
  itemId,
  skuLabel,
  onClose,
  onSaved,
}: {
  itemId: number;
  skuLabel: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [b, setB] = useState<Budget | null>(null);
  const [qty, setQty] = useState(1);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // 上限不夠時「架上其實有貨、只是沒入帳」→ 送出前先幫忙新增庫存，不用跳去庫存總覽
  const [topUp, setTopUp] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase().rpc("rpc_get_order_item_stock_budget", {
        p_item_id: itemId,
      });
      if (cancelled) return;
      if (e) {
        setError(translateRpcError(e));
        return;
      }
      const a = (data ?? {}) as Record<string, unknown>;
      const parsed: Budget = {
        order_no: String(a.order_no ?? ""),
        store_name: String(a.store_name ?? ""),
        location_id: a.location_id == null ? null : Number(a.location_id),
        sku_id: a.sku_id == null ? null : Number(a.sku_id),
        sku_label: String(a.sku_label ?? ""),
        item_qty: num(a.item_qty),
        assigned: num(a.assigned),
        backordered: !!a.backordered,
        on_hand: num(a.on_hand),
        committed: num(a.committed),
        waiting: num(a.waiting),
        pool: num(a.pool),
        pool_arrived: num(a.pool_arrived),
        assignable: num(a.assignable),
        assignable_with_pool: num(a.assignable_with_pool),
        gate_ready: !!a.gate_ready,
      };
      setB(parsed);
      // 預設就給滿：店員多半是「有多少配多少」
      setQty(Math.max(1, parsed.assignable_with_pool));
    })();
    return () => {
      cancelled = true;
    };
  }, [itemId]);

  const cap = b?.assignable_with_pool ?? 0;
  const free = b?.assignable ?? 0;
  const room = b ? Math.max(b.item_qty - b.assigned, 0) : 0;
  // 開了「一鍵新增庫存」就不受 cap 限制，只受這一行剩餘數量限制
  const effectiveCap = topUp ? room : Math.min(cap, room);
  const fromPool = Math.max(0, Math.min(qty, cap) - free);
  const shortfall = topUp ? Math.max(qty - Math.max(cap, 0), 0) : 0;
  // 配不滿整行 → 伺服端會拆行，餘量掛待補貨（開了 topUp 之後不會發生，量會補到剛好夠）
  const splitQty = b ? Math.max(room - qty, 0) : 0;
  const canSubmit = !busy && !!b && qty > 0 && qty <= effectiveCap && qty <= room;

  async function save() {
    if (!canSubmit || !b) return;
    if (
      !confirm(
        (shortfall > 0
          ? `店內庫存不足，會先在「${b.store_name}」幫這個商品新增庫存 +${shortfall} 件`
            + `（手動調整，寫進去就無法刪除／修改，只能之後盤點更正）。\n`
            + `請先確認架上真的有這批貨再送出！\n\n`
          : "") +
          `把「${skuLabel}」×${qty} 從「${b.store_name}」的庫存配給這張單？\n\n` +
          `品項會變成「已到貨・可取貨」，現在不扣庫存、不收款；\n` +
          `客人到店在「取貨」頁完成交貨時才扣庫存收款。\n` +
          (fromPool > 0 ? `其中 ${fromPool} 件來自【內部】${b.store_name}現貨池，會自動從池子扣。\n` : "") +
          (splitQty > 0 ? `沒配到的 ${splitQty} 件會拆成一行、標成「待補貨」。\n` : ""),
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
      if (shortfall > 0) {
        if (b.location_id == null || b.sku_id == null) {
          throw new Error("這張單的取貨門市沒有綁定倉別，無法新增庫存");
        }
        const { error: e0 } = await sb.rpc("rpc_add_stock_by_product", {
          p_location_id: b.location_id,
          p_sku_id: b.sku_id,
          p_qty: shortfall,
          p_reason: reason.trim() || `訂單頁強制配貨・一鍵新增庫存（${b.order_no ?? ""}）`,
          p_operator: operator,
        });
        if (e0) throw new Error(translateRpcError(e0));
      }
      const { data: res, error: e } = await sb.rpc("rpc_assign_stock_to_order_item", {
        p_item_id: itemId,
        p_qty: qty,
        p_operator: operator,
        p_reason: reason.trim() || null,
        // 已到貨的內部現貨池也算可配，超出的部分由 RPC 同步扣池子（20260824070000）
        p_use_pool: true,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as {
        note_no?: string; from_pool?: number; split_qty?: number;
        advanced?: boolean; gate_ready?: boolean;
      };
      alert(
        `✅ 已配 ${qty} 件給這張單（減抵單 ${r.note_no ?? ""}）。\n` +
          (shortfall > 0 ? `其中已先新增庫存 +${shortfall} 件。\n` : "") +
          (num(r.from_pool) > 0 ? `其中 ${num(r.from_pool)} 件從【內部】${b.store_name}現貨池扣掉。\n` : "") +
          (num(r.split_qty) > 0 ? `沒配到的 ${num(r.split_qty)} 件已拆成一行、標成「待補貨」。\n` : "") +
          (r.advanced ? "整張單都到齊了，狀態已推到「已到貨」。\n" : "") +
          (r.gate_ready ? "客人現在可以在「取貨」頁領走。" : "⚠️ 這一行的取貨閘門仍未放行，請檢查是否還有待補貨。"),
      );
      onSaved();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={onClose} title="📦 從庫存配貨給這張單" maxWidth="max-w-lg">
      <div className="space-y-3 text-sm">
        {error && (
          <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900/60">
          <div className="font-medium text-zinc-900 dark:text-zinc-100">{skuLabel}</div>
          <div className="mt-0.5 text-xs text-zinc-500">
            {b === null ? (
              "載入可配量…"
            ) : (
              <>
                {b.store_name} · 這一行 {b.item_qty} 件
                {b.assigned > 0 && <span className="ml-1">（已配 {b.assigned} 件）</span>} · 可配{" "}
                <b className={cap > 0 ? "text-emerald-700 dark:text-emerald-400" : "text-rose-600 dark:text-rose-400"}>
                  {Math.min(cap, room)}
                </b>{" "}
                件
                {cap > free && (
                  <span className="ml-1 text-zinc-400">（自由量 {free} ＋ 內部現貨池 {cap - free}）</span>
                )}
              </>
            )}
          </div>
          {b && (
            <div className="mt-1 text-[11px] text-zinc-400">
              店倉在庫 {b.on_hand} − 別的單已佔 {b.committed}
              {b.pool > b.pool_arrived && <> − 在途內部單 {b.pool - b.pool_arrived}</>}
              {b.waiting > 0 && <>｜同店還在等這個商品的單共 {b.waiting} 件</>}
            </div>
          )}
          {b && fromPool > 0 && (
            <div className="mt-1.5 text-[11px] text-amber-700 dark:text-amber-400">
              其中 <b>{fromPool}</b> 件掛在【內部】{b.store_name}現貨池，送出後會自動從池子扣掉。
            </div>
          )}
          {b && splitQty > 0 && (
            <div className="mt-1.5 text-[11px] text-amber-700 dark:text-amber-400">
              沒配到的 <b>{splitQty}</b> 件會拆成一行、標成「待補貨」（下一批貨到店時會自動解除）。
            </div>
          )}
          {b && cap <= 0 && !topUp && (
            <div className="mt-1.5">
              <div className="text-[11px] text-amber-700 dark:text-amber-400">
                {b.on_hand <= 0 ? (
                  <>店倉帳上這個商品是 0 件。架上實際有貨的話：</>
                ) : (
                  <>在庫 {b.on_hand} 件已經被別的單佔走 {b.committed} 件（已承諾未取 ＋ 已配過的單）。架上實際有更多貨的話：</>
                )}
              </div>
              <SpinButton
                onClick={() => {
                  setTopUp(true);
                  setQty(Math.max(1, room));
                }}
                className="mt-1.5 w-full rounded-md border border-amber-400 bg-amber-100 px-3 py-2 text-center text-xs font-semibold text-amber-900 hover:bg-amber-200 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200 dark:hover:bg-amber-900"
              >
                🏗 架上其實有貨、一鍵新增庫存再配貨
              </SpinButton>
            </div>
          )}
          {b && topUp && (
            <div className="mt-1.5 rounded-md border border-amber-300 bg-amber-50 px-2 py-1.5 text-[11px] text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
              已開啟「一鍵新增庫存」：送出時會先幫「{b.store_name}」把這個商品的庫存補到
              {" "}{shortfall > 0 ? `+${shortfall}` : "夠"}，再配給這張單。
              新增庫存<b>無法刪除／修改</b>，請先確認架上真的有貨。{" "}
              <SpinButton
                onClick={() => {
                  setTopUp(false);
                  setQty((q) => Math.min(q, Math.max(Math.min(cap, room), 1)));
                }}
                className="underline"
              >
                取消
              </SpinButton>
            </div>
          )}
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">配貨數量</span>
          <input
            type="number"
            min={1}
            max={Math.max(effectiveCap, 1)}
            value={qty}
            onChange={(e) => {
              const v = Math.floor(Number(e.target.value));
              setQty(Number.isFinite(v) ? Math.max(0, Math.min(v, effectiveCap)) : 0);
            }}
            className="w-28 rounded-md border border-zinc-300 bg-white px-3 py-2 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
          />
          <span className="ml-2 text-[11px] text-zinc-400">
            上限 {effectiveCap}
            {!topUp && cap > free ? `（自由量 ${free} ＋ 池子 ${cap - free}）` : ""}
            {topUp && shortfall > 0 ? `（含一鍵新增 ${shortfall} 件）` : ""}
          </span>
        </label>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">原因（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：店內現貨先給這位客人"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="rounded-md border border-violet-200 bg-violet-50 px-3 py-2 text-xs text-violet-800 dark:border-violet-900 dark:bg-violet-950/40 dark:text-violet-300">
          送出＝這一行變成<b>已到貨、可取貨</b>。現在不扣庫存、不收款；
          客人到店在「取貨」頁完成交貨時才扣庫存、收款。
          <br />
          客人就在現場、想當場交貨結案 → 請改走「庫存減抵單」。
        </div>

        <div className="flex items-center justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={save}
            disabled={!canSubmit}
            className="rounded-md bg-violet-600 px-5 py-2 font-semibold text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {busy ? "處理中…" : `配 ${qty} 件給這張單`}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

export default AssignStockModal;
