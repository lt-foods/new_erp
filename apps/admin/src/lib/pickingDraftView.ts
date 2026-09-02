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
      "「撿貨草稿」的資料表還沒建立 —— 這個功能的 migration 還沒套到資料庫。" +
      "請通知工程師套用 20260817000000_picking_drafts.sql，套好之後這一頁就會正常。" +
      "（這不是資料壞掉，也完全不影響其他頁面。）"
    );
  }

  // 42501 = insufficient_privilege；RLS 只開給總部角色（見 migration 的 RLS 段）
  if (code === "42501" || /row-level security/i.test(raw)) {
    return `這個帳號沒有「撿貨草稿」的存取權限（草稿只開給總部角色）。原始訊息：${raw}`;
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
  // 加入商品那一刻的「這家店還沒派的需求」與「這樣商品的可分配量」。
  // 20260902：rowShortfall 拿它算商品列的紅字。舊草稿（欄位上線前建的）是 null。
  snapshot_at?: string | null;
  snapshot_demand_qty?: number | null;
  snapshot_available_qty?: number | null;
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
 * 平均版分配：把 `available` **平均**分到「還有未派需求」的店，各店 cap 在自己的 demandLeft。
 * 某店的需求不足以吃下它那一份時，剩下的量下一輪重新平均（最多 10 輪）。
 *
 * ⛔⛔ 這支是「**多給一個選項**」，⛔ 不是 computePrefill 的替代品。
 *   老闆 2026-08-17 拍板：加入商品的自動預填**維持**「先來後到、前面吃滿後面掛 0」，
 *   理由是「貨不夠時讓一家真的能開賣，好過五家都缺貨賣不動」。
 *   → computePrefill **一個字都不能改**，這支只在草稿頁那顆「⚖ 平均」鈕按下去時才跑。
 *
 * ⭐ 演算法**逐行對齊**派貨工作台的 `autoDistribute()`（wms/picking/page.tsx:1406-1451），
 *   ⛔ 不要自己重新發明。兩邊要一起改，否則同一顆「⚖ 平均」在兩頁會給出不同的數字。
 *   對照表（工作台 → 這裡）：
 *     sku.totalAvailable            → pre.available
 *     allStores                     → pre.byStore 的 key（＝ demand 裡出現過的店）
 *     storeDemandLeft(sku, storeId) → pre.byStore.get(storeId).demandLeft
 *   連「eligible 已保證 cur < d、裡面那個 `if (cur < d)` 其實是多餘的」都照抄 ——
 *   逐行一樣才看得出兩邊有沒有漂移。
 *
 * ⭐⭐ `orderedStoreIds` 是**必填**，不是可選的（阿審 2026-09-01 P1-1）：
 *   「餘數只夠給幾家、而那幾家還缺的量一樣多」時，要給誰就由這個順序決定。
 *   工作台的 `allStores` 是先經 `compareStoreOrder` 排過的（wms/picking/page.tsx:874-878），
 *   所以它平手時吃的是**老闆指定的店序**。
 *   ⛔ 這裡如果沿用 `pre.byStore` 的插入順序（＝ loadPrefill 的 `po_item_id, store_id`），
 *   同一樣商品在兩頁按同一顆鈕，平手時會給到不同的店 —— 我一開始判成「無法避免」是錯的：
 *   草稿頁本來就有排好序的 `storeCols`（buildStoreColumns 用的是同一支 compareStoreOrder），
 *   把它傳進來就對齊了。
 *   做成必填參數而不是可選，是為了讓「有沒有想過順序」變成**型別逼出來的問題**，
 *   不是靠下一個人自律（同本檔 DraftSkuRecount / DraftPrecheck 的作法）。
 *   ⓘ 不在這份順序裡的店排到最後面，彼此維持傳進來的順序 —— 照樣分得到，⛔ 只是排後面。
 *     （會發生在「停用、本草稿數量 0 所以沒有欄位、但還有未派需求」這種極端情況：
 *       那種店在工作台上有欄位、在草稿頁上沒有，兩頁本來就不是同一組店。）
 *
 * ⭐ 為什麼吃 `Prefill` 而不是像規格書寫的吃 `DemandRow[]`：
 *   `available` 與 `demandLeft` 的前處理有四個很容易寫錯的坑（見 computePrefill 上面那段），
 *   而算這兩個數字的**唯一**入口是 loadPrefill（它內部就是呼叫 computePrefill）。
 *   吃 rows 的話，呼叫端得自己再下一次一模一樣的查詢 —— 多一次往返，還多一份會漂移的複製品。
 *   吃 Prefill 就保證「先來後到版」與「平均版」的前處理是**同一次計算的結果**，
 *   不可能出現兩支對「可分配量 / 還缺多少」給不同答案。
 *
 * @param pre             computePrefill()／loadPrefill() 算出來的結果（available 與各店 demandLeft）
 * @param orderedStoreIds 平手時的先後順序（草稿頁傳 storeCols 的 id，＝老闆指定的店序）
 * @returns 同樣的 available 與 demandLeft，只有 give 換成平均版；byStore 依 orderedStoreIds 排好
 */
export function computePrefillEven(pre: Prefill, orderedStoreIds: number[]): Prefill {
  // 先把各店照指定的店序排好，之後整支都吃這個順序 ——
  // ⭐ 主迴圈其實不在意順序（每家各自 min(each, 還缺多少)，互不影響），
  //   會用到順序的只有下面 each === 0 那個「一家給 1」的分支。排在最前面做，
  //   是為了讓「這支到底照什麼順序」只有一個答案、不必在兩個地方各想一次。
  const rank = new Map<number, number>();
  // id 一律 Number() 正規化（BIGINT 經過 PostgREST 可能是字串，#751 踩過）；
  // 重複的 id 以第一次出現的位置為準
  orderedStoreIds.forEach((sid, i) => {
    const n = Number(sid);
    if (!rank.has(n)) rank.set(n, i);
  });
  const last = Number.MAX_SAFE_INTEGER;
  const src: [number, { demandLeft: number; give: number }][] = [...pre.byStore.entries()]
    .map(([sid, v]) => [Number(sid), v] as [number, { demandLeft: number; give: number }])
    // ⚠ .sort 是穩定排序（ES2019 起是規格保證，browserslist 的最低版本都有）：
    //   不在店序裡的（rank 都是 last）維持傳進來的順序，結果仍然是唯一的。
    .sort((a, b) => (rank.get(a[0]) ?? last) - (rank.get(b[0]) ?? last));

  const give = new Map<number, number>();
  for (const [sid] of src) give.set(sid, 0);

  let pool = pre.available;
  for (let iter = 0; iter < 10 && pool > 0; iter += 1) {
    const eligible = src.filter(([sid, v]) => (give.get(sid) ?? 0) < v.demandLeft);
    if (eligible.length === 0) break;

    const each = Math.floor(pool / eligible.length);
    if (each === 0) {
      // 剩下的比「還有需求的店數」還少 → 依「還缺多少」由大到小，一家給 1，給完為止。
      // ⭐ 缺一樣多時（＝平手）落到 eligible 的順序，也就是上面排好的 orderedStoreIds 店序
      //   —— 這正是與工作台對齊的那一段（.sort 穩定，不會把平手的順序打亂）。
      const sorted = [...eligible].sort((a, b) => b[1].demandLeft - a[1].demandLeft);
      for (let i = 0; i < pool && i < sorted.length; i += 1) {
        const [sid, v] = sorted[i];
        const cur = give.get(sid) ?? 0;
        if (cur < v.demandLeft) give.set(sid, cur + 1);
      }
      pool = 0;
      break;
    }

    let givenThisRound = 0;
    for (const [sid, v] of eligible) {
      const cur = give.get(sid) ?? 0;
      const add = Math.min(each, v.demandLeft - cur);
      give.set(sid, cur + add);
      givenThisRound += add;
    }
    pool -= givenThisRound;
    // 一輪下來一件都沒分出去 → 再跑也不會有進展，直接收工（⛔ 不要靠 10 輪上限硬撐）
    if (givenThisRound === 0) break;
  }

  const byStore = new Map<number, { demandLeft: number; give: number }>();
  for (const [sid, v] of src) byStore.set(sid, { demandLeft: v.demandLeft, give: give.get(sid) ?? 0 });
  return { available: pre.available, byStore };
}

/**
 * 「⚖ 平均」按下去之後，這一列每一格要變成多少、以及該用哪一種寫法寫回去。
 *
 * ⛔ 純計算：不碰資料庫。抽出來的理由與本檔開頭那段一樣 ——
 *   **散在 JSX 裡就驗不起來**，而這支決定的是「會不會把老闆填好的數字洗掉」。
 *
 * ⭐ 三條規則，每一條都有非它不可的理由：
 *   1. **既有的格子只改 qty**，⛔ 不可以用 upsert 把整包欄位（含快照）蓋上去。
 *      snapshot_demand_qty / snapshot_available_qty 記的是「加入商品那一刻」的值，
 *      切片 B 的「對照現況」拿它當基準算落差；被重拍成現在的值，落差就永遠是 0。
 *      （commitCell 改既有格子時也只寫 qty + updated_by，這裡是同一條規則。）
 *   2. **沒有列、又不用給的格子不建**：為了寫一個 0 多插一列，畫面（留白）與合計（+0）
 *      完全一樣，只是多一列垃圾。
 *   3. **數量沒變的格子不寫**：與 commitCell 的短路同一條，少一次往返也少一個出錯面。
 *
 * ⭐ 「這一列有哪些格子」＝ 畫面上的欄 ∪ 已經有的格子 ∪ 需求裡出現過的店，三者缺一不可：
 *   欄     —— 老闆看得到的每一格都要有明確的新數字，否則橫加起來對不上合計
 *   已有格 —— 含被藏起來的停用分店（現在是 0，設 0 是 no-op；漏掉卻可能留著舊數字）
 *   需求店 —— ⛔ 少了它，某家店分到的量會被**靜靜丟掉**，合計就對不上可分配量
 *
 * @param even        computePrefillEven() 的結果
 * @param columnIds   畫面上有欄位的分店 id（storeCols）
 * @param cells       **這樣商品**目前的格子（呼叫端先濾好）
 */
export function planEvenWrite<T extends { id: number; store_id: number; qty: number }>(
  even: Prefill,
  columnIds: number[],
  cells: T[],
): {
  /** store_id → 這一格最後應該是多少（含 0）。合計欄 = 這些值的和 */
  targets: Map<number, number>;
  /** 還沒有列、且要給 > 0 → 要新增（呼叫端負責帶快照欄位） */
  insert: { storeId: number; qty: number }[];
  /** 同一個目標數量的既有列併成一組 → 一組一次 UPDATE（平均分配下大多是同一個數字） */
  update: { qty: number; rows: T[] }[];
  /** 會被蓋掉、目前不是 0 的格子數（呼叫端用它決定要不要先問過老闆） */
  overwriting: number;
  /** targets 的合計 ＝ 這次總共會分出去多少件 */
  giveTotal: number;
} {
  // id 一律 Number() 正規化：BIGINT 經過 PostgREST 可能是字串（#751 踩過），
  // 不正規化的話 Map.get() 對不上，每一家都會被算成「沒有需求 → 0」。
  const give = new Map<number, number>();
  for (const [sid, v] of even.byStore) give.set(Number(sid), v.give);

  const storeIds = new Set<number>(columnIds.map((v) => Number(v)));
  for (const c of cells) storeIds.add(Number(c.store_id));
  for (const sid of give.keys()) storeIds.add(sid);

  const byStore = new Map<number, T>();
  for (const c of cells) byStore.set(Number(c.store_id), c);

  const targets = new Map<number, number>();
  const insert: { storeId: number; qty: number }[] = [];
  const grouped = new Map<number, T[]>();
  let overwriting = 0;
  let giveTotal = 0;

  for (const storeId of storeIds) {
    const qty = give.get(storeId) ?? 0;
    targets.set(storeId, qty);
    giveTotal += qty;
    const cur = byStore.get(storeId);
    if (!cur) {
      if (qty > 0) insert.push({ storeId, qty });
      continue;
    }
    if (Number(cur.qty) === qty) continue;
    if (Number(cur.qty) > 0) overwriting += 1;
    const bag = grouped.get(qty) ?? [];
    bag.push(cur);
    grouped.set(qty, bag);
  }

  return {
    targets,
    insert,
    update: [...grouped.entries()].map(([qty, rows]) => ({ qty, rows })),
    overwriting,
    giveTotal,
  };
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

/** 商品列的缺口：客人要的比貨多多少。null ＝ 不顯示（沒缺口，或算不出來） */
export type RowShortfall = { demandLeft: number; available: number; short: number };

/**
 * 「這樣商品的未派需求 > 可分配量」時，缺多少。
 *
 * ⛔⛔ 這是**加入商品那一刻**的數字，不是現在的 —— 呼叫端的措辭一定要寫「加入時」。
 *   （資料來自 picking_draft_items 的快照欄位，零查詢。要現在的數字得重打
 *     loadPrefill，一張草稿三、五十樣商品 ＝ 60~100 次往返，那頁自己在
 *     evenDistribute 的註解裡已經算過這筆帳。）
 *
 * ⭐ 只取「加入那一批」的格子（同一次 insert 的 snapshot_at 相同）。三個理由：
 *   1. 加入商品時**每一家分店都會建一格**（edit/page.tsx 的 stores.map），
 *      所以那一批的 demand 加總就是當時的全店未派需求，**不會漏店**。
 *   2. 後來才補的格子（cell_created_later）是**另一個時刻**拍的快照。
 *      混在一起加＝把兩個時刻的數字相加，那種數字沒有任何一個時刻是對的。
 *   3. available 是「這樣商品」層級的值，同一批的每一格都一樣；
 *      取同一批才保證 X 與 Y 是同一刻量出來的。
 *
 * ⛔ 快照缺一格就整列不顯示（回 null），⛔ 不可以把 null 當 0：
 *   舊草稿的欄位是 NULL，當 0 算會憑空生出「缺 N」——
 *   而這張紙是要拿去給樓下撿貨的，寧可不講也不能講錯。
 */
export function rowShortfall(cells: DraftCell[], skuId: number): RowShortfall | null {
  const mine = cells.filter((c) => Number(c.sku_id) === skuId);
  if (mine.length === 0) return null;

  // 加入那一刻 = 最早的 snapshot_at。沒有 snapshot_at 的（舊草稿）一律不顯示。
  let earliest: string | null = null;
  for (const c of mine) {
    const at = c.snapshot_at ?? null;
    if (!at) continue;
    if (earliest === null || at < earliest) earliest = at;
  }
  if (earliest === null) return null;

  const batch = mine.filter((c) => (c.snapshot_at ?? null) === earliest);
  let demandLeft = 0;
  let available: number | null = null;
  for (const c of batch) {
    if (c.snapshot_demand_qty == null || c.snapshot_available_qty == null) return null;
    demandLeft += Number(c.snapshot_demand_qty);
    const a = Number(c.snapshot_available_qty);
    // 同一批理應都一樣；真的不一樣就取最小（不高估手上的貨）
    available = available === null ? a : Math.min(available, a);
  }
  if (available === null) return null;
  if (!Number.isFinite(demandLeft) || !Number.isFinite(available)) return null;

  const short = demandLeft - available;
  return short > 0 ? { demandLeft, available, short } : null;
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
 * 一次勾好幾樣加入時，**逐樣**記錄結果。
 *
 * ⛔ 這個型別存在的唯一理由：不准出現「整批成功／整批失敗」這種粗糙的回報。
 *   勾 7 樣＝7 次「查需求 + 寫入」的往返，其中兩樣壞掉是完全正常的事。
 *   把三種結局拆成三個欄位，措辭那一支就**沒有辦法**把失敗的那幾樣講漏 ——
 *   靠型別逼出來，不是靠自律（同 DraftSkuRecount 的作法）。
 */
export type AddBatchReport = {
  /** 真的寫進去了 */
  added: { name: string; demandTotal: number; giveTotal: number; available: number }[];
  /** 本來就在這張草稿裡 → 這次略過。不重複插入，也**不算失敗** */
  skipped: string[];
  /** 讀需求或寫入失敗 → **沒有**加進去。⛔ 一定要逐樣講得出名字 */
  failed: { name: string; reason: string }[];
};

/**
 * 一次加入多樣之後要對老闆說什麼。
 *
 * ⭐ 規則（每一條都是為了「不准靜默」）：
 *   1. 失敗的**逐樣列出名字**放紅框（error），一眼看得出是哪幾樣沒進去
 *   2. 成功／略過放藍框（notice），成功的也逐樣列出來
 *   3. 兩個框可以同時出現 —— 部分成功就講成部分成功。
 *      ⛔ 不可以因為有幾樣失敗就整批說失敗，也不可以因為大部分成功就不提失敗的
 *   4. 只加一樣時，措辭**原封不動**沿用單樣那四句（addOutcomeMessage）——
 *      不要因為內部改走批次，就讓老闆看到的字跟著變樣
 *
 * ⓘ 措辭放這支 lib 而不是頁面裡：與 addOutcomeMessage / deleteDraftConfirmMessage
 *   同一個理由 —— 老闆會讀到的字集中一處維護。
 * ⓘ 這裡刻意不寫 `**粗體**`：這幾段字是丟進 <div>{msg}</div> 純文字渲染的，
 *   星號會原封不動印在畫面上。要強調就用「」。
 */
export function addBatchMessage(r: AddBatchReport): { notice: string | null; error: string | null } {
  // ---- 剛好一樣：完全沿用原本那幾句已經驗過的文案 ----
  if (r.added.length === 1 && r.skipped.length === 0 && r.failed.length === 0) {
    const a = r.added[0];
    return {
      notice: addOutcomeMessage({
        kind: classifyAddOutcome(a.demandTotal, a.giveTotal),
        productName: a.name,
        demandTotal: a.demandTotal,
        giveTotal: a.giveTotal,
        available: a.available,
      }),
      error: null,
    };
  }
  if (r.added.length === 0 && r.skipped.length === 0 && r.failed.length === 1) {
    return {
      notice: null,
      error: addOutcomeMessage({
        kind: "failed",
        productName: r.failed[0].name,
        reason: r.failed[0].reason,
      }),
    };
  }

  // ---- 多樣 ----
  const parts: string[] = [];
  if (r.added.length > 0) {
    const give = r.added.reduce((s, a) => s + a.giveTotal, 0);
    parts.push(
      `已加入 ${r.added.length} 樣，帶出各店未派需求共 ${give} 件：` +
        `${r.added.map((a) => a.name).join("、")}。`,
    );
    // 「查詢正常但沒有需求」一定要單獨講：它在畫面上跟「讀取失敗」一樣是一排空格，
    // 不講的話老闆分不出這兩件事 —— 本專案反覆踩過的靜默偽裝。
    const none = r.added.filter((a) => a.demandTotal === 0).map((a) => a.name);
    if (none.length > 0) {
      parts.push(
        `其中 ${none.length} 樣查詢正常、但目前沒有任何未派需求（各店數量請自己填）：${none.join("、")}。`,
      );
    }
    const clamped = r.added.filter((a) => a.demandTotal > 0 && a.giveTotal < a.demandTotal);
    if (clamped.length > 0) {
      parts.push(
        `其中 ${clamped.length} 樣的需求超過可分配量、帶出的量已被夾住（差額要等貨到才派得出去）：` +
          clamped
            .map((a) => `${a.name}（要 ${a.demandTotal}、可分配 ${a.available}、只帶 ${a.giveTotal}）`)
            .join("、") +
          "。",
      );
    }
  }
  if (r.skipped.length > 0) {
    parts.push(
      `${r.skipped.length} 樣本來就在這張草稿裡，這次略過（原本填好的數量沒有被動到）：` +
        `${r.skipped.join("、")}。`,
    );
  }

  let error: string | null = null;
  if (r.failed.length > 0) {
    // 原因通常一樣（同一次連線壞掉）→ 一樣就只講一次，不一樣才逐樣附上。
    // ⛔ 但名字**一律逐樣列出**，不可以只說「有 N 樣失敗」。
    const reasons = Array.from(new Set(r.failed.map((f) => f.reason)));
    const detail =
      reasons.length === 1
        ? `${r.failed.map((f) => f.name).join("、")}。原因：${reasons[0]}`
        : r.failed.map((f) => `${f.name}（${f.reason}）`).join("；");
    error =
      `⚠ 這 ${r.failed.length} 樣「沒有」加入草稿：${detail} ` +
      `這是系統讀取／寫入出錯，不是這些商品沒有需求。` +
      `它們還留在上面的勾選清單裡，直接再按一次「加入選取的」就可以重試。`;
  }

  return { notice: parts.length > 0 ? parts.join(" ") : null, error };
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

// ============================================================
// 「檢查」—— 拿這張草稿去派貨工作台建單，會不會卡住
// ============================================================
//
// 這一整段回答的**只有一個問題**（老闆 2026-08-17 定案的流程）：
//   草稿改完 →【檢查】→ 列印 → 拿紙去派貨工作台**人工**挑商品、填數字、建單。
//   ⛔ 檢查鈕不導頁、不送資料、不建任何單、不改任何數字 —— 全程只下 SELECT。
//
// ⭐ 判準一律**對齊派貨工作台畫面上真正會發生的事**，⛔ 不去複製後端建單守衛的邏輯：
//   那支守衛還有跨團借調等例外（見 migration 20260816000050 檔頭），複製一份必定失準，
//   而且會隨著它改版而靜默飄移。「工作台上填不填得進去」才是老闆真正會遇到的事。
//
// ⛔ 明確**不檢查**「某店的量超過該店的訂單需求」（老闆 2026-08-17）：
//   可分配量與訂單需求是兩回事，老闆本來就會多給沒訂滿的店 —— 那不是問題，
//   標成紅的只會讓真正的問題被淹掉。

/**
 * v_picking_demand_by_po 之中，「檢查」用得到的欄位。
 * ⚠ 欄位挑選刻意與派貨工作台的可分配量算式對齊（gr_qty、po_sku_already_wave），
 *   ⛔ 不含任何寫入用的東西。
 */
export type PrecheckDemandRow = {
  po_id: number;
  sku_id: number;
  store_id: number | null;
  gr_qty: number;
  po_sku_already_wave?: number | null;
};

/**
 * 每個 SKU 目前的可分配量（只留 > 0 的，也就是「工作台上真的看得到」的那些）。
 *
 * ⭐⭐ 這支是**照抄**派貨工作台，不是重新發明。三處必須一字不差，逐條對照：
 *
 *   wms/picking/page.tsx `skuRows`（:740-811，工作台商品清單的真相）
 *       if (r.store_id === null) continue;
 *       const poSkuKey = `${r.po_id}:${r.sku_id}`;
 *       if (!poSkuSeen.has(poSkuKey)) { poSkuSeen.add(poSkuKey);
 *         s.totalGr          += Number(r.gr_qty);
 *         already_wave_for_sku = Number(r.po_sku_already_wave ?? 0); }
 *       s.totalAlreadyWave = Σ already_wave_for_sku
 *       s.totalAvailable   = Math.max(0, s.totalGr - s.totalAlreadyWave)
 *       …
 *       .filter((s) => s.totalAvailable > 0)          ← :810「商品在不在工作台」
 *
 *   wms/picking/page.tsx `alivePickableSkuIds`（:212-227，工作台自己的第二份實作，
 *       檔內註解已寫明「條件與 skuRows 的 filter(totalAvailable > 0) 完全一致」）
 *       —— 與本函式**逐行同構**（連累加「差」而不是分別累加兩個總數都一樣）。
 *
 * ⚠ Σ(gr) − Σ(already) 與 Σ(gr − already) 相等，所以工作台那邊分開累加、
 *   這邊累加差值，結果保證同一個數字。
 * ⚠ id 一律 Number() 正規化：BIGINT 經過 PostgREST 可能是字串（#751 踩過），
 *   不正規化 Map.get() 就必定對不上、整批商品被誤判成「已不在工作台」。
 */
export function availableBySku(rows: PrecheckDemandRow[]): Map<number, number> {
  const raw = new Map<number, number>();
  const poSkuSeen = new Set<string>();
  for (const r of rows) {
    if (r.store_id === null) continue; // 與工作台同條件
    const skuId = Number(r.sku_id);
    const poSkuKey = `${Number(r.po_id)}:${skuId}`;
    if (poSkuSeen.has(poSkuKey)) continue;
    poSkuSeen.add(poSkuKey);
    raw.set(skuId, (raw.get(skuId) ?? 0) + Number(r.gr_qty) - Number(r.po_sku_already_wave ?? 0));
  }
  const out = new Map<number, number>();
  // max(0, …) 之後才 filter(> 0)，與工作台 :799 + :810 的兩步一致
  for (const [skuId, v] of raw) {
    const avail = Math.max(0, v);
    if (avail > 0) out.set(skuId, avail);
  }
  return out;
}

/** (SKU, 分店) 這一格在 view 裡有沒有列。key 的組法只有這一支，⛔ 不要在別處手拼字串 */
export function demandCellKeys(rows: PrecheckDemandRow[]): Set<string> {
  const keys = new Set<string>();
  for (const r of rows) {
    if (r.store_id === null) continue;
    keys.add(`${Number(r.sku_id)}:${Number(r.store_id)}`);
  }
  return keys;
}

export type PrecheckSkuRef = { sku_id: number; code: string; label: string };
/** 草稿填的量超過目前可分配量 */
export type PrecheckOver = PrecheckSkuRef & { planned: number; available: number };
/** 這一格的分店，目前在工作台上沒有這樣商品的需求 */
export type PrecheckNoDemand = PrecheckSkuRef & { store_id: number; store_name: string; qty: number };
/** 這樣商品目前整個不在工作台上（派掉了、或還沒到貨） */
export type PrecheckGone = PrecheckSkuRef & { planned: number };
/** 沒有問題，可以照著去建單 */
export type PrecheckReady = PrecheckSkuRef & { planned: number };

/**
 * 檢查結果。
 *
 * ⭐⭐ 做成 union 而不是「一包欄位 + 一個 ok 布林」的唯一理由：
 *   **查詢失敗絕對不可以長得像全部通過**（本專案已經犯過四次靜默偽裝）。
 *   union 逼著呼叫端先分辨 kind 才拿得到 over / noDemand / ready ——
 *   靠型別擋，不是靠自律（同 DraftSkuRecount 的作法）。
 */
export type DraftPrecheck =
  | { kind: "failed"; at: string; reason: string }
  | {
      kind: "checked";
      at: string;
      over: PrecheckOver[];
      noDemand: PrecheckNoDemand[];
      gone: PrecheckGone[];
      ready: PrecheckReady[];
      /** ready 這些商品的件數合計 */
      readyQty: number;
      /** 整列每一格都是 0 的商品數（不用撿 → 這次沒有檢查，但要講出來免得數字對不起來） */
      emptySkuCount: number;
    };

/** 「檢查於 HH:MM」的那個 HH:MM。⛔ 不用 toLocaleTimeString：各環境格式不一，測不起來 */
export function checkedAtLabel(d: Date): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/**
 * 純計算：草稿現況 × 工作台現況 → 四類結果。
 *
 * ⛔ 不碰資料庫、不排序副作用；列的順序沿用傳進來的 skuRows / storeCols，
 *   老闆在結果清單裡看到的順序與上面那張表**完全一樣**（找得到同一列）。
 *
 * 分類順序是刻意的：
 *   1. 整列都是 0             → 不用撿，四類都不進（只計數）
 *   2. 商品不在工作台         → ⚠ 只講這一件。它的每一格必然也「沒有需求」，
 *                               再列一次紅的只會讓老闆以為有兩個不同的問題
 *   3. 合計 > 可分配量        → ❌
 *   4. 某格的店沒有這樣商品的需求 → ❌（3 與 4 可以同時中）
 *   5. 其餘                   → ✅
 */
export function computeDraftPrecheck(opts: {
  skuRows: SkuRow[];
  cells: DraftCell[];
  storeCols: StoreColumn[];
  demandRows: PrecheckDemandRow[];
  at: string;
}): Extract<DraftPrecheck, { kind: "checked" }> {
  const { skuRows, cells, storeCols, demandRows, at } = opts;
  const avail = availableBySku(demandRows);
  const cellKeys = demandCellKeys(demandRows);
  // 分店的顯示名稱與欄位順序都取自 storeCols（＝老闆畫面上那些欄），
  // 撈不到就退回這一格自己的分店快照 —— 分店被硬刪時照樣講得出「原本要給哪一家」。
  const storeName = new Map(storeCols.map((c) => [Number(c.id), c.name]));
  const storeOrder = new Map(storeCols.map((c, i) => [Number(c.id), i]));

  const over: PrecheckOver[] = [];
  const noDemand: PrecheckNoDemand[] = [];
  const gone: PrecheckGone[] = [];
  const ready: PrecheckReady[] = [];
  let readyQty = 0;
  let emptySkuCount = 0;

  for (const row of skuRows) {
    const ref: PrecheckSkuRef = { sku_id: row.sku_id, code: row.code, label: row.label };
    const mine = cells.filter((c) => Number(c.sku_id) === row.sku_id);
    const withQty = mine
      .filter((c) => Number(c.qty) > 0)
      .sort(
        (a, b) =>
          (storeOrder.get(Number(a.store_id)) ?? Number.MAX_SAFE_INTEGER) -
          (storeOrder.get(Number(b.store_id)) ?? Number.MAX_SAFE_INTEGER),
      );
    const planned = rowTotal(cells, row.sku_id);
    // 整列沒東西要撿 → 不進四類。⚠ 兩個條件都要（qty 的 CHECK 是 >= 0，
    //   但萬一有負數混進來，只看合計會出現 +5/−5 抵消成 0 而漏檢 —— 同 storeIdsWithQty 的理由）
    if (planned <= 0 && withQty.length === 0) {
      emptySkuCount++;
      continue;
    }

    const available = avail.get(row.sku_id);
    if (available === undefined) {
      gone.push({ ...ref, planned });
      continue;
    }

    let bad = false;
    if (planned > available) {
      over.push({ ...ref, planned, available });
      bad = true;
    }
    for (const c of withQty) {
      const storeId = Number(c.store_id);
      if (cellKeys.has(`${row.sku_id}:${storeId}`)) continue;
      noDemand.push({
        ...ref,
        store_id: storeId,
        store_name: storeName.get(storeId) ?? c.snapshot_store_name ?? `分店 #${storeId}`,
        qty: Number(c.qty),
      });
      bad = true;
    }
    if (!bad) {
      ready.push({ ...ref, planned });
      readyQty += planned;
    }
  }

  return { kind: "checked", at, over, noDemand, gone, ready, readyQty, emptySkuCount };
}

/**
 * 檢查結果最上面那一句 —— 老闆只掃一眼的話就是看這一句。
 *
 * ⛔⛔ 失敗那一句是本功能最重要的一行字：一定要先講「檢查失敗」、再講
 *   「不代表沒問題」。⛔ 絕對不可以出現任何像「通過」的字眼。
 *   本專案已經犯過四次「系統異常偽裝成一切正常」，這一條是專門擋它的。
 *
 * ⓘ 這幾段字是丟進 <div>{text}</div> 純文字渲染的，⛔ 不要寫 `**粗體**`（會原樣印出星號）。
 */
export function precheckHeadline(r: DraftPrecheck): string {
  if (r.kind === "failed") {
    // ⚠ 原因擺在**最後**：describeDraftDbError 回的是整句話、自己就帶句號，
    //   夾在中間會變成「…資料庫。 請再按一次…」多一個句點加一個空格
    //   （deleteDraftConfirmMessage 踩過同一個坑）。
    return (
      `⚠ 檢查失敗（${r.at}）—— 這次「什麼都沒有檢查到」，不代表這張草稿沒問題。` +
      `請再按一次「檢查」；一直失敗就要通知工程師。` +
      `在這之前，不要把這張草稿當成已經檢查過的。原因：${r.reason}`
    );
  }
  const blockers = r.over.length + r.noDemand.length;
  if (blockers > 0) {
    return `⚠ 檢查完成（${r.at}）：有 ${blockers} 件事要先處理，照現在這張草稿去派貨工作台建單會卡住。`;
  }
  if (r.gone.length > 0) {
    return (
      `檢查完成（${r.at}）：沒有會卡住建單的問題，` +
      `但有 ${r.gone.length} 樣目前在派貨工作台上找不到（見下面）。`
    );
  }
  if (r.ready.length > 0) {
    return `✅ 檢查完成（${r.at}）：${r.ready.length} 樣、共 ${r.readyQty} 件，可以拿去派貨工作台建單。`;
  }
  return `檢查完成（${r.at}）：這張草稿目前沒有任何要撿的數量（每一格都是空的）。`;
}

/**
 * 抓「檢查」要用的現況。
 *
 * ⛔⛔ 全程唯讀：對 v_picking_demand_by_po 下一次 SELECT，沒有任何寫回、沒有任何遠端程序呼叫。
 *
 * ⚠ 查詢條件與排序**逐項對齊**派貨工作台載入 demand 的那一段（wms/picking/page.tsx:375-385）：
 *   同樣的兩個 .eq 篩選、同樣的排序。⛔ 這裡刻意**不加** .in("sku_id", …) 把範圍縮到草稿裡那幾樣：
 *   撈回**一模一樣的那批列**，可分配量與「有沒有那一列」才保證跟老闆待會看到的畫面同一份，
 *   也少掉一個「超過 200 個 id 要分批」的出錯面。線上這兩個篩選會把上萬列收到數十列。
 *
 * ⚠ 一定要走 fetchAllRows：PostgREST 預設 1000 列上限會**靜默**截斷，
 *   被截掉的那些商品會變成「查不到 → 已不在工作台」，剛好是最像真的那種假訊息。
 *
 * ⛔⛔ 這裡**故意不 catch**：查詢失敗要讓呼叫端整個失敗、顯示「檢查失敗」。
 *   吞掉錯誤退回空陣列的話，畫面會變成「全部通過」——
 *   那正是本專案已經犯過四次的靜默偽裝，也是本切片唯一不能出的錯。
 */
export async function loadPrecheckDemand({ db, fetchAll }: PrefillDeps): Promise<PrecheckDemandRow[]> {
  return fetchAll<PrecheckDemandRow>(() =>
    db
      .from("v_picking_demand_by_po")
      .select("po_id, sku_id, store_id, gr_qty, po_sku_already_wave")
      .eq("has_stock_left", true)
      .eq("has_demand_left", true)
      .order("po_item_id", { ascending: true })
      .order("store_id", { ascending: true, nullsFirst: false }),
  );
}

// ============================================================
// 加入商品「之前」就看得到：結單日 / 總倉庫存 / 可分配量
// ============================================================
//
// 老闆 2026-08-17 原話：
//   「我發現選品項時，如果數量是 0 庫存也可以拉，這樣會浪費我的時間。」
//   「a，可以顯示結單日嗎?」
//
// ⭐⭐ 為什麼一定要顯示**兩個**數字（2026-08-17 辣椒醬 G01159-01 是活例）：
//     總倉庫存 24 ＝ 樓下**撿得到**的貨（stock_balances @ central_warehouse）
//     可分配量  0 ＝ 派貨工作台**准你派**的量（進貨 − 已派）
//   只看一個都會白跑：只看庫存 → 撿得到但建不了單；只看可分配量 → 顯示 0 但總倉其實有貨。
//
// ⛔⛔ 效能是這一段最硬的約束：搜尋一次最多 15 筆（drafts/edit 的 .limit(15)）。
//   ⛔ **不可以對每個 SKU 各呼叫一次 loadPrefill** —— 那是 15×2＝30 次往返，下拉會卡住。
//   → 三個來源**各一次 .in() 查完**，一次搜尋固定 3 次查詢。
//   ⛔ 也不可以改 loadPrefill 去配合這裡：它有兩個既有呼叫點（drafts/edit 的補格子與批次加入），
//     行為必須零變化 —— 所以這裡是**另外一支批次版**，loadPrefill 一個字都沒動。
//
// ⛔ 全程唯讀：三個來源都只下 SELECT，沒有寫回、沒有呼叫任何遠端程序，也不碰派貨工作台
//   （草稿頁＝準備紙本、工作台＝實際派貨，老闆 2026-08-17 裁示兩邊不互相伸手）。

/**
 * 搜尋下拉每一列要顯示的三個數字。
 *
 * ⭐⭐ 每個來源各自是 `Map | null`，⛔ **不是**「查不到就給 0」：
 *   `Map`  ＝ 這個來源查成功了。裡面沒有那個 sku_id ⇒ **查得到、就是 0／就是沒有**（那是事實）
 *   `null` ＝ 這個來源查失敗 ⇒ 畫面必須印「查詢失敗」，⛔ 絕對不可以印 0。
 *   老闆看到 0 會直接判定「這樣沒貨、跳過」——「系統異常偽裝成資料狀態」正是本專案
 *   反覆踩過的病，最近一次是 #757（搜尋失敗偽裝成「沒這個商品」）。
 */
export type SkuPreviewBatch = {
  /** sku_id → 可分配量（＝派貨工作台上看得到的那個數字）。null ＝ 查詢失敗 */
  available: Map<number, number> | null;
  /** sku_id → 總倉實際庫存 on_hand。null ＝ 查詢失敗（含「連總倉是哪一個都問不到」） */
  hqOnHand: Map<number, number> | null;
  /** sku_id → 結單日（已去重、已由小到大排序）。null ＝ 查詢失敗 */
  closeDates: Map<number, string[]> | null;
};

/** 三個來源全部拿不到（例如連 supabase client 都取不到）→ 每一欄都顯示「查詢失敗」 */
export const SKU_PREVIEW_ALL_FAILED: SkuPreviewBatch = {
  available: null,
  hqOnHand: null,
  closeDates: null,
};

/**
 * 總倉是哪一個 location。
 *
 * ⚠ 取法對齊 `rpc_approve_restock_to_transfer`（`20260515000004:46-48`）：
 *   `type='central_warehouse' AND is_active` → **`ORDER BY id LIMIT 1`**。
 *   既有前端兩處（`wms/picking/page.tsx:581`、`components/PickModal.tsx:186`）沒有 ORDER BY，
 *   真的有兩個總倉時取到哪一個並不確定 —— 這裡照 DB 那支補上，
 *   顯示的庫存才保證跟真正會出貨的那一個倉是同一個。
 *
 * @returns location id；`null` ＝ 查得到別的、就是沒有啟用中的總倉（⛔ 查詢失敗會 throw，不會回 null）
 */
export async function loadHqLocationId({ db }: { db: ReadOnlyDb }): Promise<number | null> {
  const { data, error } = await db
    .from("locations")
    .select("id")
    .eq("type", "central_warehouse")
    .eq("is_active", true)
    .order("id", { ascending: true })
    .limit(1);
  if (error) throw error;
  const id = ((data ?? []) as { id: number }[])[0]?.id;
  return id === undefined || id === null ? null : Number(id);
}

/**
 * 一次把 N 樣商品的「可分配量／總倉庫存／結單日」查回來（N ≤ 15，見上面的效能說明）。
 *
 * ⭐ 與 `loadPrefill` 的分工：
 *   `loadPrefill`        ＝ 加入商品**當下**要寫進快照的量（逐店分配、要夾可分配量上限）
 *   `loadSkuPreviewBatch` ＝ 加入**之前**在下拉上先看一眼（只要三個總數，不逐店）
 *   兩支共用同一份可分配量算式（`availableBySku`），⛔ 不會出現「下拉說 5、加進去變 3」。
 *
 * ⛔⛔ 這支**刻意會 catch**，與 `loadPrefill`（刻意不 catch）相反 —— 理由不同所以做法不同：
 *   loadPrefill 失敗代表「這樣商品不該被加進草稿」，必須讓呼叫端整個失敗；
 *   這裡失敗只代表「這三個數字暫時給不出來」，⛔ 不可以連帶讓老闆挑不了商品。
 *   但失敗**一定要看得見**：記成 `null`（＝「查詢失敗」），⛔ 不是記成 0。
 *   三個來源各自成敗 —— 庫存查不到，不該連可分配量也一起變成「查詢失敗」。
 *
 * @param hqLocationId 總倉 location id（呼叫端在頁面載入時查一次就好，見 loadHqLocationId）。
 *                     `null` ⇒ 總倉庫存那一欄一律「查詢失敗」（⛔ 不是 0）
 */
export async function loadSkuPreviewBatch(
  { db, fetchAll }: PrefillDeps,
  skuIds: number[],
  hqLocationId: number | null,
): Promise<SkuPreviewBatch> {
  // id 一律 Number() 正規化再去重：BIGINT 經過 PostgREST 可能是字串（#751 踩過），
  // 不正規化的話 Map.get() 必定對不上、每一列都變成「查詢失敗」。
  const ids = Array.from(new Set(skuIds.map((v) => Number(v)))).filter((v) => Number.isFinite(v));
  // 沒東西可查 ＝ 三個來源都「查得到、就是空的」，⛔ 不是失敗
  if (ids.length === 0) return { available: new Map(), hqOnHand: new Map(), closeDates: new Map() };

  // ---- 查詢 ①②：可分配量與總倉庫存互不相依 → 併發送出，而且各自成敗 ----
  const [demandRows, hqOnHand] = await Promise.all([
    // ⚠ 篩選與排序**逐項對齊** loadPrecheckDemand／派貨工作台（wms/picking/page.tsx:375-385），
    //   只多一個 .in("sku_id") 把範圍縮到這次搜尋的 15 樣 ——
    //   算出來的可分配量才跟老闆待會在工作台上看到的是同一個數字。
    // ⚠ 走 fetchAll：PostgREST 的 1000 列上限是**靜默**截斷，被截掉的商品會變成
    //   「查不到 → 可派 0」，剛好是最像真的那種假訊息。
    //   ⓘ 這兩個篩選會把整個 view 收到數十列（見 loadPrecheckDemand），加上 .in 只會更少
    //   → 實務上就是 1 次請求。
    fetchAll<PrecheckDemandRow>(() =>
      db
        .from("v_picking_demand_by_po")
        .select("po_id, sku_id, store_id, gr_qty, po_sku_already_wave")
        .in("sku_id", ids)
        .eq("has_stock_left", true)
        .eq("has_demand_left", true)
        .order("po_item_id", { ascending: true })
        .order("store_id", { ascending: true, nullsFirst: false }),
    ).catch(() => null),
    loadHqOnHand({ db }, ids, hqLocationId),
  ]);

  const available = demandRows ? availableBySku(demandRows) : null;

  // ---- 查詢 ③：結單日 ----
  // ⚠ 只認「這次真的有可分配量、也真的還有未派需求」的那些 (sku, po)，
  //   與 loadPrefill 的取法逐字相同（它是拿自己那批 rows 的 po_id 去 .in）——
  //   已無庫存／已無需求的團不顯示結單日，老闆 2026-08-17 確認**不需要**補顯示。
  // ⚠ po_id 取**全部**回傳列（含 store_id 為 NULL 的），這一點也與 loadPrefill 一致；
  //   availableBySku 才需要跳過 NULL 店的列。
  let closeDates: Map<number, string[]> | null = null;
  if (demandRows) {
    closeDates = new Map();
    const poIds = Array.from(new Set(demandRows.map((r) => Number(r.po_id))));
    // (sku, po) 配對表：`.in(sku).in(po)` 是**交叉**的，會撈到「A 商品 × B 商品那張 PO」，
    // 那種列在逐樣版的 loadPrefill 裡根本不會出現 → 撈回來之後要濾掉，兩邊才會給同一個日期。
    const allowed = new Set(demandRows.map((r) => `${Number(r.sku_id)}:${Number(r.po_id)}`));
    if (poIds.length > 0) {
      try {
        const rows = await fetchAll<{ sku_id: number; po_id: number; close_date: string | null }>(
          () =>
            db
              .from("v_po_demand_by_store")
              .select("sku_id, po_id, close_date")
              .in("sku_id", ids)
              .in("po_id", poIds)
              .not("close_date", "is", null)
              .order("close_date", { ascending: true })
              // 分頁要有穩定的全序，否則跨頁可能漏列（這一支是 PO×SKU×店 粒度）
              .order("po_item_id", { ascending: true })
              .order("store_id", { ascending: true, nullsFirst: false }),
        );
        const bag = new Map<number, Set<string>>();
        for (const r of rows) {
          const skuId = Number(r.sku_id);
          if (!allowed.has(`${skuId}:${Number(r.po_id)}`)) continue;
          if (typeof r.close_date !== "string" || !r.close_date) continue;
          const set = bag.get(skuId) ?? new Set<string>();
          set.add(r.close_date);
          bag.set(skuId, set);
        }
        for (const [skuId, set] of bag) closeDates.set(skuId, Array.from(set).sort());
      } catch {
        // ⛔ 不可以退回空 Map：那會讓「查詢失敗」長得跟「這樣商品沒有結單日」一模一樣
        closeDates = null;
      }
    }
  }

  return { available, hqOnHand, closeDates };
}

/**
 * 總倉的 on_hand。
 *
 * ⚠ 用 `on_hand` 而不是 `on_hand − reserved`：這一欄回答的是「**樓下撿不撿得到**」，
 *   與派貨工作台的總倉即時在庫（`wms/picking/page.tsx:588`，同樣是純參考顯示）同一個口徑。
 *   （`PickModal` 用 `on_hand − reserved` 是因為它算的是「派得出去多少」，不是同一件事。）
 *
 * ⛔ 任何一步失敗都回 `null`（＝畫面印「查詢失敗」），⛔ 不回空 Map（會被畫成一整排 0）。
 */
async function loadHqOnHand(
  { db }: { db: ReadOnlyDb },
  ids: number[],
  hqLocationId: number | null,
): Promise<Map<number, number> | null> {
  if (hqLocationId === null) return null;
  try {
    // ids ≤ 15（搜尋下拉的 .limit(15)）→ 一次查得完，不必分批、也不會碰到 1000 列上限。
    const { data, error } = await db
      .from("stock_balances")
      .select("sku_id, on_hand")
      .eq("location_id", hqLocationId)
      .in("sku_id", ids);
    if (error) throw error;
    const m = new Map<number, number>();
    for (const r of (data ?? []) as { sku_id: number; on_hand: number }[]) {
      const v = Number(r.on_hand);
      // 讀不成數字就當作「不知道」——⛔ 寧可整批標查詢失敗，也不要把壞資料畫成 0
      if (!Number.isFinite(v)) throw new Error(`stock_balances.on_hand 不是數字：${String(r.on_hand)}`);
      m.set(Number(r.sku_id), v);
    }
    // 沒有結存列 ＝ 這樣商品在總倉沒有庫存 → 0。
    // 這是「查得到、就是 0」，不是「查不到」——與 PickModal.tsx:207 同一個判斷。
    for (const id of ids) if (!m.has(id)) m.set(id, 0);
    return m;
  } catch {
    return null;
  }
}

/** 一個數字的狀態：ok ＝ 正常、muted ＝ 沒有這個資料、zero ＝ 確定是 0、failed ＝ 查詢失敗 */
export type PreviewTone = "ok" | "muted" | "zero" | "failed";

/** 下拉一列上那三個欄位要印的字與語氣 */
export type SkuPreviewCell = {
  /** 結單日：「8/19」「6/24、7/01」「—」（查得到、就是沒有）「查詢失敗」 */
  close: { text: string; tone: PreviewTone };
  /** 總倉庫存 */
  hq: { text: string; tone: PreviewTone };
  /** 可分配量 */
  avail: { text: string; tone: PreviewTone };
  /**
   * 兩個數字**確定**有一個是 0 → 這一列標紅（老闆 2026-08-17 選 A：**標示但不擋**，
   * ⛔ 照樣可以勾選）。
   * ⚠ 查詢失敗**不算**：查不到不等於沒貨，標成紅的等於替系統異常下了一個它沒資格下的判斷。
   */
  zero: boolean;
};

/**
 * 把批次結果變成「這一列要印什麼字」。
 *
 * ⛔ 純函式、沒有 I/O —— 措辭與紅字判準集中在這裡一處維護（同本檔其他措辭函式的理由）。
 */
export function skuPreviewCell(batch: SkuPreviewBatch, skuId: number): SkuPreviewCell {
  const id = Number(skuId);

  const num = (m: Map<number, number> | null): { text: string; tone: PreviewTone } => {
    if (!m) return { text: "查詢失敗", tone: "failed" };
    // 查得到、但沒有這一筆 ⇒ 就是 0（可分配量 0 的商品本來就不在工作台上；
    // 總倉沒有結存列就是沒庫存）。這是事實，不是查不到。
    const v = m.get(id) ?? 0;
    return { text: String(v), tone: v === 0 ? "zero" : "ok" };
  };
  const hq = num(batch.hqOnHand);
  const avail = num(batch.available);

  // 結單日的格式（月不補零、日補零、跨多團用「、」串起來）沿用列印頁那一支，⛔ 不另寫一份。
  // ⓘ 只有「沒有日期」那一句刻意不一樣：列印頁要分辨「舊版草稿（—）」與「本來就沒有（無）」，
  //   而下拉是**現查現顯示**、根本沒有舊版草稿這回事 → 一律印「—」（老闆指定的格式）。
  let close: { text: string; tone: PreviewTone };
  if (!batch.closeDates) {
    close = { text: "查詢失敗", tone: "failed" };
  } else {
    const dates = batch.closeDates.get(id) ?? [];
    close =
      dates.length === 0
        ? { text: "—", tone: "muted" }
        : { text: formatCloseDates(dates[0], { close_dates: dates }).text, tone: "ok" };
  }

  return { close, hq, avail, zero: hq.tone === "zero" || avail.tone === "zero" };
}
