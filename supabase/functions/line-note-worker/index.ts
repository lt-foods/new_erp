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
  clientFromToken, createNotePost, deleteNotePost, likeComment, type LineCredential, listComments, listHomes,
  listPosts, loginByQr, readCredential, whoami,
} from "../_shared/lineNote.ts";
import { extractPostTag, matchCampaign, normalizeForMatch, parseNoteComment, postTitle } from "../_shared/lineNoteParse.ts";
import { renderPostText, TZ } from "../_shared/lineNoteRender.ts";

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SERVICE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const CRON_SECRET = Deno.env.get("LINE_NOTE_CRON_SECRET") ?? "";
const VERBOSE = !!Deno.env.get("VERBOSE");
const TICK_BUDGET_MS = Number(Deno.env.get("LINE_NOTE_TICK_BUDGET_MS") || 100_000);
const LOGIN_DEADLINE_MS = Number(Deno.env.get("LINE_NOTE_LOGIN_DEADLINE_MS") || 110_000);
// 按笑臉的截止時間：從**這一次 invocation 開始**算起（tick 的 started），不是從 isolate 啟動算起。
// 比 TICK_BUDGET_MS 多一點，讓讀完留言之後還有時間把該按的按完。
const REACT_BUDGET_MS = Number(Deno.env.get("LINE_NOTE_REACT_BUDGET_MS") || 120_000);
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
// 憑證換新就寫回 DB。access token 只有 7 天，靠 refresh token（一年）自動換 ——
// **換到的新 refresh token 沒存回去就等於沒換**，下次拿舊的去 refresh 會被 LINE 拒，
// 又要人重新掃 QR（2026-09-20 那次停擺就是整組憑證只存了 access token）。
function credentialFields(c: Partial<LineCredential>): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (c.accessToken) body.auth_token = c.accessToken;
  if (c.refreshToken) body.refresh_token = c.refreshToken;
  if (typeof c.expire === "number") body.token_expire = c.expire;
  return body;
}

/** 對帳一次並且**等它寫完**：Edge Function 隨時可能收工，fire-and-forget 會把新 token 丟掉 */
async function persistCredential(account: any, client: any) {
  const cur = await readCredential(client);
  const body: Record<string, unknown> = {};
  if (cur.accessToken && cur.accessToken !== account.auth_token) body.auth_token = cur.accessToken;
  if (cur.refreshToken && cur.refreshToken !== account.refresh_token) body.refresh_token = cur.refreshToken;
  if (typeof cur.expire === "number" && cur.expire !== account.token_expire) body.token_expire = cur.expire;
  if (Object.keys(body).length === 0) return false;
  await patch("line_note_accounts", `id=eq.${account.id}`, body);
  Object.assign(account, body.auth_token ? { auth_token: body.auth_token } : {},
    body.refresh_token ? { refresh_token: body.refresh_token } : {},
    body.token_expire !== undefined ? { token_expire: body.token_expire } : {});
  log(`🔑 帳號 ${account.id} 的登入憑證已更新（${Object.keys(body).join("/")}）`);
  return true;
}

async function clientFor(account: any) {
  if (clients.has(account.id)) return clients.get(account.id);
  if (!account.auth_token) throw new Error(`帳號「${account.label}」還沒登入`);
  const client = await clientFromToken(
    { accessToken: account.auth_token, refreshToken: account.refresh_token, expire: account.token_expire },
    {
      // 一次 invocation 內再換 token 時用（cold start 那次由下面的 persistCredential 收）
      onCredential: (c) => {
        const body = credentialFields(c);
        if (Object.keys(body).length) patch("line_note_accounts", `id=eq.${account.id}`, body).catch(() => {});
      },
    },
  );
  await persistCredential(account, client);
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
    // ⚠ refresh_token 一定要跟著存。只存 auth_token 的話 7 天後 access token 到期就沒得換，
    //   帳號整組停擺、只能再叫人掃一次 QR（2026-09-20 的 MUST_REFRESH_V3_TOKEN）。
    const cred = await readCredential(client);
    await patch("line_note_accounts", `id=eq.${accountId}`, {
      status: "active", line_mid: me.mid, display_name: me.displayName,
      ...credentialFields({ ...cred, accessToken: cred.accessToken || client.base.authToken }),
      qr_image: null, qr_url: null, pin_code: null, last_error: null, last_seen_at: new Date().toISOString(),
    });
    if (!cred.refreshToken) log(`⚠ 帳號 ${accountId} 登入成功但沒拿到 refresh token，7 天後會需要重新掃 QR`);
    // 登入完馬上把這個帳號的群組／社群拉進來，店家不用再自己按一次同步
    let synced: any = null;
    try { synced = await syncCommunities(accountId, await listHomes(client, VERBOSE)); }
    catch (e) { log("登入後同步社群失敗（略過）:", (e as any)?.message ?? e); }
    if (job) await patch("line_note_jobs", `id=eq.${job.id}`, { status: "done", result: { ...me, sync: synced }, finished_at: new Date().toISOString() });
    return { ok: true, ...me, sync: synced };
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
    status: "logged_out", auth_token: null, refresh_token: null, token_expire: null,
    qr_image: null, qr_url: null, pin_code: null, last_error: null,
  });
  return { ok: true };
}

async function jobListHomes(job: any) {
  const account = await loadAccount(job.account_id);
  const client = await clientFor(account);
  const homes = await listHomes(client, VERBOSE);
  return { homes, sync: await syncCommunities(job.account_id, homes) };
}

// 社群清單跟著帳號走：帳號加入的群組／社群自己出現在後台，不用手動貼 homeId。
// 新長出來的一律是關的（不監聽、不自動發文）—— 備用帳號身上常有私人群組。
// 既有的只更新名字，設定一個字都不動；店家刪掉過的不會再長回來。
async function syncCommunities(accountId: number, homes: any[]) {
  try {
    const r = await rpc("rpc_line_note_community_sync", {
      p_account_id: accountId,
      p_homes: (homes ?? []).map((h: any) => ({ homeId: h.homeId, name: h.name, kind: h.kind })),
    });
    const row = Array.isArray(r) ? r[0] : r;
    log(`社群同步：新增 ${row?.out_added ?? 0}、更新 ${row?.out_updated ?? 0}、略過 ${row?.out_skipped ?? 0}`);
    return row ?? null;
  } catch (e) {
    log("社群同步失敗（略過，不影響列清單）:", (e as any)?.message ?? e);
    return null;
  }
}

function resolveImageUrl(p: unknown): string | null {
  if (!p || typeof p !== "string") return null;
  if (/^https?:\/\//i.test(p)) return p;
  return `${SUPABASE_URL}/storage/v1/object/public/${PRODUCTS_BUCKET}/${p.replace(/^\/+/, "")}`;
}

// 沒有 sharp：只帶原本就是 JPEG 的圖（PNG / WebP 略過並記 log）
// 要附哪些圖：團封面 + 每個品項的商品圖（同一張只算一次 —— 一個商品底下的品項常常共用圖）
function postImageUrls(payload: any): string[] {
  const urls: string[] = [];
  const push = (u: unknown) => { const r = resolveImageUrl(u); if (r && !urls.includes(r)) urls.push(r); };
  push(payload.campaign?.cover_image_url);
  for (const it of payload.items ?? []) for (const img of it.images ?? []) push(img);
  return urls.slice(0, MAX_POST_IMAGES);
}

async function collectPostImages(payload: any): Promise<{ bytes: Uint8Array; type: string }[]> {
  if (Deno.env.get("LINE_POST_NO_IMAGE")) return [];
  const out: { bytes: Uint8Array; type: string }[] = [];
  for (const url of postImageUrls(payload)) {
    try {
      const r = await fetch(url);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      // JPEG 以外也收 PNG（線上商品圖有 496 張 PNG）。GIF / WebP LINE 記事本吃不到，跳過。
      const ct = (r.headers.get("content-type") ?? "").toLowerCase();
      const type = /jpe?g/.test(ct) || /\.jpe?g(\?|$)/i.test(url) ? "image/jpeg"
                 : /png/.test(ct) || /\.png(\?|$)/i.test(url) ? "image/png"
                 : null;
      if (!type) { log(`圖片格式不支援（${ct}），略過：${url}`); continue; }
      out.push({ bytes: new Uint8Array(await r.arrayBuffer()), type });
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
  const text = renderPostText(payload);
  const images = await collectPostImages(payload);
  try {
    const post = await createNotePost(client, payload.home_id, { text, images, verbose: VERBOSE });
    // create.json 的回應撿不到貼文 id 時（線上 9/11 ～ 9/17 發的 38 篇全是這樣），馬上用 list 把
    // 剛發的那篇對回來 —— 沒有 line_post_id 就讀不到留言，客人的 +1 一則都不會變成訂單。
    let postId = post.postId ? String(post.postId) : null;
    let resolved: string | null = null;
    if (!postId) {
      postId = await findPostIdByText(client, payload.home_id, text).catch((e) => { log("補對貼文 id 失敗:", (e as any)?.message ?? e); return null; });
      resolved = postId ? "list" : null;
    }
    await patch("line_note_posts", `id=eq.${job.post_id}`, {
      status: "posted", line_post_id: postId, text, posted_at: new Date().toISOString(),
      // 還是沒有 id：貼文已經在 LINE 上了，先標 posted，錯誤留在畫面上；下次讀取 discoverPosts
      // 會用 🔖 團號把 id 補回來，補到才開始讀留言。
      last_error: postId ? null : "發文成功但沒拿到 LINE 貼文 id；下次讀取會用 🔖 團號自動補認，補到前讀不到留言",
    });
    return {
      postId, title: postTitle(text), images: images.length,
      ...(resolved ? { resolved } : {}),
      // 留一份回應的樣子，下次才對得出 id 到底長在哪一層
      ...(post.postId ? {} : { createRaw: JSON.stringify(post.rawCreate ?? null).slice(0, 600) }),
    };
  } catch (e) {
    await patch("line_note_posts", `id=eq.${job.post_id}`, { status: "failed", text, last_error: String((e as any)?.message ?? e).slice(0, 1000) });
    throw e;
  }
}

// 剛發出去的貼文在 list 裡長什麼樣：先認 🔖 團號章（系統發的一定有），沒章就比整篇內文。
// 只看最近 10 分鐘內建立的，免得對到小幫手先前手貼的同一團。
async function findPostIdByText(client: any, homeId: string, text: string): Promise<string | null> {
  const tag = extractPostTag(text);
  const want = normalizeForMatch(text);
  const posts = await listPosts(client, homeId, { limit: 30, verbose: VERBOSE });
  const cutoff = Date.now() - 10 * 60_000;
  const hit = posts.find((p: any) => {
    if (!p.postId) return false;
    const created = Date.parse(p.createdAt ?? "") || 0;
    if (created && created < cutoff) return false;
    const pt = String(p.text ?? "");
    return tag ? extractPostTag(pt) === tag : normalizeForMatch(pt) === want;
  });
  if (hit) log(`用 list 補對到剛發的貼文 id：${hit.postId}`);
  return hit ? String(hit.postId) : null;
}

// 刪掉 LINE 上那篇貼文，成功才連後台紀錄一起清掉。
//
// 順序不能反：先清紀錄再刪 LINE，萬一 LINE 那邊失敗（帳號掉線最常見），
// 貼文還躺在社群裡收留言，後台卻已經看不到它 —— 那些留言之後會被 discoverPosts
// 當成新貼文重新認一次，變成沒人管的孤兒。
//
// 反過來（LINE 刪掉了、清紀錄失敗）頂多留一列指向不存在貼文的紀錄，
// 使用者再按一次「只清後台紀錄」就好，不會有人撲空。
async function deletePost(postId: number, callerTenant: string | null) {
  const rows = await rest(
    `line_note_posts?id=eq.${postId}` +
    `&select=id,tenant_id,line_post_id,line_note_communities(home_id,account_id)`);
  const post = rows?.[0];
  if (!post) return { ok: false, error: "找不到這篇貼文" };
  // service_role 沒有 RLS，跨 tenant 的檢查只能自己來
  if (callerTenant && post.tenant_id !== callerTenant) return { ok: false, error: "這篇貼文不屬於你的帳戶" };
  if (!post.line_post_id) return { ok: false, error: "這篇沒有發到 LINE（沒有貼文 id），直接清紀錄就好", noLinePost: true };

  try {
    const account = await loadAccount(post.line_note_communities.account_id);
    await deleteNotePost(await clientFor(account), post.line_note_communities.home_id, post.line_post_id, { verbose: VERBOSE });
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    await patch("line_note_posts", `id=eq.${postId}`, { last_error: msg.slice(0, 1000) }).catch(() => {});
    return { ok: false, error: msg };
  }
  await rest(`line_note_jobs?post_id=eq.${postId}&status=in.(queued,running)`, { method: "DELETE", prefer: "return=minimal" }).catch(() => {});
  await rest(`line_note_posts?id=eq.${postId}`, { method: "DELETE", prefer: "return=minimal" });
  log(`🗑 貼文 ${postId}（LINE ${post.line_post_id}）已從記事本刪除，後台紀錄一併清掉`);
  return { ok: true, linePostId: post.line_post_id };
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
  // 解析規則升級後，先前被判成「非下單」（parsed 空）的留言要有機會翻案：
  // upsert 是 ignore-duplicates，舊留言存的 parsed 不會自己更新（例：2026-09-14 前
  // 「加1」「打1」解析不出來）。這裡只動 parsed 還是空的 no_order 列，重解析出東西才退回
  // pending 讓下面那段照常加單；人工標過的 ignored/resolved 不碰。
  const stale = await rest(
    `line_note_comments?post_id=eq.${post.id}&status=eq.no_order` +
    `&select=id,text,commenter_name,parsed`).catch(() => []);
  for (const c of stale ?? []) {
    if (Array.isArray(c.parsed) && c.parsed.length) continue;
    const p = parseNoteComment(c.text ?? "", c.commenter_name ?? "");
    if (!p.orders.length) continue;
    await patch("line_note_comments", `id=eq.${c.id}`, {
      parsed: p.orders, member_no_hint: p.memberNo, status: "pending", error: null, processed_at: null,
    }).catch(() => {});
  }
  // 小幫手宣布結單之後，這篇就不再自動加單、也不再讀（詳見 detectClosing）
  const closer = await detectClosing(post);
  const pendingAll = await rest(
    `line_note_comments?post_id=eq.${post.id}&status=eq.pending` +
    `&select=id,commented_at&order=commented_at.asc,id.asc`);
  // 結單之後才進來的留言不自動加單，留在「待處理」讓小幫手自己判斷要不要補。
  // 宣告本身也不進加單流程（「結單囉 A+1」這種寫法不該被當成訂單）。
  const pending = closer
    ? (pendingAll ?? []).filter((c: any) => Number(c.id) !== Number(closer.id) && beforeOrSame(c, closer))
    : (pendingAll ?? []);
  const late = Math.max((pendingAll?.length ?? 0) - pending.length - (closer ? 1 : 0), 0);
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
  const upd: Record<string, unknown> = {
    last_read_at: new Date().toISOString(), comment_count: comments.length, last_error: null,
  };
  if (closer) {
    upd.status = "closed";
    upd.closed_at = new Date().toISOString();
    upd.closed_reason = String(closer.text ?? "").slice(0, 200);
    upd.closed_comment_id = closer.id;
    // 宣告本身不是訂單，別讓它一直躺在「待處理」
    if (closer.status === "pending") {
      await patch("line_note_comments", `id=eq.${closer.id}`,
        { status: "ignored", resolution_note: "結單宣告，這篇貼文停止自動加單" }).catch(() => {});
    }
    log(`貼文 ${post.id} 讀到結單宣告，停止自動讀取：${String(closer.text ?? "").slice(0, 40)}`);
  }
  await patch("line_note_posts", `id=eq.${post.id}`, upd);
  return { comments: comments.length, pending: pending?.length ?? 0, ordered, other, closed: !!closer, late };
}

// 「結單」判定。誤判的代價是整團安靜地停止爬，所以只認宣告句 ——
// 客人問「什麼時候結單？」「還沒結單嗎」不算。
// 判過的結果寫回 is_closing_notice（NULL=沒判過 / TRUE=是 / FALSE=後台按過恢復讀取），
// 沒有這個三態的話，恢復讀取後下一次讀留言會立刻再撞到同一則、又關掉。
const CLOSE_RE = /結單|收單|截單|關單|關團|封單/;
const CLOSE_ASK_RE = /[?？]|嗎|呢|吧|何時|什麼時候|幾點|還沒|沒有|可以|要不要|是不是|準備|快要/;

function isClosingText(text: string): boolean {
  const t = String(text ?? "").replace(/\s+/g, "");
  return CLOSE_RE.test(t) && !CLOSE_ASK_RE.test(t);
}

function beforeOrSame(a: any, b: any): boolean {
  const ta = Date.parse(a.commented_at ?? "") || 0;
  const tb = Date.parse(b.commented_at ?? "") || 0;
  return ta !== tb ? ta < tb : Number(a.id) <= Number(b.id);
}

async function detectClosing(post: any): Promise<any | null> {
  const rows = await rest(
    `line_note_comments?post_id=eq.${post.id}&is_closing_notice=not.is.false` +
    `&select=id,text,status,commented_at,is_closing_notice&order=commented_at.asc,id.asc`);
  let hit: any = null;
  for (const c of rows ?? []) {
    if (c.is_closing_notice !== true && !isClosingText(c.text)) continue;
    if (c.is_closing_notice !== true) {
      await patch("line_note_comments", `id=eq.${c.id}`, { is_closing_notice: true }).catch(() => {});
    }
    hit = c;
    break;                                                 // 最早那則才算，後面的不用再看
  }
  return hit;
}

const REACT_BATCH = 80;                                  // 一次讀取最多按幾則（一則約 0.3 秒）
const REACT_MAX_MISS = 5;                                // 連續幾則按不動就停手（多半是 LINE 擋次數）

// 收到單的留言回按一個笑臉，讓客人知道「你的 +1 我收到了」。
// 只按 ordered / duplicate / resolved —— unmatched、error 還沒處理完，按了會讓客人以為收到了。
// 按過的記 reacted_at，下次讀留言不會重按。單一則失敗不影響其他則，也不影響讀留言本身。
//
// 兩件事情不能改回去：
//   1. **截止時間由呼叫端帶進來**（那一次 invocation 的預算），不可以寫成模組層級的
//      `const REACT_DEADLINE = Date.now() + 100_000` —— 模組是 isolate 啟動時求值一次，
//      isolate 會被下一分鐘的 tick 重複使用，於是「預算」從讀留言開始的那一刻就已經
//      用掉大半、甚至早就過期（那時整個按表情環節等於默默關掉）。
//   2. **一個社群挑一次、由新到舊**，不要擺在每篇貼文的讀取迴圈裡各挑各的。
//      擺在迴圈裡的話預算一定是在前面幾篇燒光，排在後面（= 最新那幾團）的貼文永遠輪不到：
//      2026-09-20 三峽店就是這樣，9/14 之後 53 則加單成功卻一個笑臉都沒有，最新那篇
//      （post 693、8 張新單）連續 6 天每次都排在隊伍最後，一次都沒按到。
//      由新到舊是因為「剛留言的那個人」才是還在等回應的人。
//
// LINE 對按表情有短時間內的次數上限：2026-09-20 補按積欠的笑臉時，**一輪剛好 30 則**
// 之後全部退 `code=115 無法對此記事本送出回應`，3 分鐘後再跑又能再按 30 則。
// 所以連續退件就停手（剩下的 reacted_at 還是 NULL，下次讀留言自然會接著按），
// 硬打下去只是把時間花在必然失敗的請求上。
async function reactPending(client: any, homeId: string, query: string, reactUntil: number) {
  const rows = await rest(
    `line_note_comments?${query}&reacted_at=is.null&status=in.(ordered,duplicate,resolved)` +
    `&order=commented_at.desc&limit=${REACT_BATCH}`);
  const list: any[] = rows ?? [];
  let reacted = 0, miss = 0;
  for (let i = 0; i < list.length; i++) {
    // 時間到就留給下一次讀留言接手（reacted_at 是 NULL 的還在，不會漏）
    if (Date.now() > reactUntil) { log(`按表情時間到，剩下 ${list.length - i} 則留到下次讀留言`); break; }
    const c = list[i];
    if (!c.line_comment_id) continue;
    try {
      await likeComment(client, homeId, c.line_comment_id, { verbose: VERBOSE });
      await patch("line_note_comments", `id=eq.${c.id}`, { reacted_at: new Date().toISOString() });
      reacted++;
      miss = 0;
    } catch (e) {
      log(`留言 ${c.line_comment_id} 按表情失敗（略過）：${(e as any)?.message ?? e}`);
      if (++miss >= REACT_MAX_MISS) {
        log(`連續 ${miss} 則按不動（多半是 LINE 擋次數），剩下 ${list.length - i - 1} 則留到下次讀留言`);
        break;
      }
    }
  }
  return { reacted, left: list.length - reacted };
}

// 讀一次 LINE 的貼文列表（read_days 內被動過的貼文）。認貼文（discoverPosts）用它，
// 「這篇從上次抓完之後有沒有人再留言」（unchangedSince）也用它 —— 一趟列表、兩件事。
async function listRecentNotes(client: any, community: any) {
  const since = new Date(Date.now() - community.read_days * 86400_000).toISOString();
  // limit 要蓋得住 read_days 內的貼文量：松山一天 ~28 篇、7 天近 200 篇，
  // 100 只看得到最近被留言碰過的那一半，前面的（9/11 ～ 9/14 那 13 篇）永遠補不到 id。
  return await listPosts(client, community.home_id, { limit: 300, since, verbose: VERBOSE });
}

// ── 貼文 ↔ 團 的候選池 ──────────────────────────────────────────────────────
//
// 兩池分開、**先開團中／已收單、認不到才找已結單的**，順序不能倒過來也不能合成一池：
// 同一個商品每隔幾週就重開一團，名字一模一樣 —— 合成一池的話新舊兩團同分（matchCampaign
// 同分就不猜、回 null），本來認得出來的貼文反而變成「未認出團」，留言就沒人讀了。
//
// 為什麼要有第二池：候選原本只有 open/closed，而團一鎖定（= 結單，線上 2,757 團裡
// 絕大多數都在這個狀態）就從候選裡消失 —— 小幫手手貼的貼文只要拖到結單後才被讀到，
// 就永遠卡在「未認出團」，而且後台「指定團」也只列 open/closed，連手動指定都指不了。
// 2026-09-21 三峽 50 則 / 松山 36 則未認出團裡，有 32 則是這種（例：#686「蒜味排骨酥600g/包」
// ↔ GRP-20260910-007 已鎖定）。
//
// 已結單那池**不拿品項商品名當比對鍵**（只用團名 / 團號），而且限「貼文前後那一陣子開的團」：
// 認錯一個還開著的團會把客人的 +1 加到別團上，認錯一個已結單的團只是掛錯名字，
// 但舊團同名的機會比新團高得多，所以這池要比第一池嚴。
const ENDED_STATUSES = "locked,ordered,receiving,ready,completed";
const ENDED_FETCH_DAYS = 45;        // 候選池：最近 45 天開的團
const ENDED_BEFORE_DAYS = 30;       // 每則貼文只比對「貼文前 30 天」開的團
const ENDED_AFTER_DAYS = 7;         // 先貼文、幾天後才在系統開團的也算（實測 -0.1 天很常見）
const RELINK_DAYS = 30;             // 重新認一次庫裡 30 天內的未認出貼文
const RELINK_LIMIT = 200;

async function loadCandidates(tenantId: string) {
  const live = await rest(`group_buy_campaigns?tenant_id=eq.${tenantId}&status=in.(open,closed)` +
    `&select=id,name,campaign_no,status,campaign_items(skus(product_name))&order=id.desc&limit=300`);
  const ended = await rest(`group_buy_campaigns?tenant_id=eq.${tenantId}&status=in.(${ENDED_STATUSES})` +
    `&created_at=gte.${new Date(Date.now() - ENDED_FETCH_DAYS * 86400_000).toISOString()}` +
    `&select=id,name,campaign_no,status,created_at&order=id.desc&limit=2000`);
  return { live: live ?? [], ended: ended ?? [] };
}

/** 已結單那池限「這則貼文前後那一陣子開的團」，免得去中到三個月前的同名舊團 */
function endedNear(ended: any[], postedAt: string | null | undefined) {
  const t = Date.parse(String(postedAt ?? "")) || Date.now();
  return ended.filter((c: any) => {
    const ct = Date.parse(c.created_at ?? "") || 0;
    return ct >= t - ENDED_BEFORE_DAYS * 86400_000 && ct <= t + ENDED_AFTER_DAYS * 86400_000;
  });
}

/** 先開團中／已收單，認不到才找已結單的（順序見上面） */
function matchTwoPass(text: string, postedAt: string | null | undefined, cand: { live: any[]; ended: any[] }) {
  return matchCampaign(text, cand.live) ?? matchCampaign(text, endedNear(cand.ended, postedAt));
}

/** 團已經結單的貼文不用再讀留言（加不了單），直接收成 closed —— 跟 jobRead 的判準同一套 */
const postStatusFor = (campaign: any) => (["open", "closed"].includes(campaign?.status) ? "posted" : "closed");

// 認貼文：小幫手手貼的團也綁進來（比對規則見 matchCampaign）
async function discoverPosts(client: any, community: any, notes: any[]) {
  const cand = await loadCandidates(community.tenant_id);
  if (notes.length === 0) return await relinkStored(community, cand);
  const known = await rest(`line_note_posts?community_id=eq.${community.id}&select=id,status,line_post_id,campaign_id,group_buy_campaigns(campaign_no)`);
  const knownByLineId = new Map((known ?? []).filter((p: any) => p.line_post_id).map((p: any) => [p.line_post_id, p]));
  // 團號 → 後台紀錄（不限團的狀態：已鎖定／已結算的團也要補得到）
  const knownByCampaignNo = new Map(
    (known ?? []).filter((p: any) => p.campaign_id && p.group_buy_campaigns?.campaign_no)
      .map((p: any) => [normalizeForMatch(p.group_buy_campaigns.campaign_no), p]));
  let linked = 0;
  for (const n of notes) {
    if (!n.postId) continue;
    const lineId = String(n.postId);
    const text = String(n.text ?? "");
    const seen = knownByLineId.get(lineId);

    // 系統自己發的文（文末有 🔖 團號章）但發文當下沒拿到貼文 id → 用章把 id 補回紀錄上。
    // 舊行為：那一團已有 status=posted 的紀錄就 continue，永遠補不到；紀錄一直沒有
    // line_post_id，留言就一直讀不到（2026-09-15 松山早上那批 24 篇、12 則 +1 全漏）。
    // 團不在候選池裡（超出「已結單」那池的時間窗）會被認成 unlinked 再存一筆重複的，
    // 這裡順手把那筆重複的清掉。
    const tag = extractPostTag(text);
    const orig = tag ? knownByCampaignNo.get(normalizeForMatch(tag)) : null;
    if (orig && !orig.line_post_id && ["posted", "closed", "failed"].includes(orig.status) && (!seen || seen.id !== orig.id)) {
      const upd: Record<string, unknown> = { line_post_id: lineId, last_error: null };
      if (n.createdAt) upd.posted_at = n.createdAt;
      if (orig.status === "failed") upd.status = "posted";        // 後台記失敗，LINE 上其實有
      await patch("line_note_posts", `id=eq.${orig.id}`, upd);
      orig.line_post_id = lineId;
      knownByLineId.set(lineId, orig);
      if (seen && seen.status === "unlinked") {
        await rest(`line_note_posts?id=eq.${seen.id}&status=eq.unlinked`, { method: "DELETE", prefer: "return=minimal" })
          .catch((e) => log(`清重複的未認出紀錄 ${seen.id} 失敗（略過）：${(e as any)?.message ?? e}`));
      }
      linked++;
      log(`🔗 補上貼文 id ${lineId} → 紀錄 ${orig.id}（團號 ${tag}）`);
      continue;
    }

    const hit = matchTwoPass(text, n.createdAt, cand);
    if (seen) {
      // 已經認過的不用再看；還沒認出團的每次都再試一次（團可能後來才改名／才開）
      if (seen.campaign_id || !hit) continue;
      // 那一團已經有別的貼文了 → 這則是重複的，維持 unlinked 讓人自己處理
      if ((known ?? []).some((p: any) => p.campaign_id === hit.id)) continue;
      await patch("line_note_posts", `id=eq.${seen.id}`, { campaign_id: hit.id, status: postStatusFor(hit) });
      seen.campaign_id = hit.id;
      linked++;
      log(`🔗 補認到貼文 ${n.postId} → 團 ${hit.campaign_no} ${hit.name}（${hit.status}）`);
      continue;
    }

    // 認不出來也要留一筆：舊行為是只印一行 log 就跳過，後台完全看不到這則存在，
    // 店家只會發現「留言沒變成訂單」卻查不出為什麼（松山「雲林小農🍀阿土伯」那則，7 則留言）。
    if (!hit) {
      log(`認不出貼文 ${n.postId}：${postTitle(text)}`);
      await rest("line_note_posts", {
        method: "POST", prefer: "return=minimal",
        body: {
          tenant_id: community.tenant_id, community_id: community.id, campaign_id: null,
          status: "unlinked", line_post_id: String(n.postId), text,
          posted_at: n.createdAt ?? new Date().toISOString(),
        },
      }).catch((e) => log(`存未認出貼文失敗（略過）：${(e as any)?.message ?? e}`));
      continue;
    }
    const existing = (known ?? []).find((p: any) => p.campaign_id === hit.id);
    const row = { status: postStatusFor(hit), line_post_id: String(n.postId), text, posted_at: n.createdAt ?? new Date().toISOString(), last_error: null };
    if (existing) {
      if (existing.status === "posted") continue;
      await patch("line_note_posts", `id=eq.${existing.id}`, row);
    } else {
      await rest("line_note_posts", { method: "POST", body: { tenant_id: community.tenant_id, community_id: community.id, campaign_id: hit.id, ...row }, prefer: "return=minimal" });
    }
    linked++;
    log(`🔗 認到貼文 ${n.postId} → 團 ${hit.campaign_no} ${hit.name}（${hit.status}）`);
  }
  return linked + await relinkStored(community, cand);
}

// 庫裡的「未認出團」貼文重認一次。
//
// 上面那一輪只看得到 LINE 列表回來的貼文，而列表只回 read_days（預設 7 天）內被動過的
// —— 所以**貼文只要放過 7 天沒人留言，就再也沒有任何路徑會重試比對**，永遠留在
// 「未認出團」那一格。2026-09-21 三峽 / 松山那 86 則裡最舊的是 9/4，早就掉出視窗了。
// 這一步不打 LINE，只拿庫裡存的內文重跑一次比對，順便把上面新加的「已結單」那池補上。
async function relinkStored(community: any, cand: { live: any[]; ended: any[] }) {
  const rows = await rest(`line_note_posts?community_id=eq.${community.id}&status=eq.unlinked&campaign_id=is.null` +
    `&posted_at=gte.${new Date(Date.now() - RELINK_DAYS * 86400_000).toISOString()}` +
    `&select=id,text,posted_at&order=id.desc&limit=${RELINK_LIMIT}`);
  if (!rows?.length) return 0;
  // 同一個社群同一團只能有一則貼文（UNIQUE (community_id, campaign_id)）—— 撞到的留著不動，
  // 讓人自己去看是不是重複貼了
  const taken = new Set<number>(
    ((await rest(`line_note_posts?community_id=eq.${community.id}&campaign_id=not.is.null&select=campaign_id`)) ?? [])
      .map((p: any) => p.campaign_id));
  let linked = 0;
  for (const p of rows) {
    const hit = matchTwoPass(String(p.text ?? ""), p.posted_at, cand);
    if (!hit || taken.has(hit.id)) continue;
    await patch("line_note_posts", `id=eq.${p.id}`, { campaign_id: hit.id, status: postStatusFor(hit) });
    taken.add(hit.id);
    linked++;
    log(`🔗 重認舊貼文 ${p.id} → 團 ${hit.campaign_no} ${hit.name}（${hit.status}）`);
  }
  return linked;
}

// 「這篇貼文從上次抓完留言之後，還有沒有人動過」。
//
// LINE 的貼文列表本來就是依 updatedTime 排序 —— 舊貼文一有新留言就跳到最前面，listPosts 的翻頁
// 靠的就是它（見 lineNote.ts）。所以「updatedTime 早於我們上次抓留言的時間」＝ 那次之後沒人留過言，
// 這篇可以不用再向 LINE 抓一次（三峽一輪 96 篇、約 36 秒，通常三分之二的貼文都沒動過）。
// 不能只比留言數：「刪一則、又新增一則」留言數不變，但新增那則會把 updatedTime 推前，照樣抓得到。
// 留言數還是一起比（多一道保險：就算哪天 updatedTime 的行為變了，多一則少一則也擋得住）。
// 留 10 分鐘餘裕給 LINE 與 DB 之間的時鐘差、以及「抓完留言」到「寫 last_read_at」之間的空檔。
const UNCHANGED_MARGIN_MS = 10 * 60_000;
function unchangedSince(note: any, post: any): boolean {
  const touchedAt = Date.parse(note?.updatedAt ?? "") || 0;
  const readAt = Date.parse(post?.last_read_at ?? "") || 0;
  if (!touchedAt || !readAt) return false;
  return touchedAt < readAt - UNCHANGED_MARGIN_MS && Number(note.commentCount) === Number(post.comment_count);
}
function taipeiDate(d: string | Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(d));
}

async function jobRead(job: any, reactUntil = Date.now() + REACT_BUDGET_MS) {
  let discovered = 0;
  let sinceFilter = "";
  let community: any = null;
  const touched = new Map<string, any>();                    // line_post_id → 列表上的那篇（updatedAt / commentCount）
  if (!job.post_id && job.community_id) {
    const c = (await rest(`line_note_communities?id=eq.${job.community_id}&select=id,tenant_id,home_id,account_id,read_days,react_on_confirm,last_read_at`))?.[0];
    community = c ?? null;
    if (c) {
      const client = await clientFor(await loadAccount(c.account_id));
      try {
        const notes = await listRecentNotes(client, c);
        for (const n of notes) if (n.postId) touched.set(String(n.postId), n);
        discovered = await discoverPosts(client, c, notes);
      } catch (e) { log("認貼文失敗（略過）:", (e as any)?.message ?? e); }
      sinceFilter = `&posted_at=gte.${new Date(Date.now() - c.read_days * 86400_000).toISOString()}`;
    }
  }
  // 沒動過的貼文不重抓，但三種情況照舊全抓：
  //   - 單篇讀取／後台手動按的（created_by 有值）：人按的就是要它現在真的去看一次
  //   - 每天第一輪（上一輪是不同的台北日期）：全抓一次當保險，萬一列表的 updatedTime 哪次沒跟上，最多延遲一天
  const fullRead = !!job.post_id || !!job.created_by || !community?.last_read_at ||
    taipeiDate(community.last_read_at) !== taipeiDate(new Date());
  const filter = job.post_id ? `id=eq.${job.post_id}` : `community_id=eq.${job.community_id}${sinceFilter}`;
  const posts = await rest(`line_note_posts?${filter}&status=eq.posted&select=id,tenant_id,line_post_id,community_id,last_read_at,comment_count,group_buy_campaigns(status),line_note_communities(id,home_id,account_id,react_on_confirm,read_days)&order=id.asc`);
  const out: any[] = [];
  let skipped = 0;
  for (const p of posts ?? []) {
    const cst = p.group_buy_campaigns?.status;
    if (cst && !["open", "closed"].includes(cst)) { await patch("line_note_posts", `id=eq.${p.id}`, { status: "closed" }); continue; }
    // 沒有貼文 id 讀不到留言：contentId 空的 getList 路由快取熱的時候回空陣列（看起來像 0 則留言）、
    // 冷的時候整組報「全部打不通」—— 兩種都是假象。標清楚原因，等 discoverPosts 補到 id 再讀。
    if (!p.line_post_id) {
      await patch("line_note_posts", `id=eq.${p.id}`, {
        last_error: "還沒對到 LINE 上的貼文 id（發文時沒拿到）；讀取時會用 🔖 團號自動補認，補到才讀得到留言",
      }).catch(() => {});
      out.push({ post_id: p.id, skipped: "no_line_post_id" });
      continue;
    }
    if (!fullRead && unchangedSince(touched.get(String(p.line_post_id)), p)) {
      skipped++;
      out.push({ post_id: p.id, skipped: "unchanged" });
      continue;
    }
    const client = await clientFor(await loadAccount(p.line_note_communities.account_id));
    try {
      out.push({ post_id: p.id, ...(await readPost(client, { ...p, home_id: p.line_note_communities.home_id })) });
    } catch (e) {
      await patch("line_note_posts", `id=eq.${p.id}`, { last_error: String((e as any)?.message ?? e).slice(0, 1000) });
      out.push({ post_id: p.id, error: String((e as any)?.message ?? e) });
    }
  }
  if (job.community_id) await patch("line_note_communities", `id=eq.${job.community_id}`, { last_read_at: new Date().toISOString(), last_error: null });
  // 讀完才按笑臉：整個社群一次挑（含已結單的貼文 —— 那些不會再被讀，留在迴圈裡就永遠按不到），
  // 母體限定跟讀取同一個時間窗，免得翻出兩星期前的舊留言忽然冒出表情。
  let react = { reacted: 0, left: 0 };
  try {
    const c0 = community ?? posts?.[0]?.line_note_communities;
    if (c0?.home_id && c0.react_on_confirm !== false) {
      const scope = job.post_id
        ? `select=id,line_comment_id&post_id=eq.${job.post_id}`
        : `select=id,line_comment_id,line_note_posts!line_note_comments_post_id_fkey!inner(community_id)` +
          `&line_note_posts.community_id=eq.${job.community_id}` +
          `&or=(commented_at.gte.${new Date(Date.now() - (c0.read_days ?? 7) * 86400_000).toISOString()},commented_at.is.null)`;
      const client = await clientFor(await loadAccount(c0.account_id));
      react = await reactPending(client, c0.home_id, scope, reactUntil);
    }
  } catch (e) {
    log("按表情整批失敗（略過，不影響讀留言）:", (e as any)?.message ?? e);
  }
  if (skipped) log(`${posts.length} 篇裡 ${skipped} 篇從上次抓完之後沒人動過，這輪沒重抓`);
  return { discovered, full_read: fullRead, skipped, ...react, posts: out };
}

const HANDLERS: Record<string, (job: any, reactUntil: number) => Promise<unknown>> = {
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

async function runJob(job: any, reactUntil: number) {
  log(`▶ job#${job.id} ${job.kind} account=${job.account_id} community=${job.community_id ?? "-"} post=${job.post_id ?? "-"}`);
  try {
    const result = await HANDLERS[job.kind](job, reactUntil);
    await patch("line_note_jobs", `id=eq.${job.id}`, { status: "done", result, finished_at: new Date().toISOString() });
    // 跑得起來就代表帳號是通的：之前被標 error 的（多半是 token 到期，現在會自動換）要自己回到
    // active，否則後台一直寫「錯誤」、「登出」鈕也不見，只有重新掃 QR 才清得掉。
    if (job.account_id) {
      await patch("line_note_accounts", `id=eq.${job.account_id}&status=eq.error`, { status: "active", last_error: null }).catch(() => {});
      await patch("line_note_accounts", `id=eq.${job.account_id}`, { last_seen_at: new Date().toISOString() }).catch(() => {});
    }
    log(`✔ job#${job.id}`, JSON.stringify(result).slice(0, 300));
    return { id: job.id, kind: job.kind, ok: true };
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    log(`✖ job#${job.id}`, msg.slice(0, 500));
    await patch("line_note_jobs", `id=eq.${job.id}`, { status: "failed", error: msg.slice(0, 2000), finished_at: new Date().toISOString() });
    if (/還沒登入|NotAuthorized|token|401/i.test(msg) && job.account_id) {
      clients.delete(job.account_id);
      await patch("line_note_accounts", `id=eq.${job.account_id}`, { status: "error", last_error: loginErrorHint(msg).slice(0, 1000) }).catch(() => {});
    }
    return { id: job.id, kind: job.kind, ok: false, error: msg.slice(0, 200) };
  }
}

// linejs 丟出來的原句（`Request internal failed, getProfile(/S4) -> {"code":…}`）
// 後台看了也不知道要做什麼，補一句該做的事。MUST_REFRESH_V3_TOKEN 走到這裡＝
// 連 refresh token 都換不動了（沒存到、或已經被 LINE 作廢），只能重新掃 QR。
function loginErrorHint(msg: string): string {
  if (/MUST_REFRESH_V3_TOKEN/i.test(msg)) {
    return `LINE 登入已過期，請到「LINE 記事本 → 帳號 → 登入」用小幫手手機重新掃一次 QR。\n原始訊息：${msg}`;
  }
  return msg;
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
    ran.push(await runJob(job, started + REACT_BUDGET_MS));
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
  let callerTenant: string | null = null;
  if (CRON_SECRET && secret === CRON_SECRET) caller = "cron";
  else {
    const auth = req.headers.get("authorization") ?? "";
    const token = auth.replace(/^Bearer\s+/i, "");
    if (token) {
      const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const { data: { user } } = await sb.auth.getUser(token);
      const role = String(user?.app_metadata?.role ?? "");
      if (user && ["owner", "admin", "hq_manager", "assistant", ""].includes(role)) {
        caller = "admin";
        // 這支函式一律用 service_role 打 DB（RLS 擋不到），所以會動到資料的 action
        // 要自己拿這個 tenant 去比對，不能只信前端傳來的 id
        callerTenant = String(user.app_metadata?.tenant_id ?? "") || null;
      }
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
    // 發文預覽：發出去才發現版型不對就來不及了（貼文是發給整個社群看的）
    if (action === "preview") {
      if (caller !== "admin") return json({ error: "preview 只能從後台按" }, 403);
      const payload = await rpc("rpc_line_note_preview_payload", {
        p_community_id: Number(body.community_id), p_campaign_id: Number(body.campaign_id),
      });
      if (!payload) return json({ error: "找不到社群或團" }, 404);
      return json({ text: renderPostText(payload), images: postImageUrls(payload) });
    }
    // 刪掉已經貼出去的貼文：LINE 上那篇先刪掉，成功了才清後台紀錄。
    // 走「後台直接呼叫」而不是排 job —— 這是破壞性動作，按下去要當場知道刪掉了沒。
    if (action === "delete_post") {
      if (caller !== "admin") return json({ error: "刪除貼文只能從後台按" }, 403);
      const postId = Number(body.post_id);
      if (!postId) return json({ error: "post_id required" }, 400);
      return json(await deletePost(postId, callerTenant));
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
