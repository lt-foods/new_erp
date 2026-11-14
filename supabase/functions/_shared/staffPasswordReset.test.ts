// 用 node:test 寫：`deno test` 與 `node --test`（Node 22.6+ 型別剝除）都跑得動。
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildResetLogRow, checkCaller, checkInput, checkTarget, type AuthUserLike } from "./staffPasswordReset.ts";

const T1 = "tenant-a";
const T2 = "tenant-b";
const FAKE_PW = "fake-pw-123456";

const u = (id: string, role: string, tenant_id: string | null = T1): AuthUserLike =>
  ({ id, app_metadata: { role, tenant_id } });

const owner = u("owner-1", "owner");
const admin = u("admin-1", "admin");
const storeManager = u("sm-1", "store_manager");
const storeStaff = u("ss-1", "store_staff");

test("店長／店員／停用／沒有角色 呼叫一律拒絕", () => {
  for (const c of [storeManager, storeStaff, u("d-1", "disabled"), u("x-1", ""), u("h-1", "hq_manager")]) {
    const r = checkCaller(c);
    assert.equal(r.ok, false);
    assert.equal(!r.ok && r.status, 403);
    // 就算目標是一般員工也不行
    assert.equal(checkTarget(c, storeStaff).ok, false);
  }
});

test("沒有 tenant_id 的 owner 也拒絕", () => {
  assert.equal(checkCaller(u("o-x", "owner", null)).ok, false);
});

test("admin 不可重設 owner；owner 可以", () => {
  const r = checkTarget(admin, owner);
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.status, 403);
  assert.equal(checkTarget(owner, u("owner-2", "owner")).ok, true);
});

test("跨公司一律拒絕（與找不到同訊息）", () => {
  const other = u("sm-other", "store_manager", T2);
  const r1 = checkTarget(owner, other);
  const r2 = checkTarget(owner, null);
  assert.equal(r1.ok, false);
  assert.deepEqual(r1, r2);
  // 目標沒有 tenant_id 也算跨公司
  assert.equal(checkTarget(owner, u("no-t", "store_staff", null)).ok, false);
});

test("密碼少於 6 碼拒絕、缺 user_id 拒絕、錯誤訊息不帶密碼", () => {
  const short = checkInput({ user_id: "sm-1", password: "abc12" });
  assert.equal(short.ok, false);
  assert.equal(!short.ok && short.error.includes("abc12"), false);
  assert.equal(checkInput({ user_id: "sm-1" }).ok, false);
  assert.equal(checkInput({ user_id: "", password: FAKE_PW }).ok, false);
  assert.equal(checkInput({ user_id: "sm-1", password: 123456 }).ok, false);
  assert.equal(checkInput(null).ok, false);
});

test("owner／admin 對同公司一般員工成功", () => {
  const input = checkInput({ user_id: "sm-1", password: FAKE_PW });
  assert.equal(input.ok, true);
  assert.equal(input.ok && input.password, FAKE_PW);
  assert.equal(checkTarget(owner, storeManager).ok, true);
  assert.equal(checkTarget(admin, storeManager).ok, true);
  assert.equal(checkTarget(admin, u("admin-2", "admin")).ok, true);
  // 改自己允許（計畫裁定）
  assert.equal(checkTarget(admin, admin).ok, true);
});

test("重設紀錄：記下誰改了誰、從哪台裝置，tenant 用呼叫者的，不含密碼", () => {
  const h = new Headers({
    "x-forwarded-for": "203.0.113.7, 10.0.0.1",
    "user-agent": "UA-test",
  });
  const row = buildResetLogRow({ ...admin, email: "a@x" }, { ...storeStaff, email: "s@x" }, h);
  assert.deepEqual(row, {
    tenant_id: T1,
    actor_user_id: "admin-1",
    actor_email: "a@x",
    target_user_id: "ss-1",
    target_email: "s@x",
    ip: "203.0.113.7",
    user_agent: "UA-test",
  });
  assert.equal(JSON.stringify(row).includes(FAKE_PW), false);
});

test("重設紀錄：cf-connecting-ip 優先；什麼都沒有就是 null", () => {
  const h = new Headers({ "cf-connecting-ip": "198.51.100.9", "x-forwarded-for": "203.0.113.7" });
  assert.equal(buildResetLogRow(admin, storeStaff, h).ip, "198.51.100.9");
  const none = buildResetLogRow(admin, storeStaff, new Headers());
  assert.equal(none.ip, null);
  assert.equal(none.user_agent, null);
  assert.equal(none.actor_email, null);
});
