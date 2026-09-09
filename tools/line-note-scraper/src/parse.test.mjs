import { test } from "node:test";
import assert from "node:assert/strict";
import { parseOrderLines, postTitle, normalize, extractMemberNo, parseNoteComment, matchCampaign, normalizeForMatch } from "./parse.mjs";

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
  assert.deepEqual(parseNoteComment("請問還有嗎"), { memberNo: null, memberNoSource: null, orders: [] });
});

test("member no from commenter name", () => {
  assert.equal(parseNoteComment("A+1", "涂003886").memberNo, "003886");
  assert.equal(parseNoteComment("A+1", "Sherry061016/松山").memberNo, "061016");
  assert.equal(parseNoteComment("A+1", "Ting/616582松山").memberNo, "616582");
  assert.equal(parseNoteComment("A+1", "Ting/616582松山").memberNoSource, "name");
  // 內文有 6 碼優先於暱稱
  assert.equal(parseNoteComment("123456 A+1", "Ting/616582松山").memberNo, "123456");
  assert.equal(parseNoteComment("A+1", "小明").memberNo, null);
  assert.equal(parseNoteComment("A+1", "0912345678").memberNo, null);
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

test("multiple items on one line", () => {
  assert.deepEqual(one("A+1 B+5"), [
    { code: "A", qty: 1, cancel: false },
    { code: "B", qty: 5, cancel: false },
  ]);
  assert.deepEqual(one("A+1, B+5"), [
    { code: "A", qty: 1, cancel: false },
    { code: "B", qty: 5, cancel: false },
  ]);
  assert.deepEqual(one("a +1  b +2 c+3"), [
    { code: "A", qty: 1, cancel: false },
    { code: "B", qty: 2, cancel: false },
    { code: "C", qty: 3, cancel: false },
  ]);
  assert.deepEqual(one("+1 A +2 B"), [
    { code: "A", qty: 1, cancel: false },
    { code: "B", qty: 2, cancel: false },
  ]);
  assert.deepEqual(one("A/B+1"), [{ code: "B", qty: 1, cancel: false }]); // 「/」當分隔：A 沒數量
  assert.deepEqual(one("A-1 B+2"), [
    { code: "A", qty: 1, cancel: true },
    { code: "B", qty: 2, cancel: false },
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

// ── 貼文 ↔ 團 的比對（線上抓不到全部貼文那次的實際團名） ────────────────────
const CAMPAIGNS = [
  { id: 1, campaign_no: "GRP-20260909-017", name: "N6090802#抽繩系帶不規則屁簾長裙" },
  { id: 2, campaign_no: "GRP-20260907-010", name: "#B2967 親膚百搭圓領長袖上衣" },
  { id: 3, campaign_no: "GRP-20260906-022", name: "丹波黑豆 300克/包(全素)" },
  { id: 4, campaign_no: "GRP-20260909-014", name: "磁吸迷你拆信刀(顏色隨機)" },
  { id: 5, campaign_no: "GRP-20260909-007", name: "台南白菜胡椒雞", campaign_items: [{ skus: { product_name: "台南白菜胡椒雞900克大份量" } }] },
];
const hit = (text) => matchCampaign(text, CAMPAIGNS)?.id ?? null;

test("normalizeForMatch", () => {
  assert.equal(normalizeForMatch("　全形 空白　Ａ"), "全形空白a");
  assert.equal(normalizeForMatch(null), "");
});

test("matchCampaign", () => {
  assert.equal(hit("N6090802# 抽繩系帶不規則屁簾長裙\n$399"), 1);   // 團名帶代碼、內文多空白
  assert.equal(hit("【#B2967】親膚百搭圓領長袖上衣 $290"), 2);        // # 在前的代碼
  assert.equal(hit("丹波黑豆　300克／包(全素)\n$150"), 3);            // 全形空白／斜線
  assert.equal(hit("磁吸迷你拆信刀(顏色隨機)\n($)(1)(0)(5)"), 4);
  assert.equal(hit("GRP-20260906-022 補貼"), 3);                       // 團號
  assert.equal(hit("台南白菜胡椒雞900克大份量 特價"), 5);              // 只寫商品名
  assert.equal(hit("今天公休喔～"), null);                              // 聊天不該中
  assert.equal(hit(""), null);
  assert.equal(matchCampaign("丹波黑豆", null), null);
});

test("matchCampaign 取最長命中、平手不猜", () => {
  const cs = [
    { id: 10, name: "黑豆" },
    { id: 11, name: "丹波黑豆 300克" },
    { id: 12, name: "丹波黑豆 500克" },
  ];
  assert.equal(matchCampaign("丹波黑豆 300克/包", cs)?.id, 11);        // 比 id:10 長
  assert.equal(matchCampaign("黑豆", cs), null);                        // 2 字太短，刻意不比（會誤中）
  assert.equal(matchCampaign("丹波黑豆 300克 丹波黑豆 500克", cs), null); // 兩個一樣長 → 不猜
});
