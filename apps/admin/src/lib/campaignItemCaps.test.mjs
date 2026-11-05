// 限量團每口味上限的純函式測試：node --test apps/admin/src/lib/campaignItemCaps.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  canEditItemCap,
  capUpsertArgs,
  itemsWithoutCap,
  limitedTotalCapProblem,
  parseCapInput,
  planItemCaps,
  skuLabel,
} from "./campaignItemCaps.ts";

test("parseCapInput：空＝不限；拒收 0、負數、小數、文字", () => {
  assert.deepEqual(parseCapInput(""), { ok: true, value: null });
  assert.deepEqual(parseCapInput("  "), { ok: true, value: null });
  assert.deepEqual(parseCapInput("3"), { ok: true, value: 3 });
  assert.deepEqual(parseCapInput(" 12 "), { ok: true, value: 12 });
  for (const bad of ["0", "00", "-1", "1.5", "1.0", "1e3", "abc", "３", "99999999999999999999"]) {
    assert.deepEqual(parseCapInput(bad), { ok: false }, bad);
  }
});

const skus = [
  { id: 11, label: "草莓" },
  { id: 12, label: "巧克力" },
  { id: 13, label: "花生" },
];

test("planItemCaps：全填送每口味上限", () => {
  assert.deepEqual(planItemCaps(skus, { 11: "3", 12: "5", 13: "1" }), {
    kind: "all",
    itemCaps: [
      { sku_id: 11, cap_qty: 3 },
      { sku_id: 12, cap_qty: 5 },
      { sku_id: 13, cap_qty: 1 },
    ],
  });
});

test("planItemCaps：全空走總量", () => {
  assert.deepEqual(planItemCaps(skus, {}), { kind: "none" });
  assert.deepEqual(planItemCaps(skus, { 11: " ", 12: "" }), { kind: "none" });
});

test("planItemCaps：填一部分要提示還缺哪些", () => {
  assert.deepEqual(planItemCaps(skus, { 11: "3" }), { kind: "partial", missing: ["巧克力", "花生"] });
});

test("planItemCaps：有不合法的數字優先報", () => {
  assert.deepEqual(planItemCaps(skus, { 11: "0", 12: "1.5", 13: "1" }), { kind: "invalid", bad: ["草莓", "巧克力"] });
  assert.deepEqual(planItemCaps(skus, { 11: "-1" }), { kind: "invalid", bad: ["草莓"] });
});

test("skuLabel：規格名優先，沒有就用編號", () => {
  assert.equal(skuLabel("草莓", "T-S"), "草莓");
  assert.equal(skuLabel("  ", "T-S"), "T-S");
  assert.equal(skuLabel(null, "T-S"), "T-S");
});

test("capUpsertArgs：單價、排序、備註帶回最新值，只換上限", () => {
  const latest = { id: 5, campaign_id: 9, sku_id: 11, unit_price: 123, sort_order: 7, notes: "備註" };
  assert.deepEqual(capUpsertArgs(latest, 8), {
    p_id: 5, p_campaign_id: 9, p_sku_id: 11, p_unit_price: 123, p_cap_qty: 8, p_sort_order: 7, p_notes: "備註",
  });
  assert.equal(capUpsertArgs(latest, null).p_cap_qty, null);
  assert.equal(capUpsertArgs({ ...latest, notes: null }, 1).p_notes, null);
});

test("canEditItemCap：限量＋草稿或開團中＋手機團控那組角色", () => {
  const ok = { closeType: "limited", status: "open", isAdminRole: false, role: "hq_manager" };
  assert.equal(canEditItemCap(ok), true);
  assert.equal(canEditItemCap({ ...ok, status: "draft", role: "assistant" }), true);
  assert.equal(canEditItemCap({ ...ok, role: "owner", isAdminRole: true }), true);
  for (const status of ["closed", "ordered", "receiving", "ready", "completed", "cancelled", undefined]) {
    assert.equal(canEditItemCap({ ...ok, status }), false, String(status));
  }
  for (const closeType of ["regular", "fast", "food_train", undefined]) {
    assert.equal(canEditItemCap({ ...ok, closeType }), false, String(closeType));
  }
  for (const role of ["hq_accountant", "store_manager", "store_staff", null]) {
    assert.equal(canEditItemCap({ ...ok, role }), false, String(role));
  }
});

const items = [
  { cap_qty: 3, label: "草莓" },
  { cap_qty: null, label: "新口味" },
  { cap_qty: 0, label: "填0的舊資料" },
];

test("itemsWithoutCap：限量團有口味沒上限且總量空著才紅字", () => {
  const base = { closeType: "limited", items, savedTotalCap: null, formTotalCap: null };
  assert.deepEqual(itemsWithoutCap(base), ["新口味", "填0的舊資料"]);
  assert.deepEqual(itemsWithoutCap({ ...base, savedTotalCap: 9, formTotalCap: 9 }), []);
  assert.deepEqual(itemsWithoutCap({ ...base, closeType: "fast" }), []);
  assert.deepEqual(itemsWithoutCap({ ...base, items: [items[0]] }), []);
  // 總量 0 等於不限
  assert.deepEqual(itemsWithoutCap({ ...base, savedTotalCap: 0, formTotalCap: 0 }), ["新口味", "填0的舊資料"]);
});

test("itemsWithoutCap：表單打了總量但還沒存，紅字不能消失；清空但還沒存，紅字要先出來", () => {
  const base = { closeType: "limited", items };
  assert.equal(itemsWithoutCap({ ...base, savedTotalCap: null, formTotalCap: 9 }).length, 2);
  assert.equal(itemsWithoutCap({ ...base, savedTotalCap: 9, formTotalCap: null }).length, 2);
});

test("limitedTotalCapProblem：限量團總量拒收 0 與小數，留空可以；其他類別不管", () => {
  assert.equal(limitedTotalCapProblem("limited", null), null);
  assert.equal(limitedTotalCapProblem("limited", 9), null);
  assert.ok(limitedTotalCapProblem("limited", 0));
  assert.ok(limitedTotalCapProblem("limited", -1));
  assert.ok(limitedTotalCapProblem("limited", 1.5));
  assert.equal(limitedTotalCapProblem("fast", 0), null);
  assert.equal(limitedTotalCapProblem("regular", 0), null);
});
