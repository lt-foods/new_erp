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
// 「不在正常狀態」的欄位／列分**兩類**，處理方式不一樣：
//   ① 異常狀態 → 一律**照樣顯示**並標示出來（藏起來就是拿系統異常冒充一切正常）：
//      - 分店 missing ：stores 裡整筆查不到（被硬刪）
//      - 分店 unknown ：分店查詢失敗 → 標「無法確認」，不武斷說被刪了
//      - 商品 missing / unknown：skus 裡查不到、或查不出來 → 用 snapshot 的品名品號照樣印
//   ② 正常狀態 → 只有「**本草稿有量**」才顯示：
//      - 分店 inactive：stores 裡還在，但 is_active = false ＝ 已經收掉的店，
//        不該再出現在撿貨單上（老闆 2026-08-17：「已停用的店家就不用出現了」）。
//        ⭐ 但有量的一定要留：rowTotal 是把該商品所有 cells 加總、不看畫面上有沒有那一欄，
//        藏掉一個有量的欄，紙上橫的加起來就 ≠ 合計。判準與證明見 buildStoreColumns。

// 唯一的 import：一份純資料 + 純函式的順序表，沒有 I/O、也不需要在測試裡 mock。
// 這支 lib 對「有副作用的東西」（supabase / fetchAllRows）仍然一個都不 import，
// 全部靠呼叫端注入 —— 理由見 loadPrefill 上面那段。
import { compareStoreOrder } from "./storeOrder";

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
  snapshot_store_code: string | null;
  snapshot_store_name: string | null;
};

export type StoreRef = { id: number; code: string; name: string };

/**
 * stores 全表的一列：**含停用**。
 * `is_active === false` → 這一欄只有「本草稿有量」時才留下來，並標「已停用」；
 * 零數量的整欄不顯示（判準見 buildStoreColumns）。
 */
export type StoreRow = StoreRef & { is_active?: boolean | null };

export type StoreColumn = StoreRef & { state: "active" | "inactive" | "missing" | "unknown" };

/**
 * ⭐ 商品的存在性是**三態**，與分店那邊 (StoreColumn.state) 語意一致：
 *   active  = 商品主檔查得到
 *   missing = 查得到別的、就是查不到這一樣 → 真的被刪了
 *   unknown = 查詢異常／結果不可信 → **無法確認**
 * ⛔ 不可以用「不標記」來表達 unknown：那會讓「草稿裡的商品真的全被刪光」
 *    看起來一切正常（阿審 #751 P1）。
 */
export type SkuRow = { sku_id: number; code: string; label: string; state: "active" | "missing" | "unknown" };

/** 商品存在性的查詢結果。known + 空集合 = 「確實一個都沒有」（例如空草稿），不是異常 */
export type SkuExistence =
  | { kind: "known"; ids: Set<number> }
  | {
      kind: "unknown";
      /**
       * ⭐ 即使整批查詢異常，之後從搜尋框加進來的商品仍然是**確定存在**的
       * （它就是從 skus 搜出來的）。把這些記著，才不會連它們也標「無法確認」。
       * 阿審 #751 複審 P2：舊版 unknown 是死狀態，加什麼進去都被誤標。
       */
      confirmedIds: Set<number>;
    };

/**
 * 這張草稿裡「數量合計 > 0」的分店 id。buildStoreColumns 用它決定停用分店要不要顯示。
 *
 * ⚠ 兩個刻意的保守處理，都是同一個理由：**寧可多顯示一欄，也不要把有數字的欄藏掉**。
 *   1. qty 讀不成有限數字（NUMERIC 經過 PostgREST 可能是字串，資料異常也可能是 undefined）
 *      → 直接當成「有量」。讀不懂就藏起來，是拿系統異常冒充「這家沒東西」。
 *   2. 除了「合計 > 0」也認「任一格不是 0」。qty 的 CHECK 是 (qty >= 0)
 *      （migration 20260817000000_picking_drafts.sql:107），所以兩者等價；
 *      但萬一哪天有負數混進來，只看合計會出現 +5/−5 抵消成 0、把有數字的欄藏掉 ——
 *      那正是「橫的加起來 ≠ 合計」。多這一條，被藏掉的欄就保證每一格都是 0。
 */
export function storeIdsWithQty(cells: DraftCell[]): Set<number> {
  const sum = new Map<number, number>();
  const hasQty = new Set<number>();
  for (const c of cells) {
    const id = Number(c.store_id);
    const n = Number(c.qty);
    if (!Number.isFinite(n)) {
      hasQty.add(id);
      continue;
    }
    if (n !== 0) hasQty.add(id);
    sum.set(id, (sum.get(id) ?? 0) + n);
  }
  for (const [id, v] of sum) if (v > 0) hasQty.add(id);
  return hasQty;
}

/**
 * 矩陣要有哪些分店欄位。
 *
 * 規則（老闆 2026-08-17 親口定案。原話：「已停用的店家就不用出現了」；
 *       追問「那草稿裡有數量的呢」→「還是顯示，標『已停用』」）：
 *   啟用中 active                          → 一律有欄位（就算這張草稿一格都沒填）
 *   已停用 inactive ＋本草稿數量合計 = 0   → ⛔ 不顯示這一欄
 *   已停用 inactive ＋本草稿數量合計 > 0   → ✅ 照樣顯示，標「已停用」
 *   已刪除 missing / 無法確認 unknown      → 一律顯示（維持原狀，見下）
 *
 * ⚠ 判準是「這家店在**這張草稿**的數量合計」，**不是**「有沒有那一列」：
 *   加入商品時會替每一家分店都建一列、qty 預設 0
 *   （migration 20260817000000_picking_drafts.sql:96-97、:107），
 *   所以「有沒有 cells」根本分不出東西 —— 這一點最容易做錯。
 *
 * ⭐ 為什麼「有數量的一定要顯示」不是保守而是必要：
 *   rowTotal() 是把**該商品所有 cells** 加總、完全不看畫面上有沒有那一欄（見本檔 rowTotal）。
 *   藏掉一個有數量的欄，紙上橫的加起來就 ≠ 合計，樓下會發現數字兜不攏。
 *   反過來看，被藏掉的欄保證每一格都是 0（見 storeIdsWithQty），
 *   對每一列的貢獻都是 0 → 橫加與合計仍然相等。這才是安全的前提。
 *
 * ⚠ missing / unknown **刻意不套這條規則**：那兩種本來就只在 cells 有資料時才會出現，
 *   而且是異常狀態（分店被硬刪 / 查詢失敗）。把它們藏起來就是拿系統異常冒充一切正常，
 *   正是本專案一路踩過的病。
 *
 * ⓘ 為什麼跟 PR #752 相反：#752 曾把「已停用分店整欄消失」開成 P1，才改成全部顯示。
 *   那條 P1 的前提是錯的 —— 需求原文「要能列出所有分店」的理由是
 *   「有庫存可能多給**沒下訂單**的店」，而已停用＝已經收掉的店，根本不是那一種。
 *   老闆本人 2026-08-17 已經講明，所以這裡改回「零數量的停用店不顯示」。
 *
 * @param allStores stores **全表**（含停用；is_active === false ＝ 停用），已依 code 排序
 * @param cells     這張草稿的所有明細
 * @param known     額外查回來的分店資料（key = store_id）；null = 查詢失敗 → 標「無法確認」
 */
export function buildStoreColumns(
  allStores: StoreRow[],
  cells: DraftCell[],
  known: Map<number, StoreRef> | null,
): StoreColumn[] {
  // ⭐ 「已經有欄位」要用 **stores 全表（含停用）** 來判，不是用下面過濾後的結果 ——
  //   否則被藏起來的停用分店會從 cells 那邊又被當成「不在清單裡」補回來
  //   （變成 missing／unknown 欄），等於白藏，而且還多貼一個錯的狀態標籤。
  // id 一律正規化成數字再比（理由同 buildSkuRows）
  const listedIds = new Set(allStores.map((s) => Number(s.id)));
  const knownById = known ? new Map(Array.from(known, ([k, v]) => [Number(k), v])) : null;
  const cols: StoreColumn[] = allStores.map((s) => ({
    ...s,
    id: Number(s.id),
    state: s.is_active === false ? ("inactive" as const) : ("active" as const),
  }));

  const extraIds = Array.from(new Set(cells.map((c) => Number(c.store_id)))).filter(
    (id) => !listedIds.has(id),
  );
  const extras: StoreColumn[] = extraIds.map((id) => {
    const snap = cells.find((c) => Number(c.store_id) === id);
    const fallback = {
      id,
      code: snap?.snapshot_store_code ?? `#${id}`,
      name: snap?.snapshot_store_name ?? `分店 #${id}`,
    };
    // ⛔ 查詢失敗（known = null）**不可以**當成「這些店都被刪了」——
    //   系統異常偽裝成資料狀態，正是本專案反覆踩過的病。標成「無法確認」。
    if (!knownById) return { ...fallback, state: "unknown" as const };
    const hit = knownById.get(id);
    if (hit) return { ...hit, id, state: "inactive" as const };
    // stores 裡查得到別人、就是查不到這一家 = 真的被硬刪 → 退回加入當下的分店快照。
    // 列印（切片 C）直接吃這個：分店沒了還是要印得出「原本要給哪一家」。
    return { ...fallback, state: "missing" as const };
  });

  // 「停用 + 這張草稿數量合計 0」的欄位到這裡才一起濾掉。
  // ⭐ 刻意放在最後、對 cols 與 extras 一起做：兩邊都可能長出 inactive 欄
  //   （extras 那邊是 stores 全表沒撈到、但單查查得到的情況），
  //   只濾其中一邊就會出現「同樣是停用零數量，有的藏有的沒藏」。
  const withQty = storeIdsWithQty(cells);

  // ⭐ 全部欄位（啟用 / 停用 / 已刪除 / 無法確認）**用單一 key 一起排**，
  //   排法用 lib/storeOrder 那份老闆指定的順序，與派貨工作台矩陣（wms/picking）、
  //   列印撿貨單（picking/print-pick-list）import 的是同一份。
  //   ⛔ 不分段串接：狀態差異用視覺（標籤／底色）表達，不用位置表達 ——
  //   位置會讓老闆在兩頁之間找不到同一家店。
  //   ⓘ 對不上順序表的（例如已刪除只剩快照名稱的 missing 欄）會排到最後面，
  //     ⛔ 但照樣顯示 —— storeOrder 只排序、不過濾。
  return [...cols, ...extras]
    .filter((c) => c.state !== "inactive" || withQty.has(c.id))
    .sort((a, b) => compareStoreOrder(a.code, a.name, b.code, b.name));
}

/**
 * 一列 = 一樣商品。品名 / 品號一律取**快照值**（草稿是快照：商品之後改名或被刪，
 * 印出來的仍是當初挑的那樣東西）。
 *
 * @param existence 商品存在性的查詢結果：
 *                  { kind:"known", ids } → 查得到的 id 集合（空集合＝確實一個都沒有）
 *                  { kind:"unknown" }    → 查詢異常／不可信 → 每一列都標「無法確認」
 */
export function buildSkuRows(cells: DraftCell[], existence: SkuExistence): SkuRow[] {
  // ⚠ 兩邊的 id 都先正規化成數字再比。BIGINT 經過 PostgREST / JSON 有可能是數字也可能是
  //   字串，而 TypeScript 的 `{ id: number }` 宣告**不會在執行期檢查** ——
  //   一邊是 "1630"、另一邊是 1630，Set.has() 就必定失敗、整批誤判成「已不存在」。
  const alive = existence.kind === "known" ? new Set(Array.from(existence.ids, (v) => Number(v))) : null;
  // 整批查不出來時，仍然認得「加入當下確定存在」的那些
  const confirmed =
    existence.kind === "unknown"
      // ?? 是刻意的：TypeScript 的型別在執行期不存在，少帶這個欄位會整頁爆掉。
      // 本專案已經因為「相信宣告的型別」踩過一次（#751 的 id 型別）。
      ? new Set(Array.from(existence.confirmedIds ?? [], (v) => Number(v)))
      : null;
  const m = new Map<number, SkuRow>();
  for (const c of cells) {
    const skuId = Number(c.sku_id);
    if (m.has(skuId)) continue;
    m.set(skuId, {
      sku_id: skuId,
      code: c.snapshot_sku_code ?? "",
      label: c.snapshot_sku_label ?? `（商品 #${skuId}，沒有留下品名）`,
      state: alive
        ? alive.has(skuId)
          ? "active"
          : "missing"
        : confirmed?.has(skuId)
          ? "active"
          : "unknown",
    });
  }
  return Array.from(m.values()).sort((a, b) => a.code.localeCompare(b.code));
}

// ============================================================
// 加入商品時，各分店要帶出多少（＝派貨工作台的自動預填）
// ============================================================

/** v_picking_demand_by_po 之中，算預填會用到的欄位 */
export type DemandRow = {
  po_id: number;
  store_id: number | null;
  demand_qty: number;
  wave_qty: number;
  gr_qty: number;
  po_sku_already_wave?: number | null;
};

export type Prefill = {
  /** 這樣商品的可分配量 = per (po,sku) 去重後 Σgr_qty − Σ已派 */
  available: number;
  /** store_id → { 未派需求, 這次要帶出的量 } */
  byStore: Map<number, { demandLeft: number; give: number }>;
};

/**
 * 預填量 = max(0, 需求 − 已派)，**並夾在該 SKU 的可分配量之內**。
 *
 * ⛔ 這支是**純計算**：只吃傳進來的列，不碰資料庫、不呼叫任何 RPC。
 *
 * ⚠ 這是「照抄」而不是重新發明：語意逐行對齊派貨工作台的預填 effect
 *   `wms/picking/page.tsx:1047-1091`，包含四個容易寫錯的細節：
 *   1. `wave_qty` 已含撿貨單與補貨直派 transfer，`shipped_qty` 是它的子集合 →
 *      **不能再減 shipped**，會重複扣。
 *   2. 可分配量要 **per (po, sku) 去重**後才加總（同一張 PO 會有多列，
 *      gr_qty / po_sku_already_wave 在那些列上是同一個值，不去重會重複累加）。
 *   3. `store_id IS NULL` 的列整列跳過 —— 連可分配量都不算它
 *      （對齊工作台的 `if (r.store_id === null) continue;` 位置）。
 *   4. ⭐ **夾在可分配量上限**：訂 108 只到 105 時，不夾就會預填 108，
 *      老闆照著印給樓下、撿出來卻派不出去（建單會被「超過可分配量」擋掉）。
 *      工作台在 PR #744 已經夾了，這裡是同一套。
 *
 * 逐格分配的順序 = 傳進來的列順序，所以呼叫端要用穩定排序
 *（po_item_id, store_id），否則同樣的資料可能填出不同結果。
 */
export function computePrefill(rows: DemandRow[]): Prefill {
  const poSeen = new Set<number>();
  let availRaw = 0;
  const agg = new Map<number, { demand: number; wave: number }>();

  for (const r of rows) {
    if (r.store_id === null) continue;
    if (!poSeen.has(r.po_id)) {
      poSeen.add(r.po_id);
      availRaw += Number(r.gr_qty) - Number(r.po_sku_already_wave ?? 0);
    }
    const slot = agg.get(r.store_id) ?? { demand: 0, wave: 0 };
    slot.demand += Number(r.demand_qty);
    slot.wave += Number(r.wave_qty);
    agg.set(r.store_id, slot);
  }

  const available = Math.max(0, availRaw);
  let room = available;
  const byStore = new Map<number, { demandLeft: number; give: number }>();
  for (const [storeId, v] of agg) {
    const demandLeft = Math.max(0, v.demand - v.wave);
    const give = Math.min(demandLeft, room);
    byStore.set(storeId, { demandLeft, give });
    room -= give;
  }
  return { available, byStore };
}

/**
 * 一樣商品的合計。
 * ⚠ 直接從 cells 加總，**不是**加總畫面上看得到的欄位 ——
 *   萬一哪天欄位漏了一欄，合計也還是對的（寧可欄位與合計對不起來被發現，
 *   也不要合計跟著一起少算而看不出來）。
 * ⓘ 「欄位漏了一欄」現在已經是**常態而不是意外**：buildStoreColumns 會藏掉
 *   「停用且本草稿數量合計 0」的欄。那種欄保證每一格都是 0、對合計的貢獻是 0，
 *   所以橫加仍然等於合計 —— 這支照樣不能改成加總畫面上的欄位。
 */
export function rowTotal(cells: DraftCell[], skuId: number): number {
  let sum = 0;
  for (const c of cells) if (c.sku_id === skuId) sum += Number(c.qty);
  return sum;
}


export type PrefillResult = {
  available: number;
  byStore: Map<number, { demandLeft: number; give: number }>;
  closeDate: string | null;
  extra: Record<string, unknown>;
};

// 這支 lib 刻意**不 import 任何有副作用／要連外的東西**（連 supabase / fetchAllRows 都不 import）：
// 全部靠呼叫端注入，才驗得起來 —— 測試可以餵一個「會丟錯」的假 db 進來，
// 證明查詢失敗時 loadPrefill 是**丟出例外**而不是回傳空需求。
// （檔頭那支 ./storeOrder 是唯一的例外：純資料 + 純函式，不需要 mock 也驗得起來。）
/** 只用到「下 SELECT」這條唯讀鏈 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type ReadOnlyDb = { from: (table: string) => any };
/** 分頁抓全部（呼叫端傳 @/lib/fetchAllRows 進來） */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type FetchAll = <T>(builder: () => any) => Promise<T[]>;
export type PrefillDeps = { db: ReadOnlyDb; fetchAll: FetchAll };

/**
 * 加入商品時，算「各分店要帶出多少」。
 *
 * ⛔⛔ 全程**唯讀**：只對兩張既有 view 下 SELECT，沒有任何寫回、也沒有呼叫任何 RPC。
 *     老闆原話：「這裡的修改是不會動到原始的，你懂嗎」——
 *     草稿做什麼都不可以改變派貨工作台看到的數字。
 *     （這裡刻意不寫出 RPC 呼叫的字面寫法：審查是 grep「全檔不得出現」，
 *       寫在註解裡會被誤判成違規 —— 與 migration 檔頭同一個理由。）
 *
 * 查詢條件與排序**逐項對齊**派貨工作台（wms/picking/page.tsx:379-385），
 * 只多一個 .eq("sku_id") 把範圍縮到這樣商品：
 *   - has_stock_left  = 這張 PO 這個 SKU 還有可分配量
 *   - has_demand_left = 還有分店的需求沒派完
 *   兩個都對齊，預填出來的數字才會跟工作台一致。
 *   ⚠ 排序也要一樣：逐格分配是依序吃可分配量的，順序不同結果就不同。
 */
export async function loadPrefill({ db, fetchAll }: PrefillDeps, skuId: number): Promise<PrefillResult> {
  // ⛔⛔ 這裡**故意不 catch**：查詢失敗要讓呼叫端整個失敗、商品不要加進去。
  //   舊版失敗時退回「空需求」，畫面會長成 14 個 0 —— 跟「這樣商品真的沒人要」
  //   一模一樣，老闆分不出是壞掉還是真的沒有，然後把錯的清單印給樓下去撿。
  //   這正是本專案反覆踩過的靜默丟失（PR #744 的根因）。
  const rows = await fetchAll<DemandRow & { po_id: number }>(() =>
    db
      .from("v_picking_demand_by_po")
      .select("po_id, store_id, demand_qty, wave_qty, gr_qty, po_sku_already_wave")
      .eq("sku_id", skuId)
      .eq("has_stock_left", true)
      .eq("has_demand_left", true)
      .order("po_item_id", { ascending: true })
      .order("store_id", { ascending: true, nullsFirst: false }),
  );

  const pre = computePrefill(rows);

  // 結單日：切片 C 列印老闆指定要看到。v_picking_demand_by_po 沒有這一欄，
  // 要從 v_po_demand_by_store 取（收貨頁 purchase/orders/receive 用的是同一支）。
  // ⚠ 同一樣商品可能橫跨多個結單日 → 主欄位存**最早**那個，
  //   完整清單另外收進 snapshot_extra，不靜默丟掉資訊（切片 C 再決定怎麼呈現）。
  //   拿不到就留 null，絕不擋住「加入商品」——
  //   ⚠ 但**要在 snapshot_extra 標記是「查失敗」還是「本來就沒有」**，
  //     不可以讓切片 C 面對一個沒頭沒尾的 null 去猜（同 P1-1 的道理）。
  let closeDate: string | null = null;
  const extra: Record<string, unknown> = {};
  const poIds = Array.from(new Set(rows.map((r) => r.po_id)));
  if (poIds.length > 0) {
    try {
      const cdRows = await fetchAll<{ close_date: string | null }>(() =>
        db
          .from("v_po_demand_by_store")
          .select("close_date")
          .eq("sku_id", skuId)
          .in("po_id", poIds)
          .not("close_date", "is", null)
          .order("close_date", { ascending: true }),
      );
      const dates = Array.from(
        new Set(cdRows.map((r) => r.close_date).filter((d): d is string => !!d)),
      ).sort();
      if (dates.length > 0) closeDate = dates[0];
      if (dates.length > 1) extra.close_dates = dates;
    } catch {
      // 結單日是給列印用的加值資訊，拿不到不擋加入商品；
      // 但要留下記號，切片 C 才分得出「沒有結單日」與「當時查失敗」
      extra.close_date_lookup = "failed";
    }
  }
  return { ...pre, closeDate, extra };
}

// ============================================================
// 加入商品之後要對老闆說什麼
// ============================================================

/**
 * ⭐ 三種狀態的措辭必須**一眼分得出來**，因為其中兩種的畫面長得幾乎一樣
 *   （都是一排 0）：
 *     failed  = 需求讀取失敗 → **商品沒有加進去**，要重試
 *     none    = 查詢正常，這樣商品就是沒有未派需求 → 商品已加入，數量自己填
 *     clamped = 有需求但可分配量不夠 → 已加入，帶出被夾住的量
 *     ok      = 有需求且貨夠 → 已加入，帶出完整需求
 *   舊版把 failed 混進 none（查詢失敗就退回空需求），老闆分不出是壞了還是真的沒有，
 *   會把錯的清單印給樓下去撿。這是本專案反覆踩過的靜默丟失。
 */
export type AddOutcome = "failed" | "none" | "clamped" | "ok";

export function addOutcomeMessage(o: {
  kind: AddOutcome;
  productName: string;
  demandTotal?: number;
  giveTotal?: number;
  available?: number;
  reason?: string;
}): string {
  const { kind, productName, demandTotal = 0, giveTotal = 0, available = 0, reason = "" } = o;
  switch (kind) {
    case "failed":
      return (
        `⚠ 讀取各分店需求失敗，「${productName}」**沒有**加入草稿 —— 請再按一次重試。` +
        `（這是系統讀取出錯，不是這樣商品沒有需求。原因：${reason}）`
      );
    case "none":
      return (
        `已加入「${productName}」。需求查詢正常，這樣商品目前**沒有**任何未派需求` +
        `（貨還沒到、需求已派完，或這是臨時插進來的商品）— 各店數量請自己填。`
      );
    case "clamped":
      return (
        `已加入「${productName}」：各店未派需求合計 ${demandTotal} 件，` +
        `但目前可分配只有 ${available} 件 → 帶出 ${giveTotal} 件。` +
        `差額 ${demandTotal - giveTotal} 件要等貨到才派得出去，先印給樓下也撿不到。`
      );
    default:
      return `已加入「${productName}」，帶出各店未派需求共 ${giveTotal} 件。`;
  }
}

/** demandTotal / giveTotal 決定是 none / clamped / ok（failed 由呼叫端在讀取階段就決定） */
export function classifyAddOutcome(demandTotal: number, giveTotal: number): AddOutcome {
  if (demandTotal === 0) return "none";
  if (giveTotal < demandTotal) return "clamped";
  return "ok";
}

/**
 * 「加入商品之後才補出來的那一格」要寫什麼快照。
 *
 * ⭐ 一定要有 snapshot_at 與 snapshot_source：
 *   切片 B 的「對照現況」拿快照當基準算落差，同一張草稿裡有些格子有基準、
 *   有些是裸 NULL，落差就算不出來、也分不出「沒拍」與「拍了但當時是 0」。
 *   ⛔ 不可以全靠 NULL 讓切片 B 去猜。
 *
 * @param pre 當下重拍的需求；傳 null = 這次讀取失敗（改數量照樣要成功，
 *            但要在 extra 標明白為什麼數字是 NULL）
 */
export function lateCellSnapshot(pre: PrefillResult | null, storeId: number, nowIso: string) {
  const extra: Record<string, unknown> = { snapshot_source: "cell_created_later" };
  if (!pre) {
    extra.demand_lookup = "failed";
    return {
      snapshot_at: nowIso,
      snapshot_demand_qty: null,
      snapshot_available_qty: null,
      snapshot_close_date: null,
      snapshot_extra: extra,
    };
  }
  Object.assign(extra, pre.extra, { snapshot_source: "cell_created_later" });
  return {
    snapshot_at: nowIso,
    snapshot_demand_qty: pre.byStore.get(storeId)?.demandLeft ?? 0,
    snapshot_available_qty: pre.available,
    snapshot_close_date: pre.closeDate,
    snapshot_extra: extra,
  };
}

// ============================================================
// 結單日的顯示
// ============================================================

/**
 * 老闆原話：「一定要標示結單日是什麼時候的，不然同樣的商品會分不出來要分那一次的。」
 * 本公司同一個商品會重複開團，光看品名分不出「這批是哪一次的」。
 *
 * ⭐ 三種「沒有日期」必須顯示**不一樣的字**，⛔ 不可以都給空白讓老闆自己猜
 *   （系統異常偽裝成資料狀態，正是本專案一路踩的病）：
 *     none    這樣商品加入當下就沒有任何未派需求 → 本來就沒有結單日可記
 *     failed  加入當下查結單日失敗（snapshot_extra.close_date_lookup === "failed"）
 *     legacy  這一列是「結單日功能上線前」建的（連 snapshot_at 都沒有記到日期欄位）
 * ⭐ 跨多個結單日要**全部列出**（6/24、7/01），不可以只顯示最早那個然後靜默隱藏其他的
 *   —— 那正是老闆說的「分不出來要分哪一次」。
 */
export type CloseDateView = { text: string; kind: "dates" | "none" | "failed" | "legacy" };

/**
 * ⚠️ legacy 的判定**必須看 metadata**，不可以看「欄位存不存在」——
 * SELECT 一旦固定選了那個欄位，key 就永遠存在，判斷永遠 false（阿審 #752 P1-2）。
 * 這裡用 `snapshot_extra.snapshot_source`：新版寫入一定有 add_sku / cell_created_later，
 * 「結單日功能上線前」建的列則沒有。
 */
export function isLegacyDraftCell(extra: Record<string, unknown> | null | undefined): boolean {
  return !extra || typeof extra.snapshot_source !== "string";
}

export function formatCloseDates(
  closeDate: string | null | undefined,
  extra: Record<string, unknown> | null | undefined,
  opts?: { legacy?: boolean },
): CloseDateView {
  const md = (iso: string) => {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
    // 月不補零、日補零（6/24、7/01）：紙本上日的寬度一致，樓下比較好對
    return m ? `${Number(m[2])}/${m[3]}` : iso;
  };
  const listRaw = extra && Array.isArray(extra.close_dates) ? (extra.close_dates as unknown[]) : [];
  const list = listRaw.filter((d): d is string => typeof d === "string");
  if (list.length > 1) {
    // 全部列出，並保證主欄位那個也在裡面（資料萬一不一致也不漏）
    const all = Array.from(new Set(closeDate ? [closeDate, ...list] : list)).sort();
    return { text: all.map(md).join("、"), kind: "dates" };
  }
  if (closeDate) return { text: md(closeDate), kind: "dates" };
  if (extra && extra.close_date_lookup === "failed") {
    return { text: "查詢失敗", kind: "failed" };
  }
  // legacy 由呼叫端傳入（用 isLegacyDraftCell 判定），或這裡自己看 metadata
  if (opts?.legacy ?? isLegacyDraftCell(extra)) return { text: "—", kind: "legacy" };
  return { text: "無", kind: "none" };
}

// ============================================================
// 刪除草稿
// ============================================================

/**
 * 按下刪除當下**重查**回來的品項數。
 *
 * ⭐ 為什麼做成 union、而不是 `number | null`：`null` 會讓呼叫端有辦法「就這樣傳下去」，
 *   靜靜沿用畫面上的舊數字。這裡把「查失敗」做成一個**非講不可**的狀態 ——
 *   由型別逼著措辭去處理它，不是靠自律。
 *
 * @property count  重查到的品項數（去重後的商品數）
 * @property shown  老闆**畫面上**那個數字（列表 load() 當下算的，可能已經過期）
 * @property reason 重查失敗的原因，要原封不動講給老闆聽
 */
export type DraftSkuRecount =
  | { kind: "ok"; count: number; shown: number }
  | { kind: "failed"; shown: number; reason: string };

/**
 * 刪草稿之前，老闆唯一會看到的那段字。
 *
 * ⭐ 一定要明講「連帶刪掉 N 樣商品」：明細是 DB 的 ON DELETE CASCADE 帶走的
 *   （migration 20260817000000_picking_drafts.sql:141-142），刪了**救不回來**，
 *   而列表頁上只看得到一個名字 —— 老闆不會意識到自己順手毀掉了幾十樣商品
 *   × 十幾家店已經填好的數量。
 * ⭐ 也要明講「不影響庫存 / 訂單 / 派貨工作台」：這個系統是正式營運中的，
 *   一個叫「刪除」的紅色按鈕不講清楚範圍，老闆根本不敢按。
 *
 * ⭐⭐ N 一定要是「按下刪除當下重查」的數字，不可以是畫面上那個（老闆 2026-08-17 拍板）：
 *   列表是幾分鐘前載入的，樓下同時在另一台 iPad 上加商品 —— 這正是本功能的設計前提。
 *   確認框說「會刪掉 12 樣」、cascade 實際帶走 32 樣，他以為刪的是一張沒用的小草稿，
 *   其實是樓下做了一半的工，而且救不回來。
 *   ⛔ 兩個數字不一樣時**不可以默默換成新的**：「這張草稿在我載入之後被別人改過」
 *      本身就是他該拿來決定要不要刪的資訊，換掉數字等於瞞著他。
 *   ⛔ 重查失敗時**不可以靜默沿用舊數字**照樣說「會刪掉 N 樣」——
 *      靜默偽裝正是本專案一路踩過的病。明講查不到，讓他自己決定。
 *   ⓘ 數字一致時，措辭與加這道防線之前**一字不差**（一切如常就不要沒事嚇人）。
 *
 * ⓘ 為什麼措辭放在這支 lib 而不是寫在頁面裡：與 addOutcomeMessage 同一個理由 ——
 *   老闆會讀到的字集中一處維護，才不會哪天改了一句忘了另一句。
 */
export function deleteDraftConfirmMessage(name: string, recount: DraftSkuRecount): string {
  // ⓘ 這幾段字最後是丟進 confirm() 的，**不會**被 render 成 markdown ——
  //   寫 `**重點**` 老闆會原封不動看到兩顆星號。要強調就用「」或換句話說。
  const head = `確定要刪除草稿「${name}」？\n\n`;
  const tail =
    `刪掉就救不回來 —— 沒有復原、也不會進垃圾桶。\n\n` +
    `（只刪這張草稿：不會動到任何庫存、訂單，也不影響派貨工作台。）`;

  if (recount.kind === "failed") {
    return (
      head +
      // ⚠ 原因是 describeDraftDbError 的整句話、自己就帶句號 → 不要再包一層「（…）。」，
      //   會變成「…資料庫。）。」。另起一行給它，跟本檔其他地方的「原始訊息：」同一個寫法。
      `⚠ 現在查不到這張草稿裡有幾樣商品。\n原因：${recount.reason}\n\n` +
      `畫面上寫的「${recount.shown} 樣」是這一頁載入當下的數字，不保證是現在的狀況 ——\n` +
      `如果樓下剛剛又加了商品，實際被刪掉的會比 ${recount.shown} 樣更多。\n` +
      `建議先按「取消」，用「重新載入」確認之後再刪。\n\n` +
      tail
    );
  }

  const { count, shown } = recount;
  const body =
    count > 0
      ? `會連帶刪掉裡面的 ${count} 樣商品，包含各分店已經填好的數量。`
      : `這張草稿裡目前沒有商品。`;
  const drift =
    count === shown
      ? ""
      : `⚠ 這張草稿在你打開這一頁之後被改過了：畫面上寫的是 ${shown} 樣，` +
        `現在實際是 ${count} 樣（可能是另一台 iPad 剛剛加了或刪了商品）。\n\n`;
  return head + drift + `${body}\n` + tail;
}
