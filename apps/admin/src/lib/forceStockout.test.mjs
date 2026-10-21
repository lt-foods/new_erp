// 採購單「已到貨也能斷貨」（20261022100000）：按鈕顯示條件、確認視窗判斷、回收貨待辦的純函式測試
//   node --test apps/admin/src/lib/forceStockout.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  FORCE_STOCKOUT_REASON_MAX,
  canSubmitForceStockout,
  fmtQty,
  normalizeSkuInput,
  paidOrderLines,
  previewStopLines,
  reasonProblem,
  resultLines,
  RETURN_DISPOSITION_NOTES,
  RETURN_DISPOSITION_STEP,
  returnTodoLine,
  returnTodoLines,
  showForceStockoutButton,
  skuCodeMatches,
  summaryLines,
  untouchedLines,
} from "./forceStockout.ts";

// 頁面上原本「⛔ 斷貨」鈕的顯示條件（purchase/orders/edit/page.tsx：canStockout && 已收 < 訂購），
// 這裡照抄一份，用來證明兩顆不會同時出現。
const originalShown = (poStatus, received, ordered) =>
  (poStatus === "sent" || poStatus === "partially_received") && received < ordered;

const row = (over = {}) => ({
  canForce: true,
  poStatus: "fully_received",
  stockoutAt: null,
  qtyReceived: 20,
  originalStockoutShown: false,
  ...over,
});

// ============================================================
// 一、按鈕顯示條件
// ============================================================

test("全部到貨、名單內 ⇒ 顯示", () => {
  assert.equal(showForceStockoutButton(row()), true);
});

test("不在名單 ⇒ 不顯示（後端也擋）", () => {
  assert.equal(showForceStockoutButton(row({ canForce: false })), false);
});

test("已收量 0 ⇒ 不顯示（請用原本的斷貨）", () => {
  assert.equal(showForceStockoutButton(row({ qtyReceived: 0, poStatus: "sent" })), false);
});

test("這一項已標斷貨 ⇒ 不顯示", () => {
  assert.equal(showForceStockoutButton(row({ stockoutAt: "2026-10-20T10:00:00+08:00" })), false);
});

test("採購單草稿／已取消 ⇒ 不顯示；沒有狀態 ⇒ 不顯示", () => {
  assert.equal(showForceStockoutButton(row({ poStatus: "draft" })), false);
  assert.equal(showForceStockoutButton(row({ poStatus: "cancelled" })), false);
  assert.equal(showForceStockoutButton(row({ poStatus: null })), false);
});

test("已結案（舊斷貨結案）、全部到貨 ⇒ 顯示", () => {
  assert.equal(showForceStockoutButton(row({ poStatus: "closed" })), true);
});

test("跟原本的「⛔ 斷貨」鈕不會同時出現在同一列（所有狀態 × 已收／訂購組合窮舉）", () => {
  const statuses = ["draft", "sent", "partially_received", "fully_received", "closed", "cancelled"];
  for (const st of statuses) {
    for (const [received, ordered] of [[0, 10], [3, 10], [10, 10], [12, 10]]) {
      for (const stockoutAt of [null, "2026-10-20T10:00:00+08:00"]) {
        const orig = !stockoutAt && originalShown(st, received, ordered);
        const mine = showForceStockoutButton({
          canForce: true, poStatus: st, stockoutAt, qtyReceived: received, originalStockoutShown: orig,
        });
        assert.equal(orig && mine, false, `${st} ${received}/${ordered} 兩顆同時出現`);
      }
    }
  }
});

test("部分到貨、還在等剩下的量 ⇒ 只有原本的鈕（這顆不出現）", () => {
  const orig = originalShown("partially_received", 3, 10);
  assert.equal(orig, true);
  assert.equal(showForceStockoutButton(row({ poStatus: "partially_received", qtyReceived: 3, originalStockoutShown: orig })), false);
});

test("部分到貨的單上、已經收滿的那一列 ⇒ 顯示這顆", () => {
  const orig = originalShown("partially_received", 10, 10);
  assert.equal(orig, false);
  assert.equal(showForceStockoutButton(row({ poStatus: "partially_received", qtyReceived: 10, originalStockoutShown: orig })), true);
});

// ============================================================
// 二、商品代碼、原因、能不能按「確定取消」
// ============================================================

test("商品代碼：前後空白去掉後要一字不差；大小寫不同、少一個字都不行", () => {
  assert.equal(skuCodeMatches("FS-001", "FS-001"), true);
  assert.equal(skuCodeMatches("  FS-001 ", "FS-001"), true);
  assert.equal(normalizeSkuInput("  FS-001 "), "FS-001");
  assert.equal(skuCodeMatches("fs-001", "FS-001"), false);
  assert.equal(skuCodeMatches("FS-00", "FS-001"), false);
  assert.equal(skuCodeMatches("FS-0 01", "FS-001"), false);
  assert.equal(skuCodeMatches("", "FS-001"), false);
  assert.equal(skuCodeMatches("FS-001", null), false);
});

test("原因：空的／只有空白 ⇒ 要填；200 字可以、201 字太長（中文一個字算一個）", () => {
  assert.match(reasonProblem(""), /請填原因/);
  assert.match(reasonProblem("   "), /請填原因/);
  assert.equal(reasonProblem("叫錯款式"), null);
  assert.equal(reasonProblem("字".repeat(FORCE_STOCKOUT_REASON_MAX)), null);
  assert.match(reasonProblem("字".repeat(FORCE_STOCKOUT_REASON_MAX + 1)), /太長（201 字）/);
});

test("能不能按確定：預覽說可以＋代碼對＋原因有填，三個都要", () => {
  const p = { can_execute: true, sku_code: "FS-001" };
  assert.equal(canSubmitForceStockout(p, "FS-001", "叫錯款式"), true);
  assert.equal(canSubmitForceStockout(p, "FS-002", "叫錯款式"), false);
  assert.equal(canSubmitForceStockout(p, "FS-001", " "), false);
  assert.equal(canSubmitForceStockout({ ...p, can_execute: false }, "FS-001", "叫錯款式"), false);
  assert.equal(canSubmitForceStockout(null, "FS-001", "叫錯款式"), false);
});

// ============================================================
// 三、預覽的字（數字取自本機臨時庫實跑的預覽回傳）
// ============================================================

const PREVIEW = {
  found: true,
  po_item_id: 1,
  sku_code: "FS-001",
  block_reasons: [],
  can_execute: true,
  already_done: false,
  nothing_to_do: false,
  restock_requests: 0,
  untouched: { picked_items: 1, picked_qty: "1.000", picked_orders: 1, dead_items: 2, dead_qty: "2.000", dead_orders: 2 },
  prior: { items: 0, qty: 0, last_at: null },
  summary: {
    items: 9, qty: "10.000", offset_items: 1, members: 8, orders: 9,
    orders_cancel: 6, orders_complete: 1, orders_keep: 1, orders_paid: 1,
    by_store: [], by_campaign: [],
    paid_orders: [{ store_name: "店B", order_no: "O04", outcome: "paid" }],
  },
};

test("會發生什麼：人數、筆數、件數、每種收尾都講出來；抵減單另外講", () => {
  const lines = summaryLines(PREVIEW.summary);
  assert.equal(lines[0], "會取消 8 位客人的 9 筆、共 10 件（9 張單；店家內部單也算在內，沒綁會員的單各算一位）");
  assert.match(lines[1], /1 筆是抵減單/);
  assert.ok(lines.some((l) => l.startsWith("・整張取消 6 張")));
  assert.ok(lines.some((l) => l.startsWith("・收尾成「已完成」1 張")));
  assert.ok(lines.some((l) => l.startsWith("・單子留著 1 張")));
  assert.ok(lines.some((l) => l.startsWith("・付過錢或用過儲值金、單子不動 1 張")));
});

test("沒有的收尾種類不出現（0 張就不寫）", () => {
  const lines = summaryLines({ ...PREVIEW.summary, offset_items: 0, orders_complete: 0, orders_keep: 0, orders_paid: 0 });
  assert.equal(lines.length, 2);
});

test("不動的：已取貨、店家已取消、補貨申請", () => {
  const lines = untouchedLines({ ...PREVIEW, restock_requests: 2 });
  assert.equal(lines.length, 3);
  assert.match(lines[0], /已經取貨的 1 筆/);
  assert.match(lines[1], /店家已經取消／過期／轉出的單上還掛著的 2 筆/);
  assert.match(lines[2], /2 筆補貨申請/);
  assert.deepEqual(untouchedLines({ ...PREVIEW, untouched: undefined, restock_requests: 0 }), []);
});

test("付過錢的單：只有店與單號，講清楚錢不會自動退", () => {
  assert.deepEqual(paidOrderLines(PREVIEW.summary.paid_orders), ["店B O04（單子不動；這一項照樣取消，錢不會自動退）"]);
  assert.match(paidOrderLines([{ store_name: "店A", order_no: "O02", outcome: "keep" }])[0], /單子留著/);
  assert.deepEqual(paidOrderLines(null), []);
});

test("紅字：有擋下原因就列原因；沒有、但已經做過 ⇒ 講「已經做過」；本來就沒有 ⇒ 講不用按", () => {
  assert.deepEqual(previewStopLines(PREVIEW), []);
  const blocked = { ...PREVIEW, block_reasons: ["這一項還沒收過貨（已收 0）：請用原本的「⛔ 斷貨」"], can_execute: false, nothing_to_do: true };
  assert.deepEqual(previewStopLines(blocked), blocked.block_reasons);
  const done = { ...PREVIEW, can_execute: false, nothing_to_do: true, already_done: true, prior: { items: 9, qty: "9.000", last_at: "x" } };
  assert.match(previewStopLines(done)[0], /^已經做過了：.*9 筆（9 件）/);
  const none = { ...PREVIEW, can_execute: false, nothing_to_do: true, already_done: false };
  assert.match(previewStopLines(none)[0], /不用按/);
});

// ============================================================
// 四、回收貨待辦
// ============================================================

const TODO = [
  { store_id: 1, store_name: "店A", wave_code: "WV-T-1", wave_status: "shipped", qty: "3.000", transfer_no: "TR-T-A", transfer_status: "received", qty_shipped: "3.000", qty_received: "3.000", received_at: "2026-10-19T15:00:00+08:00", stage: "received" },
  { store_id: 2, store_name: "店B", wave_code: "WV-T-1", wave_status: "shipped", qty: "3.000", transfer_no: "TR-T-B", transfer_status: "shipped", qty_shipped: "3.000", qty_received: "0.000", received_at: null, stage: "in_transit" },
  { store_id: 4, store_name: "店D", wave_code: "WV-T-2", wave_status: "picked", qty: "2.000", transfer_no: null, transfer_status: null, qty_shipped: null, qty_received: null, received_at: null, stage: "not_shipped" },
];

test("已收貨的店：開退回單＋總倉同意收回＋退回貨處理", () => {
  const l = returnTodoLine(TODO[0]);
  assert.match(l, /^店A：已收貨 3 件（派車單 TR-T-A）/);
  assert.match(l, /「退貨」頁開退回單/);
  assert.match(l, /總倉收件匣 → 🚚 轉貨單 → ↩ 退貨回總倉」按「同意收回」；/);
  // #924：收回後凍結，要到退回貨處理才解凍
  assert.ok(l.endsWith(RETURN_DISPOSITION_STEP));
  assert.match(l, /凍結、派不出去，要到左選單「倉儲 \(WMS\) → 退回貨處理」處理才解凍$/);
});

test("在途的店：收貨時改 0＋總倉在「店家少收」同意退、不補貨＋退回貨處理", () => {
  const l = returnTodoLine(TODO[1]);
  assert.match(l, /^店B：派出 3 件、店家還沒收（派車單 TR-T-B）/);
  assert.match(l, /實收改 0/);
  assert.match(l, /「總倉收件匣 → ⚠️ 異常 → 店家少收」按「同意退」→「不補貨」；/);
  assert.ok(l.endsWith(RETURN_DISPOSITION_STEP));
  // 畫面上沒有「收貨短少」這個分頁名，不能再出現
  assert.doesNotMatch(l, /收貨短少/);
});

test("還沒派車：先不要派出去", () => {
  assert.match(returnTodoLine(TODO[2]), /^店D：撿貨單 WV-T-2 還沒派車（2 件）→ 這一項先不要派出去/);
});

test("派車單已取消 ⇒ 不用處理；不認得的狀態 ⇒ 請總倉確認", () => {
  assert.match(returnTodoLine({ ...TODO[0], stage: "transfer_cancelled" }), /已取消 → 不用處理/);
  assert.match(returnTodoLine({ ...TODO[0], stage: "weird" }), /請總倉確認/);
});

test("整段待辦：每家一行＋最後講退回貨處理頁怎麼按、錯貨退廠商；一家都沒派過 ⇒ 貨在總倉", () => {
  const lines = returnTodoLines(TODO);
  assert.equal(lines.length, 5);
  assert.deepEqual(lines.slice(3), RETURN_DISPOSITION_NOTES);
  assert.match(lines[3], /^「退回貨處理」頁：填「完好數量」（要勾「實物已到總倉」）＝恢復成可再派出的庫存；/);
  assert.match(lines[3], /填「破損數量」或「遺失數量」（要填原因）＝記入總倉損失；填完按「送出處理」。$/);
  assert.match(lines[4], /^錯貨要退廠商的：退回貨處理頁沒有「退廠商」選項，先在那一頁處理完，再走採購單退貨；/);
  for (const l of lines) assert.doesNotMatch(l, /收貨短少/);
  assert.deepEqual(returnTodoLines([]), ["這一項還沒有撿貨派出去：貨都還在總倉，要退廠商請走採購單退貨。"]);
  assert.deepEqual(returnTodoLines(null), returnTodoLines([]));
});

// ============================================================
// 五、按完的結果
// ============================================================

test("結果：筆數件數、收尾、通知（數字取自本機實跑回傳）", () => {
  const r = {
    ok: true, already_done: false, nothing_to_do: false, items_cancelled: 9, qty_cancelled: "10.000",
    offset_items_cancelled: 1, orders_cancelled: 6, orders_completed: 1, orders_kept: 1,
    members_notified: 0, released_rows: 1, released_qty: "2.000",
  };
  const lines = resultLines(r);
  assert.equal(lines[0], "已取消 9 筆、共 10 件（另有 1 筆抵減單一併取消）");
  assert.equal(lines[1], "整張取消 6 張；收尾成已完成 1 張；單子留著 1 張");
  assert.match(lines[2], /沒有發通知/);
  assert.match(lines[3], /已還回 2 件/);
  assert.match(resultLines({ ...r, members_notified: 7 })[2], /發斷貨通知給 7 位（不推 LINE）/);
});

test("重按：已經做過 ⇒ 一句話講清楚什麼都沒改", () => {
  assert.deepEqual(resultLines({ ok: true, already_done: true, nothing_to_do: true, items_cancelled: 0 }), [
    "已經做過了：這一項之前按過，沒有新的可以取消，這次什麼都沒改。",
  ]);
  assert.match(resultLines({ ok: true, already_done: false, nothing_to_do: true, items_cancelled: 0 })[0], /沒有可以取消/);
});

test("數字顯示", () => {
  assert.equal(fmtQty("10.000"), "10");
  assert.equal(fmtQty("2.500"), "2.5");
  assert.equal(fmtQty(null), "0");
  assert.equal(fmtQty("x"), "0");
});
