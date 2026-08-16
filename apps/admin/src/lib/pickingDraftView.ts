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
  snapshot_store_code: string | null;
  snapshot_store_name: string | null;
};

export type StoreRef = { id: number; code: string; name: string };

export type StoreColumn = StoreRef & { state: "active" | "inactive" | "missing" | "unknown" };

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
  known: Map<number, StoreRef> | null,
): StoreColumn[] {
  // id 一律正規化成數字再比（理由同 buildSkuRows）
  const activeIds = new Set(active.map((s) => Number(s.id)));
  const knownById = known ? new Map(Array.from(known, ([k, v]) => [Number(k), v])) : null;
  const cols: StoreColumn[] = active.map((s) => ({ ...s, id: Number(s.id), state: "active" }));

  const extraIds = Array.from(new Set(cells.map((c) => Number(c.store_id)))).filter(
    (id) => !activeIds.has(id),
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
  // ⚠ 兩邊的 id 都先正規化成數字再比。BIGINT 經過 PostgREST / JSON 有可能是數字也可能是
  //   字串，而 TypeScript 的 `{ id: number }` 宣告**不會在執行期檢查** ——
  //   一邊是 "1630"、另一邊是 1630，Set.has() 就必定失敗、整批誤判成「已不存在」。
  const alive = existingSkuIds ? new Set(Array.from(existingSkuIds, (v) => Number(v))) : null;
  const m = new Map<number, SkuRow>();
  for (const c of cells) {
    const skuId = Number(c.sku_id);
    if (m.has(skuId)) continue;
    m.set(skuId, {
      sku_id: skuId,
      code: c.snapshot_sku_code ?? "",
      label: c.snapshot_sku_label ?? `（商品 #${skuId}，沒有留下品名）`,
      missing: alive ? !alive.has(skuId) : false,
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

// 這支 lib 刻意**不 import 任何東西**（連 supabase / fetchAllRows 都不 import）：
// 全部靠呼叫端注入，才驗得起來 —— 測試可以餵一個「會丟錯」的假 db 進來，
// 證明查詢失敗時 loadPrefill 是**丟出例外**而不是回傳空需求。
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
