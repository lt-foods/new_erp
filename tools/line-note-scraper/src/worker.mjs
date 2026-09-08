#!/usr/bin/env node
// line-notes worker：跟後台（Supabase）之間的橋。
//
// 跑在你自己的電腦／VPS 上，用 service_role 輪詢 line_note_jobs：
//   login       → 產 QR 寫進 line_note_accounts（後台顯示），掃完存 token
//   logout      → 清 token
//   list_homes  → 這個帳號加入的群組／社群清單（後台選社群用）
//   post        → 把團的內容套模板發到記事本
//   read        → 讀貼文底下留言 → 落地 line_note_comments → rpc_line_note_apply_comment 加單
// 另外每分鐘看一次社群設定的 read_times（台北時間），到點就自己排 read。
//
// 環境變數：SUPABASE_URL、SUPABASE_SERVICE_ROLE_KEY（必填）、
//           LINE_DEVICE（預設 ANDROIDSECONDARY）、LINE_STORAGE_DIR（預設 ./storage）、POLL_MS（預設 5000）
//
//   node src/worker.mjs            # 或 npm run worker

import fs from "node:fs";
import path from "node:path";
import { loginWithAuthToken, loginWithQR } from "@evex/linejs";
import { FileStorage } from "@evex/linejs/storage";
import { createNotePost, listComments, listHomes, whoami } from "./line.mjs";
import { parseNoteComment, postTitle } from "./parse.mjs";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("缺 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY（放在 .env 或環境變數）");
  process.exit(1);
}
const DEVICE = process.env.LINE_DEVICE || "ANDROIDSECONDARY";
const STORAGE_DIR = process.env.LINE_STORAGE_DIR || "./storage";
const POLL_MS = Number(process.env.POLL_MS || 5000);
const TZ = "Asia/Taipei";
const VERBOSE = !!process.env.VERBOSE;

fs.mkdirSync(STORAGE_DIR, { recursive: true });

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ── Supabase REST ──────────────────────────────────────────────────────────
async function rest(pathAndQuery, { method = "GET", body, prefer } = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: prefer ?? (method === "GET" ? "" : "return=representation"),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${pathAndQuery} → ${res.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}
const rpc = (name, args) => rest(`rpc/${name}`, { method: "POST", body: args, prefer: "" });
const patch = (table, filter, body) => rest(`${table}?${filter}`, { method: "PATCH", body });

// ── LINE client（每個帳號一個） ─────────────────────────────────────────────
const clients = new Map();
const storageFor = (accountId) => new FileStorage(path.join(STORAGE_DIR, `account-${accountId}.json`));

async function clientFor(account) {
  if (clients.has(account.id)) return clients.get(account.id);
  if (!account.auth_token) throw new Error(`帳號「${account.label}」還沒登入`);
  const client = await loginWithAuthToken(account.auth_token, { device: DEVICE, storage: storageFor(account.id) });
  client.base.on("update:authtoken", (t) => patch("line_note_accounts", `id=eq.${account.id}`, { auth_token: t }).catch(() => {}));
  clients.set(account.id, client);
  return client;
}

async function loadAccount(id) {
  const rows = await rest(`line_note_accounts?id=eq.${id}&select=*`);
  if (!rows?.[0]) throw new Error(`account ${id} not found`);
  return rows[0];
}

// ── 工作 ────────────────────────────────────────────────────────────────────
async function jobLogin(job) {
  const account = await loadAccount(job.account_id);
  clients.delete(account.id);
  const client = await loginWithQR({
    async onReceiveQRUrl(url) {
      let qr_image = null;
      try {
        const QR = await import("qrcode");
        qr_image = await (QR.default ?? QR).toDataURL(url, { width: 320, margin: 1 });
      } catch (e) {
        log("qrcode 產圖失敗（後台會只顯示網址）:", e?.message ?? e);
      }
      await patch("line_note_accounts", `id=eq.${account.id}`, { status: "pending_qr", qr_url: url, qr_image, pin_code: null });
      log(`[login ${account.label}] QR 已送到後台`);
    },
    async onPincodeRequest(pin) {
      await patch("line_note_accounts", `id=eq.${account.id}`, { pin_code: pin });
      log(`[login ${account.label}] PIN ${pin}`);
    },
  }, { device: DEVICE, storage: storageFor(account.id) });
  const me = whoami(client);
  await storageFor(account.id).set(".auth", client.base.authToken);
  await patch("line_note_accounts", `id=eq.${account.id}`, {
    status: "active", auth_token: client.base.authToken, line_mid: me.mid, display_name: me.displayName,
    qr_image: null, qr_url: null, pin_code: null, last_error: null, last_seen_at: new Date().toISOString(),
  });
  client.base.on("update:authtoken", (t) => patch("line_note_accounts", `id=eq.${account.id}`, { auth_token: t }).catch(() => {}));
  clients.set(account.id, client);
  return { mid: me.mid, displayName: me.displayName };
}

async function jobLogout(job) {
  const account = await loadAccount(job.account_id);
  const client = clients.get(account.id);
  if (client) {
    try { await client.base.auth.logoutZ(); } catch (e) { log("logoutZ 失敗（略過）:", e?.message ?? e); }
    clients.delete(account.id);
  }
  try { fs.rmSync(path.join(STORAGE_DIR, `account-${account.id}.json`), { force: true }); } catch { /* ignore */ }
  await patch("line_note_accounts", `id=eq.${account.id}`, {
    status: "logged_out", auth_token: null, qr_image: null, qr_url: null, pin_code: null, last_error: null,
  });
  return { ok: true };
}

async function jobListHomes(job) {
  const account = await loadAccount(job.account_id);
  const client = await clientFor(account);
  const homes = await listHomes(client, VERBOSE);
  return { homes };
}

const DEFAULT_TEMPLATE = `📣 {{name}}
{{description}}

{{items}}

⏰ 收單：{{end_at}}
📝 下單方式：留言「會員編號 6 碼 ＋ 品項代碼＋數量」
　例：123456 A+1 B+2`;

function fmtTaipei(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const p = new Intl.DateTimeFormat("zh-TW", { timeZone: TZ, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(d);
  const g = (t) => p.find((x) => x.type === t)?.value ?? "";
  return `${g("month")}/${g("day")} ${g("hour")}:${g("minute")}`;
}

export function renderTemplate(template, payload) {
  const c = payload.campaign ?? {};
  const items = (payload.items ?? []).map((it) => {
    const price = it.unit_price == null ? "" : ` $${Number(it.unit_price)}`;
    return `${it.code}. ${it.name}${price}`;
  }).join("\n");
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

async function jobPost(job) {
  const payload = await rpc("rpc_line_note_post_payload", { p_post_id: job.post_id });
  if (!payload) throw new Error(`post ${job.post_id} not found`);
  const account = await loadAccount(payload.account_id);
  const client = await clientFor(account);
  const text = renderTemplate(payload.post_template, payload);
  try {
    const post = await createNotePost(client, payload.home_id, { text, verbose: VERBOSE });
    await patch("line_note_posts", `id=eq.${job.post_id}`, {
      status: "posted", line_post_id: post.postId ?? null, text, posted_at: new Date().toISOString(), last_error: null,
    });
    return { postId: post.postId, title: postTitle(text) };
  } catch (e) {
    await patch("line_note_posts", `id=eq.${job.post_id}`, { status: "failed", text, last_error: String(e?.message ?? e).slice(0, 1000) });
    throw e;
  }
}

async function readPost(client, post) {
  const comments = await listComments(client, post.home_id, post.line_post_id, { verbose: VERBOSE });
  if (comments.length) {
    const rows = comments.map((c) => {
      const parsed = parseNoteComment(c.text);
      return {
        tenant_id: post.tenant_id, post_id: post.id, line_comment_id: String(c.commentId ?? ""),
        commenter_id: c.authorMid ?? null, commenter_name: c.authorName ?? null, text: c.text ?? "",
        commented_at: c.createdAt ?? null, member_no_hint: parsed.memberNo, parsed: parsed.orders,
      };
    }).filter((r) => r.line_comment_id);
    // 已經有的留言不動（on_conflict 忽略），所以人工標過「忽略」的不會被洗掉
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
      await patch("line_note_comments", `id=eq.${c.id}`, { status: "error", error: String(e?.message ?? e).slice(0, 1000) }).catch(() => {});
    }
  }
  await patch("line_note_posts", `id=eq.${post.id}`, { last_read_at: new Date().toISOString(), comment_count: comments.length, last_error: null });
  return { comments: comments.length, pending: pending?.length ?? 0, ordered, other };
}

async function jobRead(job) {
  const filter = job.post_id ? `id=eq.${job.post_id}` : `community_id=eq.${job.community_id}`;
  const posts = await rest(`line_note_posts?${filter}&status=eq.posted&select=id,tenant_id,line_post_id,community_id,group_buy_campaigns(status),line_note_communities(home_id,account_id)`);
  const out = [];
  for (const p of posts ?? []) {
    const cst = p.group_buy_campaigns?.status;
    if (cst && !["open", "closed"].includes(cst)) {
      await patch("line_note_posts", `id=eq.${p.id}`, { status: "closed" });
      continue;
    }
    const account = await loadAccount(p.line_note_communities.account_id);
    const client = await clientFor(account);
    try {
      const r = await readPost(client, { ...p, home_id: p.line_note_communities.home_id });
      out.push({ post_id: p.id, ...r });
    } catch (e) {
      await patch("line_note_posts", `id=eq.${p.id}`, { last_error: String(e?.message ?? e).slice(0, 1000) });
      out.push({ post_id: p.id, error: String(e?.message ?? e) });
    }
  }
  if (job.community_id) {
    await patch("line_note_communities", `id=eq.${job.community_id}`, { last_read_at: new Date().toISOString(), last_error: null });
  }
  return { posts: out };
}

const HANDLERS = { login: jobLogin, logout: jobLogout, list_homes: jobListHomes, post: jobPost, read: jobRead };

async function claimNextJob() {
  const rows = await rest(`line_note_jobs?status=eq.queued&select=*&order=created_at.asc&limit=1`);
  const job = rows?.[0];
  if (!job) return null;
  const claimed = await patch("line_note_jobs", `id=eq.${job.id}&status=eq.queued`, { status: "running", started_at: new Date().toISOString() });
  return claimed?.[0] ?? null;
}

async function runJob(job) {
  log(`▶ job#${job.id} ${job.kind} account=${job.account_id} community=${job.community_id ?? "-"} post=${job.post_id ?? "-"}`);
  try {
    const result = await HANDLERS[job.kind](job);
    await patch("line_note_jobs", `id=eq.${job.id}`, { status: "done", result, finished_at: new Date().toISOString() });
    if (job.account_id) await patch("line_note_accounts", `id=eq.${job.account_id}`, { last_seen_at: new Date().toISOString() }).catch(() => {});
    log(`✔ job#${job.id}`, JSON.stringify(result).slice(0, 300));
  } catch (e) {
    const msg = String(e?.message ?? e);
    log(`✖ job#${job.id}`, msg.slice(0, 500));
    await patch("line_note_jobs", `id=eq.${job.id}`, { status: "failed", error: msg.slice(0, 2000), finished_at: new Date().toISOString() });
    if (job.kind === "login") {
      await patch("line_note_accounts", `id=eq.${job.account_id}`, { status: "error", last_error: msg.slice(0, 1000), qr_image: null, qr_url: null, pin_code: null }).catch(() => {});
    } else if (/還沒登入|NotAuthorized|token/i.test(msg) && job.account_id) {
      clients.delete(job.account_id);
      await patch("line_note_accounts", `id=eq.${job.account_id}`, { status: "error", last_error: msg.slice(0, 1000) }).catch(() => {});
    }
  }
}

// ── 排程：到 read_times 就排 read ───────────────────────────────────────────
let lastTick = "";
function nowHHMM() {
  const p = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date());
  const g = (t) => p.find((x) => x.type === t)?.value ?? "00";
  return `${g("hour")}:${g("minute")}`;
}
async function scheduleTick() {
  const hhmm = nowHHMM();
  const key = new Date().toISOString().slice(0, 10) + " " + hhmm;
  if (key === lastTick) return;
  lastTick = key;
  const communities = await rest(`line_note_communities?listen_enabled=eq.true&read_times=cs.{${hhmm}}&select=id,tenant_id,account_id`);
  for (const c of communities ?? []) {
    const dup = await rest(`line_note_jobs?kind=eq.read&community_id=eq.${c.id}&status=in.(queued,running)&select=id&limit=1`);
    if (dup?.length) continue;
    await rest("line_note_jobs", { method: "POST", body: { tenant_id: c.tenant_id, kind: "read", account_id: c.account_id, community_id: c.id }, prefer: "return=minimal" });
    log(`⏰ ${hhmm} 排 read：community#${c.id}`);
  }
}

// ── 主迴圈 ──────────────────────────────────────────────────────────────────
async function main() {
  log(`worker 啟動：${SUPABASE_URL}  device=${DEVICE}  poll=${POLL_MS}ms`);
  // 開機時把上次沒跑完的 running 退回 queued
  await patch("line_note_jobs", "status=eq.running", { status: "queued", started_at: null }).catch(() => {});
  for (;;) {
    try {
      await scheduleTick();
      const job = await claimNextJob();
      if (job) { await runJob(job); continue; }
    } catch (e) {
      log("loop error:", e?.message ?? e);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
