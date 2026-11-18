// LINE 連線：(1) Thrift 不走加密閘道 /enc（LINE 2026-11-18 把它收掉了，一律空的 404）
// (2) 連線瞬斷重試。這裡壞掉的症狀是「分享／推廣文／讀留言整排
// status=404 headers=[["server","legy"]]」，8 個帳號一起掛 —— 用測試釘住。
import { clientFromToken, retryingFetch } from "./lineNote.ts";

const eq = (got: unknown, want: unknown, why: string) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`${why}\n  想要 ${JSON.stringify(want)}\n  拿到 ${JSON.stringify(got)}`);
  }
};

type Step = number | Error;
/** 把 globalThis.fetch 換成照劇本回應的假貨，回傳實際被打的 (host, body) */
async function run(url: string, script: Step[], init: RequestInit = { method: "POST", body: new Uint8Array([1, 2, 3]) }) {
  const calls: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (input: Request) => {
    const body = [...new Uint8Array(await input.arrayBuffer())].join(",");
    calls.push(`${new URL(input.url).hostname}${body ? ` [${body}]` : ""}`);
    const step = script.shift();
    if (step === undefined) throw new Error(`劇本沒寫到第 ${calls.length} 趟`);
    if (step instanceof Error) throw step;
    return new Response(step === 404 ? null : "ok", { status: step });
  }) as typeof fetch;
  try {
    const res = await retryingFetch()(url, init).then((r) => r.status, (e) => `ERR ${e.message}`);
    return { res, calls };
  } finally {
    globalThis.fetch = real;
  }
}
const broken = () => new TypeError("error sending request for url: client error (SendRequest): connection error: stream closed because of a broken pipe");
const HOST = "legy.line-apps.com";
const URL_SQ = `https://${HOST}/SQ1`;

Deno.test("帶 JWT 的登入直接打 legy.line-apps.com/S4，不包成加密信封送 /enc", async () => {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const jwt = `${b64({ alg: "HS256" })}.${b64({ sub: "u0", exp: 1999999999 })}.c2ln`;
  const urls: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((input: Request) => {
    urls.push(input.url);
    return Promise.reject(new Error("測試到這裡就夠了"));
  }) as typeof fetch;
  try {
    await clientFromToken({ accessToken: jwt }).catch(() => null);
  } finally {
    globalThis.fetch = real;
  }
  eq(urls.length > 0, true, "登入至少要打一趟");
  eq(urls.filter((u) => u.includes("/enc") || u.includes("gf.line.naver.jp")), [], "一趟都不能走加密閘道");
  eq(urls[0], `https://${HOST}/S4`, "第一趟就是 getProfile");
});

Deno.test("通的時候只打一趟，body 原封不動", async () => {
  eq(await run(URL_SQ, [200]), { res: 200, calls: [`${HOST} [1,2,3]`] }, "不多打");
});

Deno.test("瞬斷最多打三趟，每一趟 body 都在", async () => {
  const ok = await run(URL_SQ, [broken(), broken(), 200]);
  eq(ok, { res: 200, calls: [`${HOST} [1,2,3]`, `${HOST} [1,2,3]`, `${HOST} [1,2,3]`] }, "斷兩次、第三趟過");
  const dead = await run(URL_SQ, [broken(), broken(), broken()]);
  eq(String(dead.res).startsWith("ERR error sending request"), true, "三趟都斷才把錯誤丟出去");
  eq(dead.calls.length, 3, "不會打第四趟");
});

Deno.test("HTTP 錯誤原樣交回、不重試（GET 沒有 body 也行）", async () => {
  eq(await run(`https://${HOST}/sn/api/v57/post/list.json?x=1`, [404], { method: "GET" }), { res: 404, calls: [HOST] }, "404");
  eq((await run(URL_SQ, [500])).calls.length, 1, "500");
});

Deno.test("逾時／中止、不是網路斷的錯誤都不重試", async () => {
  const abort = new DOMException("The signal has been aborted", "AbortError");
  const timeout = new DOMException("Signal timed out.", "TimeoutError");
  eq((await run(URL_SQ, [abort])).calls.length, 1, "AbortError");
  eq((await run(URL_SQ, [timeout])).calls.length, 1, "TimeoutError");
  eq((await run(URL_SQ, [new TypeError("invalid url")])).calls.length, 1, "其他錯誤");
});
