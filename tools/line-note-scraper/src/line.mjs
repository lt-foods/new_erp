// linejs 包裝：登入、列群組／社群、讀記事本貼文與留言。
//
// 記事本不是 Thrift，是 LINE 內部的 JSON REST（myhome / square-note）：
//   群組  GET https://<host>/mh/api/v57/post/list.json?homeId=<c…>&sourceType=TALKROOM
//   社群  GET https://<host>/sn/api/v57/post/list.json?homeId=<m…或 s…>
//   留言  GET …/comment/getList.json?homeId=&contentId=<postId>[&scrollId=]
// header 要 X-Line-Access（登入 token）+ X-Line-ChannelToken（channel token）+ X-Line-Mid。
// 沒有 wire trace，所以 host / 路徑前綴 / channel 都做了候選清單，第一個回 code 0 的就記住。
// 打不通時用 --verbose 看每一次嘗試的回應，把輸出貼回來就能調。

import { loginWithAuthToken, loginWithQR } from "@evex/linejs";
import { FileStorage } from "@evex/linejs/storage";
import fs from "node:fs";

export const DEFAULT_DEVICE = process.env.LINE_DEVICE || "ANDROIDSECONDARY";
export const STORAGE_PATH = process.env.LINE_STORAGE || "./storage.json";

const CHANNEL_IDS = {
  HOME: "1341209850",
  TIMELINE: "1341209950",
  NOTE: "1655599932",
  SQUARE_NOTE: "1657618623",
};

export function log(verbose, ...args) {
  if (verbose) console.error("[line-notes]", ...args);
}

export async function getClient({ interactive = false, verbose = false, device = DEFAULT_DEVICE } = {}) {
  const storage = new FileStorage(STORAGE_PATH);
  const cached = await storage.get(".auth");
  const init = { device, storage };

  if (typeof cached === "string" && cached) {
    log(verbose, `using cached auth token from ${STORAGE_PATH}`);
    try {
      const client = await loginWithAuthToken(cached, init);
      client.base.on("update:authtoken", (t) => storage.set(".auth", t));
      return client;
    } catch (e) {
      if (!interactive) throw new Error(`cached token rejected (${e?.message ?? e}); run "login" again`);
      log(verbose, "cached token rejected, falling back to QR login:", e?.message ?? e);
    }
  }
  if (!interactive) throw new Error(`no auth token in ${STORAGE_PATH}; run "login" first`);

  const client = await loginWithQR({
    async onReceiveQRUrl(url) {
      console.log("\n用要當爬蟲的那支 LINE 帳號掃這個 QR（備用帳號！）：\n");
      try {
        const qr = await import("qrcode-terminal");
        (qr.default ?? qr).generate(url, { small: true });
      } catch {
        // qrcode-terminal 沒裝也沒關係，下面有網址
      }
      console.log("\n或把這個網址貼到手機 LINE 開啟：\n" + url + "\n");
    },
    onPincodeRequest(pin) {
      console.log(`\n手機 LINE 會要你輸入 PIN：  ${pin}\n`);
    },
  }, init);
  client.base.on("update:authtoken", (t) => storage.set(".auth", t));
  await storage.set(".auth", client.base.authToken);
  return client;
}

export function whoami(client) {
  const p = client.base.profile ?? {};
  return { mid: p.mid, displayName: p.displayName };
}

/** 加入中的群組（c…）、社群（s…）與社群聊天室（m…）。 */
export async function listHomes(client, verbose = false) {
  const homes = [];
  try {
    const chats = await client.fetchJoinedChats();
    for (const c of chats) {
      const type = c.raw?.type;
      if (type === "GROUP" || type === 0 || String(c.mid).startsWith("c")) {
        homes.push({ kind: "group", homeId: c.mid, name: c.name ?? "" });
      }
    }
  } catch (e) {
    log(true, "fetchJoinedChats failed:", e?.message ?? e);
  }
  try {
    const squares = await client.fetchJoinedSquares();
    for (const s of squares) {
      homes.push({ kind: "square", homeId: s.raw?.mid, name: s.raw?.name ?? "" });
    }
  } catch (e) {
    log(true, "fetchJoinedSquares failed:", e?.message ?? e);
  }
  try {
    const chats = await client.fetchJoinedSquareChats();
    for (const c of chats) {
      const raw = c.raw ?? c;
      homes.push({ kind: "square_chat", homeId: raw.squareChatMid ?? c.mid, name: raw.name ?? c.name ?? "", squareMid: raw.squareMid });
    }
  } catch (e) {
    log(verbose, "fetchJoinedSquareChats failed (可忽略，用 s… 的 id 也行):", e?.message ?? e);
  }
  return homes;
}

// ── 記事本 REST ────────────────────────────────────────────────────────────

function prefixCandidates(homeId) {
  const forced = process.env.LINE_NOTE_PREFIX;
  if (forced) return [forced];
  const first = String(homeId)[0];
  if (first === "s" || first === "m") return ["/sn", "/mh", "/ext/note/nt"];
  return ["/mh", "/ext/note/nt"];
}

function hostCandidates(client) {
  const forced = process.env.LINE_NOTE_HOST;
  if (forced) return [forced];
  const ep = client.base.request?.endpoint;
  return [...new Set([ep, "gw.line.naver.jp", "ga2.line.naver.jp"].filter(Boolean))];
}

function channelCandidates(homeId) {
  const forced = process.env.LINE_NOTE_CHANNEL;
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
    "x-lal": process.env.LINE_LANG || "zh-Hant_TW",
    "x-lsr": process.env.LINE_REGION || "TW",
    "x-lpv": "1",
    "x-lhm": "GET",
    "x-line-bdbtemplateversion": "v1",
    "x-line-global-config": "discover.enable=true; follow.enable=true",
  };
}

// 記住第一個打通的組合，之後同一個 homeId 直接用。
const routeCache = new Map();

/**
 * 對記事本 REST 打一次 GET。回 { code, message, result }。
 * 會依序試 host × prefix × channel，直到有一組回 code 0。
 */
export async function noteGet(client, homeId, path, params, verbose = false) {
  const qs = new URLSearchParams(Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== "")));
  const tryOne = async (host, prefix, channelId) => {
    const token = await channelToken(client, channelId, verbose);
    const url = `https://${host}${prefix}${path}?${qs}`;
    const res = await client.base.fetch(url, { method: "GET", headers: baseHeaders(client, token) });
    const text = await res.text();
    let body;
    try { body = JSON.parse(text); } catch { body = { code: res.status, message: text.slice(0, 200), result: null }; }
    log(verbose, `${res.status} ${url} ch=${channelId} → code=${body?.code} ${body?.message ?? ""}`);
    return { httpStatus: res.status, body };
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
      if (sinceMs && p.createdAt && new Date(p.createdAt).getTime() < sinceMs) { stop = true; break; }
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
 * @param {(string|Buffer)[]} [opts.images]  JPEG 檔路徑或 Buffer（上傳時 content-type 固定 image/jpeg）
 */
export async function createNotePost(client, homeId, { text, images = [], sourceType, verbose = false } = {}) {
  if (!text && images.length === 0) throw new Error("貼文至少要有文字或圖片");
  const tl = client.base.timeline;
  const mediaObjectIds = [];
  const mediaObjectTypes = [];
  for (const file of images) {
    const buf = Buffer.isBuffer(file) ? file : fs.readFileSync(file);
    const { objId } = await tl.uploadNoteMedia("image", new Blob([buf], { type: "image/jpeg" }));
    log(verbose, `uploaded ${file} → ${objId}`);
    mediaObjectIds.push(objId);
    mediaObjectTypes.push("PHOTO");
  }
  const res = await tl.createPost({
    homeId,
    text,
    mediaObjectIds,
    mediaObjectTypes,
    ...(sourceType ? { sourceType } : {}),
  });
  log(verbose, "createPost →", JSON.stringify(res).slice(0, 500));
  if (!res || res.code !== 0) {
    throw new Error(`發文失敗：code=${res?.code} ${res?.message ?? ""}\n${JSON.stringify(res).slice(0, 800)}`);
  }
  return normalizePost(res.result?.post ?? res.result, homeId);
}

export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}
