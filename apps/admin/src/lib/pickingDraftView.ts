// 撿貨草稿的「怎麼把明細排成矩陣」邏輯。
//
// 為什麼獨立成一支 lib 而不是寫在頁面裡：
//   picking_draft_items.sku_id / store_id **沒有外鍵**（見
//   supabase/migrations/20260817000000_picking_drafts.sql 檔頭）。
//   代價是可能出現孤兒列 —— 草稿引用到已經被刪掉的商品或分店。
//   ⛔ 這種列**絕對不能靜默跳過**：這個專案已經被靜默處理坑過一次
//      （PR #744 的根因就是「選取 ∩ 目前清單」把勾選悄悄丟掉）。
//   把判斷抽成純函式，才驗得起來（含孤兒情境），也才不會散在 JSX 裡。
//
// 三種「不在正常狀態」的欄位／列，一律**照樣顯示**並標示出來：
//   - 分店 inactive：stores 裡還在，但 is_active = false（停用後才建的草稿還看得到舊資料）
//   - 分店 missing ：stores 裡整筆查不到（被硬刪）
//   - 商品 missing ：skus 裡查不到 → 用 snapshot 的品名品號照樣印

export type DraftCell = {
  sku_id: number;
  store_id: number;
  qty: number;
  snapshot_sku_code: string | null;
  snapshot_sku_label: string | null;
};

export type StoreRef = { id: number; code: string; name: string };

export type StoreColumn = StoreRef & { state: "active" | "inactive" | "missing" };

export type SkuRow = { sku_id: number; code: string; label: string; missing: boolean };

/**
 * 矩陣要有哪些分店欄位 = 「目前啟用中的分店」∪「這張草稿裡出現過的分店」。
 *
 * ⚠ 只取啟用中的分店是不夠的：草稿建立後有人把分店停用 / 刪掉，
 *   那家店的數量會留在 DB 裡卻在畫面上整欄消失 —— 合計也會跟著少算。
 *   這正是「靜默丟失」，所以額外的分店一定要補成欄位、並標出狀態。
 *
 * @param active 目前 is_active = true 的分店（已依 code 排序）
 * @param cells  這張草稿的所有明細
 * @param known  額外查回來的分店資料（key = store_id）；查不到的就是被硬刪了
 */
export function buildStoreColumns(
  active: StoreRef[],
  cells: DraftCell[],
  known: Map<number, StoreRef>,
): StoreColumn[] {
  const activeIds = new Set(active.map((s) => s.id));
  const cols: StoreColumn[] = active.map((s) => ({ ...s, state: "active" }));

  const extraIds = Array.from(new Set(cells.map((c) => c.store_id))).filter((id) => !activeIds.has(id));
  const extras: StoreColumn[] = extraIds.map((id) => {
    const hit = known.get(id);
    return hit
      ? { ...hit, state: "inactive" as const }
      : { id, code: `#${id}`, name: `已刪除的分店 #${id}`, state: "missing" as const };
  });
  extras.sort((a, b) => a.code.localeCompare(b.code));

  // 額外的排在啟用中的後面：常用的欄位維持在左邊，異常的集中在右邊比較好認
  return [...cols, ...extras];
}

/**
 * 一列 = 一樣商品。品名 / 品號一律取**快照值**（草稿是快照：商品之後改名或被刪，
 * 印出來的仍是當初挑的那樣東西）。
 *
 * @param existingSkuIds 目前 skus 裡還查得到的 id；
 *                       傳 null = 這次查不出來（查詢失敗）→ 一律不標記，
 *                       寧可不標，也不要憑一次失敗的查詢就對老闆說「商品不見了」
 */
export function buildSkuRows(cells: DraftCell[], existingSkuIds: Set<number> | null): SkuRow[] {
  const m = new Map<number, SkuRow>();
  for (const c of cells) {
    if (m.has(c.sku_id)) continue;
    m.set(c.sku_id, {
      sku_id: c.sku_id,
      code: c.snapshot_sku_code ?? "",
      label: c.snapshot_sku_label ?? `（商品 #${c.sku_id}，沒有留下品名）`,
      missing: existingSkuIds ? !existingSkuIds.has(c.sku_id) : false,
    });
  }
  return Array.from(m.values()).sort((a, b) => a.code.localeCompare(b.code));
}

/**
 * 一樣商品的合計。
 * ⚠ 直接從 cells 加總，**不是**加總畫面上看得到的欄位 ——
 *   萬一哪天欄位漏了一欄，合計也還是對的（寧可欄位與合計對不起來被發現，
 *   也不要合計跟著一起少算而看不出來）。
 */
export function rowTotal(cells: DraftCell[], skuId: number): number {
  let sum = 0;
  for (const c of cells) if (c.sku_id === skuId) sum += Number(c.qty);
  return sum;
}
