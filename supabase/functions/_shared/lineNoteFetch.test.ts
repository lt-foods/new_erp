// retryingFetch：加密閘道（/enc）固定連 IPv4 主機名＋瞬斷重試。
// 這裡壞掉的症狀是「分享／推廣文／讀留言整排 status=404 headers=[["server","legy"]]」，
// 而且要等 Edge Function 被排到有 IPv6 的機器上才看得出來（2026-11-18）—— 所以用測試釘住。
import { LINE_ENC_HOST, LINE_ENC_V4_HOST, resetEncPinForTest, retryingFetch } from "./lineNote.ts";

const eq = (got: unknown, want: unknown, why: string) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`${why}\n  想要 ${JSON.stringify(want)}\n  拿到 ${JSON.stringify(got)}`);
  }
};

type Step = number | Error;
/** 把 globalThis.fetch 換成照劇本回應的假貨，回傳實際被打的 (host, body) */
async function run(url: string, script: Record<string, Step[]>, init: RequestInit = { method: "POST", body: new Uint8Array([1, 2, 3]) }) {
  const calls: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (input: Request) => {
    const host = new URL(input.url).hostname;
    const body = [...new Uint8Array(await input.arrayBuffer())].join(",");
    calls.push(`${host}${body ? ` [${body}]` : ""}`);
    const step = (script[host] ?? []).shift();
    if (step === undefined) throw new Error(`劇本沒寫到 ${host} 的第 ${calls.length} 趟`);
    if (step instanceof Error) throw step;
    return new Response(step === 404 ? null : "ok", { status: step, headers: step === 404 ? { server: "legy", "x-lcr": "386" } : {} });
  }) as typeof fetch;
  try {
    const res = await retryingFetch()(url, init).then((r) => r.status, (e) => `ERR ${e.message}`);
    return { res, calls };
  } finally {
    globalThis.fetch = real;
  }
}
const broken = () => new TypeError("error sending request for url: client error (SendRequest): connection error: stream closed because of a broken pipe");
const ENC = `https://${LINE_ENC_HOST}/enc`;

Deno.test("/enc 先連只有 IPv4 的那個主機名，body 原封不動", async () => {
  resetEncPinForTest();
  const r = await run(ENC, { [LINE_ENC_V4_HOST]: [200] });
  eq(r, { res: 200, calls: [`${LINE_ENC_V4_HOST} [1,2,3]`] }, "通的時候只打一趟、不碰原主機");
});

Deno.test("IPv4 主機回閘道 404 → 直接換原主機再送一次（同一條連線重打也是 404）", async () => {
  resetEncPinForTest();
  const r = await run(ENC, { [LINE_ENC_V4_HOST]: [404], [LINE_ENC_HOST]: [200] });
  eq(r, { res: 200, calls: [`${LINE_ENC_V4_HOST} [1,2,3]`, `${LINE_ENC_HOST} [1,2,3]`] }, "404 不在同一個主機上重打");
});

Deno.test("兩邊都 404 → 把 404 交回去（由 worker 把工作退回排隊）", async () => {
  resetEncPinForTest();
  const r = await run(ENC, { [LINE_ENC_V4_HOST]: [404], [LINE_ENC_HOST]: [404] });
  eq(r.res, 404, "不吞掉、不無限重試");
  eq(r.calls.length, 2, "各打一趟");
});

Deno.test("IPv4 主機瞬斷：同一個主機重試，三趟都斷才退回原主機", async () => {
  resetEncPinForTest();
  const once = await run(ENC, { [LINE_ENC_V4_HOST]: [broken(), 200] });
  eq(once, { res: 200, calls: [`${LINE_ENC_V4_HOST} [1,2,3]`, `${LINE_ENC_V4_HOST} [1,2,3]`] }, "斷一次：原地重試就過");
  const all = await run(ENC, { [LINE_ENC_V4_HOST]: [broken(), broken(), broken()], [LINE_ENC_HOST]: [200] });
  eq(all.res, 200, "三趟都斷：最後退回原主機");
  eq(all.calls.map((c) => c.split(" ")[0]), [LINE_ENC_V4_HOST, LINE_ENC_V4_HOST, LINE_ENC_V4_HOST, LINE_ENC_HOST], "順序");
});

Deno.test("IPv4 主機連續三次自己不通、原主機卻通 → 這個 isolate 之後直接連原主機", async () => {
  resetEncPinForTest();
  for (let i = 0; i < 3; i++) await run(ENC, { [LINE_ENC_V4_HOST]: [404], [LINE_ENC_HOST]: [200] });
  const r = await run(ENC, { [LINE_ENC_HOST]: [200] });
  eq(r, { res: 200, calls: [`${LINE_ENC_HOST} [1,2,3]`] }, "不再每個請求都先白打一趟");
  resetEncPinForTest();
});

Deno.test("中間只要 IPv4 主機通過一次，計數就歸零", async () => {
  resetEncPinForTest();
  for (let i = 0; i < 2; i++) await run(ENC, { [LINE_ENC_V4_HOST]: [404], [LINE_ENC_HOST]: [200] });
  await run(ENC, { [LINE_ENC_V4_HOST]: [200] });
  for (let i = 0; i < 2; i++) await run(ENC, { [LINE_ENC_V4_HOST]: [404], [LINE_ENC_HOST]: [200] });
  const r = await run(ENC, { [LINE_ENC_V4_HOST]: [200] });
  eq(r.calls, [`${LINE_ENC_V4_HOST} [1,2,3]`], "還是先連 IPv4 主機");
});

Deno.test("其他 LINE 主機不改道：瞬斷最多打三趟，HTTP 錯誤原樣交回", async () => {
  resetEncPinForTest();
  const host = "legy.line-apps.com";
  const ok = await run(`https://${host}/SQ1`, { [host]: [broken(), broken(), 200] });
  eq(ok, { res: 200, calls: [`${host} [1,2,3]`, `${host} [1,2,3]`, `${host} [1,2,3]`] }, "斷兩次、第三趟過");
  const dead = await run(`https://${host}/SQ1`, { [host]: [broken(), broken(), broken()] });
  eq(String(dead.res).startsWith("ERR error sending request"), true, "三趟都斷才把錯誤丟出去");
  const notFound = await run(`https://${host}/sn/api/v57/post/list.json?x=1`, { [host]: [404] }, { method: "GET" });
  eq(notFound, { res: 404, calls: [host] }, "不是 /enc 的 404 不重試、GET 沒有 body 也行");
  const sameHostOtherPath = await run(`https://${LINE_ENC_HOST}/other`, { [LINE_ENC_HOST]: [200] });
  eq(sameHostOtherPath.calls, [`${LINE_ENC_HOST} [1,2,3]`], "只有 /enc 這條路改道");
});

Deno.test("逾時／中止、不是網路斷的錯誤都不重試", async () => {
  resetEncPinForTest();
  const host = "legy.line-apps.com";
  const abort = new DOMException("The signal has been aborted", "AbortError");
  const timeout = new DOMException("Signal timed out.", "TimeoutError");
  eq((await run(`https://${host}/SQ1`, { [host]: [abort] })).calls.length, 1, "AbortError");
  eq((await run(`https://${host}/SQ1`, { [host]: [timeout] })).calls.length, 1, "TimeoutError");
  eq((await run(`https://${host}/SQ1`, { [host]: [new TypeError("invalid url")] })).calls.length, 1, "其他錯誤");
});
