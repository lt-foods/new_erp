// 採購單頁「分店／批發追加」預估（20261016000000 A7／A8）：純函式測試
//   node --test apps/admin/src/lib/poStoreAddEstimate.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
//
// 公式（跟後端 rpc_add_po_store_demands 同一條）：
//   請購 +max(差額 + N, 0)
//   採購單：套新規則 ⇒ +max(0, 差額 + N + R − E)；不套（或 A8 沒有這一列）⇒ 跟請購一樣
// 下面的「差額」一律是追加之前的差額（畫面上拿得到的那個），N＝這次各店加的件數合計。
import test from "node:test";
import assert from "node:assert/strict";
import {
  PO_STORE_ADD_NO_EXTRA,
  estimatePoStoreAdd,
  pickPoStoreAddExtra,
} from "./poStoreAddEstimate.ts";

const RULE = (r, e) => ({ r, e, ruleApplies: true });
const NO_RULE = (r, e) => ({ r, e, ruleApplies: false });

// ============================================================
// 一、九種對照（第一段 A7／A8 的情境）
// ============================================================

test("一般：沒有叫貨後取消、以前也沒追加過 ⇒ 套不套都一樣，請購＝採購＝N", () => {
  // 採購 100、需求 100、差額 0；店A 加 2
  assert.deepEqual(estimatePoStoreAdd(0, 2, RULE(0, 0)), { prAdd: 2, poAdd: 2 });
  assert.deepEqual(estimatePoStoreAdd(0, 2, NO_RULE(0, 0)), { prAdd: 2, poAdd: 2 });
  assert.deepEqual(estimatePoStoreAdd(0, 2, PO_STORE_ADD_NO_EXTRA), { prAdd: 2, poAdd: 2 });
});

test("叫貨後取消：採購 133、叫貨後取消 1、店A 追加 2 ⇒ 請購 +1、採購 +2（取消那件照派原店，不拿來抵）", () => {
  // 需求 132、請購 133 ⇒ 差額 −1；R＝1
  assert.deepEqual(estimatePoStoreAdd(-1, 2, RULE(1, 0)), { prAdd: 1, poAdd: 2 });
});

test("叫貨後取消後連續追加：接著店B 再追加 1 ⇒ 請購 +1、採購 +1（不重複補）", () => {
  // 上一筆之後：需求 134、請購 134、採購 135；R＝1、E＝1（上次採購比請購多加 1）
  assert.deepEqual(estimatePoStoreAdd(0, 1, RULE(1, 1)), { prAdd: 1, poAdd: 1 });
});

test("叫貨後取消 3、追加 1 ⇒ 請購 +0、採購 +1", () => {
  assert.deepEqual(estimatePoStoreAdd(-3, 1, RULE(3, 0)), { prAdd: 0, poAdd: 1 });
});

test("延長結單加單 2 ＋ 叫貨後取消 1、追加 1 ⇒ 請購 +2、採購 +3（延長加的照今天一起補）", () => {
  // 需求 133−1+2＝134、請購 133 ⇒ 差額 1
  assert.deepEqual(estimatePoStoreAdd(1, 1, RULE(1, 0)), { prAdd: 2, poAdd: 3 });
});

test("抵減單：叫貨後取消的是 −2 的抵減單、追加 1 ⇒ 請購 +3、採購 +1（R 是負的，採購單會比請購加得少）", () => {
  // 叫貨時需求 8（＋10 與 −2）、請購＝採購＝8；取消 −2 ⇒ 需求 10、R＝−2；差額 2
  assert.deepEqual(estimatePoStoreAdd(2, 1, RULE(-2, 0)), { prAdd: 3, poAdd: 1 });
});

test("一團兩張採購單：不套新規則（A8 沒有這一列）⇒ 跟改前一樣，多叫的先用掉", () => {
  // 差額 −1、追加 2 ⇒ 請購＝採購＝1
  assert.deepEqual(estimatePoStoreAdd(-1, 2, PO_STORE_ADD_NO_EXTRA), { prAdd: 1, poAdd: 1 });
  // A8 整包沒有這一組
  const extra = pickPoStoreAddExtra([], 11, 7);
  assert.deepEqual(estimatePoStoreAdd(-1, 2, extra), { prAdd: 1, poAdd: 1 });
});

test("分界前的舊採購單：不套 ⇒ 跟改前一樣", () => {
  // 分界前的採購單品項不在新規則裡 ⇒ A8 沒有列（R 一定是 0）
  assert.deepEqual(estimatePoStoreAdd(-1, 2, NO_RULE(0, 0)), { prAdd: 1, poAdd: 1 });
});

test("一鍵關掉前後：關掉前套（採購 +2）；關掉後 R 歸 0、E 還在但不套 ⇒ 採購＝請購", () => {
  assert.deepEqual(estimatePoStoreAdd(-1, 2, RULE(1, 0)), { prAdd: 1, poAdd: 2 });
  // 關掉後：叫貨後取消的清單變空（R＝0），以前多加的紀錄還在（E＝1），rule_applies＝false
  assert.deepEqual(estimatePoStoreAdd(-1, 2, NO_RULE(0, 1)), { prAdd: 1, poAdd: 1 });
});

test("R＝0、E≠0、有套：叫貨後取消過又復原，再追加 1 ⇒ 請購 +2、採購 +1（加完兩邊都 102）", () => {
  // 請購 100、採購 101（上次多加 1：E＝1）；復原後需求 101 ⇒ 差額 1；R＝0
  assert.deepEqual(estimatePoStoreAdd(1, 1, RULE(0, 1)), { prAdd: 2, poAdd: 1 });
});

test("R＝0、E≠0、沒套：同樣數字但不套 ⇒ 採購＝請購（不會因為 E 少加）", () => {
  assert.deepEqual(estimatePoStoreAdd(1, 1, NO_RULE(0, 1)), { prAdd: 2, poAdd: 2 });
});

// ============================================================
// 二、邊界
// ============================================================

test("差額查不到（null）⇒ 算不出來，回 null（畫面寫「送出時由系統計算」）", () => {
  assert.equal(estimatePoStoreAdd(null, 2, RULE(1, 0)), null);
  assert.equal(estimatePoStoreAdd(Number.NaN, 2, RULE(1, 0)), null);
});

test("加完還是多叫：套新規則時採購單也不會變成負的", () => {
  assert.deepEqual(estimatePoStoreAdd(-5, 1, RULE(0, 0)), { prAdd: 0, poAdd: 0 });
  assert.deepEqual(estimatePoStoreAdd(-5, 1, RULE(1, 3)), { prAdd: 0, poAdd: 0 });
});

test("A8 讀不到（傳 null）⇒ 照不套算", () => {
  assert.deepEqual(estimatePoStoreAdd(-1, 2, null), { prAdd: 1, poAdd: 1 });
});

test("pickPoStoreAddExtra：只挑同一個（採購單品項, 團）；id、數量是字串也認得；沒有列＝不套、0、0", () => {
  const rows = [
    { po_item_id: "11", campaign_id: "7", post_po_cancelled_qty: "1.000", prior_po_extra_qty: "0", rule_applies: true },
    { po_item_id: 11, campaign_id: 8, post_po_cancelled_qty: 5, prior_po_extra_qty: 2, rule_applies: true },
    { po_item_id: 12, campaign_id: 7, post_po_cancelled_qty: 9, prior_po_extra_qty: 9, rule_applies: true },
  ];
  assert.deepEqual(pickPoStoreAddExtra(rows, 11, 7), { r: 1, e: 0, ruleApplies: true });
  assert.deepEqual(pickPoStoreAddExtra(rows, 11, 9), PO_STORE_ADD_NO_EXTRA);
  assert.deepEqual(pickPoStoreAddExtra(rows, 11, null), PO_STORE_ADD_NO_EXTRA);
  assert.deepEqual(pickPoStoreAddExtra(null, 11, 7), PO_STORE_ADD_NO_EXTRA);
});

test("pickPoStoreAddExtra：有列但 rule_applies＝false（一鍵關掉後只剩 E）⇒ 不套", () => {
  const rows = [{ po_item_id: 11, campaign_id: 7, post_po_cancelled_qty: 0, prior_po_extra_qty: 1, rule_applies: false }];
  const extra = pickPoStoreAddExtra(rows, 11, 7);
  assert.deepEqual(extra, { r: 0, e: 1, ruleApplies: false });
  assert.deepEqual(estimatePoStoreAdd(-1, 2, extra), { prAdd: 1, poAdd: 1 });
});
