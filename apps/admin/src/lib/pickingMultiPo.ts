// 撿貨草稿／派貨工作台：「同一團、同一樣商品掛了兩張以上採購單」的判斷與措辭。
//
// 這支在解什麼（2026-10-13 實例：G02671-01／GRP-20260914-056）：
//   同一團、同一樣商品掛了兩張採購單（原單 19＋結單日補單另開的差額單 1），
//   需求表 v_picking_demand_by_po 讓每張採購單各帶一次整團訂單量（20260908000000:62-72），
//   computePrefill 與工作台的 storeDemand 再跨採購單加總 ⇒ 各店需求變兩倍 ⇒
//   先來後到分 20 件，排前面的店拿兩倍、後面的店拿 0。
//
// 做法（老闆 2026-10-14 裁示 A＋B）：
//   · 撿貨草稿：中招就「各店全部留 0」＋紅字，請人照訂單樞紐填。
//     ⛔ computePrefill / computePrefillEven / capPrefill 一個字都沒改，
//        只在 computePrefill「算完之後」用 blockPrefill 把數字拿掉。
//   · 派貨工作台：中招的商品只加紅字，數字、建單一律不動。
//   · 檢查表讀不到（查詢報錯、SQL 還沒貼）⇒ ⛔ 不可以當成沒中招照常帶數字，
//     跟中招一樣全部留 0，並明講「檢查失敗」。
//
// ⓘ 為什麼獨立成一支、而且一個 import 都沒有：
//   純計算＋措辭，`node --test` 直接吃 .ts 就驗得到（同 receiveAllocation.ts 的作法）；
//   撿貨草稿（pickingDraftView / pickingDraftHandoff）與派貨工作台共用同一份判斷與用詞，
//   不會兩頁各寫一套然後漂移。

/** 檢查表（20261015000000）的名字與要讀的欄位 —— 草稿與工作台共用，不要各寫一份 */
export const MULTI_PO_VIEW = "v_picking_multi_po_campaigns";
export const MULTI_PO_SELECT = "sku_id, campaign_id, campaign_no, po_item_ids, po_nos";

/**
 * v_picking_multi_po_campaigns 的一列：一樣商品 × 一個團，這一團連到這樣商品的有效採購單品項 ≥ 2。
 * ⓘ id 一律可能是字串（BIGINT 經 PostgREST，#751 踩過）→ 用的時候 Number() 正規化。
 */
export type MultiPoCampaignRow = {
  sku_id: number | string;
  campaign_id: number | string;
  campaign_no: string | null;
  po_item_ids: (number | string)[] | null;
  po_nos: string[] | null;
};

/** 中招的一團：團號＋這一團這樣商品掛的採購單號（去重、排序過） */
export type MultiPoHit = { campaign_no: string; po_nos: string[] };

/**
 * 一樣商品的檢查結果。三種一定要分得開：
 *   clear  = 查過了、沒中招（或這樣商品根本沒有需求列，沒有數字要保護）
 *   hit    = 中招 → 系統算的各店數量會重複，全部留 0
 *   failed = 檢查表讀不到 → ⛔ 不知道有沒有中招，一樣全部留 0，而且要明講是「檢查失敗」
 */
export type MultiPoCheck =
  | { kind: "clear" }
  | { kind: "hit"; hits: MultiPoHit[] }
  | { kind: "failed"; reason: string };

export const MULTI_PO_CLEAR: MultiPoCheck = { kind: "clear" };

/** hit 或 failed ＝ 這樣商品的各店數量不能自動帶 */
export function isMultiPoBlocked(check: MultiPoCheck): boolean {
  return check.kind !== "clear";
}

/**
 * 中招判斷：檢查表某一列的採購單品項，**至少一個**出現在這次需求表查到的列裡才算。
 *
 * ⭐ 為什麼看「至少一個還在需求表上」：
 *   檢查表看的是**全部**有效採購單（第一張派完、第二張才到時一樣會算錯，不能只看還有貨的），
 *   但這樣也會列出早就派完的舊團 —— 那些團的採購單品項都不在需求表上了，用交集排掉，免得誤擋。
 * ⓘ po_item_id 全站唯一、一個品項只屬於一樣商品，所以拿「整頁的需求列」去交集也不會串到別樣商品。
 *
 * @returns sku_id → 中招的團（依團號排序）。沒中招的商品不會出現在 Map 裡。
 */
export function multiPoHitsBySku(
  rows: MultiPoCampaignRow[],
  demandPoItemIds: Iterable<number | string | null | undefined>,
): Map<number, MultiPoHit[]> {
  const live = new Set<number>();
  for (const id of demandPoItemIds) {
    if (id === null || id === undefined) continue;
    live.add(Number(id));
  }
  const out = new Map<number, MultiPoHit[]>();
  for (const r of rows) {
    const items = (r.po_item_ids ?? []).map((v) => Number(v));
    if (!items.some((id) => live.has(id))) continue;
    const sku = Number(r.sku_id);
    const list = out.get(sku) ?? [];
    list.push({
      // 團號理論上一定有（group_buy_campaigns.campaign_no NOT NULL）；萬一沒有也要講得出是哪一團
      campaign_no: r.campaign_no ?? `團 #${r.campaign_id}`,
      po_nos: Array.from(new Set(r.po_nos ?? [])).sort(),
    });
    out.set(sku, list);
  }
  for (const list of out.values()) list.sort((a, b) => a.campaign_no.localeCompare(b.campaign_no));
  return out;
}

/**
 * 一樣商品的檢查結果（撿貨草稿 loadPrefill 用）。
 *
 * @param lookup 檢查表讀回來的列；讀失敗時傳 { ok: false, reason }
 * @param demandPoItemIds 這一樣商品這次在需求表上查到的 po_item_id
 */
export function multiPoCheckFor(
  skuId: number,
  lookup: { ok: true; rows: MultiPoCampaignRow[] } | { ok: false; reason: string },
  demandPoItemIds: (number | string | null | undefined)[],
): MultiPoCheck {
  // 需求表上一列都沒有 ⇒ 本來就帶不出任何數字，沒有東西要保護。
  // ⓘ 這時就算檢查表讀失敗也不標 failed：不然 SQL 還沒貼的那段時間，
  //   每一樣「本來就沒需求」的商品都會多一句嚇人的紅字。
  if (demandPoItemIds.length === 0) return MULTI_PO_CLEAR;
  // ⛔ 讀不到 ≠ 沒中招
  if (!lookup.ok) return { kind: "failed", reason: lookup.reason };
  const hits = multiPoHitsBySku(lookup.rows, demandPoItemIds).get(Number(skuId)) ?? [];
  return hits.length > 0 ? { kind: "hit", hits } : MULTI_PO_CLEAR;
}

/**
 * 把各店要帶出的量**全部歸零**（computePrefill 算完之後才用）。
 *
 * · give      → 0：不自動帶任何數字
 * · demandLeft → 0：⭐ 這個數字是跨採購單重複加總過的（兩倍），留著只會被下游拿去重算 ——
 *     capPrefill（iPad 傳到草稿）與 computePrefillEven（⚖ 平均）都是從 demandLeft 重新算 give 的，
 *     歸零之後它們算出來也一定是 0，不會把 0 蓋回兩倍的數字。
 *     ⛔ 寫快照時不可以把這個 0 當成「加入時需求」寫進去：中招／檢查失敗時 snapshot_demand_qty 一律寫 null。
 * · available → 不變：可分配量是按採購單去重算的，沒有重複算的問題。
 * · 分店的 key 全部保留（只改數字），呼叫端拿 byStore 建格子的邏輯不受影響。
 */
export function blockPrefill<P extends { available: number; byStore: Map<number, { demandLeft: number; give: number }> }>(
  pre: P,
): P {
  const byStore = new Map<number, { demandLeft: number; give: number }>();
  for (const storeId of pre.byStore.keys()) byStore.set(storeId, { demandLeft: 0, give: 0 });
  return { ...pre, byStore };
}

/** 寫進 snapshot_extra 的記號（重新整理後 ⚠ 標記還在，靠的就是它） */
export function multiPoExtra(check: MultiPoCheck): Record<string, unknown> {
  if (check.kind === "hit") return { multi_po: check.hits.map((h) => ({ campaign_no: h.campaign_no, po_nos: h.po_nos })) };
  if (check.kind === "failed") return { multi_po_check: "failed" };
  return {};
}

// ============================================================
// 措辭（老闆看得到的字集中在這裡）
// ⓘ 這幾段都是純文字渲染，⛔ 不要寫 `**粗體**`（星號會原樣印出來）。
// ============================================================

/** 一團的說法：「GRP-… 有 2 張採購單（PO…、PO…）」 */
export function multiPoHitPhrase(h: MultiPoHit): string {
  // 同一張採購單裡同一樣商品有兩列，需求一樣會算兩次 —— 這時「N 張採購單」會說成 1 張，要換句話講
  return h.po_nos.length >= 2
    ? `團 ${h.campaign_no} 有 ${h.po_nos.length} 張採購單（${h.po_nos.join("、")}）`
    : `團 ${h.campaign_no} 的採購單 ${h.po_nos.join("、")} 有兩列以上這樣商品`;
}

function hitsPhrase(hits: MultiPoHit[]): string {
  return hits.map(multiPoHitPhrase).join("；");
}

/** 檢查失敗那一句（草稿各處共用，計畫 B7 的原文） */
export const MULTI_PO_CHECK_FAILED_TEXT = "多張採購單檢查失敗，數量請照訂單樞紐自己填";

/**
 * 撿貨草稿加入**一樣**商品之後的紅字。clear 回 null（＝沿用原本那四句）。
 */
export function multiPoAddedMessage(productName: string, check: MultiPoCheck): string | null {
  if (check.kind === "hit") {
    return (
      `⚠ 已加入「${productName}」，但各店數量全部留 0：這樣商品在${hitsPhrase(check.hits)}，` +
      `系統帶出的各店數量會重複算、容易派錯店。請照訂單樞紐自己填各店數量。`
    );
  }
  if (check.kind === "failed") {
    return `⚠ 已加入「${productName}」，但各店數量全部留 0：${MULTI_PO_CHECK_FAILED_TEXT}。（原因：${check.reason}）`;
  }
  return null;
}

/**
 * 一次加入（或傳進）好幾樣時，中招／檢查失敗那幾樣的紅字。沒有這種商品回 null。
 * @param verb 「加入」或「傳進草稿」—— 兩個入口講法不同，其他字一樣
 */
export function multiPoBatchMessage(
  items: { name: string; check: MultiPoCheck }[],
  verb: string,
): string | null {
  const blocked = items.filter((i) => isMultiPoBlocked(i.check));
  if (blocked.length === 0) return null;
  const detail = blocked
    .map((i) =>
      i.check.kind === "hit"
        ? `${i.name}——${hitsPhrase(i.check.hits)}`
        : `${i.name}——多張採購單檢查失敗${i.check.kind === "failed" ? `（${i.check.reason}）` : ""}`,
    )
    .join("；");
  // 原因只講真的發生的那一種（或兩種都講）
  const why = [
    blocked.some((i) => i.check.kind === "hit") ? "同一團有多張採購單時，系統帶出的各店數量會重複算、容易派錯店" : null,
    blocked.some((i) => i.check.kind === "failed") ? "檢查失敗時不知道有沒有重複" : null,
  ]
    .filter((t): t is string => t !== null)
    .join("；");
  return `⚠ 這 ${blocked.length} 樣已經${verb}，但各店數量全部留 0：${detail}。${why}。請照訂單樞紐自己填各店數量。`;
}

/** 「⚖ 平均」遇到中招／檢查失敗：一格都不動，紅字講原因。clear 回 null。 */
export function multiPoEvenMessage(label: string, check: MultiPoCheck): string | null {
  if (check.kind === "hit") {
    return (
      `⚖「${label}」這次沒有改動任何數量：這樣商品在${hitsPhrase(check.hits)}，` +
      `系統算的各店需求會重複算，平均分下去也會分錯。請照訂單樞紐自己填各店數量。`
    );
  }
  if (check.kind === "failed") {
    return `⚖「${label}」這次沒有改動任何數量：${MULTI_PO_CHECK_FAILED_TEXT}。（原因：${check.reason}）`;
  }
  return null;
}

/** 草稿表格上那個 ⚠ 標記要講什麼：從這一列各格的 snapshot_extra 讀回來 */
export type MultiPoRowMark = { hits: MultiPoHit[]; failed: boolean };

/**
 * 讀這一列（同一樣商品的各格）的 snapshot_extra，有 multi_po 或 multi_po_check 就回標記。
 * ⓘ 防禦式解析：JSONB 是誰都寫得進去的欄位，形狀不對的就略過，⛔ 不可以讓整頁炸掉。
 */
export function multiPoRowMark(extras: (Record<string, unknown> | null | undefined)[]): MultiPoRowMark | null {
  const byCampaign = new Map<string, Set<string>>();
  let failed = false;
  for (const ex of extras) {
    if (!ex || typeof ex !== "object") continue;
    if (ex.multi_po_check === "failed") failed = true;
    const list = ex.multi_po;
    if (!Array.isArray(list)) continue;
    for (const h of list) {
      if (!h || typeof h !== "object") continue;
      const no = (h as { campaign_no?: unknown }).campaign_no;
      const pos = (h as { po_nos?: unknown }).po_nos;
      if (typeof no !== "string" || no === "") continue;
      const set = byCampaign.get(no) ?? new Set<string>();
      if (Array.isArray(pos)) for (const p of pos) if (typeof p === "string" && p !== "") set.add(p);
      byCampaign.set(no, set);
    }
  }
  if (byCampaign.size === 0 && !failed) return null;
  const hits = [...byCampaign.entries()]
    .map(([campaign_no, set]) => ({ campaign_no, po_nos: [...set].sort() }))
    .sort((a, b) => a.campaign_no.localeCompare(b.campaign_no));
  return { hits, failed };
}

/** 草稿表格上 ⚠ 標記的字 */
export function multiPoRowText(mark: MultiPoRowMark): string {
  const parts: string[] = [];
  if (mark.hits.length > 0) {
    parts.push(`⚠ 同一團多張採購單：${hitsPhrase(mark.hits)}。系統算的各店需求會重複算，數量請照訂單樞紐填。`);
  }
  if (mark.failed) parts.push(`⚠ 加入時${MULTI_PO_CHECK_FAILED_TEXT}。`);
  return parts.join(" ");
}

/** 派貨工作台：中招商品旁邊的紅字（老闆 10/14 定：只加紅字、不改數字） */
export function workbenchMultiPoText(h: MultiPoHit): string {
  return h.po_nos.length >= 2
    ? `⚠ 同一團有 ${h.po_nos.length} 張採購單（${h.po_nos.join("、")}；團 ${h.campaign_no}），各店預設數量會重複算，請照訂單樞紐改`
    : `⚠ 同一團的採購單 ${h.po_nos.join("、")} 有兩列以上這樣商品（團 ${h.campaign_no}），各店預設數量會重複算，請照訂單樞紐改`;
}

/** 派貨工作台：檢查表讀不到時，頁面上方那一行 */
export const WORKBENCH_MULTI_PO_FAILED_TEXT = "多張採購單檢查失敗，同一團多張採購單的商品可能被重複算";
