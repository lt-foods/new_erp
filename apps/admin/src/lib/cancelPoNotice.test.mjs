// 取消前「總倉已經叫貨」提醒（20261016000000 A9）：純函式＋讀取流程測試
//   node --test apps/admin/src/lib/cancelPoNotice.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  CANCEL_PO_NOTICE_FAILED_TEXT,
  CANCEL_PO_NOTICE_INACTIVE_TEXT,
  CANCEL_PO_NOTICE_TEXT,
  cancelPoNoticeText,
  confirmCancelPoNotice,
  fetchCancelPoNotice,
} from "./cancelPoNotice.ts";

const Q = "確定要取消這張訂單嗎？";

const row = (over) => ({
  order_item_id: 1,
  sku_id: 100,
  sku_label: "商品甲 原味",
  qty: 2,
  po_id: 9,
  po_no: "PO-TEST-1",
  store_active: true,
  ...over,
});

/** 假的 supabase：只有 rpc；記下呼叫參數，回傳交給 handler */
function fakeSb(handler) {
  const calls = [];
  return {
    calls,
    rpc(fn, args) {
      calls.push({ fn, args });
      return Promise.resolve().then(() => handler(fn, args));
    },
  };
}

// ============================================================
// 一、提醒文字：有／無／停用店／查詢失敗
// ============================================================

test("有：店有效 ⇒ 老闆原話＋列出哪幾樣、幾件＋最後一行問句", () => {
  const text = cancelPoNoticeText(
    { kind: "rows", rows: [row({}), row({ order_item_id: 2, sku_id: 101, sku_label: "商品乙", qty: "1.000" })] },
    Q,
  );
  assert.equal(
    text,
    [CANCEL_PO_NOTICE_TEXT, "", "已叫貨的品項：", "・商品甲 原味 × 2", "・商品乙 × 1", "", Q].join("\n"),
  );
  assert.ok(text.includes("總倉已經叫貨。取消只會取消客人的訂單，貨到了會直接進本店【內部】帳號，月結照算。"));
});

test("無：後端沒有列 ⇒ 不用提醒（回 null，直接進原本的取消流程）", () => {
  assert.equal(cancelPoNoticeText({ kind: "rows", rows: [] }, Q), null);
});

test("無：只有件數不大於 0 的列（抵減單那種負數行）⇒ 不用提醒", () => {
  assert.equal(cancelPoNoticeText({ kind: "rows", rows: [row({ qty: -2 }), row({ qty: 0 })] }, Q), null);
});

test("停用店 ⇒ 換另一套文字（那幾件留在派貨工作台給總倉決定），不講「進本店【內部】」", () => {
  const text = cancelPoNoticeText({ kind: "rows", rows: [row({ store_active: false, qty: 1 })] }, Q);
  assert.equal(text, [CANCEL_PO_NOTICE_INACTIVE_TEXT, "", "已叫貨的品項：", "・商品甲 原味 × 1", "", Q].join("\n"));
  assert.ok(!text.includes("【內部】帳號"));
  assert.ok(text.includes("這家店已停用"));
});

test("查詢失敗 ⇒ 「無法確認是否已叫貨，仍要取消嗎？」", () => {
  assert.equal(cancelPoNoticeText({ kind: "failed", reason: "function does not exist" }, Q), CANCEL_PO_NOTICE_FAILED_TEXT);
  assert.equal(CANCEL_PO_NOTICE_FAILED_TEXT, "無法確認是否已叫貨，仍要取消嗎？");
});

test("同一樣商品兩項 ⇒ 合併成一行、件數加總；沒有品名 ⇒ 寫（未命名商品）", () => {
  const text = cancelPoNoticeText(
    { kind: "rows", rows: [row({ qty: 1 }), row({ order_item_id: 2, qty: 3 }), row({ sku_id: 102, sku_label: null, qty: 1 })] },
    Q,
  );
  assert.ok(text.includes("・商品甲 原味 × 4"));
  assert.ok(text.includes("・（未命名商品） × 1"));
});

test("同一樣商品有正有負（+10、−2）⇒ 先加總再判斷，提醒淨件數 8（不是 10）", () => {
  const text = cancelPoNoticeText(
    { kind: "rows", rows: [row({ qty: 10 }), row({ order_item_id: 2, qty: -2 })] },
    Q,
  );
  assert.equal(text, [CANCEL_PO_NOTICE_TEXT, "", "已叫貨的品項：", "・商品甲 原味 × 8", "", Q].join("\n"));
});

test("同一樣商品正負剛好抵掉（+2、−2）⇒ 淨件數 0，不用提醒（回 null）", () => {
  assert.equal(
    cancelPoNoticeText({ kind: "rows", rows: [row({ qty: 2 }), row({ order_item_id: 2, qty: "-2.000" })] }, Q),
    null,
  );
});

test("同一樣商品但停用與否不同 ⇒ 兩邊各自加總，不互相抵", () => {
  const text = cancelPoNoticeText(
    {
      kind: "rows",
      rows: [row({ qty: 3 }), row({ order_item_id: 2, qty: -1 }), row({ order_item_id: 3, store_active: false, qty: -5 })],
    },
    Q,
  );
  assert.equal(text, [CANCEL_PO_NOTICE_TEXT, "", "已叫貨的品項：", "・商品甲 原味 × 2", "", Q].join("\n"));
});

// ============================================================
// 二、讀取流程：參數、失敗不丟例外、確定／取消
// ============================================================

test("fetchCancelPoNotice：整張取消帶 p_item_id＝null；刪單一品項帶品項 id", async () => {
  const sb = fakeSb(() => ({ data: [], error: null }));
  await fetchCancelPoNotice(sb, 55);
  await fetchCancelPoNotice(sb, 55, 77);
  assert.deepEqual(sb.calls, [
    { fn: "rpc_order_cancel_po_notice", args: { p_order_id: 55, p_item_id: null } },
    { fn: "rpc_order_cancel_po_notice", args: { p_order_id: 55, p_item_id: 77 } },
  ]);
});

test("fetchCancelPoNotice：後端回錯誤或直接丟例外 ⇒ failed（不丟出來）", async () => {
  const errSb = fakeSb(() => ({ data: null, error: { message: "Could not find the function" } }));
  assert.deepEqual(await fetchCancelPoNotice(errSb, 1), { kind: "failed", reason: "Could not find the function" });
  const throwSb = fakeSb(() => {
    throw new Error("Failed to fetch");
  });
  assert.deepEqual(await fetchCancelPoNotice(throwSb, 1), { kind: "failed", reason: "Failed to fetch" });
});

test("confirmCancelPoNotice：沒有列 ⇒ 不跳視窗、回 true（照常進原本流程）", async () => {
  const asked = [];
  const ok = await confirmCancelPoNotice(fakeSb(() => ({ data: [], error: null })), 1, null, Q, (t) => {
    asked.push(t);
    return false;
  });
  assert.equal(ok, true);
  assert.equal(asked.length, 0);
});

test("confirmCancelPoNotice：有列 ⇒ 跳提醒；按確定回 true、按取消回 false", async () => {
  const sb = fakeSb(() => ({ data: [row({})], error: null }));
  const asked = [];
  assert.equal(await confirmCancelPoNotice(sb, 1, null, Q, (t) => (asked.push(t), true)), true);
  assert.equal(await confirmCancelPoNotice(sb, 1, null, Q, (t) => (asked.push(t), false)), false);
  assert.equal(asked.length, 2);
  assert.ok(asked[0].startsWith(CANCEL_PO_NOTICE_TEXT));
});

test("confirmCancelPoNotice：查詢失敗 ⇒ 跳「無法確認」；按確定照常取消（回 true，不擋）", async () => {
  const sb = fakeSb(() => ({ data: null, error: { message: "boom" } }));
  const asked = [];
  assert.equal(await confirmCancelPoNotice(sb, 1, 3, Q, (t) => (asked.push(t), true)), true);
  assert.deepEqual(asked, [CANCEL_PO_NOTICE_FAILED_TEXT]);
  assert.equal(await confirmCancelPoNotice(sb, 1, 3, Q, () => false), false);
});
