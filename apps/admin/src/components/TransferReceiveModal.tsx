"use client";

import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { fanoutPickupNotifications } from "@/lib/pickupNotify";
import SpinButton from "@/components/SpinButton";

export type Transfer = {
  id: number;
  transfer_no: string;
  source_location: number;
  dest_location: number;
  status: string;
  transfer_type: string;
  shipped_at: string | null;
  received_at: string | null;
  notes: string | null;
  // 空中轉／互助的 AT- 單掛的轉入訂單；收貨頁用它反查「是哪家店轉來的」。
  // 選填：不是每個取用 Transfer 的畫面都有 select 這一欄。
  customer_order_id?: number | null;
};

export type Wave = {
  id: number;
  wave_code: string;
  wave_date: string;
  created_at: string;
};

type TransferItem = {
  id: number;
  transfer_id: number;
  sku_id: number;
  qty_requested: number;
  qty_shipped: number;
  qty_received: number;
  // 自由轉貨（店轉店）的實際品名；有值時掛在虛擬 SKU 上，顯示要用它取代虛擬 SKU 名稱
  description: string | null;
};

type Sku = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

export const TRANSFER_TYPE_LABEL: Record<string, string> = {
  hq_to_store: "總倉配送",
  store_to_store: "店轉店",
  return_to_hq: "退回龍潭",
};

export function parseWaveId(transferNo: string): number | null {
  const m = /^WAVE-(\d+)-S\d+$/.exec(transferNo);
  return m ? Number(m[1]) : null;
}

export function TransferReceiveModal({
  transfer,
  srcName,
  dstName,
  wave,
  notifyMembers = true,
  hideAutoAllocate = false,
  allowAdjust = true,
  onClose,
  onSubmitted,
  onManualReceive,
}: {
  transfer: Transfer;
  srcName: string;
  dstName: string;
  wave: Wave | null;
  // 收貨完成後是否整批推播「到貨」給受影響會員（收貨待辦頁的開關）
  notifyMembers?: boolean;
  // 目的地是分店（手動配用得到）就藏「✓ 收貨·自動配」，只留手動配；
  // 總倉調撥（沒有分店、沒有顧客訂單可配）手動配用不了，這顆是唯一入口，不能藏。
  hideAutoAllocate?: boolean;
  // 已收貨的單是否給「✎ 修改實收」（走 rpc_adjust_received_transfer）。
  // 預設開；沒有理由關掉時不要傳。
  allowAdjust?: boolean;
  onClose: () => void;
  onSubmitted: () => void;
  // 「✋ 收貨·手動配」：不在這裡收貨 — 把改好的實收數量與備註交回收貨待辦頁，
  // 開「這張單對到的訂單」勾選視窗，按確認才一次完成收貨＋配單
  // （見 20260813010000 migration）。沒給這個 prop 就不顯示手動配按鈕。
  onManualReceive?: (
    lines: Array<{ transfer_item_id: number; qty_received: number }> | null,
    note: string | null,
  ) => void;
}) {
  const [items, setItems] = useState<TransferItem[] | null>(null);
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [edits, setEdits] = useState<Map<number, string>>(new Map());
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 已收貨的單按「✎ 修改實收」進入調整模式：格子重新可編輯，基準線改成「目前實收」，
  // 送出走 rpc_adjust_received_transfer（20260903000005）—— 不是再收一次貨。
  const [adjusting, setAdjusting] = useState(false);
  const isReceived = transfer.status === "received";
  const readOnly = transfer.status !== "shipped" && !adjusting;
  // 每一列的「基準量」：收貨時是派出量（預設全收），調整時是目前實收量（預設不動）。
  const baseQty = (it: TransferItem) => (adjusting ? it.qty_received : it.qty_shipped);
  // 撿貨波次派貨單：背後掛著多張顧客訂單，店端拒收會讓訂單卡在派貨中、
  // 庫存虛回總倉（2026-07-30 湖口誤拒收事故）。不給拒收，RPC 端也有同款守衛。
  const isWaveDispatch = wave !== null || parseWaveId(transfer.transfer_no) !== null;

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: itemRows, error: e } = await sb
          .from("transfer_items")
          .select("id, transfer_id, sku_id, qty_requested, qty_shipped, qty_received, description")
          .eq("transfer_id", transfer.id)
          .order("id");
        if (e) throw new Error(e.message);
        const list = ((itemRows as TransferItem[] | null) ?? []).map((r) => ({
          ...r,
          qty_requested: Number(r.qty_requested),
          qty_shipped: Number(r.qty_shipped),
          qty_received: Number(r.qty_received),
        }));
        if (cancelled) return;
        setItems(list);

        const skuIds = Array.from(new Set(list.map((r) => r.sku_id)));
        if (skuIds.length > 0) {
          const { data: skuRows } = await sb
            .from("skus")
            .select("id, sku_code, product_name, variant_name")
            .in("id", skuIds);
          const m = new Map<number, Sku>();
          for (const s of (skuRows as Sku[] | null) ?? []) m.set(s.id, s);
          if (!cancelled) setSkus(m);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [transfer.id]);

  const totalShipped = useMemo(
    () => (items ?? []).reduce((s, r) => s + r.qty_shipped, 0),
    [items],
  );
  const totalReceived = useMemo(() => {
    if (!items) return 0;
    return items.reduce((s, r) => {
      if (readOnly) return s + r.qty_received;
      const e = edits.get(r.id);
      const v = e !== undefined ? Number(e) : adjusting ? r.qty_received : r.qty_shipped;
      return s + (Number.isNaN(v) ? 0 : v);
    }, 0);
  }, [items, edits, readOnly, adjusting]);
  const variance = totalReceived - totalShipped;
  // 有格子被清成空白＝還沒填完。此時 `Number("")` 會讓合計/差異算成 0，看起來像
  // 「真的收 0 件」→ 合計那一列與該行的差異改成顯示「—」，並提示要填數字。
  // （送出端的硬擋在 buildLines()）
  const hasBlankQty = useMemo(() => {
    if (readOnly || !items) return false;
    return items.some((r) => {
      const e = edits.get(r.id);
      return e !== undefined && e.trim() === "";
    });
  }, [items, edits, readOnly]);
  // 短收警語的件數；有空白格時先不算（那時的 variance 是假的）
  const shortQty = !readOnly && !hasBlankQty && variance < 0 ? -variance : 0;

  function setQty(itemId: number, val: string) {
    setEdits((cur) => {
      const next = new Map(cur);
      next.set(itemId, val);
      return next;
    });
  }

  // 錯誤訊息要讓店員看得懂是哪一列 → 用畫面上的商品名，不要用內部 id
  function itemLabel(it: TransferItem): string {
    if (it.description) return it.description;
    const sku = skus.get(it.sku_id);
    return sku?.product_name ?? sku?.sku_code ?? `品項 #${it.id}`;
  }

  // 依畫面上的編輯組出 p_lines（只送有改動的行；數量不合法直接 throw）
  function buildLines(): Array<{ transfer_item_id: number; qty_received: number }> {
    const lines: Array<{ transfer_item_id: number; qty_received: number }> = [];
    for (const it of items ?? []) {
      const e = edits.get(it.id);
      if (e === undefined) continue;
      // ⚠️ 空白格一定要擋下來：`Number("") === 0`，既不是 NaN 也不 < 0，會一路
      // 通過下面的檢查、被記成「收 0 件」，而畫面完全不報錯（店員把數字刪掉
      // 想重打、還沒打就按送出就中招）。
      // ⛔ 也不可以當成「沒編輯」直接 continue —— 那會靜默改成全收，一樣是騙人。
      if (e.trim() === "") {
        throw new Error(`「${itemLabel(it)}」的實收還沒填。請填數字（真的沒收到請填 0）。`);
      }
      const v = Number(e);
      if (Number.isNaN(v) || v < 0) {
        throw new Error(`「${itemLabel(it)}」的實收「${e}」不是有效數量。請填 0 或正整數。`);
      }
      // 20260824020000：多收（實收 > 派出）放行 — 照實入庫，差異回報總倉收件匣
      // 基準量：收貨時是派出量，調整已收時是目前實收量（只送真的被改動的行）
      if (v !== baseQty(it)) {
        lines.push({ transfer_item_id: it.id, qty_received: v });
      }
    }
    return lines;
  }

  // 「✋ 收貨·手動配」：驗完數量就交棒給勾單視窗，這裡不打收貨 RPC
  function handOffManual() {
    if (!onManualReceive) return;
    setError(null);
    try {
      const lines = buildLines();
      onManualReceive(lines.length === 0 ? null : lines, note.trim() === "" ? null : note.trim());
    } catch (e) {
      setError(translateRpcError(e));
    }
  }

  // 「💾 儲存實收」：已收貨的單改數量 —— 走 rpc_adjust_received_transfer
  // （20260903000005）。**純紀錄**：只改 qty_received，不寫庫存、不動單頭狀態、
  // 不碰訂單／取貨／配單（老闆 2026-09-03：跟會員端脫鉤）。
  // 改小之後那一列會自己回到總倉收件匣的「收貨短少」，跟收貨當下填少同一條路。
  async function submitAdjust() {
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const lines = buildLines();
      if (lines.length === 0) throw new Error("沒有任何數量被改動。");

      const { data, error: e } = await sb.rpc("rpc_adjust_received_transfer", {
        p_transfer_id: transfer.id,
        p_lines: lines,
        p_operator: operator,
        p_notes: note.trim() === "" ? null : note.trim(),
      });
      if (e) throw new Error(translateRpcError(e));

      const r = data as
        | {
            items_changed: number;
            qty_delta: number;
            total_received: number;
            short_lines: number;
            over_lines: number;
          }
        | null;
      const shortNote =
        Number(r?.short_lines ?? 0) > 0
          ? `\n⚠ 有 ${r?.short_lines} 項少收，已列入總倉收件匣等總倉決定`
          : "";
      const overNote =
        Number(r?.over_lines ?? 0) > 0 ? `\n🎁 有 ${r?.over_lines} 項多收，已回報總倉` : "";
      alert(
        `實收紀錄已更新：${r?.items_changed ?? 0} 項，實收合計 ${r?.total_received ?? 0}` +
          `${shortNote}${overNote}\n（庫存沒有變動；架上數量對不上請到庫存總覽盤點）`,
      );
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  // 「✓ 收貨·自動配」：收貨並依訂單時間自動配（原行為）
  async function submit() {
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const lines = buildLines();

      const { data, error: e } = await sb.rpc("rpc_receive_transfer", {
        p_transfer_id: transfer.id,
        p_lines: lines.length === 0 ? null : lines,
        p_operator: operator,
        p_notes: note.trim() === "" ? null : note.trim(),
        p_auto_allocate: true,
      });
      if (e) throw new Error(translateRpcError(e));

      const r = data as
        | {
            transfer_id: number;
            items_received: number;
            total_qty_received: number;
            total_variance: number;
          }
        | null;
      const varNote =
        r && Number(r.total_variance) < 0
          ? `\n⚠ 短收 ${Math.abs(Number(r.total_variance))}`
          : "";

      // Fire-and-forget：通知該店所有受影響的顧客「貨已到店」，依「收貨後通知會員」設定可整批關掉
      // 失敗不影響收貨流程（push 失敗只是該會員拿不到推播）
      const pushed = notifyMembers
        ? await fanoutPickupNotifications([transfer.id]).catch((err) => {
            console.warn("push fanout error:", err);
            return 0;
          })
        : 0;
      const pushNote = pushed > 0 ? `\n📩 已推播 ${pushed} 位顧客` : "";
      alert(
        `收貨完成：${r?.items_received ?? 0} 行，實收合計 ${r?.total_qty_received ?? 0}${varNote}${pushNote}`,
      );
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function reject() {
    const reason = prompt(
      "⚠ 拒收＝退貨作廢：整張調撥單會被取消、貨退回寄出端，對應的顧客訂單也會一併取消。\n" +
        "貨還沒送到？請按「取消」關閉此視窗，等貨到再收即可。\n\n確定要拒收請輸入原因:",
    );
    if (reason === null) return;
    setError(null);
    setSubmitting(true);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const { data, error: e } = await sb.rpc("rpc_reject_transfer", {
        p_transfer_id: transfer.id,
        p_reason: reason,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));

      const r = data as { leg3_transfer_id: number | null } | null;
      const leg3Note = r?.leg3_transfer_id
        ? `\n已自動建立退回單 #${r.leg3_transfer_id}（HQ → 原 source 店）`
        : "";
      alert(`拒收完成。${leg3Note}`);
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="flex max-h-[90vh] w-full max-w-3xl flex-col overflow-hidden rounded-md bg-white shadow-xl dark:bg-zinc-900">
        <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
          <div>
            <h2 className="font-semibold">
              收貨：<span className="font-mono">{transfer.transfer_no}</span>
            </h2>
            <div className="mt-0.5 text-xs text-zinc-500">
              {srcName} → {dstName} ·{" "}
              {TRANSFER_TYPE_LABEL[transfer.transfer_type] ?? transfer.transfer_type}
              {wave && (
                <>
                  {" · 來自撿貨單 "}
                  <span className="font-mono">{wave.wave_code}</span>
                </>
              )}
            </div>
          </div>
          <div className="flex gap-2">
            {readOnly ? (
              <>
                <span className="self-center rounded bg-emerald-100 px-2 py-1 text-xs text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                  ✓ 已收貨
                </span>
                {/* 已收貨也要能改數量（老闆 2026-09-03）：收貨當下打錯不必再整張
                    「返回收貨配單」把配單決策全退掉重來。 */}
                {isReceived && allowAdjust && (
                  <SpinButton
                    onClick={() => {
                      setError(null);
                      setEdits(new Map());
                      setNote("");
                      setAdjusting(true);
                    }}
                    className="rounded-md border border-amber-500 px-3 py-1.5 text-xs font-semibold text-amber-700 hover:bg-amber-50 dark:text-amber-400 dark:hover:bg-amber-950"
                    title="更正這張單的實收數量（給總倉的紀錄）：月結數量跟著走、少收／多收進總倉收件匣；庫存與客人取貨不受影響"
                  >
                    ✎ 修改實收
                  </SpinButton>
                )}
              </>
            ) : adjusting ? (
              <>
                <SpinButton
                  onClick={submitAdjust}
                  disabled={submitting || !items}
                  title="只改實收數量的紀錄，不動庫存、不重跑配單；改少的部分會回到總倉收件匣等總倉決定"
                  className="rounded-md bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
                >
                  {submitting ? "儲存中…" : "💾 儲存實收"}
                </SpinButton>
                <SpinButton
                  onClick={() => {
                    setAdjusting(false);
                    setEdits(new Map());
                    setNote("");
                    setError(null);
                  }}
                  disabled={submitting}
                  className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  取消修改
                </SpinButton>
              </>
            ) : (
              <>
                {!hideAutoAllocate && (
                  <SpinButton
                    onClick={submit}
                    disabled={submitting || !items}
                    title="收貨後依下單時間由早到晚自動配給訂單"
                    className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                  >
                    {submitting ? "送出中…" : "✓ 收貨·自動配"}
                  </SpinButton>
                )}
                {onManualReceive && (
                  <SpinButton
                    onClick={handOffManual}
                    disabled={submitting || !items}
                    title="先跳出這張單對到的訂單勾選要配給誰，按「確認收貨」才完成收貨（會帶著這裡調整的實收數量）"
                    className={
                      hideAutoAllocate
                        ? "rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                        : "rounded-md border border-emerald-600 px-3 py-1.5 text-xs font-semibold text-emerald-700 hover:bg-emerald-50 disabled:opacity-50 dark:text-emerald-400 dark:hover:bg-emerald-950"
                    }
                  >
                    ✋ 配單
                  </SpinButton>
                )}
                {isWaveDispatch ? (
                  <span
                    className="self-center text-[11px] text-zinc-400"
                    title="總倉派貨單不可拒收：貨還沒到請等貨到再收；貨品有誤或毀損請聯繫總倉處理"
                  >
                    有問題請聯繫總倉
                  </span>
                ) : (
                  <SpinButton
                    onClick={reject}
                    disabled={submitting || !items}
                    className="rounded-md border border-red-500 px-3 py-1.5 text-xs font-semibold text-red-600 hover:bg-red-50 disabled:opacity-50 dark:border-red-700 dark:text-red-400 dark:hover:bg-red-950"
                  >
                    ✗ 拒收
                  </SpinButton>
                )}
              </>
            )}
            <SpinButton
              onClick={onClose}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              關閉
            </SpinButton>
          </div>
        </div>

        <Timeline transfer={transfer} wave={wave} />

        {error && (
          <div className="border-b border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {/* 調整已收模式的說明 —— 每一句都要對得上程式（本檔第一鐵則）：
            ① 「這是給總倉的紀錄」：rpc_adjust_received_transfer（20260903000005）
               只 UPDATE qty_received，一筆 stock_movements 都不寫。
            ② 「月結數量跟著走」：月結 hq_to_store 的量是 GREATEST(派出, 實收)
               （20260901000000 派車制）→ 改大就跟著大；改小維持派出量，
               那一段錢要總倉在收件匣按「同意退回」才沖掉（20260901000010）。
               ⛔ 不可以寫成「改小月結就會變少」——那是錯的。
            ③ 「庫存不會跟著改」＋「客人不受影響」：老闆 2026-09-03 要求跟會員端脫鉤，
               函式因此不碰庫存／訂單／取貨閘門／配單。 */}
        {adjusting && (
          <div className="border-b border-amber-200 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
            <div className="font-semibold">✎ 修改實收數量（給總倉的紀錄）</div>
            <div className="mt-0.5">
              用途是回頭跟總倉更正「這批到底來了幾件」：月結數量跟著這裡的實收走，
              少收／多收會出現在總倉的收件匣。
            </div>
            <div className="mt-0.5">
              <span className="font-semibold">庫存不會跟著改，客人的訂單與取貨也不受影響。</span>
              架上數量對不上請到「庫存總覽」新增庫存／盤點。
            </div>
          </div>
        )}

        {/* 空白格提示 — 放在不會被捲走的區塊，商品多的時候也看得到 */}
        {hasBlankQty && (
          <div className="border-b border-red-200 bg-red-50 px-4 py-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            有「實收」欄位是空白的，送出前請填數字（真的沒收到請填 0）。
          </div>
        )}

        {/* 短收警語 — 每一句都要能指出出處，⛔ 不要寫查不到根據的推論（2026-08-21 教訓）
            ① 「這等於向總倉提出退回」：收貨後 qty_received < qty_shipped 的明細會自動出現在
               總倉收件匣的「⚠️ 異常 → 收貨短少」等總倉決定
               （v_hq_exceptions 最新版 20260811020010:141-161，條件 t.status='received'
                 AND ti.qty_received < ti.qty_shipped AND shortage_resolution IS NULL）。
            ② 「這 N 件不會進到店家的帳上」：收貨只把「實收量」入庫到分店，
               差額從頭到尾沒有被記進分店庫存，也沒有任何補償動作
               （rpc_receive_transfer 最新版
                 20260814010000_receive_surplus_to_internal_pool.sql:1192-1211，
                 rpc_inbound 的 p_quantity => v_qty_received）。
               ⛔ 舊文案寫「會先從帳上扣掉」是錯的框架：那句話暗示「先加進去再扣掉」，
                  實際是「根本沒加進去」。2026-08-21 複審 P1。
            ③ 「備註總倉看得到」：view 直接把 transfers.notes 串成「店家收貨備註：…」顯示
               （20260811020010:114-115）。
            ⛔ 不可以寫「系統會自動補回總倉」：那要總倉在收件匣按一顆鈕
               （rpc_resolve_transfer_item_shortage，20260811020000:109-110 的角色檢查是
                 v_role NOT IN ('owner','admin','hq_manager','') 才擋
                 —— 也就是空字串角色同樣放行，⛔ 不要再寫成「只有 owner/admin/hq_manager 能按」，
                 2026-08-21 複審 P2），不是自動的。
            ⛔ 不可以寫「填少不等於把貨退回去」：老闆的模型裡店家填少就是在提出退回，
               只是總倉還沒決定接不接受 —— 舊文案的框架是錯的。 */}
        {shortQty > 0 && (
          <div className="border-b border-amber-200 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
            <div className="font-semibold">
              ⚠️ 少收 {shortQty} 件：這等於向總倉提出退回 {shortQty} 件。
            </div>
            <div className="mt-0.5">
              {adjusting ? (
                <>
                  <span className="font-semibold">總倉會在收件匣決定接不接受</span>；
                  這裡只改紀錄，<span className="font-semibold">庫存不會跟著扣</span>。
                </>
              ) : (
                <>
                  這 {shortQty} 件<span className="font-semibold">不會進到你們店的庫存</span>，
                  <span className="font-semibold">總倉會在收件匣決定接不接受</span>。
                </>
              )}
            </div>
            <div className="mt-0.5">
              請在下面備註寫清楚原因（例：總倉多給 2、破損 2），總倉看得到這段備註。
            </div>
          </div>
        )}

        <div className="overflow-auto p-3">
          {items === null ? (
            <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
          ) : (
            <Fragment>
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <th className="px-3 py-2 text-left text-xs uppercase text-zinc-500">商品</th>
                    <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">出貨</th>
                    <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">實收</th>
                    <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">差異</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {items.map((it) => {
                    const sku = skus.get(it.sku_id);
                    const editVal = edits.get(it.id);
                    const cur = readOnly
                      ? String(it.qty_received)
                      : editVal !== undefined
                      ? editVal
                      : String(baseQty(it));
                    const numCur = Number(cur);
                    const diff = !Number.isNaN(numCur) ? numCur - it.qty_shipped : 0;
                    // 20260824020000：多收放行 — 不再標紅擋輸入，跟少收一樣算差異回報
                    const overflowing = false;
                    // 這一行被清成空白＝還沒填完，不是「收 0 件」→ 差異顯示「—」、框線標紅
                    const blank = !readOnly && editVal !== undefined && editVal.trim() === "";
                    return (
                      <tr key={it.id}>
                        <td className="px-3 py-2">
                          {it.description ? (
                            <>
                              <div className="font-medium">{it.description}</div>
                              <div className="text-xs text-zinc-500">
                                <span className="rounded bg-blue-100 px-1.5 py-0.5 text-[10px] font-medium text-blue-700 dark:bg-blue-950 dark:text-blue-300">自由轉貨</span>
                              </div>
                            </>
                          ) : (
                            <>
                              <div className="font-medium">{sku?.product_name ?? "—"}</div>
                              <div className="text-xs text-zinc-500">
                                {sku?.sku_code}
                                {sku?.variant_name ? ` / ${sku.variant_name}` : ""}
                              </div>
                            </>
                          )}
                        </td>
                        <td className="px-3 py-2 text-right font-mono text-zinc-600 dark:text-zinc-300">
                          {it.qty_shipped}
                        </td>
                        <td className="px-3 py-2 text-right">
                          <input
                            inputMode="decimal"
                            value={cur}
                            disabled={readOnly}
                            onChange={(e) => setQty(it.id, e.target.value)}
                            className={`w-20 rounded-md border px-2 py-0.5 text-right font-mono text-sm font-semibold ${
                              overflowing || blank
                                ? "border-red-400 bg-red-50 dark:bg-red-950"
                                : editVal !== undefined
                                ? "border-amber-400 bg-amber-50 dark:bg-amber-950"
                                : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
                            } disabled:bg-zinc-100 disabled:opacity-70 dark:disabled:bg-zinc-800`}
                          />
                          {adjusting && (
                            <div className="mt-0.5 text-[10px] text-zinc-400">
                              原實收 {it.qty_received}
                            </div>
                          )}
                        </td>
                        <td
                          className={`px-3 py-2 text-right font-mono text-xs ${
                            blank || diff === 0
                              ? "text-zinc-400"
                              : diff < 0
                              ? "text-red-600 dark:text-red-400"
                              : "text-purple-600 dark:text-purple-400"
                          }`}
                        >
                          {blank || diff === 0 ? "—" : diff > 0 ? `+${diff}` : `${diff}`}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
                <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <td className="px-3 py-2 text-right text-xs font-semibold text-zinc-500">合計</td>
                    <td className="px-3 py-2 text-right font-mono font-semibold">{totalShipped}</td>
                    {/* 有空白格時合計是假的（`Number("")===0`）→ 顯示「—」，不要讓人以為真的收那麼少 */}
                    <td className="px-3 py-2 text-right font-mono font-semibold">
                      {hasBlankQty ? "—" : totalReceived}
                    </td>
                    <td
                      className={`px-3 py-2 text-right font-mono text-xs font-semibold ${
                        hasBlankQty
                          ? "text-zinc-400"
                          : variance === 0
                          ? "text-emerald-600 dark:text-emerald-400"
                          : variance < 0
                          ? "text-red-600 dark:text-red-400"
                          : "text-purple-600 dark:text-purple-400"
                      }`}
                    >
                      {hasBlankQty ? "—" : variance === 0 ? "✓" : variance > 0 ? `+${variance}` : `${variance}`}
                    </td>
                  </tr>
                </tfoot>
              </table>

              {!readOnly && (
                <div className="mt-4">
                  <label className="block text-xs text-zinc-500">
                    {adjusting ? "備註（調整原因，總倉看得到）" : "備註（短收 / 異常說明）"}
                  </label>
                  <textarea
                    value={note}
                    onChange={(e) => setNote(e.target.value)}
                    rows={2}
                    className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
                    placeholder="例：途中破損 2 件 ／ 總倉多給 2，貨還在總倉"
                  />
                </div>
              )}
              {readOnly && transfer.notes && (
                <div className="mt-4 rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-950 dark:text-zinc-300">
                  <div className="mb-1 text-zinc-500">備註</div>
                  <div className="whitespace-pre-line">{transfer.notes}</div>
                </div>
              )}
            </Fragment>
          )}
        </div>
      </div>
    </div>
  );
}

function Timeline({ transfer, wave }: { transfer: Transfer; wave: Wave | null }) {
  const steps: Array<{ label: string; ts: string | null; done: boolean }> = [
    { label: "撿貨單建立", ts: wave?.created_at ?? null, done: !!wave },
    { label: "派貨出倉", ts: transfer.shipped_at, done: !!transfer.shipped_at },
    { label: "收貨", ts: transfer.received_at, done: transfer.status === "received" },
  ];
  return (
    <div className="border-b border-zinc-200 bg-zinc-50 px-4 py-3 dark:border-zinc-800 dark:bg-zinc-950">
      <ol className="flex items-center gap-1 overflow-x-auto text-xs">
        {steps.map((s, i) => (
          <Fragment key={s.label}>
            <li className="flex min-w-0 items-center gap-2">
              <span
                className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold ${
                  s.done
                    ? "bg-emerald-600 text-white"
                    : "bg-zinc-300 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                }`}
              >
                {s.done ? "✓" : i + 1}
              </span>
              <div className="min-w-0">
                <div className={s.done ? "font-medium" : "text-zinc-500"}>{s.label}</div>
                {s.ts && (
                  <div className="text-[10px] text-zinc-500">
                    {new Date(s.ts).toLocaleString("zh-TW")}
                  </div>
                )}
              </div>
            </li>
            {i < steps.length - 1 && (
              <li
                aria-hidden
                className={`h-[1px] flex-1 ${
                  steps[i + 1].done ? "bg-emerald-400" : "bg-zinc-300 dark:bg-zinc-700"
                }`}
              />
            )}
          </Fragment>
        ))}
      </ol>
    </div>
  );
}
