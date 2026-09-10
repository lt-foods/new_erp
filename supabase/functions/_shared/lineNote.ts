// @ts-nocheck — JS 移植，不做型別檢查
// ⚠ 這是 tools/line-note-scraper/src/line.mjs 的 Deno 版（Edge Function 用）。
// 差異：linejs 走 jsr、不用檔案 storage（token 在 line_note_accounts.auth_token）、
// 圖片只收 Uint8Array。REST 探測 / 解析 / 發文邏輯要跟 tools 那邊保持一致，改一邊記得改另一邊。
//
// 記事本不是 Thrift，是 LINE 內部的 JSON REST（myhome / square-note）：
//   群組  GET https://<host>/mh/api/v57/post/list.json?homeId=<c…>&sourceType=TALKROOM
//   社群  GET https://<host>/sn/api/v57/post/list.json?homeId=<m…或 s…>
//   留言  GET …/comment/getList.json?homeId=&contentId=<postId>[&scrollId=]
// 沒有 wire trace，所以 host / 路徑前綴 / channel 都做了候選清單，第一個回 code 0 的就記住。
// ⚠ 不要改用 linejs 內建的 timeline.createPost/listPost —— 它把網址寫死成 legy.line-apps.com
// （LEGY 加密閘道，不吃純 HTTPS JSON），直接 fetch failed。
// deno-lint-ignore-file no-explicit-any

import { loginWithAuthToken, loginWithQR } from "jsr:@evex/linejs@^3.4.2";
import { MemoryStorage } from "jsr:@evex/linejs@^3.4.2/storage";

export const DEFAULT_DEVICE = Deno.env.get("LINE_DEVICE") || "ANDROIDSECONDARY";

const CHANNEL_IDS = {
  HOME: "1341209850",
  TIMELINE: "1341209950",
  NOTE: "1655599932",
  SQUARE_NOTE: "1657618623",
};

export function log(verbose: any, ...args: any[]) {
  if (verbose) console.log("[line-notes]", ...args);
}

/** 用存在 DB 的 token 登入（每次 Edge Function 冷啟動都會做一次，只有一趟 getProfile） */
export async function clientFromToken(authToken: string, device = DEFAULT_DEVICE): Promise<any> {
  return await loginWithAuthToken(authToken, { device, storage: new MemoryStorage() });
}

/**
 * 掃 QR 登入。QR 網址 / PIN 透過 callback 回報（寫進 DB 給後台顯示）。
 * 有 deadline：Edge Function 有時限，掃太慢就放棄，帳號標 error 請使用者再按一次。
 */
export async function loginByQr(opts: {
  onQr: (url: string) => Promise<void> | void;
  onPin: (pin: string) => Promise<void> | void;
  deadlineMs: number;
  device?: string;
}): Promise<any> {
  const login = loginWithQR(
    { onReceiveQRUrl: opts.onQr, onPincodeRequest: opts.onPin },
    { device: opts.device ?? DEFAULT_DEVICE, storage: new MemoryStorage() },
  );
  const timeout = new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error("等太久沒掃 QR，請回後台再按一次「登入」")), opts.deadlineMs));
  return await Promise.race([login, timeout]);
}

export function whoami(client: any) {
  const p = client.base.profile ?? {};
  return { mid: p.mid as string, displayName: p.displayName as string };
}

/** 加入中的群組（c…）、社群（s…）與社群聊天室（m…）。 */
export async function listHomes(client: any, verbose = false) {
  const homes: { kind: string; homeId: string; name: string; squareMid?: string }[] = [];
  try {
    const chats = await client.fetchJoinedChats();
    for (const c of chats) {
      const type = c.raw?.type;
      if (type === "GROUP" || type === 0 || String(c.mid).startsWith("c")) {
        homes.push({ kind: "group", homeId: c.mid, name: c.name ?? "" });
      }
    }
  } catch (e) {
    log(true, "fetchJoinedChats failed:", (e as any)?.message ?? e);
  }
  try {
    const squares = await client.fetchJoinedSquares();
    for (const s of squares) homes.push({ kind: "square", homeId: s.raw?.mid, name: s.raw?.name ?? "" });
  } catch (e) {
    log(true, "fetchJoinedSquares failed:", (e as any)?.message ?? e);
  }
  try {
    const r = await client.base.square.getJoinedSquareChats({ request: { limit: 100, continuationToken: "" } });
    for (const c of r?.chats ?? []) {
      homes.push({ kind: "square_chat", homeId: c.squareChatMid, name: c.name ?? "", squareMid: c.squareMid });
    }
  } catch (e) {
    log(verbose, "getJoinedSquareChats failed (可忽略，用 s… 的 id 也行):", (e as any)?.message ?? e);
  }
  return homes;
}

// ── 記事本 REST ────────────────────────────────────────────────────────────

function prefixCandidates(homeId) {
  const forced = Deno.env.get("LINE_NOTE_PREFIX");
  if (forced) return [forced];
  const first = String(homeId)[0];
  if (first === "s" || first === "m") return ["/sn", "/mh", "/ext/note/nt"];
  return ["/mh", "/ext/note/nt"];
}

function hostCandidates(client) {
  const forced = Deno.env.get("LINE_NOTE_HOST");
  if (forced) return [forced];
  const ep = client.base.request?.endpoint;
  return [...new Set([ep, "gw.line.naver.jp", "ga2.line.naver.jp"].filter(Boolean))];
}

function channelCandidates(homeId) {
  const forced = Deno.env.get("LINE_NOTE_CHANNEL");
  if (forced) return [forced];
  const first = String(homeId)[0];
  return first === "s" || first === "m"
    ? [CHANNEL_IDS.SQUARE_NOTE, CHANNEL_IDS.HOME, CHANNEL_IDS.TIMELINE, CHANNEL_IDS.NOTE]
    : [CHANNEL_IDS.HOME, CHANNEL_IDS.NOTE, CHANNEL_IDS.TIMELINE, CHANNEL_IDS.SQUARE_NOTE];
}

const tokenCache = new Map();
async function channelToken(client, channelId, verbose) {
  if (tokenCache.has(channelId)) return tokenCache.get(channelId);
  let token;
  try {
    const r = await client.base.channel.approveChannelAndIssueChannelToken({ channelId });
    token = r?.channelAccessToken ?? r?.token;
  } catch (e) {
    log(verbose, `approveChannelAndIssueChannelToken(${channelId}) failed:`, e?.message ?? e);
  }
  if (!token) {
    const r = await client.base.channel.issueChannelToken({ channelId });
    token = r?.token ?? r?.channelAccessToken;
  }
  if (!token) throw new Error(`no channel token for ${channelId}`);
  tokenCache.set(channelId, token);
  return token;
}

function baseHeaders(client, token) {
  return {
    accept: "application/json",
    "content-type": "application/json",
    "user-agent": client.base.request.userAgent,
    "x-line-application": client.base.request.systemType,
    "x-line-mid": client.base.profile?.mid ?? "",
    "x-line-access": client.base.authToken,
    "x-line-channeltoken": token,
    "x-lal": Deno.env.get("LINE_LANG") || "zh-Hant_TW",
    "x-lsr": Deno.env.get("LINE_REGION") || "TW",
    "x-lpv": "1",
    "x-lhm": "GET",
    "x-line-bdbtemplateversion": "v1",
    "x-line-global-config": "discover.enable=true; follow.enable=true",
  };
}

// 記住第一個打通的組合，之後同一個 homeId 直接用。
const routeCache = new Map();

/**
 * 對記事本 REST 打一次請求。回 { code, message, result }。
 * 會依序試 host × prefix × channel，直到有一組回 code 0，然後記住那組。
 *
 * ⚠ 不要改用 linejs 內建的 timeline.createPost/listPost —— 它把網址寫死成
 * `https://${client.request.endpoint}/…`，而 endpoint 預設是 legy.line-apps.com
 * （LEGY 加密閘道，不吃這種純 HTTPS JSON），直接丟 `fetch failed`。
 */
export async function noteRequest(client, homeId, path, params, { method = "GET", lhm, body, verbose = false } = {}) {
  const qs = new URLSearchParams(Object.fromEntries(Object.entries(params ?? {}).filter(([, v]) => v !== undefined && v !== null && v !== "")));
  const tryOne = async (host, prefix, channelId) => {
    const token = await channelToken(client, channelId, verbose);
    const url = `https://${host}${prefix}${path}?${qs}`;
    const res = await client.base.fetch(url, {
      method,
      // x-lhm 預設跟著 HTTP method，但不是每支都一樣 —— post/delete.json 是 POST 卻要送 GET
      // （linejs 的 deletePost/getPost 都這樣，create 才是 POST）。要不一樣就用 lhm 指定。
      headers: { ...baseHeaders(client, token), "x-lhm": lhm ?? method },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await res.text();
    // ⚠ 不要叫 body —— 外層參數就叫 body，同一個 scope 會 TDZ 炸掉
    let json;
    try { json = JSON.parse(text); } catch { json = { code: res.status, message: text.slice(0, 200), result: null }; }
    log(verbose, `${res.status} ${url} ch=${channelId} → code=${json?.code} ${json?.message ?? ""}`);
    return { httpStatus: res.status, body: json };
  };

  const cached = routeCache.get(homeId);
  if (cached) {
    const { body } = await tryOne(cached.host, cached.prefix, cached.channelId);
    return body;
  }
  const attempts = [];
  for (const host of hostCandidates(client)) {
    for (const prefix of prefixCandidates(homeId)) {
      for (const channelId of channelCandidates(homeId)) {
        try {
          const { httpStatus, body } = await tryOne(host, prefix, channelId);
          if (body && body.code === 0) {
            routeCache.set(homeId, { host, prefix, channelId });
            log(verbose, `route ok: host=${host} prefix=${prefix} channel=${channelId}`);
            return body;
          }
          attempts.push(`${httpStatus} ${host}${prefix}${path} ch=${channelId} code=${body?.code} ${body?.message ?? ""}`);
        } catch (e) {
          attempts.push(`ERR ${host}${prefix}${path} ch=${channelId}: ${e?.message ?? e}`);
        }
      }
    }
  }
  throw new Error(`記事本 API 全部打不通（homeId=${homeId}）。把下面這段貼回來：\n` + attempts.join("\n"));
}

/** GET 版（大部分呼叫點用這支） */
export async function noteGet(client, homeId, path, params, verbose = false) {
  return await noteRequest(client, homeId, path, params, { method: "GET", verbose });
}

// ── 回應解析（結構沒 wire trace，寫成寬鬆版；raw 一律保留） ──────────────

function pick(obj, ...paths) {
  for (const p of paths) {
    const v = p.split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);
    if (v !== undefined && v !== null && v !== "") return v;
  }
  return undefined;
}

function toIso(ms) {
  const n = Number(ms);
  if (!Number.isFinite(n) || n <= 0) return null;
  return new Date(n < 1e12 ? n * 1000 : n).toISOString();
}

export function normalizePost(p, homeId) {
  const post = p?.post ?? p; // feeds[] 會包一層 { post: {...} }
  return {
    homeId,
    postId: pick(post, "id", "postInfo.postId", "postId"),
    authorMid: pick(post, "userInfo.mid", "userInfo.writerMid", "postInfo.userInfo.mid", "actorId"),
    authorName: pick(post, "userInfo.nickname", "userInfo.displayName", "postInfo.userInfo.nickname"),
    createdAt: toIso(pick(post, "postInfo.createdTime", "createdTime")),
    updatedAt: toIso(pick(post, "postInfo.updatedTime", "updatedTime")),
    text: pick(post, "contents.text", "contents.textMeta.text", "text") ?? "",
    commentCount: Number(pick(post, "postInfo.commentCount", "commentCount") ?? 0),
    likeCount: Number(pick(post, "postInfo.likeCount", "likeCount") ?? 0),
    raw: post,
  };
}

export function normalizeComment(c, homeId, postId) {
  return {
    homeId,
    postId,
    commentId: pick(c, "id", "commentId"),
    authorMid: pick(c, "userInfo.mid", "userInfo.writerMid", "actorId", "mid"),
    authorName: pick(c, "userInfo.nickname", "userInfo.displayName", "nickname"),
    createdAt: toIso(pick(c, "createdTime", "postInfo.createdTime")),
    text: pick(c, "commentText", "text", "contents.text") ?? "",
    raw: c,
  };
}

function extractPosts(result) {
  if (!result) return [];
  if (Array.isArray(result.posts)) return result.posts;
  if (Array.isArray(result.feeds)) return result.feeds;
  if (Array.isArray(result)) return result;
  return [];
}

function extractComments(result) {
  if (!result) return [];
  if (Array.isArray(result.comments)) return result.comments;
  if (Array.isArray(result.commentList)) return result.commentList;
  if (Array.isArray(result)) return result;
  return [];
}

/** 列貼文，自動翻頁（用最後一篇的 postId + updatedTime 當游標）。 */
export async function listPosts(client, homeId, { limit = 200, since = null, verbose = false, onRaw } = {}) {
  const out = [];
  let postId, updatedTime;
  const sinceMs = since ? new Date(since).getTime() : null;
  for (let page = 0; page < 50 && out.length < limit; page++) {
    const body = await noteGet(client, homeId, "/api/v57/post/list.json", {
      homeId, sourceType: "TALKROOM", likeLimit: "0", commentLimit: "0", postId, updatedTime,
    }, verbose);
    onRaw?.(body);
    const posts = extractPosts(body.result).map((p) => normalizePost(p, homeId));
    if (posts.length === 0) break;
    let stop = false;
    for (const p of posts) {
      if (out.some((x) => x.postId === p.postId)) { stop = true; break; }
      // ⚠ LINE 的列表是依 updatedTime 排序（翻頁游標就是 updatedTime），所以「早於 since 就停」
      //   要看 updatedAt，不能看 createdAt —— 舊貼文一有新留言就會排到最前面，用 createdAt 判斷
      //   會在第一頁就停掉，後面幾十篇全漏（2026-09-09 抓不到全部貼文就是這個）。
      const lastTouched = p.updatedAt ?? p.createdAt;
      if (sinceMs && lastTouched && new Date(lastTouched).getTime() < sinceMs) { stop = true; break; }
      out.push(p);
    }
    if (stop) break;
    const last = posts[posts.length - 1];
    postId = last.postId;
    updatedTime = pick(last.raw, "postInfo.updatedTime", "updatedTime");
    if (!postId || !updatedTime) break;
  }
  return out.slice(0, limit);
}

/** 列一篇貼文的全部留言，用 scrollId 翻頁。 */
export async function listComments(client, homeId, postId, { verbose = false, onRaw } = {}) {
  const out = [];
  let scrollId;
  for (let page = 0; page < 200; page++) {
    const body = await noteGet(client, homeId, "/api/v57/comment/getList.json", {
      homeId, contentId: postId, limit: "50", scrollId,
    }, verbose);
    onRaw?.(body);
    const comments = extractComments(body.result).map((c) => normalizeComment(c, homeId, postId));
    if (comments.length === 0) break;
    let added = 0;
    for (const c of comments) {
      if (out.some((x) => x.commentId === c.commentId)) continue;
      out.push(c);
      added++;
    }
    const next = pick(body.result, "scrollId", "nextScrollId", "cursor", "nextCursor");
    if (!next || next === scrollId || added === 0) break;
    scrollId = next;
  }
  return out;
}

// ── 發文 ───────────────────────────────────────────────────────────────────

/**
 * 在記事本發一篇貼文（文字 + 可選圖片）。走 linejs 內建的 createPost：
 * 群組 → /mh/api/v57/post/create.json、社群（s…）→ /sn/…，
 * 圖片先上傳到 obs（myhome/h）拿 objId 再掛進 contents.media。
 * @param {object} opts
 * @param {string} opts.text
 * @param {Uint8Array[]} [opts.images]  JPEG bytes（上傳時 content-type 固定 image/jpeg）
 */
/**
 * 在某則留言上按表情（笑臉）。likeType 1003 = 笑
 * （1001 讚 / 1002 愛心 / 1003 笑 / 1004 驚 / 1005 哭 / 1006 怒）。
 * contentId 放**留言 id**；actorId 是自己的 mid。走跟讀留言同一套 host/prefix/channel 探測。
 */
export async function likeComment(client, homeId, commentId, { likeType = "1003", sourceType = "TIMELINE", verbose = false } = {}) {
  const res = await noteRequest(client, homeId, "/api/v57/like/create.json",
    { homeId, sourceType },
    {
      method: "POST",
      body: { contentId: String(commentId), actorId: client.base.profile?.mid ?? "", likeType: String(likeType), sharable: false },
      verbose,
    });
  if (!res || res.code !== 0) {
    throw new Error(`按表情失敗：code=${res?.code} ${res?.message ?? ""}`);
  }
  return res;
}

/**
 * 刪掉記事本上的一篇貼文（社群成員就看不到了）。
 * 端點與參數比照 linejs 的 timeline.deletePost：homeId / postId 走 query string、
 * 沒有 body、而且 **x-lhm 要送 "GET"**（跟 create.json 不一樣）。
 * 走跟讀貼文同一套 host/prefix/channel 探測，不用 linejs 那條寫死 legy 的路。
 */
export async function deleteNotePost(client, homeId, postId, { sourceType, verbose = false } = {}) {
  if (!postId) throw new Error("沒有貼文 id，無法刪除");

  // 先用唯讀的 list 把路由（host/prefix/channel）探出來並記住，delete 才不會拿**破壞性**的
  // 請求去一組一組試。萬一某組真的刪掉了卻回非 0，探測會繼續往下試、最後回報失敗，
  // 而貼文其實已經不見了 —— 那是最難查的一種狀況。（createNotePost 也是同樣的理由。）
  try {
    await noteGet(client, homeId, "/api/v57/post/list.json",
      { homeId, sourceType: sourceType ?? "TALKROOM", likeLimit: "0", commentLimit: "0" }, verbose);
  } catch (e) {
    log(verbose, "探路用的 list 失敗（照樣試刪除）:", e?.message ?? e);
  }

  const res = await noteRequest(client, homeId, "/api/v57/post/delete.json",
    { homeId, postId: String(postId) }, { method: "POST", lhm: "GET", verbose });
  if (!res || res.code !== 0) {
    throw new Error(`刪除貼文失敗：code=${res?.code} ${res?.message ?? ""}`);
  }
  return res;
}

export async function createNotePost(client, homeId, { text, images = [], sourceType, verbose = false } = {}) {
  if (!text && images.length === 0) throw new Error("貼文至少要有文字或圖片");

  // 圖片上傳走 obs.line-apps.com（linejs 的 uploadNoteMedia），失敗就只發文字，
  // 不要讓整篇貼文因為一張圖掛掉。
  const media = [];
  for (const file of images) {
    try {
      // images 可以是 Uint8Array（當 JPEG）或 { bytes, type } —— PNG 也要能上傳，
      // 宣告錯的 MIME 會被 obs 退掉。
      const bytes = file?.bytes ?? file;
      const type = file?.type || "image/jpeg";
      const { objId } = await client.base.timeline.uploadNoteMedia("image", new Blob([bytes], { type }));
      media.push({ objectId: objId, type: "PHOTO", obsFace: "[]" });
      log(verbose, `uploaded <${(file?.bytes ?? file).byteLength} bytes, ${type}> → ${objId}`);
    } catch (e) {
      log(true, `圖片上傳失敗，這張跳過：${e?.message ?? e}`);
    }
  }

  // 先打一次 list 把路由（host/prefix/channel）探出來並記住，create 才不會在探路
  // 的過程中對不同前綴各發一篇（重複貼文）。
  try {
    await noteGet(client, homeId, "/api/v57/post/list.json",
      { homeId, sourceType: sourceType ?? "TALKROOM", likeLimit: "0", commentLimit: "0" }, verbose);
  } catch (e) {
    log(verbose, "探路用的 list 失敗（照樣試發文）:", e?.message ?? e);
  }

  const body = {
    postInfo: { readPermission: { type: "ALL", gids: [] } },
    contents: {
      contentsStyle: {
        textStyle: { textSizeMode: "AUTO", backgroundColor: "", textAnimation: "NONE" },
        mediaStyle: { displayType: "GRID_1_A" },
      },
      stickers: [],
      locations: [],
      media,
      ...(text ? { text } : {}),
    },
  };
  const res = await noteRequest(client, homeId, "/api/v57/post/create.json",
    { homeId, sourceType: sourceType ?? "TALKROOM" }, { method: "POST", body, verbose });
  log(verbose, "createPost →", JSON.stringify(res).slice(0, 500));
  if (!res || res.code !== 0) {
    throw new Error(`發文失敗：code=${res?.code} ${res?.message ?? ""}\n${JSON.stringify(res).slice(0, 800)}`);
  }
  return normalizePost(res.result?.post ?? res.result, homeId);
}

