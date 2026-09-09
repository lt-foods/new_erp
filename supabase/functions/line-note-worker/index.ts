// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: line-note-worker
//
// LINE 記事本整合的「worker」，排程版。取代 tools/line-note-scraper/src/worker.mjs
// 那支要一直開著的程序 —— 每個工作都只是幾秒鐘的事，不需要常駐。
//
//   { action: "tick" }                 pg_cron 每分鐘打一次（header x-line-note-secret）
//                                      → 到 read_times 就排 read；撿 line_note_jobs 裡
//                                        queued 的工作跑（logout / list_homes / post / read）
//   { action: "login", account_id }    後台按「登入」直接呼叫（Authorization: 使用者 JWT）
//                                      → 掃 QR，QR 圖 / PIN 寫進 line_note_accounts 給後台顯示，
//                                        掃完把 token 存進 DB，之後 tick 都用那把 token
//   { action: "run" }                  後台按「立即讀取／發文」後順手叫一下，不用等下一分鐘
//
// token 失效（帳號 error）→ 後台再按一次登入就好。
//
// 跟 worker.mjs 的差異：
//   - 沒有檔案 storage，token 只在 DB
//   - 沒有 sharp：圖片只帶原本就是 JPEG 的（PNG / WebP 略過）
//   - 有時間預算：tick 跑到 ~100 秒就停，剩下的下一分鐘再撿（Edge Function 有 wall-clock 上限）
// ─────────────────────────────────────────────────────────────────────────────
// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";
import QRCode from "npm:qrcode@1.5.4";
import { corsHeaders } from "../_shared/cors.ts";
import {
  clientFromToken, createNotePost, listComments, listHomes, listPosts, loginByQr, whoami,
} from "../_shared/lineNote.ts";
import { parseNoteComment, postTitle } from "../_shared/lineNoteParse.ts";

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SERVICE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const CRON_SECRET = Deno.env.get("LINE_NOTE_CRON_SECRET") ?? "";
const VERBOSE = !!Deno.env.get("VERBOSE");
const TZ = "Asia/Taipei";
const TICK_BUDGET_MS = Number(Deno.env.get("LINE_NOTE_TICK_BUDGET_MS") || 100_000);
const LOGIN_DEADLINE_MS = Number(Deno.env.get("LINE_NOTE_LOGIN_DEADLINE_MS") || 110_000);
const MAX_POST_IMAGES = Number(Deno.env.get("LINE_POST_MAX_IMAGES") || 10);
const PRODUCTS_BUCKET = Deno.env.get("PRODUCTS_BUCKET") || "products";

const log = (...a: any[]) => console.log(new Date().toISOString(), ...a);

// ── PostgREST（service_role，跟 worker.mjs 同一套 helper，方便對照） ────────
async function rest(pathAndQuery: string, opts: { method?: string; body?: unknown; prefer?: string } = {}) {
  const method = opts.method ?? "GET";
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: opts.prefer ?? (method === "GET" ? "" : "return=representation"),
    },
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${pathAndQuery} → ${res.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}
const rpc = (name: string, args: unknown) => rest(`rpc/${name}`, { method: "POST", body: args, prefer: "" });
const patch = (table: string, filter: string, body: unknown) => rest(`${table}?${filter}`, { method: "PATCH", body });

// ── LINE client（一次 invocation 內快取；token 在 DB） ─────────────────────
const clients = new Map<number, any>();
async function loadAccount(id: number) {
  const rows = await rest(`line_note_accounts?id=eq.${id}&select=*`);
  if (!rows?.[0]) throw new Error(`account ${id} not found`);
  return rows[0];
}
async function clientFor(account: any) {
  if (clients.has(account.id)) return clients.get(account.id);
  if (!account.auth_token) throw new Error(`帳號「${account.label}」還沒登入`);
  const client = await clientFromToken(account.auth_token);
  client.base.on("update:authtoken", (t: string) =>
    patch("line_note_accounts", `id=eq.${account.id}`, { auth_token: t }).catch(() => {}));
  clients.set(account.id, client);
  return client;
}

// ── 登入（後台按鈕直接呼叫） ────────────────────────────────────────────────
async function doLogin(accountId: number) {
  const account = await loadAccount(accountId);
  await patch("line_note_accounts", `id=eq.${accountId}`, {
    status: "pending_qr", qr_image: null, qr_url: null, pin_code: null, last_error: null,
  });
  const job = (await rest("line_note_jobs", {
    method: "POST",
    body: { tenant_id: account.tenant_id, kind: "login", account_id: accountId, status: "running", started_at: new Date().toISOString() },
  }))?.[0];
  try {
    const client = await loginByQr({
      deadlineMs: LOGIN_DEADLINE_MS,
      async onQr(url) {
        let qr_image: string | null = null;
        try { qr_image = await QRCode.toDataURL(url, { width: 320, margin: 1 }); } catch (e) { log("qrcode 產圖失敗:", (e as any)?.message ?? e); }
        await patch("line_note_accounts", `id=eq.${accountId}`, { status: "pending_qr", qr_url: url, qr_image, pin_code: null });
        log(`[login ${account.label}] QR 已送到後台`);
      },
      async onPin(pin) {
        await patch("line_note_accounts", `id=eq.${accountId}`, { pin_code: pin });
      },
    });
    const me = whoami(client);
    await patch("line_note_accounts", `id=eq.${accountId}`, {
      status: "active", auth_token: client.base.authToken, line_mid: me.mid, display_name: me.displayName,
      qr_image: null, qr_url: null, pin_code: null, last_error: null, last_seen_at: new Date().toISOString(),
    });
    if (job) await patch("line_note_jobs", `id=eq.${job.id}`, { status: "done", result: me, finished_at: new Date().toISOString() });
    return { ok: true, ...me };
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    await patch("line_note_accounts", `id=eq.${accountId}`, { status: "error", last_error: msg.slice(0, 1000), qr_image: null, qr_url: null, pin_code: null });
    if (job) await patch("line_note_jobs", `id=eq.${job.id}`, { status: "failed", error: msg.slice(0, 2000), finished_at: new Date().toISOString() });
    return { ok: false, error: msg };
  }
}

// ── 工作 ────────────────────────────────────────────────────────────────────
async function jobLogout(job: any) {
  const account = await loadAccount(job.account_id);
  const client = clients.get(account.id) ?? (account.auth_token ? await clientFor(account).catch(() => null) : null);
  if (client) { try { await client.base.auth.logoutZ(); } catch { /* token 可能早就失效，略過 */ } }
  clients.delete(account.id);
  await patch("line_note_accounts", `id=eq.${account.id}`, {
    status: "logged_out", auth_token: null, qr_image: null, qr_url: null, pin_code: null, last_error: null,
  });
  return { ok: true };
}

async function jobListHomes(job: any) {
  const account = await loadAccount(job.account_id);
  const client = await clientFor(account);
  return { homes: await listHomes(client, VERBOSE) };
}

const DEFAULT_TEMPLATE = `📣 {{name}}
{{description}}

{{items}}

⏰ 收單：{{end_at}}
📝 下單方式：留言「會員編號 6 碼 ＋ 品項代碼＋數量」
　例：123456 A+1 B+2`;

function fmtTaipei(iso: string | null | undefined) {
  if (!iso) return "";
  const p = new Intl.DateTimeFormat("zh-TW", { timeZone: TZ, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(iso));
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "";
  return `${g("month")}/${g("day")} ${g("hour")}:${g("minute")}`;
}

export function renderTemplate(template: string | null, payload: any) {
  const c = payload.campaign ?? {};
  const items = (payload.items ?? []).map((it: any) => `${it.code}. ${it.name}${it.unit_price == null ? "" : ` $${Number(it.unit_price)}`}`).join("\n");
  return (template || DEFAULT_TEMPLATE)
    .replaceAll("{{name}}", c.name ?? "")
    .replaceAll("{{campaign_no}}", c.campaign_no ?? "")
    .replaceAll("{{description}}", c.description ?? "")
    .replaceAll("{{items}}", items)
    .replaceAll("{{end_at}}", fmtTaipei(c.end_at))
    .replaceAll("{{start_at}}", fmtTaipei(c.start_at))
    .replaceAll("{{pickup_deadline}}", fmtTaipei(c.pickup_deadline))
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function resolveImageUrl(p: unknown): string | null {
  if (!p || typeof p !== "string") return null;
  if (/^https?:\/\//i.test(p)) return p;
  return `${SUPABASE_URL}/storage/v1/object/public/${PRODUCTS_BUCKET}/${p.replace(/^\/+/, "")}`;
}

// 沒有 sharp：只帶原本就是 JPEG 的圖（PNG / WebP 略過並記 log）
async function collectPostImages(payload: any): Promise<Uint8Array[]> {
  if (Deno.env.get("LINE_POST_NO_IMAGE")) return [];
  const urls: string[] = [];
  const push = (u: unknown) => { const r = resolveImageUrl(u); if (r && !urls.includes(r)) urls.push(r); };
  push(payload.campaign?.cover_image_url);
  for (const it of payload.items ?? []) for (const img of it.images ?? []) push(img);
  const out: Uint8Array[] = [];
  for (const url of urls.slice(0, MAX_POST_IMAGES)) {
    try {
      const r = await fetch(url);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const ct = r.headers.get("content-type") ?? "";
      if (!/image\/jpe?g/i.test(ct) && !/\.jpe?g(\?|$)/i.test(url)) { log(`圖片不是 JPEG（${ct}），略過：${url}`); continue; }
      out.push(new Uint8Array(await r.arrayBuffer()));
    } catch (e) {
      log(`圖片略過 ${url}：${(e as any)?.message ?? e}`);
    }
  }
  return out;
}

async function jobPost(job: any) {
  const cur = await rest(`line_note_posts?id=eq.${job.post_id}&select=status,line_post_id`);
  if (cur?.[0]?.status === "posted") return { skipped: "already posted", postId: cur[0].line_post_id };
  const payload = await rpc("rpc_line_note_post_payload", { p_post_id: job.post_id });
  if (!payload) throw new Error(`post ${job.post_id} not found`);
  const account = await loadAccount(payload.account_id);
  const client = await clientFor(account);
  const text = renderTemplate(payload.post_template, payload);
  const images = await collectPostImages(payload);
  try {
    const post = await createNotePost(client, payload.home_id, { text, images, verbose: VERBOSE });
    await patch("line_note_posts", `id=eq.${job.post_id}`, {
      status: "posted", line_post_id: post.postId ?? null, text, posted_at: new Date().toISOString(), last_error: null,
    });
    return { postId: post.postId, title: postTitle(text), images: images.length };
  } catch (e) {
    await patch("line_note_posts", `id=eq.${job.post_id}`, { status: "failed", text, last_error: String((e as any)?.message ?? e).slice(0, 1000) });
    throw e;
  }
}

async function readPost(client: any, post: any) {
  const comments = await listComments(client, post.home_id, post.line_post_id, { verbose: VERBOSE });
  if (comments.length) {
    const rows = comments.map((c: any) => {
      const parsed = parseNoteComment(c.text, c.authorName ?? "");
      return {
        tenant_id: post.tenant_id, post_id: post.id, line_comment_id: String(c.commentId ?? ""),
        commenter_id: c.authorMid ?? null, commenter_name: c.authorName ?? null, text: c.text ?? "",
        commented_at: c.createdAt ?? null, member_no_hint: parsed.memberNo, parsed: parsed.orders,
      };
    }).filter((r: any) => r.line_comment_id);
    await rest(`line_note_comments?on_conflict=post_id,line_comment_id`, {
      method: "POST", body: rows, prefer: "resolution=ignore-duplicates,return=minimal",
    });
  }
  const pending = await rest(`line_note_comments?post_id=eq.${post.id}&status=eq.pending&select=id&order=commented_at.asc,id.asc`);
  let ordered = 0, other = 0;
  for (const c of pending ?? []) {
    try {
      const r = await rpc("rpc_line_note_apply_comment", { p_comment_id: c.id });
      const st = Array.isArray(r) ? r[0]?.out_status : r?.out_status;
      if (st === "ordered") ordered++; else other++;
    } catch (e) {
      other++;
      await patch("line_note_comments", `id=eq.${c.id}`, { status: "error", error: String((e as any)?.message ?? e).slice(0, 1000) }).catch(() => {});
    }
  }
  await patch("line_note_posts", `id=eq.${post.id}`, { last_read_at: new Date().toISOString(), comment_count: comments.length, last_error: null });
  return { comments: comments.length, pending: pending?.length ?? 0, ordered, other };
}

// 認貼文：小幫手手貼的團（內文含開團中／已收單的團名或團號）也綁進來
async function discoverPosts(client: any, community: any) {
  const since = new Date(Date.now() - community.read_days * 86400_000).toISOString();
  const notes = await listPosts(client, community.home_id, { limit: 100, since, verbose: VERBOSE });
  if (notes.length === 0) return 0;
  const known = await rest(`line_note_posts?community_id=eq.${community.id}&select=id,status,line_post_id,campaign_id`);
  const knownByLineId = new Map((known ?? []).filter((p: any) => p.line_post_id).map((p: any) => [p.line_post_id, p]));
  const campaigns = await rest(`group_buy_campaigns?tenant_id=eq.${community.tenant_id}&status=in.(open,closed)&select=id,name,campaign_no&order=id.desc&limit=200`);
  let linked = 0;
  for (const n of notes) {
    if (!n.postId || knownByLineId.has(String(n.postId))) continue;
    const text = String(n.text ?? "");
    const hit = (campaigns ?? []).find((c: any) => (c.name && text.includes(c.name)) || (c.campaign_no && text.includes(c.campaign_no)));
    if (!hit) continue;
    const existing = (known ?? []).find((p: any) => p.campaign_id === hit.id);
    const row = { status: "posted", line_post_id: String(n.postId), text, posted_at: n.createdAt ?? new Date().toISOString(), last_error: null };
    if (existing) {
      if (existing.status === "posted") continue;
      await patch("line_note_posts", `id=eq.${existing.id}`, row);
    } else {
      await rest("line_note_posts", { method: "POST", body: { tenant_id: community.tenant_id, community_id: community.id, campaign_id: hit.id, ...row }, prefer: "return=minimal" });
    }
    linked++;
    log(`🔗 認到貼文 ${n.postId} → 團 ${hit.campaign_no} ${hit.name}`);
  }
  return linked;
}

async function jobRead(job: any) {
  let discovered = 0;
  let sinceFilter = "";
  if (!job.post_id && job.community_id) {
    const c = (await rest(`line_note_communities?id=eq.${job.community_id}&select=id,tenant_id,home_id,account_id,read_days`))?.[0];
    if (c) {
      const client = await clientFor(await loadAccount(c.account_id));
      try { discovered = await discoverPosts(client, c); } catch (e) { log("認貼文失敗（略過）:", (e as any)?.message ?? e); }
      sinceFilter = `&posted_at=gte.${new Date(Date.now() - c.read_days * 86400_000).toISOString()}`;
    }
  }
  const filter = job.post_id ? `id=eq.${job.post_id}` : `community_id=eq.${job.community_id}${sinceFilter}`;
  const posts = await rest(`line_note_posts?${filter}&status=eq.posted&select=id,tenant_id,line_post_id,community_id,group_buy_campaigns(status),line_note_communities(home_id,account_id)`);
  const out: any[] = [];
  for (const p of posts ?? []) {
    const cst = p.group_buy_campaigns?.status;
    if (cst && !["open", "closed"].includes(cst)) { await patch("line_note_posts", `id=eq.${p.id}`, { status: "closed" }); continue; }
    const client = await clientFor(await loadAccount(p.line_note_communities.account_id));
    try {
      out.push({ post_id: p.id, ...(await readPost(client, { ...p, home_id: p.line_note_communities.home_id })) });
    } catch (e) {
      await patch("line_note_posts", `id=eq.${p.id}`, { last_error: String((e as any)?.message ?? e).slice(0, 1000) });
      out.push({ post_id: p.id, error: String((e as any)?.message ?? e) });
    }
  }
  if (job.community_id) await patch("line_note_communities", `id=eq.${job.community_id}`, { last_read_at: new Date().toISOString(), last_error: null });
  return { discovered, posts: out };
}

const HANDLERS: Record<string, (job: any) => Promise<unknown>> = {
  logout: jobLogout, list_homes: jobListHomes, post: jobPost, read: jobRead,
};

async function claimNextJob() {
  // login 不在排程裡跑（要等人掃 QR，會把整個 tick 卡住 110 秒），只走後台按鈕 → action=login
  const rows = await rest(`line_note_jobs?status=eq.queued&kind=neq.login&select=*&order=created_at.asc&limit=1`);
  const job = rows?.[0];
  if (!job) return null;
  const claimed = await patch("line_note_jobs", `id=eq.${job.id}&status=eq.queued`, { status: "running", started_at: new Date().toISOString() });
  return claimed?.[0] ?? null;
}

async function runJob(job: any) {
  log(`▶ job#${job.id} ${job.kind} account=${job.account_id} community=${job.community_id ?? "-"} post=${job.post_id ?? "-"}`);
  try {
    const result = await HANDLERS[job.kind](job);
    await patch("line_note_jobs", `id=eq.${job.id}`, { status: "done", result, finished_at: new Date().toISOString() });
    if (job.account_id) await patch("line_note_accounts", `id=eq.${job.account_id}`, { last_seen_at: new Date().toISOString() }).catch(() => {});
    log(`✔ job#${job.id}`, JSON.stringify(result).slice(0, 300));
    return { id: job.id, kind: job.kind, ok: true };
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    log(`✖ job#${job.id}`, msg.slice(0, 500));
    await patch("line_note_jobs", `id=eq.${job.id}`, { status: "failed", error: msg.slice(0, 2000), finished_at: new Date().toISOString() });
    if (/還沒登入|NotAuthorized|token|401/i.test(msg) && job.account_id) {
      clients.delete(job.account_id);
      await patch("line_note_accounts", `id=eq.${job.account_id}`, { status: "error", last_error: msg.slice(0, 1000) }).catch(() => {});
    }
    return { id: job.id, kind: job.kind, ok: false, error: msg.slice(0, 200) };
  }
}

// ── 排程：到 read_times 就排 read ───────────────────────────────────────────
function nowHHMM() {
  const p = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date());
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "00";
  return `${g("hour")}:${g("minute")}`;
}
async function scheduleReads() {
  const hhmm = nowHHMM();
  const communities = await rest(`line_note_communities?listen_enabled=eq.true&read_times=cs.{${hhmm}}&select=id,tenant_id,account_id,last_read_at`);
  let n = 0;
  for (const c of communities ?? []) {
    // 同一分鐘只排一次：剛讀過（<= 90 秒）或已經有排隊中的就略過
    if (c.last_read_at && Date.now() - new Date(c.last_read_at).getTime() < 90_000) continue;
    const dup = await rest(`line_note_jobs?kind=eq.read&community_id=eq.${c.id}&status=in.(queued,running)&select=id&limit=1`);
    if (dup?.length) continue;
    await rest("line_note_jobs", { method: "POST", body: { tenant_id: c.tenant_id, kind: "read", account_id: c.account_id, community_id: c.id }, prefer: "return=minimal" });
    n++;
    log(`⏰ ${hhmm} 排 read：community#${c.id}`);
  }
  return n;
}

async function tick() {
  const started = Date.now();
  // 上一次沒跑完（Edge Function 被砍）的 running 退回 queued，超過 10 分鐘才算
  await patch("line_note_jobs", `status=eq.running&started_at=lt.${new Date(Date.now() - 600_000).toISOString()}`, { status: "queued", started_at: null }).catch(() => {});
  // 舊路徑排進來的 login（rpc_line_note_enqueue）不跑，直接標失敗請使用者從後台按登入
  await patch("line_note_jobs", "status=eq.queued&kind=eq.login", {
    status: "failed", error: "登入請從後台「帳號 → 登入」按（排程不跑登入）", finished_at: new Date().toISOString(),
  }).catch(() => {});
  const scheduled = await scheduleReads();
  const ran: any[] = [];
  while (Date.now() - started < TICK_BUDGET_MS) {
    const job = await claimNextJob();
    if (!job) break;
    ran.push(await runJob(job));
  }
  return { scheduled, ran, ms: Date.now() - started };
}

// ── HTTP ────────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  let body: any = {};
  try { body = await req.json(); } catch { /* 空 body 當 tick */ }
  const action = String(body.action ?? "tick");

  // 認證：cron 用 secret header；後台用使用者 JWT（要是管理層級）
  const secret = req.headers.get("x-line-note-secret");
  let caller: "cron" | "admin" | null = null;
  if (CRON_SECRET && secret === CRON_SECRET) caller = "cron";
  else {
    const auth = req.headers.get("authorization") ?? "";
    const token = auth.replace(/^Bearer\s+/i, "");
    if (token) {
      const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const { data: { user } } = await sb.auth.getUser(token);
      const role = String(user?.app_metadata?.role ?? "");
      if (user && ["owner", "admin", "hq_manager", "assistant", ""].includes(role)) caller = "admin";
    }
  }
  if (!caller) return json({ error: "unauthorized" }, 401);

  try {
    if (action === "login") {
      if (caller !== "admin") return json({ error: "login 只能從後台按" }, 403);
      const accountId = Number(body.account_id);
      if (!accountId) return json({ error: "account_id required" }, 400);
      return json(await doLogin(accountId));
    }
    if (action === "tick" || action === "run") return json(await tick());
    return json({ error: `unknown action ${action}` }, 400);
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    log("error:", msg);
    return json({ error: msg }, 500);
  }
});

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
