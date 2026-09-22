// 撿貨矩陣的兩條規則 —— 純函式，畫面與檢查程式共用**同一份**：
//   一、總倉收件匣「✎ 修正數量」彈窗（components/PickModal.tsx）要有哪些分店欄
//   二、派貨工作台（wms/picking/page.tsx）哪些格子「建單規劃器收得下」
//
// 為什麼獨立成一支 lib（2026-09-22，PR #983 審查 P1-1 / P2-2 / P2-4）：
//   規則寫在元件裡，檢查程式（scripts/check-store-kind-columns.mjs）只能抄一份去測；
//   抄的那份測得再綠，真正的程式被改壞也不會知道。放在這裡、畫面 import 它、
//   檢查程式也 import 它 —— 測到的就是畫面上跑的那一份。
//
// ⛔ 這支只放純函式：不 import supabase、不碰 React、不讀網路。
//   唯一的 import 是 ./storeOrder（純資料 + 純函式，理由同 pickingDraftView.ts 檔頭）。
//   ⛔ 也不要用 enum / namespace 這類「去掉型別之後就不是 JavaScript」的寫法：
//   檢查程式是用 Node 直接載入這支 .ts（只把型別去掉），用了就載不進去。
import { compareStoreOrder } from "./storeOrder";

// ============================================================
// 一、「✎ 修正數量」彈窗要有哪些分店欄
// ============================================================
//
// 這個彈窗的空格子可以直接填數字，用 rpc_add_wave_item 把貨加給**原本沒叫貨的店**
// （切片 B，老闆 2026-08-17：「我入庫的會是原本沒叫貨的店家」）。
// 所以欄位有沒有出現不只是好不好看：**沒有欄位 ＝ 那家店在這裡加不到貨。**
//
// 規則：
//   已刪除（stores 查不到，但本單有列）    → 一律顯示，標「已刪除」（異常狀態不藏）
//   已停用 ＋ 本單有列                    → 顯示，標「已停用」
//   已停用 ＋ 本單沒有列                  → ⛔ 不顯示；「顯示批發店」打開也一樣
//                                           （老闆 2026-08-17：「已停用的店家就不用出現了」）
//   啟用中 包子媽分店                     → 一律顯示
//   啟用中 批發 ＋ 本單有列               → 顯示
//   啟用中 批發 ＋ 這次已經填了新數量     → 顯示。⭐ 開關關掉也照樣顯示 ——
//                                           藏起來的話，那一格「看不到、但按儲存照樣會送出」
//   啟用中 批發 ＋ 以上都不是             → 只有「顯示批發店」打開時才顯示
//
// ⭐ 判準是「本單有沒有那一列」而不是「數量大不大」：撿貨單明細的 qty 是 CHECK (qty > 0)
//   （20260423120002_picking_waves.sql:52），有列就一定有量 —— 這一點跟撿貨草稿不一樣
//   （草稿會替每家店建 qty = 0 的列，所以 pickingDraftView.ts 那邊必須看數量合計）。
// ⛔ 有列的一定要留：彈窗的合計是把該商品本單所有列加總、不看畫面上有沒有那一欄，
//   藏掉一個有量的欄，橫的加起來就 ≠ 合計。

/** stores 全表的一列（含停用）。`is_active === false` ＝ 已經收掉的店 */
export type PickModalStore = {
  id: number;
  code: string | null;
  name: string;
  is_active: boolean | null;
  /** 'branch' ＝ 包子媽分店、'wholesale' ＝ 批發（stores.store_kind，20260922000000） */
  store_kind?: string | null;
};

export type PickModalColumn = PickModalStore & { state: "active" | "inactive" | "missing" };

export type PickModalColumns = {
  /** 要畫出來的分店欄，已照老闆指定的動線順序排好（lib/storeOrder） */
  columns: PickModalColumn[];
  /**
   * 「顯示批發店」開關管的那幾家：啟用中的批發店、本單沒有列、這次也還沒填新數量。
   * 開關打開就顯示它們，關掉就藏起來。
   */
  optionalWholesaleCount: number;
  /** 其中目前藏起來的有幾家：開關關著 ＝ optionalWholesaleCount，打開 ＝ 0 */
  hiddenWholesaleCount: number;
};

/**
 * @param allStores       stores **全表**（含停用）
 * @param rowStoreIds     本單（picking_wave_items）有列的分店
 * @param newCellStoreIds 這次在空格子填了新數量的分店（有填就算，填錯的也算 —— 填錯的更要看得到才改得掉）
 * @param showWholesale   「顯示批發店」開關
 */
export function buildPickModalColumns(opts: {
  allStores: PickModalStore[];
  rowStoreIds: Iterable<number>;
  newCellStoreIds: Iterable<number>;
  showWholesale: boolean;
}): PickModalColumns {
  // id 一律正規化成數字再比：BIGINT 經過 PostgREST 可能是字串（#751 踩過）
  const hasRow = new Set(Array.from(opts.rowStoreIds, (id) => Number(id)));
  const hasNewCell = new Set(Array.from(opts.newCellStoreIds, (id) => Number(id)));
  const listed = new Set(opts.allStores.map((s) => Number(s.id)));

  const cols: PickModalColumn[] = opts.allStores.map((s) => ({
    ...s,
    id: Number(s.id),
    state: s.is_active === false ? ("inactive" as const) : ("active" as const),
  }));
  // 本單有列、stores 全表卻查不到 ＝ 被硬刪的店 → 照樣顯示並標「已刪除」
  const missing: PickModalColumn[] = Array.from(hasRow)
    .filter((id) => !listed.has(id))
    .map((id) => ({ id, code: `#${id}`, name: `分店 #${id}`, is_active: false, state: "missing" as const }));

  // 開關管的就是這一種；其餘的店開關開或關都一樣
  const isOptionalWholesale = (c: PickModalColumn) =>
    c.state === "active" && c.store_kind === "wholesale" && !hasRow.has(c.id) && !hasNewCell.has(c.id);
  const optionalWholesaleCount = cols.filter(isOptionalWholesale).length;

  const columns = [...cols, ...missing]
    .filter((c) => c.state !== "inactive" || hasRow.has(c.id))
    .filter((c) => opts.showWholesale || !isOptionalWholesale(c))
    .sort((a, b) => compareStoreOrder(a.code, a.name, b.code, b.name));

  return {
    columns,
    optionalWholesaleCount,
    hiddenWholesaleCount: opts.showWholesale ? 0 : optionalWholesaleCount,
  };
}

// ============================================================
// 二、派貨工作台：哪些格子「建單規劃器收得下」
// ============================================================
//
// 建單規劃器 planWaveAllocations（wms/picking/page.tsx）只肯把貨派給「有訂」的店：
//   第一輪：只倒給「(採購單, 商品, 店) 在需求表裡有列」的採購單
//   第二輪（跨團借調）：只在「這家店這樣商品還有未派需求」時啟動
// 兩輪都進不去的格子，填多少都會原封不動留下來 → 整批建單被擋。
// #983 讓每一家包子媽分店都有固定欄位之後，這種「一定送不出去的格子」從零星幾格變成整欄，
// 所以畫面要把它們鎖起來、標「沒訂」，建單訊息也要講真正原因（#983 審查 P2-2）。
//
// ⭐⭐ 畫面（哪些格子能填）與規劃器（建單時怎麼分類）用的是**同一份判斷**：
//   同一個 key 函式、同一份需求集合、同一個 plannerCanTakeCell。
//   ⛔ 不要在畫面上另外寫一套「看起來差不多」的條件 —— 兩套遲早會漂移，漂移的下場是
//     「格子開著讓你填、建單才說不行」或「明明收得下卻鎖住不給填」。
//   ⚠ 改規劃器那兩輪的進場條件時，plannerCanTakeCell 要一起改。

/** (採購單, 商品, 店) 的 key。⛔ 只有這一支會組，不要在別處手拼字串 */
export function poSkuStoreKey(poId: number, skuId: number, storeId: number): string {
  return `${poId}:${skuId}:${storeId}`;
}

/**
 * 需求表（v_picking_demand_by_po）裡有列的 (採購單, 商品, 店)。
 * 「有列 ＝ 這家店在這張採購單有需求」：view 只在某店對某 PO 對應的開團／補貨有需求時才產生那一列。
 * store_id 為 NULL 的列不算（與規劃器原本的寫法相同）。
 */
export function buildDemandPoSkuStore(
  rows: ReadonlyArray<{ po_id: number; sku_id: number; store_id: number | null }>,
): Set<string> {
  const keys = new Set<string>();
  for (const r of rows) {
    if (r.store_id === null) continue;
    keys.add(poSkuStoreKey(r.po_id, r.sku_id, r.store_id));
  }
  return keys;
}

/**
 * 規劃器收不收得下這一格（這家店、這樣商品）。
 *
 * ⭐ 只回答「有沒有可能收」，不回答「收得下幾件」：
 *   收得下的格子照樣可能因為貨不夠而「缺 N」—— 那是真的缺貨，畫面照舊讓你填、建單照舊擋。
 *   收不下的格子是**填多少都沒用**，所以畫面直接鎖住、標「沒訂」。
 *
 * @param poIds           這樣商品在工作台上的採購單（SkuRow.poList 的 po_id）
 * @param storeDemandLeft 這家店這樣商品的未派需求（工作台的 storeDemandLeft()）
 */
export function plannerCanTakeCell(opts: {
  poIds: readonly number[];
  skuId: number;
  storeId: number;
  demandPoSkuStore: ReadonlySet<string>;
  storeDemandLeft: number;
}): boolean {
  // 第一輪的進場條件：某張含這樣商品的採購單，這家店在需求表裡有列
  const round1 = opts.poIds.some((poId) =>
    opts.demandPoSkuStore.has(poSkuStoreKey(poId, opts.skuId, opts.storeId)),
  );
  // 第二輪（跨團借調）的進場條件：這家店這樣商品還有未派需求
  return round1 || opts.storeDemandLeft > 0;
}
