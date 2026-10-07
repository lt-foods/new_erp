// 月結對帳單列印「一日一行」純函式測試：
//   node --test apps/admin/src/lib/settlementPrintRows.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  buildSettlementPrintRows,
  fmtPrintDate,
  fmtStatementMoney,
  sumMoney,
  summarizeSettlementItems,
  taipeiDate,
} from "./settlementPrintRows.ts";

let nextId = 1;
// 一行明細；at 用 UTC 寫，跟跑測試的機器時區無關
const item = (entry_type, at, o = {}) => ({
  id: nextId++,
  transfer_id: 1,
  sku_id: 1,
  qty_received: 1,
  unit_cost: 10,
  line_amount: 10,
  unit_branch_price: 12,
  branch_amount: 12,
  received_at: at,
  entry_type,
  description: null,
  ...o,
});
const days = (rows) => rows.filter((r) => r.kind === "day");
const lines = (rows) => rows.filter((r) => r.kind === "line");

test("台北日期：UTC 16:00 是台北隔天 00:00，不看機器時區", () => {
  assert.equal(taipeiDate("2026-09-02T15:59:59Z"), "2026-09-02");
  assert.equal(taipeiDate("2026-09-02T16:00:00Z"), "2026-09-03");
  assert.equal(taipeiDate("2026-09-03T00:00:00+08:00"), "2026-09-03");
  assert.equal(taipeiDate("not-a-date"), "");
});

test("HQ 進貨跨台北午夜：切成兩天兩行", () => {
  const rows = buildSettlementPrintRows([
    item("hq_inbound", "2026-09-02T15:59:59Z", { branch_amount: 100 }),
    item("hq_inbound", "2026-09-02T16:00:00Z", { branch_amount: 200 }),
    item("hq_inbound", "2026-09-03T15:59:59Z", { branch_amount: 300 }),
  ]);
  const d = days(rows);
  assert.deepEqual(d.map((r) => [r.date, r.branchAmount, r.lineCount]), [
    ["2026-09-02", 100, 1],
    ["2026-09-03", 500, 2],
  ]);
  assert.equal(lines(rows).length, 0);
});

test("同日多張調撥單：transferIds 不重複、照出現順序；一張單多行只算一張", () => {
  const rows = buildSettlementPrintRows([
    item("hq_inbound", "2026-09-05T01:00:00Z", { transfer_id: 77 }),
    item("hq_inbound", "2026-09-05T02:00:00Z", { transfer_id: 55 }),
    item("hq_inbound", "2026-09-05T03:00:00Z", { transfer_id: 77 }),
    item("hq_inbound", "2026-09-06T03:00:00Z", { transfer_id: 90 }),
    item("hq_inbound", "2026-09-06T04:00:00Z", { transfer_id: 90 }),
  ]);
  const [d5, d6] = days(rows);
  assert.deepEqual(d5.transferIds, [77, 55]);
  assert.equal(d5.lineCount, 3);
  assert.deepEqual(d6.transferIds, [90]);
  assert.equal(d6.lineCount, 2);
});

test("同日同商品多行：數量、金額都加總，項數＝行數", () => {
  const rows = buildSettlementPrintRows([
    item("hq_inbound", "2026-09-07T01:00:00Z", { sku_id: 9, transfer_id: 1, qty_received: 3, branch_amount: 36, line_amount: 30 }),
    item("hq_inbound", "2026-09-07T05:00:00Z", { sku_id: 9, transfer_id: 2, qty_received: 2.5, branch_amount: 30, line_amount: 25 }),
  ]);
  const [d] = days(rows);
  assert.equal(d.lineCount, 2);
  assert.equal(d.qty, 5.5);
  assert.equal(d.branchAmount, 66);
  assert.equal(d.costAmount, 55);
  assert.equal(d.costMissingCount, 0);
});

test("負數：空中轉出逐筆保留負值；退貨沖回一天一行、加總是負的", () => {
  const rows = buildSettlementPrintRows([
    item("air_out", "2026-09-08T01:00:00Z", { branch_amount: -24, line_amount: -20 }),
    item("return_out", "2026-09-08T02:00:00Z", { branch_amount: -12.5, line_amount: -10 }),
    item("return_out", "2026-09-08T03:00:00Z", { branch_amount: -7.25, line_amount: -6 }),
  ]);
  const [l] = lines(rows);
  assert.equal(l.item.entry_type, "air_out");
  assert.equal(l.item.branch_amount, -24);
  const [d] = days(rows);
  assert.equal(d.entryType, "return_out");
  assert.equal(d.branchAmount, -19.75);
  assert.equal(d.costAmount, -16);
});

test("成本 null：不當 0 默默加，另外記幾項缺成本；全缺時 costMissingCount＝lineCount", () => {
  const rows = buildSettlementPrintRows([
    item("hq_inbound", "2026-09-09T01:00:00Z", { line_amount: 30 }),
    item("hq_inbound", "2026-09-09T02:00:00Z", { line_amount: null, unit_cost: null }),
    item("hq_inbound", "2026-09-09T03:00:00Z", { line_amount: "12.5" }),
    item("return_out", "2026-09-10T01:00:00Z", { line_amount: null, unit_cost: null }),
    item("return_out", "2026-09-10T02:00:00Z", { line_amount: null, unit_cost: null }),
  ]);
  const [hq, ret] = days(rows);
  assert.equal(hq.costAmount, 42.5);
  assert.equal(hq.costMissingCount, 1);
  assert.equal(ret.costMissingCount, 2);
  assert.equal(ret.lineCount, 2);
  assert.equal(ret.costAmount, 0);

  const all = summarizeSettlementItems([
    item("hq_inbound", "2026-09-09T01:00:00Z", { line_amount: 30 }),
    item("hq_inbound", "2026-09-09T02:00:00Z", { line_amount: null }),
    item("air_in", "2026-09-09T02:00:00Z", { line_amount: "" }),
  ]);
  assert.equal(all.costAmount, 30);
  assert.equal(all.costMissingCount, 2);
});

test("併日後分店小計總和＝逐筆總和（含小數、正負混合、金額是字串也一樣）", () => {
  const amounts = [0.1, 0.2, 12.3456, -3.3333, 100.5, "7.0001", 45.67, -0.05, 0.3, 19.99];
  const types = ["hq_inbound", "hq_inbound", "hq_inbound", "return_out", "hq_inbound", "air_in", "hq_inbound", "air_out", "return_out", "free_in"];
  const ats = [
    "2026-09-01T00:00:00Z", "2026-09-01T10:00:00Z", "2026-09-01T16:00:00Z", "2026-09-02T01:00:00Z",
    "2026-09-03T03:00:00Z", "2026-09-03T04:00:00Z", "2026-09-03T15:59:59Z", "2026-09-04T01:00:00Z",
    "2026-09-02T23:00:00Z", "2026-09-05T01:00:00Z",
  ];
  const items = amounts.map((a, i) => item(types[i], ats[i], { branch_amount: a }));
  const rows = buildSettlementPrintRows(items);

  const fromRows = sumMoney(rows.map((r) => (r.kind === "day" ? r.branchAmount : r.item.branch_amount)));
  const perLine = summarizeSettlementItems(items).branchAmount;
  // 手算：0.1+0.2+12.3456-3.3333+100.5+7.0001+45.67-0.05+0.3+19.99 = 182.7224
  assert.equal(perLine, 182.7224);
  assert.equal(fromRows, perLine);
  // 每一行都還在：併日不吃掉任何明細
  const covered = rows.reduce((s, r) => s + (r.kind === "day" ? r.lineCount : 1), 0);
  assert.equal(covered, items.length);
  // 浮點陷阱：0.1+0.2 直接相加是 0.30000000000000004，這裡要剛好 0.3
  assert.equal(sumMoney([0.1, 0.2]), 0.3);
});

test(".5 的金額不會因浮點誤差少 1 元：100.25＋0.25＝100.5 顯示 $101", () => {
  const rows = buildSettlementPrintRows([
    item("hq_inbound", "2026-09-11T01:00:00Z", { branch_amount: 100.25 }),
    item("hq_inbound", "2026-09-11T02:00:00Z", { branch_amount: 0.25 }),
  ]);
  const [d] = days(rows);
  assert.equal(d.branchAmount, 100.5);
  assert.equal(fmtStatementMoney(d.branchAmount), "$101");
});

test("店到店仍逐筆且排最前（空中轉入→空中轉出→自由轉入→自由轉出），再來 HQ 進貨、最後退貨", () => {
  const items = [
    item("return_out", "2026-09-01T01:00:00Z"),
    item("hq_inbound", "2026-09-20T01:00:00Z"),
    item("free_out", "2026-09-02T01:00:00Z"),
    item("air_out", "2026-09-15T01:00:00Z"),
    item("hq_inbound", "2026-09-03T01:00:00Z"),
    item("air_in", "2026-09-10T01:00:00Z"),
    item("air_in", "2026-09-04T01:00:00Z"),
    item("free_in", "2026-09-05T01:00:00Z"),
    item("air_in", "2026-09-04T01:00:00Z"),
  ];
  const rows = buildSettlementPrintRows(items);
  assert.deepEqual(
    rows.map((r) => (r.kind === "line" ? `${r.item.entry_type}@${r.date}#${r.item.id}` : `${r.entryType}@${r.date}`)),
    [
      `air_in@2026-09-04#${items[6].id}`,
      `air_in@2026-09-04#${items[8].id}`,
      `air_in@2026-09-10#${items[5].id}`,
      `air_out@2026-09-15#${items[3].id}`,
      `free_in@2026-09-05#${items[7].id}`,
      `free_out@2026-09-02#${items[2].id}`,
      "hq_inbound@2026-09-03",
      "hq_inbound@2026-09-20",
      "return_out@2026-09-01",
    ],
  );
  // 店到店那幾行原樣帶著原本的明細
  assert.equal(lines(rows)[0].item, items[6]);
});

test("不認得的類型照逐筆印在店到店後面，不會被吞掉", () => {
  const rows = buildSettlementPrintRows([
    item("hq_inbound", "2026-09-01T01:00:00Z"),
    item("something_new", "2026-09-01T01:00:00Z"),
    item("air_in", "2026-09-02T01:00:00Z"),
  ]);
  assert.deepEqual(
    rows.map((r) => (r.kind === "line" ? r.item.entry_type : r.entryType)),
    ["air_in", "something_new", "hq_inbound"],
  );
});

test("沒有明細：空陣列", () => {
  assert.deepEqual(buildSettlementPrintRows([]), []);
  assert.deepEqual(summarizeSettlementItems([]), { lineCount: 0, branchAmount: 0, costAmount: 0, costMissingCount: 0 });
});

test("日期顯示：2026-09-03 → 2026/9/3；空的顯示 —", () => {
  assert.equal(fmtPrintDate("2026-09-03"), "2026/9/3");
  assert.equal(fmtPrintDate("2026-12-31"), "2026/12/31");
  assert.equal(fmtPrintDate(""), "—");
});

test("等式金額：負數寫成 －$N、沒有調整是 $0、四捨五入後是 0 不帶負號", () => {
  assert.equal(fmtStatementMoney(123456.4), "$123,456");
  assert.equal(fmtStatementMoney(-500), "－$500");
  assert.equal(fmtStatementMoney(-1234.5), "－$1,235");
  assert.equal(fmtStatementMoney(0), "$0");
  assert.equal(fmtStatementMoney(-0.4), "$0");
  assert.equal(fmtStatementMoney(Number.NaN), "$0");
});
