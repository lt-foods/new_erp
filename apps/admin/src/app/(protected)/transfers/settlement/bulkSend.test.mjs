// 月結一次全選送出：純函式測試
//   node --test "apps/admin/src/app/(protected)/transfers/settlement/bulkSend.test.mjs"
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  BULK_SEND_FIRST_MONTH,
  bulkSendBlockReason,
  bulkSendLoadBlockReason,
  bulkSendMonthBlockReason,
  collectSendResults,
  monthSendIssue,
  nextMonthFirstDay,
  singleSendMonthWarning,
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

test("月份判斷（列表與明細頁共用）：吃 YYYY-MM 與 YYYY-MM-DD 都一樣", () => {
  const oct7 = tpe("2026-10-07T12:00:00");
  assert.equal(monthSendIssue("2026-08", oct7), "before_first");
  assert.equal(monthSendIssue("2026-08-01", oct7), "before_first");
  assert.equal(monthSendIssue("2026-10", oct7), "not_ended");
  assert.equal(monthSendIssue("2026-10-01", oct7), "not_ended");
  assert.equal(monthSendIssue("2026-11-01", oct7), "not_ended");
  assert.equal(monthSendIssue("2026-09", oct7), null);
  assert.equal(monthSendIssue("2026-09-01", oct7), null);
});

test("明細頁單張送出：還沒結束的月份要紅字提醒（只提醒不擋）", () => {
  const w = singleSendMonthWarning("2026-10-01", tpe("2026-10-07T12:00:00"));
  assert.equal(
    w,
    "⚠️ 2026-10 還沒結束（要到 2026-11-01）。現在送出，店家按同意後就鎖住，之後重算會跳過這家，下半月的貨會收不到錢。確定要送嗎？",
  );
  // 台北時間邊界：10/31 23:59:59 還要提醒，11/1 00:00 就不用
  assert.ok(singleSendMonthWarning("2026-10-01", tpe("2026-10-31T23:59:59"))?.includes("2026-10 還沒結束"));
  assert.equal(singleSendMonthWarning("2026-10-01", tpe("2026-11-01T00:00:00")), null);
  // 跨年
  assert.ok(singleSendMonthWarning("2026-12-01", tpe("2026-12-15T09:00:00"))?.includes("要到 2027-01-01"));
  // 未來月份一樣提醒
  assert.ok(singleSendMonthWarning("2026-11-01", tpe("2026-10-07T12:00:00"))?.includes("2026-11 還沒結束"));
});

test("明細頁單張送出：8 月（含）以前提醒原則上不送", () => {
  const after = tpe("2026-10-07T12:00:00");
  for (const m of ["2026-08-01", "2026-07-01", "2025-12-01"]) {
    assert.equal(singleSendMonthWarning(m, after), "⚠️ 8 月（含）以前的月結原則上不送店家核對。確定要送嗎？", m);
  }
});

test("明細頁單張送出：已結束的月份不提醒；沒有月份也不提醒", () => {
  assert.equal(singleSendMonthWarning("2026-09-01", tpe("2026-10-07T12:00:00")), null);
  assert.equal(singleSendMonthWarning("2026-09-01", tpe("2026-10-01T00:00:00")), null);
  assert.ok(singleSendMonthWarning("2026-09-01", tpe("2026-09-30T23:59:59")));
  assert.equal(singleSendMonthWarning(null, tpe("2026-10-07T12:00:00")), null);
  assert.equal(singleSendMonthWarning("", tpe("2026-10-07T12:00:00")), null);
});

test("明細頁提醒與列表擋法用同一套判斷：列表擋的月份，明細頁一定提醒", () => {
  const times = ["2026-09-30T23:59:59", "2026-10-01T00:00:00", "2026-10-31T23:59:59", "2026-11-01T00:00:00"].map(tpe);
  for (const m of ["2026-07", "2026-08", "2026-09", "2026-10", "2026-11"]) {
    for (const t of times) {
      const blocked = bulkSendMonthBlockReason(m, t) !== null;
      const warned = singleSendMonthWarning(`${m}-01`, t) !== null;
      assert.equal(warned, blocked, `${m} @ ${t.toISOString()}`);
    }
  }
});

test("列表沒把月份載完：實際張數 > 已載入張數就擋，不讓全選默默漏掉", () => {
  assert.equal(bulkSendLoadBlockReason(230, 200), "這個月有 230 張、目前只載入 200 張，不能一次全選");
  assert.equal(bulkSendLoadBlockReason(31, 30), "這個月有 31 張、目前只載入 30 張，不能一次全選");
  assert.equal(bulkSendLoadBlockReason(30, 30), null);
  assert.equal(bulkSendLoadBlockReason(0, 0), null);
  // 查不到總張數：寧可擋
  assert.ok(bulkSendLoadBlockReason(null, 30)?.includes("查不到"));
});
