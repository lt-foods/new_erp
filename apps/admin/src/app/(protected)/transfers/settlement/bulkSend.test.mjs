// 月結一次全選送出：純函式測試
//   node --test "apps/admin/src/app/(protected)/transfers/settlement/bulkSend.test.mjs"
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  BULK_SEND_FIRST_MONTH,
  bulkSendBlockReason,
  bulkSendMonthBlockReason,
  collectSendResults,
  nextMonthFirstDay,
  taipeiMonth,
} from "./bulkSend.ts";

// 台北時間寫法 → Date（帶 +08:00，與跑測試的機器時區無關）
const tpe = (s) => new Date(`${s}+08:00`);
const draft = (month) => ({ status: "draft", settlement_month: `${month}-01` });
const AFTER_OCT = tpe("2026-11-05T10:00:00");

test("台北月份：用 UTC+8 算，不看機器時區", () => {
  assert.equal(taipeiMonth(tpe("2026-10-31T23:59:59")), "2026-10");
  assert.equal(taipeiMonth(tpe("2026-11-01T00:00:00")), "2026-11");
  // UTC 10/31 16:00 ＝台北 11/1 00:00
  assert.equal(taipeiMonth(new Date("2026-10-31T16:00:00Z")), "2026-11");
  assert.equal(taipeiMonth(new Date("2026-10-31T15:59:59Z")), "2026-10");
});

test("下個月 1 號：含跨年", () => {
  assert.equal(nextMonthFirstDay("2026-10"), "2026-11-01");
  assert.equal(nextMonthFirstDay("2026-09"), "2026-10-01");
  assert.equal(nextMonthFirstDay("2026-12"), "2027-01-01");
});

test("沒選月份：整列不能勾，提示先選月份", () => {
  assert.equal(bulkSendMonthBlockReason("", AFTER_OCT), "先選月份");
  assert.equal(bulkSendBlockReason(draft("2026-09"), "", AFTER_OCT), "先選月份");
});

test("8 月（含）以前不送", () => {
  assert.equal(BULK_SEND_FIRST_MONTH, "2026-09");
  for (const m of ["2026-08", "2026-07", "2025-12"]) {
    const r = bulkSendBlockReason(draft(m), m, AFTER_OCT);
    assert.ok(r && r.includes("8 月"), `${m} 應該擋：${r}`);
  }
  assert.equal(bulkSendBlockReason(draft("2026-09"), "2026-09", AFTER_OCT), null);
});

test("當月還沒結束：10/31 23:59 台北不能送，11/1 00:00 台北可以送", () => {
  const before = bulkSendBlockReason(draft("2026-10"), "2026-10", tpe("2026-10-31T23:59:59"));
  assert.ok(before && before.includes("2026-11-01"), `10/31 23:59 應該擋：${before}`);
  assert.equal(bulkSendBlockReason(draft("2026-10"), "2026-10", tpe("2026-11-01T00:00:00")), null);
  // 月中
  assert.ok(bulkSendBlockReason(draft("2026-10"), "2026-10", tpe("2026-10-07T12:00:00")));
  // 未來月份（還沒到）也不能送
  assert.ok(bulkSendBlockReason(draft("2026-11"), "2026-11", tpe("2026-10-07T12:00:00")));
});

test("已結束的月份：草稿可以送", () => {
  assert.equal(bulkSendBlockReason(draft("2026-09"), "2026-09", tpe("2026-10-07T12:00:00")), null);
  assert.equal(bulkSendBlockReason(draft("2026-09"), "2026-09", tpe("2026-10-01T00:00:00")), null);
  assert.equal(bulkSendMonthBlockReason("2026-09", tpe("2026-10-01T00:00:00")), null);
  assert.ok(bulkSendMonthBlockReason("2026-09", tpe("2026-09-30T23:59:59")));
});

test("非草稿不能勾：爭議中要到明細頁處理", () => {
  const month = "2026-09";
  const now = tpe("2026-10-07T12:00:00");
  const disputed = bulkSendBlockReason({ status: "disputed", settlement_month: "2026-09-01" }, month, now);
  assert.ok(disputed && disputed.includes("明細頁"), disputed);
  for (const status of ["sent", "confirmed", "remitted", "settled", "cancelled"]) {
    const r = bulkSendBlockReason({ status, settlement_month: "2026-09-01" }, month, now);
    assert.equal(r, "只有草稿能一次送出", status);
  }
});

test("列的月份跟篩選月份不一樣（換月份、列表還沒重載）：不能勾", () => {
  const r = bulkSendBlockReason(draft("2026-09"), "2026-10", AFTER_OCT);
  assert.equal(r, "不是目前篩選的月份");
  assert.equal(
    bulkSendBlockReason({ status: "draft", settlement_month: null }, "2026-09", AFTER_OCT),
    "不是目前篩選的月份",
  );
});

test("送出結果彙總：成功、RPC 回錯、整個丟例外", () => {
  const out = collectSendResults(
    ["甲", "乙", "丙", "丁"],
    [
      { status: "fulfilled", value: { error: null } },
      { status: "fulfilled", value: { error: { message: "狀態 sent 不可送單" } } },
      { status: "rejected", reason: new Error("Failed to fetch") },
      { status: "fulfilled", value: { error: null } },
    ],
  );
  assert.equal(out.ok, 2);
  assert.deepEqual(out.fails, [
    { label: "乙", message: "狀態 sent 不可送單" },
    { label: "丙", message: "Failed to fetch" },
  ]);
  assert.deepEqual(collectSendResults([], []), { ok: 0, fails: [] });
});
