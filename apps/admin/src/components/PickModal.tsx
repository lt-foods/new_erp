"use client";

// 總倉收件匣「✎ 修正數量」彈窗（商品 × 分店矩陣）。
//
// ⭐ 切片 A（老闆 2026-08-17 原話）：
//   「修正數量如果 1 改 2 會出現要增加數量，有辦法在旁邊幫我加一個鈕 就是增加庫存嗎」
//   → 商品那一欄多一顆「＋ 補庫存」，開既有的 AddStockModal。**後端零改動**，
//     用的就是庫存總覽那支 rpc_add_stock_by_product。
import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { AddStockModal } from "@/components/AddStockModal";
import { DatePicker } from "@/components/DatePicker";

export type PickWave = {
  id: number;
  wave_code: string;
  wave_date: string;
  status: string;
  store_count: number;
  item_count: number;
  total_qty: number;
  note: string | null;
  created_at: string;
  expected_total: number;
  actual_total: number;
  source_po_id: number | null;
  source_po_no: string | null;
};

export type PickWaveItem = {
  id: number;
  sku_id: number;
  store_id: number;
  qty: number;
  picked_qty: number | null;
  generated_transfer_id: number | null;
};

type Store = { id: number; name: string };
type Sku = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

export const WAVE_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  picking: "撿貨中",
  picked: "撿貨完成",
  shipped: "已派貨",
  cancelled: "已取消",
};

export const WAVE_STATUS_COLOR: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  picking: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  picked: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  shipped: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

export function PickModal({
  wave,
  onClose,
  onSubmitted,
}: {
  wave: PickWave;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [items, setItems] = useState<PickWaveItem[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [skus, setSkus] = useState<Sku[]>([]);
  const [edits, setEdits] = useState<Map<number, string>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [shipping, setShipping] = useState(false);
  const [hqLocId, setHqLocId] = useState<number | null>(null);
  /**
   * 總倉目前可用量（on_hand − reserved，與 rpc_outbound 的判準同一條算式）。
   * ⛔ null ＝ **沒讀到**（有些角色讀不到 stock_balances），不是「庫存 0」——
   *   這兩件事在畫面上必須講不同的話，否則系統異常會偽裝成真的缺貨。
   */
  const [hqAvail, setHqAvail] = useState<Map<number, number> | null>(null);
  /** 開著「＋ 補庫存」的是哪一樣商品、預設補多少 */
  const [addStock, setAddStock] = useState<{ sku: Sku; qty: number } | null>(null);
  /** 補完庫存要就地重載（彈窗不關），讓老闆接著按派貨 */
  const [reloadTick, setReloadTick] = useState(0);
  const [effectiveStatus] = useState<string>(wave.status);
  // 配送日在收件匣設定；shipped/cancelled 唯讀（RPC 也擋）
  const [waveDate, setWaveDate] = useState(wave.wave_date);
  const [savingDate, setSavingDate] = useState(false);

  /** 已派貨／已取消 → 不給補庫存（那張單已經定案了） */
  const locked = effectiveStatus === "shipped" || effectiveStatus === "cancelled";

  const shortageCount = useMemo(() => {
    if (!items) return 0;
    let n = 0;
    for (const it of items) {
      const e = edits.get(it.id);
      const v = e !== undefined ? Number(e) : Number(it.picked_qty ?? it.qty);
      if (!Number.isNaN(v) && v < Number(it.qty)) n += 1;
    }
    return n;
  }, [items, edits]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: itemsData, error: e1 } = await sb
          .from("picking_wave_items")
          .select("id, sku_id, store_id, qty, picked_qty, generated_transfer_id")
          .eq("wave_id", wave.id);
        if (e1) throw new Error(e1.message);
        if (cancelled) return;
        const arr = ((itemsData as PickWaveItem[] | null) ?? []).map((r) => ({
          ...r,
          qty: Number(r.qty),
          picked_qty: r.picked_qty === null ? null : Number(r.picked_qty),
        }));
        setItems(arr);

        // ⚠ id 一律 Number() 正規化再拿去當 Map 的 key：BIGINT 經過 PostgREST 可能是字串，
        //   而 TypeScript 的 `{ id: number }` 宣告在執行期不檢查（本專案 #751 踩過）。
        const skuIds = Array.from(new Set(arr.map((r) => Number(r.sku_id))));
        const storeIds = Array.from(new Set(arr.map((r) => r.store_id)));

        if (skuIds.length) {
          const { data: skuData } = await sb
            .from("skus")
            .select("id, sku_code, product_name, variant_name")
            .in("id", skuIds);
          if (!cancelled) setSkus((skuData as Sku[] | null) ?? []);
        }
        if (storeIds.length) {
          const { data: storeData } = await sb
            .from("stores")
            .select("id, name")
            .in("id", storeIds)
            .order("id");
          if (!cancelled) setStores((storeData as Store[] | null) ?? []);
        }

        const { data: loc } = await sb
          .from("locations")
          .select("id")
          .eq("type", "central_warehouse")
          .eq("is_active", true)
          .limit(1);
        const hq = ((loc as { id: number }[] | null) ?? [])[0]?.id ?? null;
        if (!cancelled) setHqLocId(hq);

        // 總倉即時可用量（切片 A 的「差額」要用）。
        // ⚠ 分批 200 筆：對齊派貨工作台既有寫法（wms/picking/page.tsx:582），避免 URL 過長。
        // ⛔ 讀失敗一律留 null（＝「不知道」），不要退回空 Map 讓畫面顯示「可用 0」——
        //   那會長得跟真的缺貨一模一樣，是本專案反覆踩過的靜默偽裝。
        if (hq != null && skuIds.length) {
          try {
            const m = new Map<number, number>();
            for (let i = 0; i < skuIds.length; i += 200) {
              const { data, error: eb } = await sb
                .from("stock_balances")
                .select("sku_id, on_hand, reserved")
                .eq("location_id", hq)
                .in("sku_id", skuIds.slice(i, i + 200));
              if (eb) throw new Error(eb.message);
              for (const r of (data ?? []) as { sku_id: number; on_hand: number; reserved: number }[]) {
                // 與 rpc_outbound（20260705000000:144）同一條算式：on_hand − reserved
                m.set(Number(r.sku_id), Number(r.on_hand) - Number(r.reserved));
              }
            }
            // 沒有結存列 = 這樣商品在總倉沒有庫存 → 0（這是「查得到、就是 0」，不是查不到）
            for (const id of skuIds) if (!m.has(id)) m.set(id, 0);
            if (!cancelled) setHqAvail(m);
          } catch {
            if (!cancelled) setHqAvail(null);
          }
        }
      } catch (e) {
        if (!cancelled) setError(translateRpcError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [wave.id, reloadTick]);

  const matrix: Map<number, Map<number, PickWaveItem>> = useMemo(() => {
    const m = new Map<number, Map<number, PickWaveItem>>();
    for (const it of items ?? []) {
      if (!m.has(it.sku_id)) m.set(it.sku_id, new Map());
      m.get(it.sku_id)!.set(it.store_id, it);
    }
    return m;
  }, [items]);

  const skuList = useMemo(
    () => skus.sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? "")),
    [skus],
  );

  function setEdit(itemId: number, val: string) {
    setEdits((cur) => {
      const next = new Map(cur);
      next.set(itemId, val);
      return next;
    });
  }

  async function changeDate(newDate: string) {
    if (newDate === waveDate) return;
    setSavingDate(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");
      const { error: e } = await sb.rpc("rpc_update_wave_date", {
        p_wave_id: wave.id,
        p_new_date: newDate,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      setWaveDate(newDate);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSavingDate(false);
    }
  }

  async function saveEdits() {
    if (edits.size === 0) {
      onSubmitted();
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      for (const [itemId, val] of edits) {
        const newQty = Number(val);
        if (Number.isNaN(newQty) || newQty < 0) continue;
        const { error: e } = await sb.rpc("rpc_update_picked_qty", {
          p_wave_item_id: itemId,
          p_new_qty: newQty,
          p_operator: operator,
          p_note: "manual fix in /hq/inbox (picking tab)",
        });
        if (e) throw new Error(`item ${itemId}: ${e.message}`);
      }
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function ship() {
    if (!hqLocId) {
      setError("找不到總倉 location，請確認倉庫設定");
      return;
    }

    const allZero = items != null && items.length > 0 && items.every((it) => {
      const e = edits.get(it.id);
      const v = e !== undefined ? Number(e) : Number(it.picked_qty ?? it.qty);
      return !Number.isNaN(v) && v === 0;
    });
    if (allZero) {
      setError("所有品項撿貨數量均為 0，請先在上方輸入實際撿貨量再派貨");
      return;
    }

    const needsConfirm = effectiveStatus !== "picked";
    const shortMsg = shortageCount > 0
      ? `\n\n⚠ 有 ${shortageCount} 行短缺（撿到的數量少於應撿量），派貨後該店家會拿不到應有量。是否仍要繼續？`
      : "";
    const stepMsg = needsConfirm
      ? `\n\n目前狀態為「${WAVE_STATUS_LABEL[effectiveStatus] ?? effectiveStatus}」,將自動 確認撿貨完成 + 派貨出倉。`
      : "";
    if (!confirm(`確認派貨？將為 ${wave.store_count} 間分店產生 transfer 並從總倉出庫。${stepMsg}${shortMsg}`)) return;
    setShipping(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      if (edits.size > 0) {
        for (const [itemId, val] of edits) {
          const newQty = Number(val);
          if (Number.isNaN(newQty) || newQty < 0) continue;
          const { error: e } = await sb.rpc("rpc_update_picked_qty", {
            p_wave_item_id: itemId,
            p_new_qty: newQty,
            p_operator: operator,
            p_note: "manual fix before dispatch",
          });
          if (e) throw new Error(`item ${itemId}: ${e.message}`);
        }
      }
      if (needsConfirm) {
        const { error: ec } = await sb.rpc("rpc_confirm_picked", {
          p_wave_id: wave.id,
          p_operator: operator,
        });
        if (ec) throw new Error(ec.message);
      }
      const { error: e } = await sb.rpc("generate_transfer_from_wave", {
        p_wave_id: wave.id,
        p_hq_location_id: hqLocId,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      alert(`派貨完成！${wave.store_count} 張 transfer 已建立`);
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setShipping(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="flex max-h-[90vh] w-full max-w-[90vw] flex-col overflow-hidden rounded-md bg-white shadow-xl dark:bg-zinc-900">
        <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="font-semibold">
              修正數量：<span className="font-mono">{wave.wave_code}</span>{" "}
              <span className="text-xs text-zinc-500">
                · 狀態 {WAVE_STATUS_LABEL[effectiveStatus] ?? effectiveStatus}
              </span>
              {shortageCount > 0 && (
                <span className="ml-2 inline-block rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                  ⚠ {shortageCount} 行短缺（可派貨，部分店家拿不到應有量）
                </span>
              )}
            </h2>
            {/* DatePicker 根節點是 div，不能塞進 h2（heading 只能含 phrasing content）→ 做成 h2 的 sibling chip */}
            {effectiveStatus !== "shipped" && effectiveStatus !== "cancelled" ? (
              <div
                className="inline-flex items-center gap-1 rounded bg-blue-100 px-1.5 py-0.5 text-xs font-semibold text-blue-800 dark:bg-blue-950 dark:text-blue-300"
                title="點日期修改配送日"
              >
                📅 配送日
                <DatePicker
                  value={waveDate}
                  onChange={changeDate}
                  popover="fixed"
                  disabled={savingDate}
                  className="rounded border border-dashed border-blue-400 px-1 font-mono text-xs font-semibold text-blue-800 hover:bg-blue-200 disabled:opacity-50 dark:border-blue-600 dark:text-blue-300 dark:hover:bg-blue-900"
                />
              </div>
            ) : (
              <span className="text-xs text-zinc-500">📅 配送日 {waveDate}</span>
            )}
          </div>
          <div className="flex gap-2">
            {effectiveStatus !== "shipped" && edits.size > 0 && (
              <SpinButton
                onClick={saveEdits}
                disabled={submitting}
                className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-xs font-semibold text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800"
                title="僅儲存修正不派貨"
              >
                {submitting ? "儲存中…" : `儲存修正 (${edits.size})`}
              </SpinButton>
            )}
            {effectiveStatus !== "shipped" && effectiveStatus !== "cancelled" && (
              <SpinButton
                onClick={ship}
                disabled={shipping || submitting}
                className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                title={
                  effectiveStatus === "picked"
                    ? "建立 transfer 並從總倉出庫"
                    : "自動 儲存修正 + 確認撿貨完成 + 派貨出倉"
                }
              >
                {shipping ? "派貨中…" : "🚚 派貨出倉"}
              </SpinButton>
            )}
            <SpinButton
              onClick={onClose}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              關閉
            </SpinButton>
          </div>
        </div>

        {error && (
          <div className="border-b border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="overflow-auto p-3">
          {items === null ? (
            <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
          ) : (
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="sticky left-0 z-10 bg-zinc-50 px-3 py-2 text-left text-xs uppercase text-zinc-500 dark:bg-zinc-900">
                    品名
                  </th>
                  <th className="px-2 py-2 text-left text-xs uppercase text-zinc-500">項目</th>
                  {stores.map((s) => (
                    <th
                      key={s.id}
                      className="px-2 py-2 text-right text-xs uppercase text-zinc-500"
                    >
                      {s.name}
                    </th>
                  ))}
                  <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">合計</th>
                </tr>
              </thead>
              <tbody className="divide-y-2 divide-zinc-300 dark:divide-zinc-700">
                {skuList.map((sku) => {
                  const row = matrix.get(sku.id);
                  const expectedTotal = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    return it ? s + Number(it.qty) : s;
                  }, 0);
                  const actualTotal = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    if (!it) return s;
                    const edit = edits.get(it.id);
                    const v = edit !== undefined ? Number(edit) : Number(it.picked_qty ?? it.qty);
                    return s + (Number.isNaN(v) ? 0 : v);
                  }, 0);
                  const totalDiff = actualTotal - expectedTotal;
                  // 總倉可用量 vs 這次要出的量。⛔ avail === null ＝「沒讀到」，
                  //   絕對不可以當成 0 顯示成缺貨（見 hqAvail 的說明）。
                  const avail = hqAvail?.get(Number(sku.id)) ?? null;
                  const shortStock = avail !== null ? Math.max(0, actualTotal - avail) : 0;
                  let skuShortStores = 0;
                  let skuShortQty = 0;
                  if (row) {
                    for (const st of stores) {
                      const it = row.get(st.id);
                      if (!it) continue;
                      const e = edits.get(it.id);
                      const v = Number(e !== undefined ? e : (it.picked_qty ?? it.qty));
                      if (!Number.isNaN(v) && v < Number(it.qty)) {
                        skuShortStores += 1;
                        skuShortQty += Number(it.qty) - v;
                      }
                    }
                  }
                  const skuHasShortage = skuShortStores > 0;
                  return (
                    <Fragment key={sku.id}>
                      <tr className={skuHasShortage ? "bg-red-50/60 dark:bg-red-950/20" : "bg-zinc-50/50 dark:bg-zinc-900/50"}>
                        <td
                          rowSpan={3}
                          className={`sticky left-0 px-3 py-2 align-top ${skuHasShortage ? "bg-red-50 dark:bg-red-950/30" : "bg-white dark:bg-zinc-900"}`}
                        >
                          <div className="font-medium">{sku.product_name ?? "—"}</div>
                          <div className="text-xs text-zinc-500">
                            {sku.sku_code}{sku.variant_name ? ` / ${sku.variant_name}` : ""}
                          </div>
                          {skuHasShortage && (
                            <div className="mt-1 inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-medium text-red-700 dark:bg-red-950 dark:text-red-300">
                              ⚠ 短缺 {skuShortStores} 店 / {skuShortQty} 件
                            </div>
                          )}
                          {/* 切片 A：總倉庫存不夠時，就地把庫存補上（老闆：「有辦法在旁邊幫我加一個鈕
                              就是增加庫存嗎」）。後端零改動，用的是庫存總覽那支 rpc_add_stock_by_product。 */}
                          {!locked && (
                            <div className="mt-1 flex flex-wrap items-center gap-1">
                              <span
                                className={`inline-block rounded px-1.5 py-0.5 text-[10px] font-medium ${
                                  avail !== null && shortStock > 0
                                    ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                                    : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                                }`}
                                title="總倉可用量 = 在庫 − 已保留，與派貨時實際檢查的是同一個數字"
                              >
                                {/* ⛔ 讀不到就要講「讀不到」，不可以顯示 0 —— 那跟真的沒貨長得一模一樣 */}
                                {avail === null
                                  ? "總倉庫存讀不到"
                                  : shortStock > 0
                                  ? `總倉可用 ${avail}，短少 ${shortStock}`
                                  : `總倉可用 ${avail}`}
                              </span>
                              <SpinButton
                                onClick={() =>
                                  setAddStock({ sku, qty: Math.max(1, Math.ceil(shortStock)) })
                                }
                                disabled={hqLocId === null}
                                title={
                                  hqLocId === null
                                    ? "找不到總倉 location，請先確認倉庫設定"
                                    : "對總倉補一筆手動庫存（不可刪除、不可修改）"
                                }
                                className="rounded border border-emerald-300 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700 hover:bg-emerald-50 disabled:opacity-40 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
                              >
                                ＋ 補庫存
                              </SpinButton>
                            </div>
                          )}
                        </td>
                        <td className="px-2 py-1 text-xs text-zinc-500">應發</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          return (
                            <td key={st.id} className="px-2 py-1 text-right font-mono text-zinc-500">
                              {it ? Number(it.qty) : <span className="text-zinc-300">·</span>}
                            </td>
                          );
                        })}
                        <td className="px-3 py-1 text-right font-mono text-zinc-600">{expectedTotal}</td>
                      </tr>
                      <tr>
                        <td className="px-2 py-1 text-xs font-semibold">實分</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          if (!it) return <td key={st.id} className="px-2 py-1 text-right text-zinc-300">·</td>;
                          const edit = edits.get(it.id);
                          const cur = edit !== undefined ? edit : String(it.picked_qty ?? it.qty);
                          const curNum = Number(cur);
                          const expNum = Number(it.qty);
                          const isShort = !Number.isNaN(curNum) && curNum < expNum;
                          const isOver = !Number.isNaN(curNum) && curNum > expNum;
                          const isEdited = edit !== undefined;
                          const isShippedItem = it.generated_transfer_id !== null;
                          const inputCls = isShort
                            ? "border-red-400 bg-red-50 text-red-700 dark:border-red-700 dark:bg-red-950 dark:text-red-300"
                            : isOver
                            ? "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-700 dark:bg-purple-950 dark:text-purple-300"
                            : isEdited
                            ? "border-amber-400 bg-amber-50 dark:bg-amber-950"
                            : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800";
                          return (
                            <td
                              key={st.id}
                              className={`px-1 py-1 text-right ${isShort ? "bg-red-50/50 dark:bg-red-950/20" : ""}`}
                            >
                              <input
                                inputMode="decimal"
                                disabled={isShippedItem || effectiveStatus === "shipped"}
                                value={cur}
                                onChange={(e) => setEdit(it.id, e.target.value)}
                                className={`w-14 rounded-md border px-1 py-0.5 text-right font-mono text-sm font-semibold ${inputCls} disabled:opacity-60`}
                              />
                            </td>
                          );
                        })}
                        <td className={`px-3 py-1 text-right font-mono font-semibold ${
                          totalDiff < 0
                            ? "text-red-700 dark:text-red-300"
                            : totalDiff > 0
                            ? "text-purple-700 dark:text-purple-300"
                            : ""
                        }`}>
                          {actualTotal}
                        </td>
                      </tr>
                      <tr className={skuHasShortage ? "bg-red-50/60 dark:bg-red-950/20" : "bg-zinc-50/50 dark:bg-zinc-900/50"}>
                        <td className="px-2 py-1 text-xs text-zinc-500">狀態</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          if (!it) return <td key={st.id} className="px-2 py-1 text-right text-zinc-300">—</td>;
                          const edit = edits.get(it.id);
                          const cur = Number(edit !== undefined ? edit : (it.picked_qty ?? it.qty));
                          const diff = !Number.isNaN(cur) ? cur - Number(it.qty) : 0;
                          if (diff === 0) {
                            return <td key={st.id} className="px-2 py-1 text-right text-xs text-zinc-400">—</td>;
                          }
                          if (diff > 0) {
                            return (
                              <td key={st.id} className="px-2 py-1 text-right">
                                <span className="inline-block rounded bg-purple-100 px-1.5 py-0.5 text-[10px] font-semibold text-purple-700 dark:bg-purple-950 dark:text-purple-300">
                                  +{diff} 超賣
                                </span>
                              </td>
                            );
                          }
                          return (
                            <td key={st.id} className="bg-red-50/50 px-2 py-1 text-right dark:bg-red-950/20">
                              <span className="inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-semibold text-red-700 dark:bg-red-950 dark:text-red-300">
                                {diff} 短缺
                              </span>
                            </td>
                          );
                        })}
                        <td className={`px-3 py-1 text-right font-mono text-xs font-semibold ${
                          totalDiff === 0
                            ? "text-emerald-600 dark:text-emerald-400"
                            : totalDiff > 0
                            ? "text-purple-600 dark:text-purple-400"
                            : "text-red-600 dark:text-red-400"
                        }`}>
                          {totalDiff === 0 ? "✓" : (totalDiff > 0 ? `+${totalDiff}` : `${totalDiff}`)}
                        </td>
                      </tr>
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {/* 切片 A：就地補總倉庫存。用的是庫存總覽那一支既有的彈窗與 RPC，後端零改動。
          倉別鎖成總倉（locked）、商品鎖成這一列（presetSku）、數量預設帶短少的差額。
          ⛔ 存完不關 PickModal，只重載一次數字 —— 老闆補完貨要能接著按「派貨出倉」。 */}
      {addStock && hqLocId !== null && (
        <AddStockModal
          locations={[{ id: hqLocId, label: "總倉" }]}
          defaultLocationId={String(hqLocId)}
          locked
          presetSku={addStock.sku}
          defaultQty={addStock.qty}
          onClose={() => setAddStock(null)}
          onSaved={() => setReloadTick((n) => n + 1)}
        />
      )}
    </div>
  );
}
