// Edge Function 呼叫：登入失效時的重試 / 訊息
//   node --test apps/admin/src/lib/edgeInvoke.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { SESSION_EXPIRED_MSG, invokeEdge, isCallerRejected, readEdgeError } from "./edgeInvoke.ts";

// 仿 supabase-js 的 FunctionsHttpError：message 固定那一句、context 是 Response
function httpError(status, body) {
  return {
    message: "Edge Function returned a non-2xx status code",
    context: new Response(typeof body === "string" ? body : JSON.stringify(body), { status }),
  };
}

function fakeClient(responses, refreshError = null) {
  const calls = { invoke: 0, refresh: 0 };
  return {
    calls,
    functions: {
      invoke: async () => {
        const r = responses[Math.min(calls.invoke, responses.length - 1)];
        calls.invoke++;
        return typeof r === "function" ? r() : r;
      },
    },
    auth: {
      refreshSession: async () => {
        calls.refresh++;
        return { error: refreshError };
      },
    },
  };
}

const rejected = () => ({ data: null, error: httpError(401, { error: "invalid token", detail: "Session not found" }) });

test("成功：原樣回 data，不碰 refresh", async () => {
  const sb = fakeClient([{ data: { ok: true }, error: null }]);
  assert.deepEqual(await invokeEdge(sb, "f", {}, "失敗"), { data: { ok: true }, error: null });
  assert.equal(sb.calls.refresh, 0);
});

test("登入已被清掉：refresh 被拒 → 給看得懂的訊息，不是 invalid token", async () => {
  const sb = fakeClient([rejected], { message: "Invalid Refresh Token: Refresh Token Not Found" });
  const r = await invokeEdge(sb, "staff-reset-password", {}, "重設失敗");
  assert.equal(r.error, SESSION_EXPIRED_MSG);
  assert.equal(sb.calls.invoke, 1);
  assert.equal(sb.calls.refresh, 1);
});

test("憑證只是過期：refresh 成功 → 自動重試一次就過", async () => {
  const sb = fakeClient([rejected, { data: { ok: true }, error: null }]);
  assert.deepEqual(await invokeEdge(sb, "f", {}, "失敗"), { data: { ok: true }, error: null });
  assert.equal(sb.calls.invoke, 2);
  assert.equal(sb.calls.refresh, 1);
});

test("refresh 成功但還是被拒：只重試一次，不會無限迴圈", async () => {
  const sb = fakeClient([rejected]);
  const r = await invokeEdge(sb, "f", {}, "失敗");
  assert.equal(r.error, SESSION_EXPIRED_MSG);
  assert.equal(sb.calls.invoke, 2);
  assert.equal(sb.calls.refresh, 1);
});

test("權限不足 / 輸入有誤：照函式的訊息回，不重試、不叫人重新登入", async () => {
  for (const [status, error] of [
    [403, "admin 不可重設 owner 的密碼"],
    [404, "找不到這位員工"],
    [422, "密碼至少 6 碼"],
  ]) {
    const sb = fakeClient([{ data: null, error: httpError(status, { error }) }]);
    assert.deepEqual(await invokeEdge(sb, "f", {}, "失敗"), { data: null, error });
    assert.equal(sb.calls.invoke, 1);
    assert.equal(sb.calls.refresh, 0);
  }
});

test("連不上函式（沒有 context）：回 supabase-js 的訊息；連 message 都沒有才用 fallback", async () => {
  const net = fakeClient([{ data: null, error: { message: "Failed to send a request to the Edge Function" } }]);
  assert.equal((await invokeEdge(net, "f", {}, "失敗")).error, "Failed to send a request to the Edge Function");
  const bare = fakeClient([{ data: null, error: {} }]);
  assert.equal((await invokeEdge(bare, "f", {}, "失敗")).error, "失敗");
});

test("readEdgeError：body 不是 JSON 時保留原訊息與狀態碼", async () => {
  const r = await readEdgeError(httpError(502, "<html>bad gateway</html>"), "失敗");
  assert.deepEqual(r, { status: 502, message: "Edge Function returned a non-2xx status code" });
});

test("isCallerRejected：只認 401 + 函式自己的兩句", () => {
  assert.equal(isCallerRejected(401, "invalid token"), true);
  assert.equal(isCallerRejected(401, "missing authorization"), true);
  assert.equal(isCallerRejected(403, "invalid token"), false);
  assert.equal(isCallerRejected(401, "something else"), false);
  assert.equal(isCallerRejected(null, "invalid token"), false);
});
