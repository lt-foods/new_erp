// 收貨配單「預設勾誰」＋現場分貨單：純函式測試
//   node --test apps/admin/src/lib/receiveAllocation.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import { buildSortSheet, greedyItemsByTime, normalizeReceivePreview, toProductView } from "./receiveAllocation.ts";

// ============================================================
// 舊版：搬進 lib 之前，收貨視窗（fbe14545 的 apps/admin/src/components/ManualAllocateModal.tsx）
// 自己算預設勾選的那幾段。逐字抄過來，只拿掉 TypeScript 型別（.mjs 不能有型別）：
//   greedyItemsByTime ＝ :54-72
//   loadPreview 內文 ＝ :218-251（RPC 回傳 → 正規化 → cap）＋ :254-258（預設勾選）；
//     原本的 setData / setSelected 改成 return，touchedRef.current 改成參數 touched。
// ⛔ 這段是「對照組」，以後 lib 改挑法時不要跟著改它 —— 改了就失去對照的意義；
//    真的要改挑法，連這個檔一起重寫並在 PR 寫清楚收貨視窗的行為變了。
// ============================================================
const legacy = (() => {
  function greedyItemsByTime(
    orders,
    caps,
    onlyWithin,
  ) {
    const used = new Map();
    const next = new Set();
    for (const o of orders) {
      for (const it of o.items) {
        if (it.item_id == null) continue;
        if (onlyWithin && !onlyWithin.has(it.item_id)) continue;
        if (it.qty <= (caps.get(it.sku_id) ?? 0) - (used.get(it.sku_id) ?? 0)) {
          next.add(it.item_id);
          used.set(it.sku_id, (used.get(it.sku_id) ?? 0) + it.qty);
        }
      }
    }
    return next;
  }

  function loadPreview(d, touched, cur) {
      const raw = d;
      const incoming = (raw.incoming ?? []).map((r) => ({ ...r, qty: Number(r.qty) }));
      const incMap = new Map(incoming.map((r) => [r.sku_id, r.qty]));
      const orders = (raw.orders ?? []).map((o) => ({
        ...o,
        status: o.status ?? "confirmed",
        arrived: Boolean(o.arrived),
        items: (o.items ?? []).map((i) => ({
          item_id: i.item_id,
          sku_id: i.sku_id,
          qty: Number(i.qty),
          backordered: Boolean(i.backordered),
        })),
      }));
      // 可配上限 = 既有可配（可能為負；伺服端已把畫面上的派貨中單從「已承諾」
      // 排除）+ 本次到貨 —— 跟確認收貨後伺服端算出的預算一致
      const budgetRows = (raw.budget ?? []).map((b) => ({
        sku_id: b.sku_id,
        sku_code: b.sku_code,
        name: b.name,
        cap: Number(b.available) + (incMap.get(b.sku_id) ?? 0),
        pool: Number(b.pool) || 0,
      }));
      const data = { budget: budgetRows, incoming, orders, waiting_count: 0 };

      const caps = new Map(budgetRows.map((b) => [b.sku_id, b.cap]));
      const selected =
        touched
          ? greedyItemsByTime(orders, caps, cur)
          : greedyItemsByTime(orders, caps);
      return { data, selected };
  }

  return { loadPreview };
})();

// 新版：收貨視窗現在的寫法（ManualAllocateModal.loadPreview 呼叫 lib）
function current(d, touched, cur) {
  const { incoming, orders, budgetRows } = normalizeReceivePreview(d);
  const data = { budget: budgetRows, incoming, orders, waiting_count: 0 };
  const caps = new Map(budgetRows.map((b) => [b.sku_id, b.cap]));
  const selected = touched ? greedyItemsByTime(orders, caps, cur) : greedyItemsByTime(orders, caps);
  return { data, selected };
}

// 分貨單：跟列印頁同一條路（normalize → greedy → buildSortSheet）
function sheetOf(d) {
  const pv = normalizeReceivePreview(d);
  const caps = new Map(pv.budgetRows.map((b) => [b.sku_id, b.cap]));
  return buildSortSheet(pv, greedyItemsByTime(pv.orders, caps), { tag: "meta" });
}

const sorted = (set) => [...set].sort((a, b) => a - b);
const near = (a, b) => Math.abs(a - b) < 1e-9;

// 新舊完全相同：正規化後的資料、預設勾選
function assertSameAsLegacy(d, touched = false, cur = undefined) {
  const a = legacy.loadPreview(d, touched, cur);
  const b = current(d, touched, cur);
  assert.deepStrictEqual(b.data, a.data);
  assert.deepStrictEqual(sorted(b.selected), sorted(a.selected));
}

// 三條固定檢查（對「所有被勾的商品」，含不在這車的）＋兩段加總要對得上每個客人那幾行。
// 回傳 sheet 與「被勾到但不在這車的商品有幾個」（隨機測試用來確認真的有涵蓋到）。
function assertSheetInvariants(d) {
  const sheet = sheetOf(d);
  const { data, selected } = legacy.loadPreview(d, false);
  // 舊版視窗的預設勾選，逐商品加總（只算 > 0 的品項；0 個的勾了也沒有貨要拿）
  const pickedBySku = new Map();
  for (const o of data.orders)
    for (const it of o.items)
      if (it.item_id != null && selected.has(it.item_id) && it.qty > 0)
        pickedBySku.set(it.sku_id, (pickedBySku.get(it.sku_id) ?? 0) + it.qty);
  const sumLines = (section, skuId) =>
    section.reduce((s, c) => s + c.lines.filter((l) => l.sku_id === skuId).reduce((x, l) => x + l.qty, 0), 0);
  const incomingIds = new Set(data.incoming.map((r) => r.sku_id));
  const notInTruck = [...pickedBySku.keys()].filter((id) => !incomingIds.has(id));
  // 商品清單＝這車的（照到貨清單順序）＋ 被勾到但不在這車的
  assert.deepStrictEqual(
    sheet.skus.filter((s) => s.inTruck).map((s) => s.sku_id),
    data.incoming.map((r) => r.sku_id),
    "這車的商品照到貨清單順序全列",
  );
  assert.deepStrictEqual(
    new Set(sheet.skus.filter((s) => !s.inTruck).map((s) => s.sku_id)),
    new Set(notInTruck),
    "被勾到但不在這車的商品要列出來",
  );
  // ① 每個被勾的商品：這車 ＋ 門市現貨 ＝ 視窗預設勾選
  for (const [skuId, picked] of pickedBySku) {
    const s = sheet.skus.find((x) => x.sku_id === skuId);
    assert.ok(s, `sku ${skuId}：視窗勾了 ${picked} 個，分貨單沒有這個商品`);
    assert.ok(
      near(s.toCustomers + s.fromStore, picked),
      `sku ${skuId}：這車 ${s.toCustomers}＋門市現貨 ${s.fromStore} ≠ 視窗預設勾選 ${picked}`,
    );
  }
  for (const s of sheet.skus) {
    // ② 這車 ≤ 到貨；③ 這車 ＋ 分剩 ＝ 到貨（不在這車的：到貨 0、這車 0、分剩 0）
    assert.ok(s.toCustomers <= s.shipped + 1e-9, `sku ${s.sku_id}：這車 ${s.toCustomers} > 到貨 ${s.shipped}`);
    assert.ok(near(s.toCustomers + s.surplus, s.shipped), `sku ${s.sku_id}：這車＋分剩 ≠ 到貨`);
    if (!s.inTruck) assert.deepStrictEqual([s.shipped, s.toCustomers, s.surplus], [0, 0, 0]);
    if (!pickedBySku.has(s.sku_id)) assert.equal(s.toCustomers + s.fromStore, 0);
    assert.ok(near(sumLines(sheet.customers, s.sku_id), s.toCustomers), `sku ${s.sku_id}：客人段加總 ≠ 這車`);
    assert.ok(near(sumLines(sheet.fromStore, s.sku_id), s.fromStore), `sku ${s.sku_id}：門市現貨段加總 ≠ 門市現貨`);
    assert.ok(s.fillDeficit >= 0 && s.fillDeficit <= s.surplus + 1e-9);
  }
  for (const c of [...sheet.customers, ...sheet.fromStore]) {
    assert.ok(c.lines.length > 0);
    for (const l of c.lines) assert.ok(l.qty > 0, "不印 0 個的行");
  }
  for (const c of sheet.customers) {
    for (const l of c.lines) assert.ok(incomingIds.has(l.sku_id), "這車段（倉庫分袋）只能有這車的商品");
  }
  return { sheet, notInTruckCount: notInTruck.length };
}

// 依商品樣式（toProductView）只是把同一份 sheet 換方向排：
// ① 每塊的客人數量加總 ＝ 該商品「分給客人」；② 分給客人 ＋ 分剩 ＝ 到貨；
// ③ 三種樣式每人每商品數量一致（清單、一客一段都直接印 sheet.customers，所以拿它來比）；
// ④ 「另 n 個由門市現貨拿」＝門市現貨段同一位客人同一商品；⑤ 只有這車的商品、照到貨清單順序；
// ⑥ 塊內客人順序跟另外兩種樣式一樣（照名字）。
function assertProductView(sheet) {
  const blocks = toProductView(sheet);
  assert.deepStrictEqual(
    blocks.map((b) => b.sku.sku_id),
    sheet.skus.filter((s) => s.inTruck).map((s) => s.sku_id),
    "依商品：只有這車的商品、照到貨清單順序",
  );
  const byCustomer = new Map(); // 清單／一客一段：key|sku → 數量
  for (const c of sheet.customers) for (const l of c.lines) byCustomer.set(`${c.key}|${l.sku_id}`, l.qty);
  const byProduct = new Map(); // 依商品：key|sku → 數量
  const storeQty = new Map();
  for (const c of sheet.fromStore) for (const l of c.lines) storeQty.set(`${c.key}|${l.sku_id}`, l.qty);
  const order = new Map(sheet.customers.map((c, i) => [c.key, i]));
  for (const b of blocks) {
    const sum = b.rows.reduce((s, r) => s + r.qty, 0);
    assert.ok(near(sum, b.sku.toCustomers), `sku ${b.sku.sku_id}：塊內加總 ${sum} ≠ 分給客人 ${b.sku.toCustomers}`);
    assert.ok(near(b.sku.toCustomers + b.sku.surplus, b.sku.shipped), `sku ${b.sku.sku_id}：分給客人＋分剩 ≠ 到貨`);
    for (let i = 1; i < b.rows.length; i++) {
      assert.ok(order.get(b.rows[i - 1].key) < order.get(b.rows[i].key), "塊內客人順序要跟另外兩種樣式一樣");
    }
    for (const r of b.rows) {
      assert.ok(r.qty > 0);
      const k = `${r.key}|${b.sku.sku_id}`;
      assert.ok(!byProduct.has(k), "同一位客人同一商品只能一列");
      byProduct.set(k, r.qty);
      assert.equal(r.fromStore, storeQty.get(k) ?? 0, "另由門市現貨拿的量要跟門市現貨段一樣");
    }
  }
  assert.deepStrictEqual(byProduct, byCustomer, "三種樣式每人每商品數量要一樣");
  return blocks;
}

// ---------------- 固定案例的組裝工具 ----------------
let nextItemId = 1;
let nextOrderId = 1;
const it = (sku_id, qty) => ({ item_id: nextItemId++, sku_id, qty, backordered: false });
// 依建立順序給時間（伺服端已照 created_at 排好，這裡照陣列順序）
const ord = (customer, member_id, items, extra = {}) => {
  const id = nextOrderId++;
  return {
    order_id: id,
    order_no: `GRP-TEST-${String(id).padStart(4, "0")}`,
    member_id,
    customer,
    campaign_name: null,
    created_at: new Date(Date.UTC(2026, 9, 1, 0, id)).toISOString(),
    status: "shipping",
    arrived: false,
    items,
    ...extra,
  };
};
const sku = (sku_id, qty, available = 0) => ({
  inc: { sku_id, sku_code: `G${String(sku_id).padStart(5, "0")}-01`, name: `商品${sku_id} / 規格`, qty },
  bud: { sku_id, sku_code: `G${String(sku_id).padStart(5, "0")}-01`, name: `商品${sku_id} / 規格`, available, pool: 0 },
});
const preview = (skus, orders, extraBudget = []) => ({
  store_id: 1,
  store_name: "測試店",
  incoming: skus.map((s) => s.inc),
  budget: [...skus.map((s) => s.bud), ...extraBudget],
  orders,
});
const names = (section) => section.map((c) => c.customer);
const linesOf = (c) => c.lines.map((l) => [l.sku_id, l.qty]);

// ---------------- 固定案例 ----------------

test("到 8 包、10 人訂 → 只列前 8 位（照下單時間），後 2 位不列", () => {
  const orders = Array.from({ length: 10 }, (_, i) =>
    ord(`客${String(i + 1).padStart(2, "0")}`, 100 + i, [it(1, 1)]),
  );
  const d = preview([sku(1, 8)], orders);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  assert.deepStrictEqual(
    new Set(sheet.customers.flatMap((c) => c.order_nos)),
    new Set(orders.slice(0, 8).map((o) => o.order_no)),
  );
  assert.equal(sheet.customers.length, 8);
  assert.equal(sheet.fromStore.length, 0);
  assert.deepStrictEqual(sheet.skus[0], {
    sku_id: 1, sku_code: "G00001-01", name: "商品1 / 規格", inTruck: true,
    shipped: 8, toCustomers: 8, surplus: 0, fromStore: 0, fillDeficit: 0,
  });
});

test("同一會員兩團 → 合成一段，同商品合成一行", () => {
  const a = ord("王小明 123456", 7, [it(1, 1)], { campaign_name: "團A" });
  const other = ord("李大華 654321", 8, [it(2, 1)]);
  const b = ord("王小明 123456", 7, [it(1, 2), it(2, 1)], { campaign_name: "團B" });
  const d = preview([sku(1, 5), sku(2, 5)], [a, other, b]);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  const wang = sheet.customers.find((c) => c.member_id === 7);
  assert.deepStrictEqual(wang.order_nos, [a.order_no, b.order_no]);
  assert.deepStrictEqual(linesOf(wang), [[1, 3], [2, 1]]);
  assert.equal(wang.qty, 4);
  assert.equal(sheet.customers.length, 2);
});

test("多品項只分到部分：裝不下的那一項不印，裝得下的照印", () => {
  const x = ord("甲", 1, [it(1, 1), it(2, 1)]);
  const y = ord("乙", 2, [it(1, 1), it(2, 1)]); // 商品2 只到 1 個，被甲拿走
  const d = preview([sku(1, 2), sku(2, 1)], [x, y]);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  const byName = Object.fromEntries(sheet.customers.map((c) => [c.customer, linesOf(c)]));
  assert.deepStrictEqual(byName["甲"], [[1, 1], [2, 1]]);
  assert.deepStrictEqual(byName["乙"], [[1, 1]]);
});

test("cap 3、訂量 [2,2,1] → 第 1、3 位（第 2 位裝不下就跳過、繼續試後面）", () => {
  const o1 = ord("第一位", 1, [it(1, 2)]);
  const o2 = ord("第二位", 2, [it(1, 2)]);
  const o3 = ord("第三位", 3, [it(1, 1)]);
  const d = preview([sku(1, 3)], [o1, o2, o3]);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  assert.deepStrictEqual(new Set(sheet.customers.map((c) => c.order_nos[0])), new Set([o1.order_no, o3.order_no]));
  assert.equal(sheet.skus[0].surplus, 0);
});

test("available ＋2：超過這車的量列「門市現貨」段，跨界線的那一筆拆兩段", () => {
  const a = ord("A客", 1, [it(1, 3)]);
  const b = ord("B客", 2, [it(1, 3)]); // 累計 6 > 到貨 5 → 這車 2、門市現貨 1
  const c = ord("C客", 3, [it(1, 1)]); // 累計 7 → 全部門市現貨
  const d = preview([sku(1, 5, 2)], [a, b, c]);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  const truck = Object.fromEntries(sheet.customers.map((x) => [x.customer, x.qty]));
  const store = Object.fromEntries(sheet.fromStore.map((x) => [x.customer, x.qty]));
  assert.deepStrictEqual(truck, { A客: 3, B客: 2 });
  assert.deepStrictEqual(store, { B客: 1, C客: 1 });
  assert.deepStrictEqual(
    [sheet.skus[0].toCustomers, sheet.skus[0].fromStore, sheet.skus[0].surplus, sheet.skus[0].fillDeficit],
    [5, 2, 0, 0],
  );
});

test("available −2：分剩的有 2 個會先補門市帳上不足（小註）", () => {
  // 到 10、帳上欠 2 → 可配 8；只有 5 人要 → 分剩 5，其中 2 個先補帳
  const few = Array.from({ length: 5 }, (_, i) => ord(`少${i}`, 200 + i, [it(1, 1)]));
  const d1 = preview([sku(1, 10, -2)], few);
  assertSameAsLegacy(d1);
  const s1 = assertSheetInvariants(d1).sheet.skus[0];
  assert.deepStrictEqual([s1.toCustomers, s1.surplus, s1.fillDeficit], [5, 5, 2]);

  // 到 10、帳上欠 2、9 人要 → 只能勾 8 人；分剩 2 個全部拿去補帳
  const many = Array.from({ length: 9 }, (_, i) => ord(`多${i}`, 300 + i, [it(1, 1)]));
  const d2 = preview([sku(1, 10, -2)], many);
  assertSameAsLegacy(d2);
  const { sheet: sheet2 } = assertSheetInvariants(d2);
  const s2 = sheet2.skus[0];
  assert.deepStrictEqual([s2.toCustomers, s2.surplus, s2.fillDeficit], [8, 2, 2]);
  assert.equal(sheet2.customers.length, 8);
});

test("純補貨（沒有任何客人訂單）：客人段空白，全部是這車分剩的", () => {
  const d = preview([sku(1, 6), sku(2, 4)], []);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  assert.equal(sheet.customers.length, 0);
  assert.equal(sheet.fromStore.length, 0);
  assert.deepStrictEqual(sheet.skus.map((s) => [s.sku_id, s.surplus]), [[1, 6], [2, 4]]);
});

test("不在這車、但視窗預設勾了的商品：整項列在「門市現貨」段，倉庫分袋段不列", () => {
  const a = ord("甲", 1, [it(1, 1), it(9, 2)]);
  const b = ord("乙", 2, [it(9, 4)]); // 門市只有 5 個：甲 2 個之後剩 3，乙要 4 裝不下
  const d = preview([sku(1, 2)], [a, b], [sku(9, 0, 5).bud]);
  assertSameAsLegacy(d);
  const { selected } = legacy.loadPreview(d, false);
  assert.equal(selected.size, 2, "視窗勾甲的兩項（商品9 用門市現貨），乙裝不下");
  const { sheet, notInTruckCount } = assertSheetInvariants(d);
  assert.equal(notInTruckCount, 1);
  assert.deepStrictEqual(names(sheet.customers), ["甲"]);
  assert.deepStrictEqual(linesOf(sheet.customers[0]), [[1, 1]], "倉庫分袋只有這車的商品");
  assert.deepStrictEqual(names(sheet.fromStore), ["甲"]);
  assert.deepStrictEqual(linesOf(sheet.fromStore[0]), [[9, 2]], "商品9 整項由門市現貨拿");
  // 品名、編號取自 budget
  assert.deepStrictEqual(
    [sheet.fromStore[0].lines[0].name, sheet.fromStore[0].lines[0].sku_code],
    ["商品9 / 規格", "G00009-01"],
  );
  assert.deepStrictEqual(
    sheet.skus.map((s) => [s.sku_id, s.inTruck, s.shipped, s.toCustomers, s.fromStore, s.surplus]),
    [
      [1, true, 2, 1, 0, 1],
      [9, false, 0, 0, 2, 0],
    ],
  );
});

test("不在這車的商品連 budget 都查不到：視窗勾不到（可配 0），分貨單也不會憑空列出", () => {
  const a = ord("甲", 1, [it(1, 1), it(8, 1)]);
  const d = preview([sku(1, 2)], [a]); // 商品8 沒有 budget 列 → cap 0
  assertSameAsLegacy(d);
  const { sheet, notInTruckCount } = assertSheetInvariants(d);
  assert.equal(notInTruckCount, 0);
  assert.equal(sheet.fromStore.length, 0);
});

test("member_id 是 null：一張單一段，同名也不合併", () => {
  const a = ord("路人", null, [it(1, 1)]);
  const b = ord("路人", null, [it(1, 1)]);
  const d = preview([sku(1, 2)], [a, b]);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  assert.equal(sheet.customers.length, 2);
  assert.deepStrictEqual(sheet.customers.map((c) => c.order_nos), [[a.order_no], [b.order_no]]);
});

test("數量是字串：一律當數字算", () => {
  const a = ord("A", 1, [{ item_id: nextItemId++, sku_id: 1, qty: "2", backordered: false }]);
  const b = ord("B", 2, [{ item_id: nextItemId++, sku_id: 1, qty: "2", backordered: false }]);
  const d = {
    store_id: 1,
    incoming: [{ sku_id: 1, sku_code: "G00001-01", name: "商品1", qty: "4" }],
    budget: [{ sku_id: 1, sku_code: "G00001-01", name: "商品1", available: "-1", pool: "2" }],
    orders: [a, b],
  };
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  const s = sheet.skus[0];
  assert.equal(typeof s.shipped, "number");
  // 可配 = −1 + 4 = 3 → A(2) 勾、B(2) 裝不下
  assert.deepStrictEqual([s.shipped, s.toCustomers, s.surplus, s.fillDeficit], [4, 2, 2, 1]);
  assert.deepStrictEqual(names(sheet.customers), ["A"]);
});

test("客人依名字排序（zh-TW），不是照下單時間；沒名字印「（無名字）」", () => {
  const list = ["王小明", "Serena 005932", "李四", "陳一", null];
  const orders = list.map((n, i) => ord(n, 400 + i, [it(1, 1)]));
  const d = preview([sku(1, 5)], orders);
  const { sheet } = assertSheetInvariants(d);
  const shown = list.map((n) => n ?? "（無名字）");
  assert.deepStrictEqual(names(sheet.customers), [...shown].sort((a, b) => a.localeCompare(b, "zh-TW")));
  assert.notDeepStrictEqual(names(sheet.customers), shown);
});

test("依商品：每個這車的商品一塊；跨界線的客人註明另由門市現貨拿；全部由門市現貨拿的不列在塊裡", () => {
  const a = ord("A客", 1, [it(1, 3)]);
  const b = ord("B客", 2, [it(1, 3), it(2, 1)]); // 商品1：累計 6 > 到貨 5 → 這車 2、門市現貨 1
  const c = ord("C客", 3, [it(2, 2)]);
  const d0 = ord("D客", 4, [it(1, 1)]); // 商品1 累計 7 → 全部門市現貨
  const e = ord("E客", 5, [it(9, 1)]); // 不在這車的商品
  const d = preview([sku(1, 5, 2), sku(2, 4)], [a, b, c, d0, e], [sku(9, 0, 3).bud]);
  assertSameAsLegacy(d);
  const { sheet } = assertSheetInvariants(d);
  const blocks = assertProductView(sheet);
  assert.deepStrictEqual(
    blocks.map((bl) => [bl.sku.sku_id, bl.rows.map((r) => [r.customer, r.qty, r.fromStore])]),
    [
      [1, [["A客", 3, 0], ["B客", 2, 1]]],
      [2, [["B客", 1, 0], ["C客", 2, 0]]],
    ],
  );
  assert.deepStrictEqual(
    blocks.map((bl) => [bl.sku.shipped, bl.sku.toCustomers, bl.sku.surplus]),
    [
      [5, 5, 0],
      [4, 3, 1],
    ],
  );
});

test("依商品：純補貨也照樣每個商品一塊（塊內沒有客人）", () => {
  const { sheet } = assertSheetInvariants(preview([sku(1, 6), sku(2, 4)], []));
  const blocks = assertProductView(sheet);
  assert.deepStrictEqual(blocks.map((bl) => [bl.sku.sku_id, bl.rows.length, bl.sku.surplus]), [[1, 0, 6], [2, 0, 4]]);
});

test("單頭資料原樣帶出", () => {
  const sheet = sheetOf(preview([sku(1, 1)], []));
  assert.deepStrictEqual(sheet.meta, { tag: "meta" });
});

// ---------------- 固定種子的隨機案例：新舊逐筆對拍 ----------------

// mulberry32：固定種子，每次跑出來的案例都一樣
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomPreview(r) {
  const int = (lo, hi) => lo + Math.floor(r() * (hi - lo + 1));
  const maybeStr = (n) => (r() < 0.3 ? String(n) : n);
  const allSkus = [1, 2, 3, 4, 5, 6];
  const truckSkus = allSkus.filter(() => r() < 0.5);
  if (truckSkus.length === 0) truckSkus.push(int(1, 6));
  const incoming = truckSkus.map((s) => ({ sku_id: s, sku_code: `S${s}`, name: `商品${s}`, qty: maybeStr(int(1, 12)) }));
  const budgetSkus = allSkus.filter((s) => truckSkus.includes(s) || r() < 0.4);
  const budget = budgetSkus.map((s) => {
    const b = { sku_id: s, sku_code: `S${s}`, name: `商品${s}`, available: maybeStr(int(-4, 4)) };
    if (r() < 0.8) b.pool = maybeStr(int(0, 3));
    return b;
  });
  const nameList = ["王小明", "李四", "Serena 005932", "陳一", "路人", null];
  const orders = [];
  const nOrders = int(0, 12);
  for (let i = 0; i < nOrders; i++) {
    const items =
      r() < 0.03
        ? null
        : Array.from({ length: int(1, 3) }, () => {
            const x = { sku_id: allSkus[int(0, 5)], qty: maybeStr(int(1, 4)) };
            if (r() < 0.95) x.item_id = nextItemId++;
            if (r() < 0.5) x.backordered = r() < 0.3;
            return x;
          });
    const o = {
      order_id: nextOrderId++,
      order_no: `R-${i}`,
      member_id: r() < 0.25 ? null : int(1, 6),
      customer: nameList[int(0, 5)],
      campaign_name: r() < 0.5 ? null : "某團",
      created_at: new Date(Date.UTC(2026, 9, 1, 0, i)).toISOString(),
      items,
    };
    if (r() < 0.9) o.status = r() < 0.5 ? "shipping" : "confirmed";
    if (r() < 0.9) o.arrived = r() < 0.3;
    orders.push(o);
  }
  return { store_id: 1, store_name: "測試店", incoming, budget, orders };
}

test("固定種子隨機 2000 例：新版預設勾選跟舊版完全相同，三條固定檢查都成立，依商品樣式數量一致", () => {
  const r = rng(20261013);
  let casesWithNotInTruck = 0;
  let casesWithStoreOverflow = 0;
  for (let n = 0; n < 2000; n++) {
    const d = randomPreview(r);
    assertSameAsLegacy(d);
    // 使用者動過勾選之後的那條路（只修剪裝不下的）也要一樣
    const ids = (d.orders ?? []).flatMap((o) => (o.items ?? []).map((i) => i.item_id)).filter((x) => x != null);
    const cur = new Set(ids.filter(() => r() < 0.5));
    assertSameAsLegacy(d, true, cur);
    // 分貨單的三條固定檢查（客人沒有 item_id 的品項整張略過，跟視窗一樣）
    const { sheet, notInTruckCount } = assertSheetInvariants(d);
    assertProductView(sheet);
    if (notInTruckCount > 0) casesWithNotInTruck += 1;
    if (sheet.skus.some((s) => s.inTruck && s.fromStore > 0)) casesWithStoreOverflow += 1;
  }
  // 確認隨機案例真的涵蓋到「勾到不在這車的商品」與「超過這車量由門市現貨補」兩種情況
  assert.ok(casesWithNotInTruck >= 100, `只有 ${casesWithNotInTruck} 例勾到不在這車的商品`);
  assert.ok(casesWithStoreOverflow >= 100, `只有 ${casesWithStoreOverflow} 例超過這車量`);
});
