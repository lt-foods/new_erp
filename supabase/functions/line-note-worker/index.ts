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
  clientFromToken, createNotePost, deleteNotePost, likeComment, listComments, listHomes, listPosts, loginByQr, whoami,
} from "../_shared/lineNote.ts";
import { buildPostTag, matchCampaign, parseNoteComment, postTitle, withPostTag } from "../_shared/lineNoteParse.ts";
import { applyDeco, DECO_OPEN, decoPrice, stripDeco } from "../_shared/lineNoteDeco.ts";

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
    status: "logged_out", auth_token: null, qr_image: null, qr_url: null, pin_code: null, last_error: null,
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

// 版型照小幫手手貼的樣子：團名開頭、商品用 (A) 品名 ＋ 下一行價格、⏰ 結單、#開團 收尾。
// 文案本體吃 campaign.description —— 那本來就是商品那邊寫好的行銷文（線上近兩週 377/395 團有）。
// {{title}} / {{items}} / {{deadline}} 是「聰明版」：文案自己已經寫過的就不再重複一次。
// 從記事本匯進來的團，description 常常就是整篇貼文（標題＋(A)(B)品項＋⏰結單都在裡面），
// 照樣接上去會變成品項印兩次、結單寫兩行。
// {{name}} / {{end_at}} 維持原樣（照印），自訂模板的行為不變。
// {{tag}} 是團號章（🔖 團號 GRP-…）：爬回來的時候靠它精準認出是哪一團，不用猜團名。
// 自訂模板沒寫 {{tag}} 也會被 withPostTag 補在文末 —— 章一定要有，不然這篇就只能靠猜。
const DEFAULT_TEMPLATE = `{{title}}

{{description}}

{{items}}

{{deadline}}
📝 留言「會員編號 6 碼 ＋ 品項代碼＋數量」，例：123456 A+1 B+2
#開團
{{tag}}`;

// 比對標題用：去掉表情符號、空白、標點，只留文字
function bareText(s: string) {
  return String(s ?? "").normalize("NFKC").toLowerCase()
    .replace(/[\s\p{P}\p{S}\p{M}\p{C}]/gu, "");   // \p{M}/\p{C} 要一起拿掉：emoji 後面的 VS16、ZWJ 都藏在那裡
}

// 從記事本抓回來的舊文會帶 LINE 裝飾表情的佔位字：($)(3)(5) = $35、(emoji) = 一個貼圖。
// 原樣貼出去客人會看到一串「($)(3)(5)」，所以還原成看得懂的字。
function stripLineDeco(s: string) {
  return String(s ?? "")
    .replace(/(?:\((?:\$|[0-9]|\/)\)){2,}/g, (m) => m.replace(/[()]/g, ""))
    .replace(/\((?:emoji|好吃|讚|哭|笑|愛心)\)/g, "")
    .replace(/[ \t]+\n/g, "\n");
}

// 品項名在 DB 裡是「團名 (A) 空心菜200g」，直接印會變成「(A) 團名 (A) 空心菜200g」。
// 去掉團名前綴和重複的代碼，只留真正的品名。
function itemLabel(name: string, code: string, campaignName: string) {
  let t = String(name ?? "").trim();
  const cn = String(campaignName ?? "").trim();
  if (cn && t.startsWith(cn)) t = t.slice(cn.length).trim();
  t = t.replace(new RegExp(`^[(（]${code}[)）]\\s*`), "").trim();
  return t || String(name ?? "").trim();
}

function fmtTaipei(iso: string | null | undefined) {
  if (!iso) return "";
  const p = new Intl.DateTimeFormat("zh-TW", { timeZone: TZ, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(iso));
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "";
  return `${g("month")}/${g("day")} ${g("hour")}:${g("minute")}`;
}

export function renderTemplate(template: string | null, payload: any) {
  const c = payload.campaign ?? {};
  const items = (payload.items ?? []).map((it: any) => {
    const label = itemLabel(it.name, it.code, c.name);
    // 金額用 LINE 的數字表情（小幫手手貼都是這樣打的），只包我們自己產的這一行 ——
    // 店家寫在文案裡的「（市價$150/盒）」不要動
    const price = it.unit_price == null ? "" : `\n${decoPrice(`$${Number(it.unit_price)}`)}`;
    return `(${it.code}) ${label}${price}`;
  }).join("\n");
  const desc = stripLineDeco(c.description ?? "");
  // 文案自己就列了 (A)(B) 品項 / 寫了結單 / 開頭就是團名 → 那三個聰明佔位符留空
  const descHasItems = /(^|\n)\s*[(（][A-Za-z][)）]/.test(desc);
  const descHasDeadline = /結單|收單|截單/.test(desc);
  const firstLine = bareText(desc.split("\n").find((x) => x.trim()) ?? "");
  const bareName = bareText(c.name ?? "");
  const descHasTitle = !!firstLine && !!bareName && firstLine.length >= 4
    && (bareName.includes(firstLine) || firstLine.includes(bareName));
  const deadline = c.end_at ? `⏰ ${fmtTaipei(c.end_at)} 結單` : "";

  const rendered = (template || DEFAULT_TEMPLATE)
    .replaceAll("{{tag}}", buildPostTag(c.campaign_no))
    .replaceAll("{{title}}", descHasTitle ? "" : (c.name ?? ""))
    .replaceAll("{{items}}", descHasItems ? "" : items)
    .replaceAll("{{deadline}}", descHasDeadline ? "" : deadline)
    .replaceAll("{{name}}", c.name ?? "")
    .replaceAll("{{campaign_no}}", c.campaign_no ?? "")
    .replaceAll("{{description}}", desc)
    .replaceAll("{{end_at}}", fmtTaipei(c.end_at))
    .replaceAll("{{start_at}}", fmtTaipei(c.start_at))
    .replaceAll("{{pickup_deadline}}", fmtTaipei(c.pickup_deadline))
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return withPostTag(rendered, c.campaign_no);
}

// 文案裡「自己獨立一行的 $數字」也是價格（匯進來的團，品項與價格都寫在 description 裡），
// 一併用數字表情。行內的「（市價$150/盒）」不動 —— 那不是這團的售價。
function decoStandalonePrices(text: string) {
  return text.split("\n")
    .map((line) => /^\s*\$\d+\s*$/.test(line) && !line.includes(DECO_OPEN)
      ? line.replace(/\$\d+/, (m) => decoPrice(m))
      : line)
    .join("\n");
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
  const rendered = decoStandalonePrices(renderTemplate(payload.post_template, payload));
  const { text, sticonMetas } = applyDeco(rendered);
  const plain = stripDeco(rendered);          // 存 DB / 給人看的版本："$79" 而不是 "($)(7)(9)"
  const images = await collectPostImages(payload);
  try {
    const post = await createNotePost(client, payload.home_id, { text, sticonMetas, images, verbose: VERBOSE });
    await patch("line_note_posts", `id=eq.${job.post_id}`, {
      status: "posted", line_post_id: post.postId ?? null, text: plain, posted_at: new Date().toISOString(), last_error: null,
    });
    return { postId: post.postId, title: postTitle(plain), images: images.length, deco: sticonMetas.length };
  } catch (e) {
    await patch("line_note_posts", `id=eq.${job.post_id}`, { status: "failed", text: plain, last_error: String((e as any)?.message ?? e).slice(0, 1000) });
    throw e;
  }
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
  const reacted = await reactToConfirmed(client, post);
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
  return { comments: comments.length, pending: pending?.length ?? 0, ordered, other, reacted, closed: !!closer, late };
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

const REACT_BATCH = 40;                                  // 每則貼文一次最多按幾則
const REACT_DEADLINE = Date.now() + 100_000;             // 本次呼叫按表情的總預算（idle timeout 150s）

// 收到單的留言回按一個笑臉，讓客人知道「你的 +1 我收到了」。
// 只按 ordered / duplicate / resolved —— unmatched、error 還沒處理完，按了會讓客人以為收到了。
// 按過的記 reacted_at，下次讀留言不會重按。單一則失敗不影響其他則，也不影響讀留言本身。
async function reactToConfirmed(client: any, post: any): Promise<number> {
  if (post.react_on_confirm === false) return 0;
  const rows = await rest(
    `line_note_comments?post_id=eq.${post.id}&reacted_at=is.null` +
    `&status=in.(ordered,duplicate,resolved)&select=id,line_comment_id&limit=${REACT_BATCH}`);
  let n = 0;
  for (const c of rows ?? []) {
    if (!c.line_comment_id) continue;
    // Edge Function 有 150 秒 idle timeout，按表情一則約 1 秒。
    // 超過預算就留給下一次讀留言接手（reacted_at 是 NULL 的還在，不會漏）。
    if (Date.now() > REACT_DEADLINE) { log("按表情時間到，剩下的留到下次讀留言"); break; }
    try {
      await likeComment(client, post.home_id, c.line_comment_id, { verbose: VERBOSE });
      await patch("line_note_comments", `id=eq.${c.id}`, { reacted_at: new Date().toISOString() });
      n++;
    } catch (e) {
      log(`留言 ${c.line_comment_id} 按表情失敗（略過）：${(e as any)?.message ?? e}`);
    }
  }
  return n;
}

// 認貼文：小幫手手貼的團也綁進來（比對規則見 matchCampaign）
async function discoverPosts(client: any, community: any) {
  const since = new Date(Date.now() - community.read_days * 86400_000).toISOString();
  const notes = await listPosts(client, community.home_id, { limit: 100, since, verbose: VERBOSE });
  if (notes.length === 0) return 0;
  const known = await rest(`line_note_posts?community_id=eq.${community.id}&select=id,status,line_post_id,campaign_id`);
  const knownByLineId = new Map((known ?? []).filter((p: any) => p.line_post_id).map((p: any) => [p.line_post_id, p]));
  const campaigns = await rest(`group_buy_campaigns?tenant_id=eq.${community.tenant_id}&status=in.(open,closed)&select=id,name,campaign_no,campaign_items(skus(product_name))&order=id.desc&limit=300`);
  let linked = 0;
  for (const n of notes) {
    if (!n.postId) continue;
    const text = String(n.text ?? "");
    const hit = matchCampaign(text, campaigns ?? []);

    const seen = knownByLineId.get(String(n.postId));
    if (seen) {
      // 已經認過的不用再看；還沒認出團的每次都再試一次（團可能後來才改名／才開）
      if (seen.campaign_id || !hit) continue;
      // 那一團已經有別的貼文了 → 這則是重複的，維持 unlinked 讓人自己處理
      if ((known ?? []).some((p: any) => p.campaign_id === hit.id)) continue;
      await patch("line_note_posts", `id=eq.${seen.id}`, { campaign_id: hit.id, status: "posted" });
      linked++;
      log(`🔗 補認到貼文 ${n.postId} → 團 ${hit.campaign_no} ${hit.name}`);
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
  const posts = await rest(`line_note_posts?${filter}&status=eq.posted&select=id,tenant_id,line_post_id,community_id,group_buy_campaigns(status),line_note_communities(home_id,account_id,react_on_confirm)`);
  const out: any[] = [];
  for (const p of posts ?? []) {
    const cst = p.group_buy_campaigns?.status;
    if (cst && !["open", "closed"].includes(cst)) { await patch("line_note_posts", `id=eq.${p.id}`, { status: "closed" }); continue; }
    const client = await clientFor(await loadAccount(p.line_note_communities.account_id));
    try {
      out.push({ post_id: p.id, ...(await readPost(client, {
        ...p, home_id: p.line_note_communities.home_id,
        react_on_confirm: p.line_note_communities.react_on_confirm,
      })) });
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
      const rendered = decoStandalonePrices(renderTemplate(payload.post_template, payload));
      return json({
        text: stripDeco(rendered),
        deco: applyDeco(rendered).sticonMetas.length,   // 有幾個字會用 LINE 數字表情貼出去
        images: postImageUrls(payload),
      });
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
