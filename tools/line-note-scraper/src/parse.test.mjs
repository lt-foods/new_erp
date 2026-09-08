import { test } from "node:test";
import assert from "node:assert/strict";
import { parseOrderLines, postTitle, normalize, extractMemberNo, parseNoteComment } from "./parse.mjs";

test("extractMemberNo", () => {
  assert.deepEqual(extractMemberNo("123456 A+1"), { hint: "123456", rest: "A+1" });
  assert.deepEqual(extractMemberNo("A+1 M123456"), { hint: "123456", rest: "A+1" });
  assert.deepEqual(extractMemberNo("１２３４５６ +2"), { hint: "123456", rest: "+2" });
  assert.equal(extractMemberNo("0912345678 +1").hint, null);   // 手機 10 碼不算
  assert.equal(extractMemberNo("A1+1").hint, null);
  assert.equal(extractMemberNo("+1").hint, null);
});

test("parseNoteComment", () => {
  const r = parseNoteComment("123456\nA+1\nB+2");
  assert.equal(r.memberNo, "123456");
  assert.deepEqual(r.orders.map((o) => [o.code, o.qty]), [["A", 1], ["B", 2]]);
  const single = parseNoteComment("654321 +3");
  assert.deepEqual(single.orders.map((o) => [o.code, o.qty]), [[null, 3]]);
  assert.deepEqual(parseNoteComment("請問還有嗎"), { memberNo: null, orders: [] });
});

const one = (text) => parseOrderLines(text).map(({ code, qty, cancel }) => ({ code, qty, cancel }));

test("plain +1 variants", () => {
  assert.deepEqual(one("+1"), [{ code: null, qty: 1, cancel: false }]);
  assert.deepEqual(one("＋２"), [{ code: null, qty: 2, cancel: false }]);
  assert.deepEqual(one(" + 3 "), [{ code: null, qty: 3, cancel: false }]);
  assert.deepEqual(one("+2份"), [{ code: null, qty: 2, cancel: false }]);
});

test("code before qty", () => {
  assert.deepEqual(one("A+1"), [{ code: "A", qty: 1, cancel: false }]);
  assert.deepEqual(one("b +2"), [{ code: "B", qty: 2, cancel: false }]);
  assert.deepEqual(one("A1+1"), [{ code: "A1", qty: 1, cancel: false }]);
  assert.deepEqual(one("B-2 +1"), [{ code: "B-2", qty: 1, cancel: false }]);
  assert.deepEqual(one("A x2"), [{ code: "A", qty: 2, cancel: false }]);
  assert.deepEqual(one("A×2"), [{ code: "A", qty: 2, cancel: false }]);
  assert.deepEqual(one("C 3份"), [{ code: "C", qty: 3, cancel: false }]);
});

test("qty before code", () => {
  assert.deepEqual(one("+1 A"), [{ code: "A", qty: 1, cancel: false }]);
  assert.deepEqual(one("+2 b2"), [{ code: "B2", qty: 2, cancel: false }]);
});

test("units without code", () => {
  assert.deepEqual(one("2份"), [{ code: null, qty: 2, cancel: false }]);
  assert.deepEqual(one("3組"), [{ code: null, qty: 3, cancel: false }]);
});

test("multi-line and separators", () => {
  assert.deepEqual(one("A+1\nB+2"), [
    { code: "A", qty: 1, cancel: false },
    { code: "B", qty: 2, cancel: false },
  ]);
  assert.deepEqual(one("A+1, B+2、C+3"), [
    { code: "A", qty: 1, cancel: false },
    { code: "B", qty: 2, cancel: false },
    { code: "C", qty: 3, cancel: false },
  ]);
});

test("cancellations", () => {
  assert.deepEqual(one("-1"), [{ code: null, qty: 1, cancel: true }]);
  assert.deepEqual(one("A-1"), [{ code: "A", qty: 1, cancel: true }]);
  assert.deepEqual(one("取消 A+1"), [{ code: "A", qty: 1, cancel: true }]);
  assert.deepEqual(one("退1"), []);
  assert.deepEqual(one("取消"), [{ code: null, qty: 0, cancel: true }]);
});

test("ignores chatter and ambiguous lines", () => {
  assert.deepEqual(one("請問還有嗎"), []);
  assert.deepEqual(one("2"), []);
  assert.deepEqual(one("A2"), []); // 品號還是 A×2 分不清 → 不猜
  assert.deepEqual(one("好吃+1"), []); // 不是下單
  assert.deepEqual(one(""), []);
  assert.deepEqual(one(null), []);
});

test("code is limited to 8 chars", () => {
  assert.deepEqual(one("ABCDEFGHI+1"), []);
  assert.deepEqual(one("ABCDEFGH+1"), [{ code: "ABCDEFGH", qty: 1, cancel: false }]);
});

test("normalize + title", () => {
  assert.equal(normalize("Ａ＋１"), "Ａ+1");
  assert.equal(postTitle("\n  🍓 草莓開團  \n價格 100"), "🍓 草莓開團");
  assert.equal(postTitle("x".repeat(70)).length, 61);
});
