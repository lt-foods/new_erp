// 手機團控純函式測試：node --test "apps/admin/src/app/(protected)/campaigns/quick-control/quickControl.test.mjs"
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  QUICK_PAGE_OVERLAP,
  QUICK_PAGE_SIZE,
  campaignSearchOrFilter,
  canQuickUpdateCampaign,
  customerUrlFor,
  mergeCampaignRows,
  pageWindow,
  sanitizeCampaignSearch,
  soldQtyByCampaign,
  splitPage,
} from "./quickControl.ts";

test("客人網址：結尾斜線不會變成雙斜線", () => {
  assert.equal(customerUrlFor("https://example.com", 12), "https://example.com/shop/c/12");
  assert.equal(customerUrlFor("https://example.com/", 12), "https://example.com/shop/c/12");
});

test("搜尋字：保留團號的連字號，拿掉會打斷 or() 的符號", () => {
  assert.equal(sanitizeCampaignSearch("  GRP-20260730-016 "), "GRP-20260730-016");
  assert.equal(sanitizeCampaignSearch("a,b.c(d):e"), "a%b%c%d%e");
  assert.equal(sanitizeCampaignSearch("【內部】芒果"), "內部%芒果");
  assert.equal(sanitizeCampaignSearch("芒果   鮮奶"), "芒果 鮮奶");
  assert.equal(sanitizeCampaignSearch("%%%"), "");
  assert.equal(sanitizeCampaignSearch("   "), "");
});

test("搜尋條件：團號或團名，空白不送條件", () => {
  assert.equal(campaignSearchOrFilter("芒果"), "campaign_no.ilike.%芒果%,name.ilike.%芒果%");
  assert.equal(campaignSearchOrFilter("  "), null);
  assert.equal(campaignSearchOrFilter("()"), null);
});

test("分頁範圍：第一頁從 0 開始，多要一筆判斷下一頁", () => {
  assert.deepEqual(pageWindow(0), { from: 0, to: QUICK_PAGE_SIZE });
  assert.deepEqual(pageWindow(QUICK_PAGE_SIZE), {
    from: QUICK_PAGE_SIZE - QUICK_PAGE_OVERLAP,
    to: QUICK_PAGE_SIZE * 2,
  });
  assert.deepEqual(pageWindow(3), { from: 0, to: 3 + QUICK_PAGE_SIZE });
});

test("切頁：剛好滿一頁沒有下一頁，多一筆才有", () => {
  const w = pageWindow(0);
  const size = w.to - w.from;
  const full = Array.from({ length: size }, (_, i) => i);
  assert.deepEqual(splitPage(full, w), { rows: full, hasMore: false });
  const plusOne = [...full, 999];
  const res = splitPage(plusOne, w);
  assert.equal(res.rows.length, size);
  assert.equal(res.hasMore, true);
  assert.deepEqual(splitPage([], w), { rows: [], hasMore: false });
});

test("載入更多合併：重疊的保留畫面上那筆，新的接在後面", () => {
  const cur = [{ id: 1, v: "畫面" }, { id: 2, v: "畫面" }];
  const inc = [{ id: 2, v: "伺服端" }, { id: 3, v: "伺服端" }, { id: 3, v: "重複" }];
  assert.deepEqual(mergeCampaignRows(cur, inc), [
    { id: 1, v: "畫面" },
    { id: 2, v: "畫面" },
    { id: 3, v: "伺服端" },
  ]);
});

test("已售件數：排除取消／過期／轉出單、非一般單、取消品項", () => {
  const sold = soldQtyByCampaign([
    { campaign_id: 1, status: "confirmed", order_kind: null, customer_order_items: [{ qty: "2", status: "pending" }, { qty: 5, status: "cancelled" }] },
    { campaign_id: 1, status: "ready", order_kind: "normal", customer_order_items: [{ qty: 3, status: "picked_up" }] },
    { campaign_id: 1, status: "cancelled", order_kind: "normal", customer_order_items: [{ qty: 9, status: "pending" }] },
    { campaign_id: 1, status: "transferred_out", order_kind: "normal", customer_order_items: [{ qty: 9, status: "pending" }] },
    { campaign_id: 1, status: "confirmed", order_kind: "restock", customer_order_items: [{ qty: 9, status: "pending" }] },
    { campaign_id: 2, status: "confirmed", order_kind: "normal" },
  ]);
  assert.equal(sold.get(1), 5);
  assert.equal(sold.get(2), 0);
});

test("延長／重開／加名額資格：照資料庫守衛", () => {
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "fast", total_cap_qty: null, campaign_items: [] }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "limited", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "food_train", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: null, campaign_items: [{ cap_qty: null }] }), false);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: 0, campaign_items: null }), false);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: "10", campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: null, campaign_items: [{ cap_qty: 0 }, { cap_qty: "3" }] }), true);
  // 狀態條件：已鎖定一律擋，草稿／已關團照類型判斷
  assert.equal(canQuickUpdateCampaign({ status: "locked", close_type: "fast", total_cap_qty: 10, campaign_items: null }), false);
  assert.equal(canQuickUpdateCampaign({ status: "draft", close_type: "fast", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "closed", close_type: "limited", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "closed", close_type: "regular", total_cap_qty: null, campaign_items: null }), false);
});
