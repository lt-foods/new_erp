"use client";

// 採購單頁「分店／批發追加」（20261002000000_po_store_additions.sql）
//
// 團已結單／已鎖、已轉採購、貨還沒到也還沒派時，替分店或批發加量：
//   後端一次做三件事：原團加店家內部單（+N）、請購單 +X、採購單 +X，**不重開團**。
//   X = max(這個團這個商品還沒叫貨的量, 0)，所以 X 可能 ≠ N（原本多叫就先用掉；原本少叫就一起補）。
// ⛔ 系統不會通知廠商 —— 確認框與成功訊息都要講。
// ⛔ 這是採購單頁專用的新元件；請購單頁那個「分店／批發加單」（#995）不要改成用它。

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { PO_TERM_ZH } from "@/lib/poStatus";

/** rpc_preview_po_store_additions 的一列：一個 (採購單品項, 可選的團)。對不出團時 campaign_id 是 null。 */
export type POStoreAddPreviewRow = {
  po_item_id: number;
  sku_id: number;
  sku_label: string;
  qty_ordered: number;
  campaign_id: number | null;
  campaign_no: string | null;
  campaign_name: string | null;
  can_add: boolean;
  block_reason: string | null;
  // 追加之前這個 (團, 商品) 的需求／已請購／差額；需求是 0 時後端查不到 → null
  demand_qty: number | null;
  already_qty: number | null;
  delta_qty: number | null;
};

export type POStoreAddTarget = {
  poId: number;
  poNo: string;
  poItemId: number;
  label: string;
  skuCode: string;
  unit: string;
  qtyOrdered: number;
  /** 這個品項的所有團（含不能加的 —— 畫面要寫出原因） */
  options: POStoreAddPreviewRow[];
};

type StoreRow = { id: number; code: string | null; name: string; store_kind: string | null };

type AddResult = {
  idempotent?: boolean;
  store_count?: number | string;
  store_added_qty?: number | string;
  po_added_qty?: number | string;
  po_qty_before?: number | string | null;
  po_qty_after?: number | string | null;
};

/** 這個品項能不能按「追加」：至少一個團可以加 → null；否則回給人看的原因 */
export function poStoreAddBlockReason(
  options: POStoreAddPreviewRow[] | undefined,
  previewError: string | null,
): string | null {
  if (previewError) return `查不到可追加的資訊：${previewError}`;
  if (!options || options.length === 0) return "查不到這個商品的追加資訊";
  if (options.some((o) => o.can_add)) return null;
  const reasons = Array.from(new Set(options.map((o) => o.block_reason).filter((r): r is string => !!r)));
  return reasons.join("；") || "目前不能追加";
}

/** 採購單明細列上的按鈕：能按就開視窗；不能按就反灰，滑過去（或點一下）看原因 */
export function POStoreAddButton({
  options,
  previewError,
  onOpen,
}: {
  options: POStoreAddPreviewRow[] | undefined;
  previewError: string | null;
  onOpen: () => void;
}) {
  const reason = poStoreAddBlockReason(options, previewError);
  if (reason == null) {
    return (
      <SpinButton
        onClick={onOpen}
        className="min-h-[44px] touch-manipulation rounded-md border border-blue-400 bg-blue-50 px-2 text-sm font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
        title="幫分店或批發在原團加量：會同時加店家內部單、請購單與這張採購單（不重開團）"
      >
        ＋ 分店／批發追加
      </SpinButton>
    );
  }
  // 反灰但仍可點：平板沒有「滑過去」，點一下才看得到原因（點了也不會做任何事）
  return (
    <span title={reason} className="inline-block">
      <button
        type="button"
        aria-disabled="true"
        onClick={() => window.alert(`現在不能追加：\n${reason}`)}
        className="min-h-[44px] cursor-not-allowed touch-manipulation rounded-md border border-zinc-200 bg-zinc-100 px-2 text-sm text-zinc-400 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-500"
      >
        ＋ 分店／批發追加
      </button>
    </span>
  );
}

/**
 * 追加視窗。由頁面在「要開的時候」才掛上去（關掉就卸下），
 * 所以每次打開都是全新的狀態，request_key 也是每次打開產生一個（比照 #995：同一個視窗重送不會重複加）。
 */
export function POStoreAddModal({
  target,
  onClose,
  onDone,
}: {
  target: POStoreAddTarget;
  onClose: () => void;
  onDone: () => unknown;
}) {
  const [campaignId, setCampaignId] = useState<number | null>(() => {
    // 只有一個團可以選就自動帶（其他團不能加的，畫面上會寫原因）
    const addable = target.options.filter((o) => o.can_add && o.campaign_id != null);
    return addable.length === 1 ? addable[0].campaign_id : null;
  });
  const [requestKey] = useState<string>(() => newUuid());
  const [stores, setStores] = useState<StoreRow[] | null>(null);
  const [storesErr, setStoresErr] = useState<string | null>(null);
  const [qtyByStore, setQtyByStore] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 分店／批發清單：條件跟後端檢查一致（啟用、未刪除、store_kind 是 branch／wholesale），
  // 跟請購單頁 #995 是同一個查法。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("stores")
        .select("id, code, name, store_kind")
        .eq("is_active", true)
        .is("deleted_at", null)
        .in("store_kind", ["branch", "wholesale"])
        .order("name");
      if (cancelled) return;
      if (err) {
        setStoresErr(err.message);
        setStores([]);
        return;
      }
      const rows = ((data ?? []) as StoreRow[]).slice();
      // 分店在前、批發在後
      rows.sort((a, b) => Number(a.store_kind === "wholesale") - Number(b.store_kind === "wholesale"));
      setStores(rows);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const selected = target.options.find((o) => o.campaign_id != null && o.campaign_id === campaignId) ?? null;

  const lines = useMemo(
    () =>
      (stores ?? [])
        .filter((s) => (qtyByStore[s.id] ?? "").trim() !== "")
        .map((s) => ({ store: s, qty: Number(qtyByStore[s.id]) })),
    [stores, qtyByStore],
  );
  const invalid = lines.some((l) => !Number.isFinite(l.qty) || l.qty <= 0);
  const storeTotal = lines.reduce((sum, l) => (Number.isFinite(l.qty) && l.qty > 0 ? sum + l.qty : sum), 0);

  // 預估採購單加幾件（實際以送出當下後端算的為準）
  const predictedX =
    selected && selected.delta_qty != null ? Math.max(Number(selected.delta_qty) + storeTotal, 0) : null;

  async function submit() {
    if (!selected || !selected.can_add) {
      setError("請先選要加到哪一團");
      return;
    }
    if (lines.length === 0 || invalid) {
      setError("請至少填一家，而且數量要大於 0");
      return;
    }
    setError(null);

    // 送出前再抓一次最新的差額，確認框上的數字才不會是幾分鐘前的
    let delta: number | null = selected.delta_qty == null ? null : Number(selected.delta_qty);
    let a = target.qtyOrdered;
    try {
      const { data: fresh, error: freshErr } = await getSupabase().rpc("rpc_preview_po_store_additions", {
        p_po_id: target.poId,
      });
      if (freshErr) throw new Error(freshErr.message);
      const row = ((fresh ?? []) as POStoreAddPreviewRow[]).find(
        (r) => Number(r.po_item_id) === target.poItemId && Number(r.campaign_id) === Number(selected.campaign_id),
      );
      if (!row) throw new Error("這個團已經不在這個商品上了，請關掉視窗重新整理");
      if (!row.can_add) throw new Error(`現在不能追加：${row.block_reason ?? "原因不明"}`);
      delta = row.delta_qty == null ? null : Number(row.delta_qty);
      a = Number(row.qty_ordered);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return;
    }

    const n = storeTotal;
    const x = delta == null ? null : Math.max(delta + n, 0);
    const storeText = lines.map((l) => `${l.store.name} +${formatQty(l.qty)}`).join("、");
    // null ＝ 這一行不顯示；"" ＝ 空一行
    const confirmText = [
      "確定要追加？",
      "",
      `團：${selected.campaign_no ?? ""} ${selected.campaign_name ?? ""}`.trim(),
      `商品：${target.label}`,
      `店家加 ${formatQty(n)} 件：${storeText}（加在各店的店家內部單，不重開團）`,
      x == null
        ? `${PO_TERM_ZH}會加幾件：送出後由系統計算（目前查不到這個團的叫貨差額）`
        : `${PO_TERM_ZH}加 ${formatQty(x)} 件：訂購量 ${formatQty(a)} → ${formatQty(a + x)}`,
      x != null && x < n
        ? `　（這個團原本已經多叫 ${formatQty(n - x)} 件——之前有人取消——先用掉，所以${PO_TERM_ZH}只加 ${formatQty(x)} 件）`
        : null,
      x != null && x > n
        ? `　（其中 ${formatQty(x - n)} 件是這個團原本就還沒叫貨的量，一起補進這張${PO_TERM_ZH}）`
        : null,
      x === 0
        ? "請購單不用改（原本叫的量已經夠）。"
        : `請購單對應那一列會跟著${PO_TERM_ZH}一起加（不用另外動）。`,
      "",
      "⚠ 系統不會通知廠商：送出後請自己打電話或傳訊息跟廠商說數量改了。",
    ]
      .filter((line): line is string => line !== null)
      .join("\n");
    if (!window.confirm(confirmText)) return;

    setBusy(true);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data, error: rpcErr } = await supabase.rpc("rpc_add_po_store_demands", {
        p_po_id: target.poId,
        p_po_item_id: target.poItemId,
        p_campaign_id: selected.campaign_id,
        p_additions: lines.map((l) => ({ store_id: l.store.id, qty: l.qty })),
        p_operator: userData.user?.id,
        p_request_key: requestKey,
      });
      if (rpcErr) throw new Error(rpcErr.message);

      const r = (data ?? {}) as AddResult;
      const after = r.po_qty_after == null ? "?" : formatQty(r.po_qty_after);
      if (r.idempotent) {
        window.alert(
          `這一筆之前已經送出成功了（同一個視窗重送，不會重複加）。\n` +
            `${PO_TERM_ZH}這個商品目前訂購量 ${after}。\n` +
            `請記得通知廠商（系統不會自動通知）。`,
        );
      } else {
        window.alert(
          `已完成。\n` +
            `店家加 ${formatQty(r.store_added_qty)} 件；${PO_TERM_ZH}加 ${formatQty(r.po_added_qty)} 件，改成 ${after}。\n` +
            `請記得通知廠商（系統不會自動通知）。`,
        );
      }
      // 先關視窗再重讀：重讀時整頁會切成「載入中」，視窗若還掛著會被卸下又重新掛上一次
      onClose();
      await onDone();
    } catch (e) {
      // ⚠️ 不換 request_key：如果其實已經寫進去、只是回應沒收到，再按一次會拿到上次的結果，不會重複加
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={busy ? () => {} : onClose} title={`分店／批發追加 · ${target.label}`} maxWidth="max-w-2xl">
      <div className="space-y-4 text-sm">
        <p className="text-xs text-zinc-500">
          {PO_TERM_ZH} {target.poNo} · {target.skuCode} · 目前訂購 {formatQty(target.qtyOrdered)} {target.unit}
        </p>

        {/* 1. 選團 */}
        <div>
          <div className="mb-1 text-xs font-medium text-zinc-500">加到哪一團</div>
          <div className="space-y-1">
            {target.options.map((o) => (
              <label
                key={o.campaign_id ?? "none"}
                className={
                  "flex items-start gap-2 rounded-md border px-3 py-2 " +
                  (o.can_add
                    ? "cursor-pointer border-zinc-300 dark:border-zinc-700"
                    : "border-zinc-200 bg-zinc-50 text-zinc-400 dark:border-zinc-800 dark:bg-zinc-900")
                }
              >
                <input
                  type="radio"
                  name="po-store-add-campaign"
                  className="mt-1"
                  disabled={!o.can_add || busy}
                  checked={o.campaign_id != null && o.campaign_id === campaignId}
                  onChange={() => setCampaignId(o.campaign_id)}
                />
                <span className="min-w-0">
                  <span className="font-mono text-xs">{o.campaign_no ?? "（對不出團）"}</span>{" "}
                  <span>{o.campaign_name ?? ""}</span>
                  {!o.can_add && o.block_reason ? (
                    <span className="mt-0.5 block text-xs text-rose-600 dark:text-rose-400">不能加：{o.block_reason}</span>
                  ) : null}
                </span>
              </label>
            ))}
          </div>
        </div>

        {/* 2. 每家填要加幾件 */}
        <div>
          <div className="mb-1 text-xs font-medium text-zinc-500">每家要加幾件（不加的留空）</div>
          {stores == null ? (
            <div className="text-zinc-500">載入分店…</div>
          ) : storesErr ? (
            <div className="text-rose-600">讀取分店失敗：{storesErr}</div>
          ) : (
            <div className="max-h-[40vh] divide-y divide-zinc-100 overflow-y-auto rounded-md border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
              {stores.map((s) => (
                <div key={s.id} className="flex items-center justify-between gap-2 px-3 py-1.5">
                  <span className="min-w-0 truncate">
                    {s.code ? <span className="font-mono text-xs text-zinc-500">{s.code} </span> : null}
                    {s.name}
                    {s.store_kind === "wholesale" ? <span className="text-xs text-zinc-500">（批發）</span> : null}
                  </span>
                  <input
                    type="number"
                    inputMode="decimal"
                    min="0"
                    step="1"
                    disabled={busy}
                    value={qtyByStore[s.id] ?? ""}
                    onChange={(e) => setQtyByStore((cur) => ({ ...cur, [s.id]: e.target.value }))}
                    className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-right dark:border-zinc-700 dark:bg-zinc-900"
                  />
                </div>
              ))}
            </div>
          )}
        </div>

        {/* 3. 送出前先講清楚會發生什麼 */}
        <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200">
          {!selected ? (
            <div>請先選要加到哪一團。</div>
          ) : (
            <>
              <div>
                店家加 <strong>{formatQty(storeTotal)}</strong> 件
                {predictedX == null ? (
                  <>；{PO_TERM_ZH}會加幾件由系統在送出時計算。</>
                ) : (
                  <>
                    ；{PO_TERM_ZH}加 <strong>{formatQty(predictedX)}</strong> 件（訂購量 {formatQty(target.qtyOrdered)} →{" "}
                    {formatQty(target.qtyOrdered + predictedX)}）。
                  </>
                )}
              </div>
              {predictedX != null && storeTotal > 0 && predictedX < storeTotal ? (
                <div>這個團原本已經多叫 {formatQty(storeTotal - predictedX)} 件（之前有人取消），會先用掉。</div>
              ) : null}
              {predictedX != null && storeTotal > 0 && predictedX > storeTotal ? (
                <div>其中 {formatQty(predictedX - storeTotal)} 件是這個團原本就還沒叫貨的量，會一起補進來。</div>
              ) : null}
            </>
          )}
          <div className="mt-1 font-medium">⚠ 系統不會通知廠商，送出後請自己跟廠商說。</div>
        </div>

        {error ? (
          <div className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-rose-700 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300">
            {error}
          </div>
        ) : null}

        <div className="flex justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-3 py-2 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </button>
          <SpinButton
            onClick={submit}
            disabled={busy || !selected || lines.length === 0 || invalid}
            loading={busy}
            className="rounded-md bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-500 disabled:opacity-50"
          >
            送出追加
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

function formatQty(value: number | string | null | undefined): string {
  const n = Number(value ?? 0);
  if (!Number.isFinite(n)) return "0";
  return Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/\.?0+$/, "");
}

function newUuid(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = Math.floor(Math.random() * 16);
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
