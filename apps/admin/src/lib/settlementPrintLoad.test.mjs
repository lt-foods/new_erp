// 月結對帳單一次列印：勾選規則、限流、讀法的純函式測試（資料庫用假的查詢物件）
//   node --test apps/admin/src/lib/settlementPrintLoad.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
//
// settlementPrintLoad.ts 用的是專案慣例的無副檔名 import（"./fetchAllRows"），
// node 自己解不到 → 用 node:module 的 registerHooks 補一個「找不到就試 .ts」，只在這個測試裡生效。
import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (e) {
      if (specifier.startsWith(".")) return nextResolve(`${specifier}.ts`, context);
      throw e;
    }
  },
});

const {
  PRINT_BATCH_ITEM_CONCURRENCY,
  adjustmentsForSettlement,
  batchPrintState,
  loadBatchStatements,
  parsePrintBatchIds,
  printBatchHref,
  printSelectAllIds,
  printSelectBlockReason,
  printTargetIds,
  printableRows,
  printedLineSkuIds,
  runWithLimit,
  statementPrintBlockReason,
} = await import("./settlementPrintLoad.ts");

const row = (id, status, month = "2026-10") => ({ id, status, settlement_month: `${month}-01` });
const ALL_STATUSES = ["draft", "sent", "disputed", "confirmed", "remitted", "settled", "cancelled"];
const rows = ALL_STATUSES.map((s, i) => row(i + 1, s));

// ── 勾選規則 ──

test("可勾：沒選月份一律不給勾", () => {
  for (const s of ALL_STATUSES) assert.equal(printSelectBlockReason(row(1, s), "", null), "先選月份");
  assert.deepEqual(printSelectAllIds(rows, "", null), []);
  assert.deepEqual(printTargetIds(rows, new Set([1, 2]), "", null), []);
});

test("可勾：只有已取消不給勾（草稿可以手動勾）", () => {
  for (const s of ["draft", "sent", "disputed", "confirmed", "remitted", "settled"]) {
    assert.equal(printSelectBlockReason(row(1, s), "2026-10", null), null, s);
  }
  assert.match(printSelectBlockReason(row(1, "cancelled"), "2026-10", null), /已取消/);
});

test("可勾：這個月沒全部載入 → 全部不給勾，原因照傳", () => {
  const block = "這個月有 20 張、目前只載入 16 張，不能一次全選";
  assert.equal(printSelectBlockReason(row(1, "sent"), "2026-10", block), block);
  assert.deepEqual(printableRows(rows, "2026-10", block), []);
  assert.deepEqual(printSelectAllIds(rows, "2026-10", block), []);
  assert.deepEqual(printTargetIds(rows, new Set([2]), "2026-10", block), []);
});

test("可勾：換月份還沒載入完那一瞬間，上個月的列不給勾也不會被印", () => {
  assert.match(printSelectBlockReason(row(1, "sent", "2026-09"), "2026-10", null), /不是目前篩選的月份/);
  assert.deepEqual(printTargetIds([row(1, "sent", "2026-09")], new Set([1]), "2026-10", null), []);
});

test("全選：不選草稿、不選已取消，其他狀態都選", () => {
  assert.deepEqual(printSelectAllIds(rows, "2026-10", null), [2, 3, 4, 5, 6]);
});

test("要印的：列表與勾選的交集、照列表順序；手動勾的草稿算、勾選集合裡的已取消與不在列表的不算", () => {
  const selected = new Set([6, 1, 7, 999, 2]);
  assert.deepEqual(printTargetIds(rows, selected, "2026-10", null), [1, 2, 6]);
});

test("列印網址只帶單號，不帶版本", () => {
  assert.equal(printBatchHref([3, 1]), "/transfers/settlement/print-batch?ids=3,1");
});

test("網址 ids 解析：空、非法、重複、順序", () => {
  assert.deepEqual(parsePrintBatchIds(null), { kind: "empty" });
  assert.deepEqual(parsePrintBatchIds(""), { kind: "empty" });
  for (const bad of ["abc", "1,abc", "1,,2", "1,-2", "1.5", "0", "1;2", "99999999999999999999"]) {
    assert.deepEqual(parsePrintBatchIds(bad), { kind: "invalid" }, bad);
  }
  assert.deepEqual(parsePrintBatchIds("7,3,7, 5"), { kind: "ok", ids: [7, 3, 5] });
});

// ── 限流 ──

test("限流：同時最多 limit 個、全部跑完、順序照排", async () => {
  let running = 0;
  let peak = 0;
  const seen = [];
  await runWithLimit([1, 2, 3, 4, 5, 6, 7, 8], 3, async (n) => {
    running++;
    peak = Math.max(peak, running);
    seen.push(n);
    await new Promise((r) => setTimeout(r, 2));
    running--;
  });
  assert.equal(peak, 3);
  assert.deepEqual(seen, [1, 2, 3, 4, 5, 6, 7, 8]);
});

test("限流：空陣列不跑；limit 不合法丟錯；取消後不再開始新的", async () => {
  await runWithLimit([], 3, async () => assert.fail("不該跑"));
  await assert.rejects(() => runWithLimit([1], 0, async () => {}), /limit/);
  let count = 0;
  await runWithLimit([1, 2, 3, 4], 1, async () => { count++; }, () => count >= 2);
  assert.equal(count, 2);
});

// ── 調整對回各家 ──

test("調整按店＋月份對回各家，同店不同月不混、順序照查詢結果", () => {
  const adj = [
    { id: 1, store_id: 1, settlement_month: "2026-10-01", amount: 100, reason: "A十月-1", created_at: "2026-10-05T00:00:00Z" },
    { id: 2, store_id: 2, settlement_month: "2026-10-01", amount: 200, reason: "B十月", created_at: "2026-10-06T00:00:00Z" },
    { id: 3, store_id: 1, settlement_month: "2026-09-01", amount: 300, reason: "A九月", created_at: "2026-09-06T00:00:00Z" },
    { id: 4, store_id: 1, settlement_month: "2026-10-01", amount: -50, reason: "A十月-2", created_at: "2026-10-07T00:00:00Z" },
  ];
  const a10 = adjustmentsForSettlement(adj, { store_id: 1, settlement_month: "2026-10-01" });
  assert.deepEqual(a10.map((a) => a.reason), ["A十月-1", "A十月-2"]);
  assert.deepEqual(adjustmentsForSettlement(adj, { store_id: 1, settlement_month: "2026-09-01" }).map((a) => a.reason), ["A九月"]);
  assert.deepEqual(adjustmentsForSettlement(adj, { store_id: 3, settlement_month: "2026-10-01" }), []);
});

test("品名只查逐筆印出的行：HQ 進貨、退貨沖回不查，未知類型要查，跨店去重", () => {
  const it = (entry_type, sku_id) => ({ id: sku_id * 10, transfer_id: 1, sku_id, qty_received: 1, line_amount: 1, branch_amount: 1, received_at: "2026-10-01T00:00:00Z", entry_type, description: null });
  const ids = printedLineSkuIds([
    [it("hq_inbound", 1), it("return_out", 2), it("air_in", 3), it("mystery", 4)],
    [it("air_out", 3), it("free_in", 5), it("hq_inbound", 6)],
  ]);
  assert.deepEqual(ids.sort((a, b) => a - b), [3, 4, 5]);
});

// ── 假資料庫 ──
function fakeSb(tables, { fail = () => false, delay = 0 } = {}) {
  const log = [];
  let inFlightItems = 0;
  let peakItems = 0;
  const sb = {
    log,
    peak: () => peakItems,
    from(table) {
      const q = { table, eq: [], in: [], range: null, limit: null };
      const builder = {
        select() { return builder; },
        order() { return builder; },
        eq(k, v) { q.eq.push([k, v]); return builder; },
        in(k, v) { q.in.push([k, v]); return builder; },
        limit(n) { q.limit = n; return builder; },
        range(a, b) { q.range = [a, b]; return builder; },
        then(res, rej) {
          log.push(q);
          const isItems = table === "store_monthly_settlement_items";
          return (async () => {
            if (isItems) { inFlightItems++; peakItems = Math.max(peakItems, inFlightItems); }
            await new Promise((r) => setTimeout(r, delay));
            if (isItems) inFlightItems--;
            if (fail(table, q)) return { data: null, error: { message: `假的失敗 ${table}` } };
            let rows = tables[table] ?? [];
            for (const [k, v] of q.eq) rows = rows.filter((r) => r[k] === v);
            for (const [k, v] of q.in) rows = rows.filter((r) => v.includes(r[k]));
            if (q.range) rows = rows.slice(q.range[0], q.range[1] + 1);
            else rows = rows.slice(0, q.limit ?? 1000);
            return { data: rows, error: null };
          })().then(res, rej);
        },
      };
      return builder;
    },
  };
  return sb;
}

const S = (id, store_id, payable, o = {}) => ({ id, settlement_month: "2026-10-01", store_id, payable_amount: payable, cost_amount: 1, branch_amount: payable, transfer_count: 1, item_count: 1, status: "sent", generated_receivable_id: null, ...o });
let iid = 0;
const I = (settlement_id, entry_type, branch_amount, sku_id) => ({ id: ++iid, settlement_id, transfer_id: 1, sku_id, qty_received: 1, unit_cost: 1, line_amount: 1, unit_branch_price: branch_amount, branch_amount, received_at: "2026-10-03T00:00:00Z", entry_type, description: null });

function baseTables() {
  return {
    store_monthly_settlements: [S(3, 30, 150), S(1, 10, 100, { generated_receivable_id: 77 }), S(2, 20, 50)],
    stores: [{ id: 10, code: "A", name: "測試店A" }, { id: 20, code: "B", name: "測試店B" }, { id: 30, code: "C", name: "測試店C" }],
    tenants: [{ name: "測試公司" }],
    store_settlement_adjustments: [
      { id: 1, store_id: 10, settlement_month: "2026-10-01", status: "active", amount: -20, reason: "A折讓", created_at: "2026-10-09T00:00:00Z" },
      { id: 2, store_id: 10, settlement_month: "2026-10-01", status: "void", amount: 999, reason: "作廢的不可出現", created_at: "2026-10-09T00:00:00Z" },
      { id: 3, store_id: 20, settlement_month: "2026-09-01", status: "active", amount: 999, reason: "別的月份", created_at: "2026-09-09T00:00:00Z" },
    ],
    store_receivables: [{ id: 77, receivable_no: "AR-1", due_date: "2026-11-30", status: "open" }],
    store_monthly_settlement_items: [
      I(1, "hq_inbound", 120, 501),
      I(2, "hq_inbound", 50, 502),
      I(3, "hq_inbound", 100, 503),
      I(3, "air_in", 50, 504),
    ],
    skus: [501, 502, 503, 504].map((id) => ({ id, sku_code: `C${id}`, product_name: `品${id}`, variant_name: null })),
  };
}

async function load(sb, ids) {
  let last = null;
  const snapshots = [];
  await loadBatchStatements(sb, ids, (s) => { last = s; snapshots.push(s); });
  return { sheets: last, snapshots };
}

test("讀法：順序照網址、調整對回各家且只取 active、應收單對回、品名只查逐筆行", async () => {
  const sb = fakeSb(baseTables());
  const { sheets } = await load(sb, [3, 1, 2]);
  assert.deepEqual(sheets.map((s) => s.id), [3, 1, 2]);
  assert.deepEqual(sheets.map((s) => s.error), [null, null, null]);
  assert.deepEqual(sheets.map((s) => s.namesFailed), [[], [], []]);
  const [c, a, b] = sheets;
  assert.deepEqual(a.data.adjustments.map((x) => x.reason), ["A折讓"]);
  assert.deepEqual(b.data.adjustments, []);
  assert.equal(a.data.receivable.receivable_no, "AR-1");
  assert.equal(b.data.receivable, null);
  assert.equal(a.data.tenantName, "測試公司");
  assert.deepEqual(c.data.items.map((x) => x.entry_type).sort(), ["air_in", "hq_inbound"]);
  // 品名只查了店C的逐筆行
  const skuQueries = sb.log.filter((q) => q.table === "skus");
  assert.equal(skuQueries.length, 1);
  assert.deepEqual(skuQueries[0].in[0][1], [504]);
  // 全部讀完可以印
  const st = batchPrintState(sheets, new Set());
  assert.equal(st.blockReason, undefined);
  assert.equal(st.loadedCount, 3);
  assert.equal(st.issues.length, 0);
});

test("查詢次數：每張共用表一次查詢，明細每家一次（沒破千時），明細同時最多 3 家", async () => {
  const t = baseTables();
  const ids = [];
  for (let i = 0; i < 16; i++) {
    const id = 100 + i;
    ids.push(id);
    t.store_monthly_settlements.push(S(id, 1000 + i, 10));
    t.stores.push({ id: 1000 + i, code: `X${i}`, name: `測試店X${i}` });
    t.store_monthly_settlement_items.push(I(id, "hq_inbound", 10, 501));
  }
  const sb = fakeSb(t, { delay: 2 });
  const { sheets } = await load(sb, ids);
  assert.equal(batchPrintState(sheets, new Set()).blockReason, undefined);
  const count = (table) => sb.log.filter((q) => q.table === table).length;
  assert.equal(PRINT_BATCH_ITEM_CONCURRENCY, 3);
  assert.equal(sb.peak(), 3);
  assert.equal(count("store_monthly_settlement_items"), 16);
  assert.equal(count("store_monthly_settlements"), 1);
  assert.equal(count("stores"), 1);
  assert.equal(count("tenants"), 1);
  assert.equal(count("store_settlement_adjustments"), 1);
  assert.equal(count("store_receivables"), 0); // 這批都沒有應收單
  assert.equal(count("skus"), 0); // 這批都是一天一行，不用品名
});

test("明細破千行：讀得完不截斷", async () => {
  const t = baseTables();
  t.store_monthly_settlements = [S(1, 10, 2500)];
  t.store_settlement_adjustments = [];
  t.store_monthly_settlement_items = Array.from({ length: 2500 }, () => I(1, "hq_inbound", 1, 501));
  const { sheets } = await load(fakeSb(t), [1]);
  assert.equal(sheets[0].data.items.length, 2500);
  assert.equal(batchPrintState(sheets, new Set()).blockReason, undefined);
});

test("查詢失敗不能當空資料：月結表頭失敗丟錯", async () => {
  const sb = fakeSb(baseTables(), { fail: (t) => t === "store_monthly_settlements" });
  await assert.rejects(() => load(sb, [1]), /假的失敗/);
});

test("查詢失敗不能當空資料：調整失敗 → 每家都不給印（不當成 0），也不去讀明細", async () => {
  const sb = fakeSb(baseTables(), { fail: (t) => t === "store_settlement_adjustments" });
  const { sheets } = await load(sb, [1, 2]);
  for (const s of sheets) {
    assert.match(s.error, /金額調整載入失敗/);
    assert.equal(s.data, null);
  }
  assert.equal(sb.log.filter((q) => q.table === "store_monthly_settlement_items").length, 0);
  const st = batchPrintState(sheets, new Set());
  assert.equal(st.issues.length, 2);
  assert.ok(st.blockReason);
});

test("查詢失敗不能當空資料：分店失敗、明細失敗只記在該家，其他家照讀", async () => {
  let sb = fakeSb(baseTables(), { fail: (t) => t === "stores" });
  let { sheets } = await load(sb, [1]);
  assert.match(sheets[0].error, /分店資料載入失敗/);

  sb = fakeSb(baseTables(), { fail: (t, q) => t === "store_monthly_settlement_items" && q.eq.some(([k, v]) => k === "settlement_id" && v === 2) });
  ({ sheets } = await load(sb, [1, 2, 3]));
  assert.match(sheets[1].error, /明細讀取失敗/);
  assert.ok(sheets[0].data && sheets[2].data);
  const st = batchPrintState(sheets, new Set());
  assert.deepEqual(st.issues.map((i) => i.id), [2]);
  assert.match(st.issues[0].label, /測試店B/);
  assert.ok(st.blockReason);
  // 拿掉那家後其他家可以印，而且列得出這次沒印誰
  const after = batchPrintState(sheets, new Set([2]));
  assert.equal(after.blockReason, undefined);
  assert.deepEqual(after.active.map((s) => s.id), [1, 3]);
  assert.deepEqual(after.removed.map((s) => s.id), [2]);
});

test("名稱類失敗：只擋得到要用到的家", async () => {
  // 品名失敗：只有店C有逐筆行
  let { sheets } = await load(fakeSb(baseTables(), { fail: (t) => t === "skus" }), [1, 3]);
  assert.deepEqual(sheets.map((s) => s.namesFailed), [[], ["商品編號／品名"]]);
  assert.ok(batchPrintState(sheets, new Set()).blockReason);
  // 應收單失敗：只有店A有應收單
  ({ sheets } = await load(fakeSb(baseTables(), { fail: (t) => t === "store_receivables" }), [1, 2]));
  assert.deepEqual(sheets.map((s) => s.namesFailed), [["應收單號"], []]);
  // 公司名失敗：每家都有
  ({ sheets } = await load(fakeSb(baseTables(), { fail: (t) => t === "tenants" }), [1, 2]));
  assert.deepEqual(sheets.map((s) => s.namesFailed), [["公司名稱"], ["公司名稱"]]);
});

test("查無此單、已取消：講得出來，不給印，拿掉後其他家可印", async () => {
  const t = baseTables();
  t.store_monthly_settlements.push(S(9, 10, 0, { status: "cancelled" }));
  const { sheets } = await load(fakeSb(t), [1, 8888, 9]);
  const st = batchPrintState(sheets, new Set());
  assert.deepEqual(st.issues.map((i) => i.message), ["查無此月結單", "這張月結已取消"]);
  assert.equal(st.issues[0].label, "#8888");
  assert.equal(batchPrintState(sheets, new Set([8888, 9])).blockReason, undefined);
});

test("金額對不上：不用等品名就講、列印擋住；草稿有數字", async () => {
  const t = baseTables();
  t.store_monthly_settlements[1].payable_amount = 999; // 店A
  t.store_monthly_settlements[2].status = "draft"; // 店B
  const { sheets, snapshots } = await load(fakeSb(t), [1, 2]);
  const st = batchPrintState(sheets, new Set());
  assert.deepEqual(st.issues.map((i) => i.id), [1]);
  assert.match(st.issues[0].message, /不一致/);
  assert.equal(st.draftCount, 1);
  assert.ok(st.blockReason);
  // 中途狀態：明細還沒全讀完就不能印，品名還在讀也不能印
  for (const snap of snapshots.slice(0, -1)) {
    assert.ok(batchPrintState(snap, new Set([1])).blockReason, "讀完前不可放行");
  }
  // 拿掉對不上的那家，草稿還在就還是能印（黃字提醒）
  const after = batchPrintState(sheets, new Set([1]));
  assert.equal(after.blockReason, undefined);
  assert.equal(after.draftCount, 1);
  assert.equal(batchPrintState(sheets, new Set([1, 2])).blockReason, "沒有要印的對帳單");
});

test("不給印的原因：順序與單張頁相同", () => {
  assert.match(statementPrintBlockReason({ ok: false }, []), /不一致/);
  assert.match(statementPrintBlockReason({ ok: true }, ["應收單號"]), /載入失敗/);
  assert.match(statementPrintBlockReason({ ok: true }, null), /載入中/);
  assert.equal(statementPrintBlockReason({ ok: true }, []), undefined);
});
