// 月結明細頁「店家爭議對到哪一行明細」純函式測試：
//   node --test "apps/admin/src/app/(protected)/transfers/settlement/detail/disputeLine.test.mjs"
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import { describeDisputeLine, disputeStatusByItemId, findDisputeItem, matchDisputeItem, skuIdsToLoad } from "./disputeLine.ts";

const item = (o) => ({
  id: 1,
  transfer_id: 500,
  transfer_item_id: 7000,
  sku_id: 4263,
  qty_received: "3.000",
  unit_branch_price: "33.6700",
  branch_amount: "101.0000",
  received_at: "2026-09-12T02:00:00+00:00",
  entry_type: "hq_inbound",
  description: null,
  ...o,
});
const dispute = (o) => ({
  transfer_item_id: 7000,
  status: "open",
  item_snapshot: {
    entry_type: "hq_inbound",
    description: null,
    sku_id: 4263,
    qty_received: 3,
    branch_amount: 101,
    received_at: "2026-09-12T02:00:00+00:00",
  },
  ...o,
});

test("對明細：transfer_item_id 與類型都要一樣", () => {
  const items = [
    item({ id: 1, transfer_item_id: 7001 }),
    item({ id: 2, transfer_item_id: 7000, entry_type: "return_out" }),
    item({ id: 3, transfer_item_id: 7000 }),
  ];
  assert.equal(findDisputeItem(items, dispute()).id, 3);
});

test("對明細：類型不同就算對不到", () => {
  const items = [item({ entry_type: "air_in" })];
  assert.equal(findDisputeItem(items, dispute()), null);
});

test("對明細：快照沒記類型時只比 transfer_item_id，剛好一行才算對上", () => {
  const items = [item({ id: 8, transfer_item_id: 7001 }), item({ id: 9, entry_type: "air_in" })];
  assert.equal(findDisputeItem(items, dispute({ item_snapshot: { sku_id: 4263 } })).id, 9);
  assert.equal(findDisputeItem(items, dispute({ item_snapshot: null })).id, 9);
  assert.deepEqual(matchDisputeItem(items, dispute({ item_snapshot: null })), { item: items[1], ambiguous: false });
});

test("對明細：快照沒記類型、同一個 transfer_item_id 有兩行 → 不猜，當作對不到並標無法確定", () => {
  const items = [
    item({ id: 8, transfer_item_id: 7000, entry_type: "hq_inbound" }),
    item({ id: 9, transfer_item_id: 7000, entry_type: "return_out", branch_amount: "-33.67" }),
  ];
  for (const snap of [{ sku_id: 4263, qty_received: 3, branch_amount: 101 }, null]) {
    const d = dispute({ item_snapshot: snap });
    assert.equal(findDisputeItem(items, d), null);
    assert.deepEqual(matchDisputeItem(items, d), { item: null, ambiguous: true });
  }
  // 快照有記類型時照舊用類型分得出來
  assert.equal(findDisputeItem(items, dispute()).id, 8);
  assert.deepEqual(matchDisputeItem(items, dispute()), { item: items[0], ambiguous: false });
});

test("無法確定是哪一行：用快照數字、不說已不在明細、沒有跳轉與單號", () => {
  const v = describeDisputeLine(dispute({ item_snapshot: { sku_id: 4263, qty_received: 3, branch_amount: 101 } }), null, true, true);
  assert.equal(v.ambiguous, true);
  assert.equal(v.gone, false);
  assert.equal(v.itemId, null);
  assert.equal(v.transferId, null);
  assert.equal(v.unitPrice, null);
  assert.equal(v.qty, 3);
  assert.equal(v.amount, 101);
  assert.equal(v.skuId, 4263);
  // 一般對不到（不是分不出來）照舊標已不在明細
  assert.equal(describeDisputeLine(dispute(), null, true).ambiguous, false);
});

test("明細表標記：無法確定是哪一行的爭議兩行都不標", () => {
  const items = [
    item({ id: 8, transfer_item_id: 7000, entry_type: "hq_inbound" }),
    item({ id: 9, transfer_item_id: 7000, entry_type: "return_out" }),
  ];
  const m = disputeStatusByItemId(items, [dispute({ item_snapshot: { sku_id: 4263 } })]);
  assert.equal(m.size, 0);
});

test("對明細：id 是字串也對得到（PostgREST bigint 有時給字串）", () => {
  assert.equal(findDisputeItem([item({ id: 5, transfer_item_id: "7000" })], dispute()).id, 5);
});

test("對得到：數量、單價、金額、調撥單都用目前那一行", () => {
  const it = item({ id: 3 });
  const v = describeDisputeLine(dispute(), it, true);
  assert.deepEqual(v, {
    entryType: "hq_inbound",
    receivedAt: "2026-09-12T02:00:00+00:00",
    description: null,
    skuId: 4263,
    qty: 3,
    unitPrice: 33.67,
    amount: 101,
    transferId: 500,
    itemId: 3,
    raisedAmount: null,
    gone: false,
    ambiguous: false,
  });
});

test("對得到但金額改過：留店家提出當下的金額", () => {
  const it = item({ entry_type: "free_out", description: "測試估價品", unit_branch_price: 0, branch_amount: "-280" });
  const d = dispute({ item_snapshot: { entry_type: "free_out", description: "測試估價品", sku_id: 1, qty_received: 1, branch_amount: -500 } });
  const v = describeDisputeLine(d, it, true);
  assert.equal(v.amount, -280);
  assert.equal(v.raisedAmount, -500);
  assert.equal(v.description, "測試估價品");
  // 自由轉貨沒有單價（明細表也是「—」）
  assert.equal(v.unitPrice, null);
});

test("對不到且明細已載入：用快照數字、標已不在明細、沒有單價與單號", () => {
  const v = describeDisputeLine(dispute(), null, true);
  assert.equal(v.gone, true);
  assert.equal(v.qty, 3);
  assert.equal(v.amount, 101);
  assert.equal(v.unitPrice, null);
  assert.equal(v.transferId, null);
  assert.equal(v.itemId, null);
  assert.equal(v.skuId, 4263);
  assert.equal(v.receivedAt, "2026-09-12T02:00:00+00:00");
});

test("明細還沒載入或載入失敗：不說「已不在明細」", () => {
  assert.equal(describeDisputeLine(dispute(), null, false).gone, false);
});

test("快照是空的也不會壞", () => {
  const v = describeDisputeLine(dispute({ item_snapshot: null }), null, true);
  assert.equal(v.entryType, null);
  assert.equal(v.skuId, null);
  assert.equal(v.qty, null);
  assert.equal(v.amount, null);
  assert.equal(v.gone, true);
});

test("明細表標記：未處理優先於已處理；對不到的爭議不標", () => {
  const items = [item({ id: 1, transfer_item_id: 7000 }), item({ id: 2, transfer_item_id: 7002 })];
  const m = disputeStatusByItemId(items, [
    dispute({ status: "resolved" }),
    dispute({ status: "open" }),
    dispute({ transfer_item_id: 7002, status: "resolved" }),
    dispute({ transfer_item_id: 9999, status: "open" }),
  ]);
  assert.deepEqual([...m.entries()], [[1, "open"], [2, "resolved"]]);
});

test("商品對照表：明細＋爭議快照的 sku_id，去重去空值", () => {
  const ids = skuIdsToLoad(
    [{ sku_id: 1 }, { sku_id: 2 }, { sku_id: 1 }],
    [
      dispute({ item_snapshot: { sku_id: 2 } }),
      dispute({ item_snapshot: { sku_id: 77 } }),
      dispute({ item_snapshot: { sku_id: null } }),
      dispute({ item_snapshot: null }),
    ],
  );
  assert.deepEqual(ids, [1, 2, 77]);
});
