// 月結對帳單列印「一日一行」純函式測試：
//   node --test apps/admin/src/lib/settlementPrintRows.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  buildSettlementPrintRows,
  fetchInBatches,
  fmtPrintDate,
  fmtStatementMoney,
  roundYuan,
  statementTotals,
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

test("整頁共用金額格式：小計負數也是 －$N（不是 $-N）；單價帶兩位小數", () => {
  assert.equal(fmtStatementMoney(-20), "－$20");
  assert.equal(fmtStatementMoney(-19.75), "－$20");
  assert.equal(fmtStatementMoney(12.5, 2), "$12.50");
  assert.equal(fmtStatementMoney(-12.5, 2), "－$12.50");
  assert.equal(fmtStatementMoney(1234.5678, 2), "$1,234.57");
  assert.equal(fmtStatementMoney(-0.004, 2), "$0.00");
  for (const v of [-1, -20, -1234.5, -99999.4]) {
    assert.ok(!fmtStatementMoney(v).includes("$-"), `${v} 不能印成 $-N`);
    assert.ok(fmtStatementMoney(v).startsWith("－$"), `${v} 要印成 －$N`);
  }
});

test("取整到元：四捨五入、.5 遠離 0、字串也吃、跟顯示取整同一套", () => {
  assert.equal(roundYuan(100.5), 101);
  assert.equal(roundYuan(100.4999), 100);
  assert.equal(roundYuan(-0.5), -1);
  assert.equal(roundYuan(-0.4999), 0);
  assert.ok(Object.is(roundYuan(-0.4), 0), "取整後是 0 不能是 -0");
  assert.equal(roundYuan("2136.1"), 2136);
  assert.equal(roundYuan(null), 0);
  for (const v of [0.5, 1.5, 2.5, -2.5, 100.5, 1234.4999, -7.5]) {
    assert.equal(fmtStatementMoney(roundYuan(v)), fmtStatementMoney(v), `${v}：取整後顯示要跟直接顯示一樣`);
  }
});

test("紙上整數等式：100.50＋0.50＝101.00 → 印 $100＋$1＝$101（不能印成 $101＋$1＝$101）", () => {
  const t = statementTotals(100.5, 0.5, 101);
  assert.equal(t.ok, true);
  assert.deepEqual([t.goods, t.adjustment, t.payable], [100, 1, 101]);
  assert.equal(t.goods + t.adjustment, t.payable);
  // 金額是字串（PostgREST numeric）也一樣
  const s = statementTotals("100.5000", "0.5000", "101.0000");
  assert.deepEqual([s.goods, s.adjustment, s.payable], [100, 1, 101]);
});

test("紙上整數等式：各種小數、正負調整、沒有調整，X印＋Y印＝Z印 一律成立", () => {
  const branches = [0, 0.5, 100.5, 2135.6, 2136.1, 99.4999, -20.5, 12345.6789, 0.0001, 7.5];
  const adjs = [0, 0.5, -0.5, 1.4999, -300.25, 2.5, -2.5, 0.0001];
  for (const b of branches) {
    for (const a of adjs) {
      const payable = sumMoney([b, a]); // 產生月結時就是這兩項相加
      const t = statementTotals(b, a, payable);
      assert.equal(t.ok, true, `${b}＋${a}`);
      assert.equal(t.goods + t.adjustment, t.payable, `${b}＋${a}＝${payable}：紙上 ${t.goods}＋${t.adjustment}≠${t.payable}`);
      assert.equal(t.payable, roundYuan(payable));
      assert.equal(t.adjustment, roundYuan(a));
      // 貨款跟明細合計取整最多差 1 元（取整誤差，總額以系統應付為準）
      assert.ok(Math.abs(t.goods - roundYuan(b)) <= 1, `${b}＋${a}：貨款差太多`);
    }
  }
});

test("自我核對：明細少讀一段（例如截在 1000 筆）→ 不通過、差額照實回報、貨款印明細合計", () => {
  const t = statementTotals(70000, 0, 100000);
  assert.equal(t.ok, false);
  assert.equal(t.diff, 30000);
  assert.equal(t.goods, 70000);
  assert.equal(t.payable, 100000);
  // 調整讀漏也一樣擋
  assert.equal(statementTotals(1000, 0, 1050).ok, false);
});

test("自我核對：差 0.01 元以內算通過，超過就不通過（兩個方向都看）", () => {
  assert.equal(statementTotals(100, 0, 100.01).ok, true);
  assert.equal(statementTotals(100, 0, 99.99).ok, true);
  assert.equal(statementTotals(100, 0, 100.0101).ok, false);
  assert.equal(statementTotals(100, 0, 99.9899).ok, false);
  assert.equal(statementTotals("0.1", "0.2", "0.3").ok, true); // 浮點陷阱不能誤判成不一致
});

// 假的 .in("id", …) 查詢：記下每批收到哪些 id；failAt 指定第幾批（從 1 算）回 error
const fakeInQuery = (failAt = 0) => {
  const calls = [];
  const query = async (batch) => {
    calls.push(batch);
    if (calls.length === failAt) return { data: null, error: { message: "boom" } };
    return { data: batch.map((id) => ({ id, name: `n${id}` })), error: null };
  };
  return { calls, query };
};
const range = (n, from = 1) => Array.from({ length: n }, (_, i) => from + i);

test("分批查詢：450 個 id、一批 200 → 查三批（200／200／50），結果全部合併、照順序", async () => {
  const { calls, query } = fakeInQuery();
  const rows = await fetchInBatches(range(450), 200, query);
  assert.deepEqual(calls.map((b) => b.length), [200, 200, 50]);
  assert.deepEqual(calls.flat(), range(450));
  assert.deepEqual(rows.map((r) => r.id), range(450));
});

test("分批查詢：第 2 批回 error → 整個丟錯，不把其他批的結果當成完整資料回傳", async () => {
  const { calls, query } = fakeInQuery(2);
  await assert.rejects(fetchInBatches(range(450), 200, query), (e) => {
    assert.match(e.message, /第 2／3 批查詢失敗：boom/);
    return true;
  });
  assert.equal(calls.length, 3, "各批照樣都有送出（平行查），但結果不合併");
});

test("分批查詢：只有一批時失敗也要丟錯；最後一批失敗也一樣", async () => {
  await assert.rejects(fetchInBatches(range(5), 200, fakeInQuery(1).query), /第 1／1 批查詢失敗/);
  await assert.rejects(fetchInBatches(range(401), 200, fakeInQuery(3).query), /第 3／3 批查詢失敗/);
});

test("分批查詢：沒有 id 就不查、回空陣列；data 是 null 但沒有 error 當查無資料", async () => {
  const { calls, query } = fakeInQuery();
  assert.deepEqual(await fetchInBatches([], 200, query), []);
  assert.equal(calls.length, 0);
  assert.deepEqual(await fetchInBatches([1, 2], 200, async () => ({ data: null, error: null })), []);
});

test("分批查詢：查詢本身丟例外（例如斷網）也往外丟，不吞掉", async () => {
  await assert.rejects(
    fetchInBatches([1], 200, async () => {
      throw new Error("Failed to fetch");
    }),
    /Failed to fetch/,
  );
});

test("分批查詢：一批幾個不合理（0、負數）直接丟錯，不會無窮迴圈", async () => {
  await assert.rejects(fetchInBatches([1], 0, fakeInQuery().query), /batchSize/);
  await assert.rejects(fetchInBatches([1], -1, fakeInQuery().query), /batchSize/);
});
