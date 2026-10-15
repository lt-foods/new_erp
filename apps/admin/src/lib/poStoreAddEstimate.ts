// 採購單頁「分店／批發追加」：送出前預估「請購單、採購單各會加幾件」。
//
// 後端（20261016000000_picking_post_po_cancel_to_store.sql）：
//   rpc_add_po_store_demands（A7）實際寫入時：
//     請購 +max(差額 + N, 0)（N＝這次各店加的件數合計；跟改前一模一樣）
//     採購單：這個（採購單品項, 團）套新規則 ⇒ +max(0, 差額 + N + R − E)
//             不套（分界前、一團兩張、一鍵關掉）⇒ 跟請購一樣
//   R、E、套不套都讀 rpc_preview_po_store_addition_extra（A8）：
//     R＝叫貨後才取消、照派原店的件數（不拿來抵這次追加）
//     E＝以前追加時採購單比請購多加的件數合計（可能是負的）
//     沒有列＝R、E 都是 0、當不套（後端 A7 也是這樣當）。
//   ⇒ 這支的公式要跟 A7 同一條；A7 改了這裡要跟著改。
//
// ⓘ 一個 import 都沒有：純計算，`node --test` 直接吃 .ts 就驗得到（同 receiveAllocation.ts 的作法）。

/** rpc_preview_po_store_addition_extra 的一列。id、數量經 PostgREST 可能是字串 → 用的時候 Number() */
export type PoStoreAddExtraRow = {
  po_item_id: number | string;
  campaign_id: number | string;
  post_po_cancelled_qty: number | string | null;
  prior_po_extra_qty: number | string | null;
  rule_applies: boolean | null;
};

/** 一個（採購單品項, 團）的 R、E、套不套 */
export type PoStoreAddExtra = { r: number; e: number; ruleApplies: boolean };

/** 沒有列＝R、E 都是 0、不套（跟後端 A7 同一個當法） */
export const PO_STORE_ADD_NO_EXTRA: PoStoreAddExtra = { r: 0, e: 0, ruleApplies: false };

/**
 * 從 A8 的回傳挑出這個（採購單品項, 團）。
 * 跟 A7 讀法一樣：同一組有幾列就加總 R、E，有一列套就算套（實際上一組最多一列）。
 */
export function pickPoStoreAddExtra(
  rows: PoStoreAddExtraRow[] | null | undefined,
  poItemId: number,
  campaignId: number | null,
): PoStoreAddExtra {
  if (!rows || campaignId == null) return PO_STORE_ADD_NO_EXTRA;
  let r = 0;
  let e = 0;
  let ruleApplies = false;
  let found = false;
  for (const row of rows) {
    if (Number(row.po_item_id) !== Number(poItemId) || Number(row.campaign_id) !== Number(campaignId)) continue;
    found = true;
    r += toNum(row.post_po_cancelled_qty);
    e += toNum(row.prior_po_extra_qty);
    if (row.rule_applies === true) ruleApplies = true;
  }
  return found ? { r, e, ruleApplies } : PO_STORE_ADD_NO_EXTRA;
}

export type PoStoreAddEstimate = {
  /** 請購單會加幾件 */
  prAdd: number;
  /** 採購單會加幾件 */
  poAdd: number;
};

/**
 * 預估這次追加，請購單、採購單各會加幾件。
 *   delta      ＝追加之前這個（團, 商品）的差額（rpc_preview_po_store_additions 的 delta_qty；null＝後端查不到）
 *   storeTotal ＝這次各店加的件數合計（N）
 *   extra      ＝A8 這一組的 R、E、套不套；讀不到 A8 時傳 null ⇒ 照不套算（呼叫端要註明「以送出後為準」）
 * delta 是 null ⇒ 回 null（算不出來，由後端在送出時算）。
 */
export function estimatePoStoreAdd(
  delta: number | null,
  storeTotal: number,
  extra: PoStoreAddExtra | null,
): PoStoreAddEstimate | null {
  if (delta == null || !Number.isFinite(delta)) return null;
  const base = delta + storeTotal;
  const prAdd = Math.max(base, 0);
  const ex = extra ?? PO_STORE_ADD_NO_EXTRA;
  const poAdd = ex.ruleApplies ? Math.max(0, base + ex.r - ex.e) : prAdd;
  return { prAdd, poAdd };
}

function toNum(value: number | string | null | undefined): number {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}
