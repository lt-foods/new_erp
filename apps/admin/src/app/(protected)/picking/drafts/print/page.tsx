"use client";

// 撿貨草稿列印 — 給**樓下撿貨的人**看的紙（不是給店家）。
// 開啟方式：草稿編輯頁點「🖨 列印」開新分頁。 /picking/drafts/print?id=<草稿編號>
//
// 老闆指定要看到的三樣（＋合計）：結單日 / 品名 / 所有分店的數量 / 合計。
//   「所有分店」＝全部分店都要有欄位，不是只有這次有需求的那幾家
//   （他可能有庫存就多給沒下訂單的店）。
//   結單日：本公司同一個商品會重複開團，光看品名分不出「這批是哪一次的」。
//
// ⛔ 為什麼不是改既有的 picking/print-pick-list：
//   那頁的資料源是 v_picking_demand_by_po（現況），分店欄位從 demand 列長出來
//   （只有有需求的店）、還會過濾 has_stock_left/has_demand_left。
//   草稿是**快照**、要印所有分店、不過濾、還要處理孤兒商品／已刪分店 ——
//   兩條路徑除了列印 CSS 幾乎零共用。而紅線正是「不得破壞既有的 ?skus=」，
//   新開一頁讓那條紅線變成結構上不可能違反（兩頁零共用程式碼）。
//
// ⛔ 全程唯讀，而且只讀草稿自己那兩張表 + stores/skus：
//   不寫入任何表、不呼叫任何 RPC、完全不影響派貨工作台的數字。

import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import {
  buildSkuRows,
  buildStoreColumns,
  describeDraftDbError,
  formatCloseDates,
  rowTotal,
  type DraftCell,
  type SkuExistence,
  type StoreRef,
  type StoreRow,
} from "@/lib/pickingDraftView";
import { PRINT_SHEET_CSS, csvFileName, excelSafeText, toCsv } from "@/lib/printSheet";
import SpinButton from "@/components/SpinButton";
import { getTenantName } from "@/lib/tenant";

type Draft = { id: number; name: string; status: string; created_at: string };

type Cell = DraftCell & { snapshot_close_date: string | null; snapshot_extra: Record<string, unknown> | null };

const STORE_STATE_LABEL: Record<string, string> = {
  inactive: "已停用",
  missing: "已刪除",
  unknown: "無法確認",
};

export default function PickingDraftPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const draftId = Number(useSearchParams().get("id"));
  const validId = Number.isFinite(draftId) && draftId > 0;
  const [draft, setDraft] = useState<Draft | null>(null);
  const [cells, setCells] = useState<Cell[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [extraStores, setExtraStores] = useState<Map<number, StoreRef> | null>(new Map());
  const [skuExistence, setSkuExistence] = useState<SkuExistence>({ kind: "unknown", confirmedIds: new Set() });
  const [loading, setLoading] = useState(validId);
  const [error, setError] = useState<string | null>(null);

  // ⚠ 第一件事就 await，不在 effect body 同步 setState（react-hooks/set-state-in-effect）
  const load = useCallback(async () => {
    if (!validId) return;
    try {
      const sb = getSupabase();
      const [{ data: head, error: headErr }, storeRes] = await Promise.all([
        sb.from("picking_drafts").select("id, name, status, created_at").eq("id", draftId).maybeSingle(),
        // ⭐ 撈**全部**分店（含停用）：只撈 is_active 的話，「已停用、而且這張草稿
        //   沒有那家店明細」的分店會整欄消失 —— 老闆要的是所有分店都有欄位。
        sb.from("stores").select("id, code, name, is_active").order("code"),
      ]);
      if (headErr) throw headErr;
      if (!head) throw new Error(`找不到草稿 #${draftId}`);
      if (storeRes.error) throw new Error(`撈分店清單失敗：${describeDraftDbError(storeRes.error)}`);

      // 明細是 SKU×分店 一格一列，50 樣 × 十幾家店就破千 → 一定要分頁，
      // 否則 PostgREST 靜默截在 1000 列、紙上會少印商品（樓下就會漏撿）。
      const rows = await fetchAllRows<Cell>(() =>
        sb
          .from("picking_draft_items")
          .select(
            "sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name, snapshot_close_date, snapshot_extra",
          )
          .eq("draft_id", draftId)
          .order("id", { ascending: true }),
      );

      const allStores = (storeRes.data ?? []) as StoreRow[];
      const listedIds = new Set(allStores.map((s) => Number(s.id)));
      const extraIds = Array.from(new Set(rows.map((c) => Number(c.store_id)))).filter((id) => !listedIds.has(id));
      // ⛔ 查詢失敗（null）要跟「查得到、就是查不到這家」分開 —— 前者標「無法確認」
      let extra: Map<number, StoreRef> | null = new Map<number, StoreRef>();
      if (extraIds.length > 0) {
        try {
          for (let i = 0; i < extraIds.length; i += 200) {
            const { data: got, error: e } = await sb
              .from("stores")
              .select("id, code, name")
              .in("id", extraIds.slice(i, i + 200));
            if (e) throw e;
            for (const s of (got ?? []) as StoreRef[]) extra.set(Number(s.id), s);
          }
        } catch {
          extra = null;
        }
      }

      const skuIds = Array.from(new Set(rows.map((c) => Number(c.sku_id))));
      // 三態，與編輯頁同一套（#751）：known / missing / unknown
      let existence: SkuExistence = { kind: "known", ids: new Set<number>() };
      if (skuIds.length > 0) {
        try {
          const found = new Set<number>();
          for (let i = 0; i < skuIds.length; i += 200) {
            const { data: got, error: e } = await sb.from("skus").select("id").in("id", skuIds.slice(i, i + 200));
            if (e) throw e;
            for (const s of (got ?? []) as { id: number }[]) found.add(Number(s.id));
          }
          // 一樣都沒對上：分不出是查詢異常還是真的整批被刪 → 標「無法確認」，不武斷
          existence = found.size === 0 ? { kind: "unknown", confirmedIds: new Set() } : { kind: "known", ids: found };
        } catch {
          existence = { kind: "unknown", confirmedIds: new Set() };
        }
      }

      setError(null);
      setDraft(head as Draft);
      setStores(allStores);
      setExtraStores(extra);
      setSkuExistence(existence);
      setCells(rows);
    } catch (e) {
      setError(describeDraftDbError(e));
    } finally {
      setLoading(false);
    }
  }, [draftId, validId]);

  useEffect(() => {
    // 新檔案：不在 effect body 同步觸發 setState（react-hooks/set-state-in-effect）。
    // 既有兩頁是舊寫法、屬於既有問題，本次不動。
    queueMicrotask(() => void load());
  }, [load]);

  const skuRows = useMemo(() => buildSkuRows(cells, skuExistence), [cells, skuExistence]);
  const storeCols = useMemo(() => buildStoreColumns(stores, cells, extraStores), [stores, cells, extraStores]);
  const byKey = useMemo(() => {
    const m = new Map<string, number>();
    for (const c of cells) m.set(`${Number(c.sku_id)}:${Number(c.store_id)}`, Number(c.qty));
    return m;
  }, [cells]);

  // 每樣商品的結單日（取該商品任一格的快照 —— 同一樣商品的各格是同一次加入拍的）
  const closeDateBySku = useMemo(() => {
    const m = new Map<number, ReturnType<typeof formatCloseDates>>();
    for (const c of cells) {
      const id = Number(c.sku_id);
      if (m.has(id)) continue;
      // ⛔ 不可以用「欄位存不存在」判斷 —— SELECT 固定選了它，key 永遠在。
      //   改看 metadata（snapshot_extra.snapshot_source），見 isLegacyDraftCell。
      m.set(id, formatCloseDates(c.snapshot_close_date, c.snapshot_extra));
    }
    return m;
  }, [cells]);

  // 整張草稿都沒有結單日資料 = 多半是「結單日功能上線前」建的那幾張。
  // ⚠ 這句話要跟「查詢失敗」明顯不同 —— 不可以讓老闆以為系統壞了。
  const legacyDraft = useMemo(
    () => skuRows.length > 0 && skuRows.every((r) => closeDateBySku.get(r.sku_id)?.kind === "legacy"),
    [skuRows, closeDateBySku],
  );
  const anyLookupFailed = useMemo(
    () => skuRows.some((r) => closeDateBySku.get(r.sku_id)?.kind === "failed"),
    [skuRows, closeDateBySku],
  );
  const grandTotal = useMemo(() => cells.reduce((s, c) => s + Number(c.qty), 0), [cells]);

  // 匯出 CSV：欄位與紙本完全一致（結單日 / 品名 / 品號 / 合計 / 各分店），
  // 免得紙本與檔案對不起來。⚠ 一定要 BOM，否則 Excel 開中文是亂碼。
  function exportCsv() {
    // ⚠ 文字欄位一律過 excelSafeText：擋公式注入 + 擋 Excel 把品號改成日期/科學記號。
    //   數量欄維持數字，Excel 才加得了總。
    const header = [
      "結單日",
      "品名",
      "品號",
      "合計",
      ...storeCols.map((st) => (st.state === "active" ? st.name : `${st.name}(${STORE_STATE_LABEL[st.state]})`)),
    ];
    const body = skuRows.map((row) => [
      excelSafeText(closeDateBySku.get(row.sku_id)?.text ?? "無"),
      excelSafeText(
        row.state === "active" ? row.label : `${row.label}（${row.state === "missing" ? "商品主檔已查不到" : "無法確認"}）`,
      ),
      excelSafeText(row.code),
      rowTotal(cells, row.sku_id),
      ...storeCols.map((st) => byKey.get(`${row.sku_id}:${st.id}`) ?? 0),
    ]);
    const csv = toCsv([header, ...body]);
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = csvFileName(draft?.name ?? "", new Date().toISOString());
    a.click();
    URL.revokeObjectURL(url);
  }

  if (loading) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  if (!draft) {
    return (
      <div className="p-6 text-sm text-red-700">
        {error ?? (validId ? `找不到草稿 #${draftId}` : "網址缺少草稿編號（?id=）")}
      </div>
    );
  }

  return (
    <>
      <style>{PRINT_SHEET_CSS}</style>
      <div className="p-4">
        <div className="no-print mb-3 flex flex-wrap items-center gap-2">
          <SpinButton
            onClick={() => window.print()}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
          >
            🖨 列印
          </SpinButton>
          <SpinButton
            onClick={exportCsv}
            disabled={skuRows.length === 0}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm disabled:opacity-40 dark:border-zinc-700"
          >
            ⬇ 匯出 CSV
          </SpinButton>
          <SpinButton
            onClick={load}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700"
          >
            重新整理
          </SpinButton>
          <span className="text-xs text-zinc-500">
            共 {skuRows.length} 樣商品 × {storeCols.length} 個分店欄位・總計 {grandTotal} 件
          </span>
        </div>

        {error && <div className="no-print mb-3 rounded border border-red-300 bg-red-50 p-2 text-sm text-red-800">{error}</div>}

        <header className="mb-2">
          <h1 className="text-lg font-semibold">
            {getTenantName()}・撿貨草稿：{draft.name}
          </h1>
          <p className="text-xs text-zinc-600">
            草稿 #{draft.id}・建立 {String(draft.created_at).slice(0, 16).replace("T", " ")}
            ・列印 {new Date().toLocaleString("sv-SE").slice(0, 16)}
            ・共 {skuRows.length} 樣・總計 {grandTotal} 件
          </p>
          {legacyDraft && (
            <p className="mt-1 text-xs text-zinc-700">
              ※ 這張草稿沒有結單日資料 —— 它建立於「結單日」功能上線前。
              <strong>不是系統故障</strong>；重建一張新草稿就會有結單日。
            </p>
          )}
          {anyLookupFailed && (
            <p className="mt-1 text-xs text-amber-800">
              ※ 有商品的結單日在<strong>加入當下查詢失敗</strong>（表格內標「查詢失敗」）——
              那幾樣的結單日沒有記到，不是「沒有結單日」。
            </p>
          )}
        </header>

        {skuRows.length === 0 ? (
          <p className="text-sm text-zinc-500">這張草稿還沒有任何商品。</p>
        ) : (
          <table className="pick-table">
            <thead>
              <tr>
                <th className="frozen-col">結單日</th>
                <th className="sku-cell frozen-col">品名 / 品號</th>
                <th className="frozen-col">合計</th>
                {storeCols.map((st) => (
                  <th key={st.id} className={st.state === "active" ? "store-col" : "store-col odd-col"}>
                    {st.name}
                    {st.state !== "active" && <span className="note">{STORE_STATE_LABEL[st.state]}</span>}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {skuRows.map((row) => {
                const cd = closeDateBySku.get(row.sku_id);
                return (
                  <tr key={row.sku_id}>
                    <td className={`num-cell ${cd?.kind === "dates" ? "" : "odd-col"}`}>{cd?.text ?? "無"}</td>
                    <td className="sku-cell">
                      {row.label}
                      <span className="note" style={{ color: "#64748b" }}>{row.code}</span>
                      {row.state === "missing" && <span className="note">⚠ 商品主檔已查不到（顯示加入當下的名稱）</span>}
                      {row.state === "unknown" && <span className="note">⚠ 無法確認商品是否還在主檔</span>}
                    </td>
                    <td className="num-cell frozen-col">{rowTotal(cells, row.sku_id)}</td>
                    {storeCols.map((st) => {
                      const q = byKey.get(`${row.sku_id}:${st.id}`) ?? 0;
                      return (
                        <td
                          key={st.id}
                          className={`num-cell ${st.state === "active" ? "store-col" : "store-col odd-col"} ${q === 0 ? "zero" : ""}`}
                        >
                          {q === 0 ? "－" : q}
                        </td>
                      );
                    })}
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
