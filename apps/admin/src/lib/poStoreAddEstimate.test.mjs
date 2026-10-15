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
  poStoreAddExplainLines,
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

test("pickPoStoreAddExtra：這一組的 R 或 E 不是數字（\"NaN\"、\"abc\"）⇒ 回 null＝讀不到，走退路照不套算＋註明以送出後為準", () => {
  const badR = [{ po_item_id: 11, campaign_id: 7, post_po_cancelled_qty: "NaN", prior_po_extra_qty: 0, rule_applies: true }];
  const badE = [{ po_item_id: 11, campaign_id: 7, post_po_cancelled_qty: 1, prior_po_extra_qty: "abc", rule_applies: true }];
  assert.equal(pickPoStoreAddExtra(badR, 11, 7), null);
  assert.equal(pickPoStoreAddExtra(badE, 11, 7), null);
  // 走退路＝照不套 ⇒ 請購＝採購＝1（說明文字那半在「三、說明文字」驗）
  assert.deepEqual(estimatePoStoreAdd(-1, 2, pickPoStoreAddExtra(badR, 11, 7)), { prAdd: 1, poAdd: 1 });
  // R 有值但 E 壞掉：當 0 會算成 −1＋2＋1−0＝採購 +2；退路照不套 ⇒ 採購 +1
  assert.deepEqual(estimatePoStoreAdd(-1, 2, pickPoStoreAddExtra(badE, 11, 7)), { prAdd: 1, poAdd: 1 });
  // 別組的壞值不影響這一組；R、E 是 null 照舊當 0
  const mixed = [
    { po_item_id: 12, campaign_id: 7, post_po_cancelled_qty: "NaN", prior_po_extra_qty: "abc", rule_applies: true },
    { po_item_id: 11, campaign_id: 7, post_po_cancelled_qty: null, prior_po_extra_qty: null, rule_applies: true },
  ];
  assert.deepEqual(pickPoStoreAddExtra(mixed, 11, 7), { r: 0, e: 0, ruleApplies: true });
});

test("小數：差額 0.1、追加 0.2 ⇒ 請購、採購剛好加 0.3（沒有 0.30000000000000004 這種浮點尾數）", () => {
  assert.deepEqual(estimatePoStoreAdd(0.1, 0.2, PO_STORE_ADD_NO_EXTRA), { prAdd: 0.3, poAdd: 0.3 });
  assert.deepEqual(estimatePoStoreAdd(0.1, 0.2, RULE(0, 0)), { prAdd: 0.3, poAdd: 0.3 });
  assert.deepEqual(estimatePoStoreAdd(0.1, 0.2, RULE(0.1, 0)), { prAdd: 0.3, poAdd: 0.4 });
});

// ============================================================
// 三、說明文字（數字對、解釋也對）
//   不套新規則：跟改前（75bab10a 的 POStoreAddModal.tsx :233-240、:404-407）原文一字不差
//   套新規則：叫貨後的取消照派原店、不拿來抵 ⇒ 不可以再說「之前有人取消、先用掉」
// ============================================================

const PO = "採購單";
const explain = (delta, n, extra, style, extraLoading) =>
  poStoreAddExplainLines({
    estimate: estimatePoStoreAdd(delta, n, extra),
    storeTotal: n,
    extra,
    extraLoading,
    style,
    poTerm: PO,
  });
const WHY = `請購單只照現在還有效的訂單算，${PO}照派車要送的量算，所以兩邊加的不一樣`;
const FOLLOW = `請購單對應那一列會跟著${PO}一起加（不用另外動）。`;

/** 套新規則時，任何一行都不能把「先用掉」歸因到取消 */
function assertNoCancelOffset(lines) {
  for (const l of lines) {
    assert.ok(!l.includes("之前有人取消"), `不該出現「之前有人取消」：${l}`);
    assert.ok(!/取消.*先用掉|先用掉.*取消/.test(l), `不該說取消的件數被先用掉：${l}`);
  }
}

test("說明・一般（沒有叫貨後取消、沒有 E）：預估區塊不加字；確認框只有請購跟著加那一行（套不套一樣）", () => {
  for (const extra of [RULE(0, 0), NO_RULE(0, 0), PO_STORE_ADD_NO_EXTRA]) {
    assert.deepEqual(explain(0, 2, extra, "preview"), []);
    assert.deepEqual(explain(0, 2, extra, "confirm"), [FOLLOW]);
  }
});

test("說明・叫貨後取消（差額 −1、追加 2、R 1）：套新規則 ⇒ 寫照派原店、不拿來抵，請購另寫；不寫「之前有人取消先用掉」", () => {
  const preview = explain(-1, 2, RULE(1, 0), "preview");
  assert.deepEqual(preview, [
    "叫貨後才取消的 1 件照派原店，不算多叫，不拿來抵這次追加。",
    `請購單加 1 件（${WHY}）。`,
  ]);
  assertNoCancelOffset(preview);
  const confirm = explain(-1, 2, RULE(1, 0), "confirm");
  assert.deepEqual(confirm, [
    "　（叫貨後才取消的 1 件照派原店，不算多叫，不拿來抵這次追加）",
    `請購單對應那一列加 1 件（${WHY}；不用另外動）。`,
  ]);
  assertNoCancelOffset(confirm);
});

test("說明・同樣數字但不套（一團兩張）⇒ 改前原文：多叫 1 件——之前有人取消——先用掉", () => {
  assert.deepEqual(explain(-1, 2, PO_STORE_ADD_NO_EXTRA, "preview"), [
    "這個團原本已經多叫 1 件（之前有人取消），會先用掉。",
  ]);
  assert.deepEqual(explain(-1, 2, PO_STORE_ADD_NO_EXTRA, "confirm"), [
    `　（這個團原本已經多叫 1 件——之前有人取消——先用掉，所以${PO}只加 1 件）`,
    FOLLOW,
  ]);
});

test("說明・叫貨後取消 3、追加 1 ⇒ 採購 +1、請購不用改；不說先用掉", () => {
  const confirm = explain(-3, 1, RULE(3, 0), "confirm");
  assert.deepEqual(confirm, [
    "　（叫貨後才取消的 3 件照派原店，不算多叫，不拿來抵這次追加）",
    `請購單不用改（${WHY}；不用另外動）。`,
  ]);
  assertNoCancelOffset(confirm);
});

test("說明・延長加單 2 ＋ 叫貨後取消 1、追加 1 ⇒ 其中 2 件是還沒叫貨的量＋照派原店＋請購加 2", () => {
  assert.deepEqual(explain(1, 1, RULE(1, 0), "preview"), [
    "其中 2 件是這個團原本就還沒叫貨的量，會一起補進來。",
    "叫貨後才取消的 1 件照派原店，不算多叫，不拿來抵這次追加。",
    `請購單加 2 件（${WHY}）。`,
  ]);
});

test("說明・抵減單（差額 2、追加 1、R −2）⇒ 照叫貨時的數量算、採購單不用為它多加；請購加 3 另寫", () => {
  const preview = explain(2, 1, RULE(-2, 0), "preview");
  assert.deepEqual(preview, [
    `叫貨後才取消的抵減單 2 件，派車照叫貨時的數量算，${PO}不用為它多加。`,
    `請購單加 3 件（${WHY}）。`,
  ]);
  assertNoCancelOffset(preview);
  assert.deepEqual(explain(2, 1, RULE(-2, 0), "confirm"), [
    `　（叫貨後才取消的抵減單 2 件，派車照叫貨時的數量算，${PO}不用為它多加）`,
    `請購單對應那一列加 3 件（${WHY}；不用另外動）。`,
  ]);
});

test("說明・R＝0、E≠0、有套（復原後再追加：差額 1、追加 1、E 1）⇒ 採購 +1＝店家件數，只寫請購加 2 為什麼不一樣", () => {
  const preview = explain(1, 1, RULE(0, 1), "preview");
  assert.deepEqual(preview, [`請購單加 2 件（${WHY}）。`]);
  assertNoCancelOffset(preview);
});

test("說明・R＝0、E≠0、有套、採購比派車要送的多（差額 0、追加 1、E 1）⇒ 先用掉 1 件，不說是取消造成的", () => {
  const confirm = explain(0, 1, RULE(0, 1), "confirm");
  assert.deepEqual(confirm, [
    `　（這個團原本叫的量比派車要送的多，先用掉其中 1 件，所以${PO}只加 0 件）`,
    `請購單對應那一列加 1 件（${WHY}；不用另外動）。`,
  ]);
  assertNoCancelOffset(confirm);
});

test("說明・R＝0、E≠0、沒套 ⇒ 改前原文（其中 1 件是還沒叫貨的量、請購跟著一起加）", () => {
  assert.deepEqual(explain(1, 1, NO_RULE(0, 1), "preview"), [
    "其中 1 件是這個團原本就還沒叫貨的量，會一起補進來。",
  ]);
  assert.deepEqual(explain(1, 1, NO_RULE(0, 1), "confirm"), [
    `　（其中 1 件是這個團原本就還沒叫貨的量，一起補進這張${PO}）`,
    FOLLOW,
  ]);
});

test("說明・採購單加 0（不套）⇒ 改前原文「請購單不用改（原本叫的量已經夠）」", () => {
  assert.deepEqual(explain(-5, 1, NO_RULE(0, 0), "confirm"), [
    `　（這個團原本已經多叫 1 件——之前有人取消——先用掉，所以${PO}只加 0 件）`,
    "請購單不用改（原本叫的量已經夠）。",
  ]);
});

test("說明・R、E 讀取中／讀不到 ⇒ 照改前原文＋一行「照舊算法估的，實際以送出後為準」", () => {
  assert.deepEqual(explain(-1, 2, null, "preview", true), [
    "這個團原本已經多叫 1 件（之前有人取消），會先用掉。",
    "叫貨後取消的件數讀取中，這是照舊算法估的，實際以送出後為準。",
  ]);
  assert.deepEqual(explain(-1, 2, null, "preview", false)[1], "叫貨後取消的件數讀不到，這是照舊算法估的，實際以送出後為準。");
  assert.deepEqual(explain(0, 2, null, "confirm"), [
    "　（叫貨後取消的件數讀不到，這是照舊算法估的，實際以送出後為準）",
    FOLLOW,
  ]);
});

test("說明・A8 的 R 是 \"NaN\" ⇒ 跟讀不到一樣：改前原文＋「讀不到，照舊算法估，以送出後為準」，不當成套新規則、R＝0", () => {
  const extra = pickPoStoreAddExtra(
    [{ po_item_id: 11, campaign_id: 7, post_po_cancelled_qty: "NaN", prior_po_extra_qty: 0, rule_applies: true }],
    11,
    7,
  );
  assert.deepEqual(explain(-1, 2, extra, "confirm"), [
    `　（這個團原本已經多叫 1 件——之前有人取消——先用掉，所以${PO}只加 1 件）`,
    "　（叫貨後取消的件數讀不到，這是照舊算法估的，實際以送出後為準）",
    FOLLOW,
  ]);
  assert.deepEqual(explain(-1, 2, extra, "preview", false), [
    "這個團原本已經多叫 1 件（之前有人取消），會先用掉。",
    "叫貨後取消的件數讀不到，這是照舊算法估的，實際以送出後為準。",
  ]);
});

test("說明・差額查不到 ⇒ 預估區塊不加字；確認框照改前只留請購跟著加；預估區塊店家還沒填數量也不加字", () => {
  assert.deepEqual(explain(null, 2, RULE(1, 0), "preview"), []);
  assert.deepEqual(explain(null, 2, RULE(1, 0), "confirm"), [FOLLOW]);
  assert.deepEqual(explain(-1, 0, RULE(1, 0), "preview"), []);
});
