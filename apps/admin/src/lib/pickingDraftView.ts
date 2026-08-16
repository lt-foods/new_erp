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

/**
 * 把 DB 錯誤翻成老闆看得懂、而且知道下一步要做什麼的話。
 *
 * ⚠ 最重要的情境：**前端已上線、migration 還沒人工套**的空窗期。
 *   這個系統的 migration 全部人工套，所以「頁面在、表還沒建」是一定會發生的狀態。
 *   這時 PostgREST 會回英文的 "Could not find the table ... in the schema cache"，
 *   老闆看到只會以為系統壞了 —— 要明講「是 migration 還沒套，不是資料壞掉」。
 *
 * 傳進來的是 supabase-js 的 PostgrestError（它是 Error 的子類，另外帶 code），
 * 也接受任何東西 —— 不會因為錯誤形狀不對就變成 "[object Object]"。
 */
export function describeDraftDbError(err: unknown): string {
  const e = (err ?? {}) as { code?: unknown; message?: unknown };
  const code = typeof e.code === "string" ? e.code : "";
  let raw = typeof e.message === "string" && e.message ? e.message : String(err);
  // 丟進來的不是 Error 也不是 PostgrestError 時，String() 會給 "[object Object]" ——
  // 那是老闆完全看不懂的字。寧可印 JSON，也不要留一句沒有資訊的話。
  if (!raw || raw === "[object Object]") {
    try {
      raw = JSON.stringify(err) ?? "";
    } catch {
      raw = "";
    }
    if (!raw || raw === "{}") raw = "未知錯誤（系統沒有回傳錯誤訊息）";
  }

  // 42P01 = Postgres undefined_table；PGRST205 = PostgREST 在 schema cache 找不到這張表
  const tableMissing =
    code === "42P01" ||
    code === "PGRST205" ||
    (/picking_draft/i.test(raw) && /(does not exist|schema cache)/i.test(raw));
  if (tableMissing) {
    return (
      "「派貨草稿」的資料表還沒建立 —— 這個功能的 migration 還沒套到資料庫。" +
      "請通知工程師套用 20260817000000_picking_drafts.sql，套好之後這一頁就會正常。" +
      "（這不是資料壞掉，也完全不影響其他頁面。）"
    );
  }

  // 42501 = insufficient_privilege；RLS 只開給總部角色（見 migration 的 RLS 段）
  if (code === "42501" || /row-level security/i.test(raw)) {
    return `這個帳號沒有「派貨草稿」的存取權限（草稿只開給總部角色）。原始訊息：${raw}`;
  }

  return raw;
}

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
