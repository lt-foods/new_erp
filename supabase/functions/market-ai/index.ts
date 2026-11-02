// ─────────────────────────────────────────────────────────────────────────────
// Edge Function: market-ai
//
// 選品 AI，全部走 Cloudflare Workers AI（2026-11-01 老闆決定不用 Claude 排程，20261101000090）：
//   1. 廠商貼文拆品項（含看圖）：rpc_market_post_claim → 視覺模型 → rpc_market_post_write
//   2. 商品向量：rpc_ai_product_embed_claim → bge-m3 → rpc_ai_product_embed_write
//   3. 品項向量＋比對：rpc_ai_item_embed_claim → bge-m3 → rpc_ai_item_embed_write（重算「賣過嗎」、同步候選池）
//   4. 新品貼標：rpc_product_tag_llm_claim → 文字模型 → rpc_product_tag_llm_write
//   5. 品類（20261101000220）：rpc_ai_kind_claim → 文字模型 → rpc_ai_kind_write（廠商品項 → 市場熱門 → 商品）
//   2b. 市場熱門榜單向量（20261102000010）：rpc_ai_hot_embed_claim → bge-m3 → rpc_ai_hot_embed_write
//
// 呼叫：
//   { action: "tick" }               pg_cron 'market-ai-tick' 每 5 分鐘（有工作才打）；line-note-worker 讀完
//                                    廠商群組也會馬上叫一次，「立即讀取」幾分鐘內就整理好
//   { action: "probe", post_ids }    只解析不寫入，回傳模型結果（人工抽查用）
// 認證：x-line-note-secret = LINE_NOTE_CRON_SECRET（跟 line-note-worker 同一把），或 Bearer service_role key。
//
// secrets：CLOUDFLARE_ACCOUNT_ID、CLOUDFLARE_AI_TOKEN（Workers AI 權限），
//   選填 CLOUDFLARE_AI_MODEL（預設 @cf/meta/llama-4-scout-17b-16e-instruct，看得懂圖）、
//   CLOUDFLARE_EMBED_MODEL（預設 @cf/baai/bge-m3）；內建 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY。
// 截止時間在 handler 裡算（模組層級只求值一次，見 CLAUDE.md #970）。
// ─────────────────────────────────────────────────────────────────────────────
// deno-lint-ignore-file no-explicit-any

import { corsHeaders } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CRON_SECRET = Deno.env.get("LINE_NOTE_CRON_SECRET") ?? "";
const CF_ACCOUNT = Deno.env.get("CLOUDFLARE_ACCOUNT_ID") ?? "";
const CF_TOKEN = Deno.env.get("CLOUDFLARE_AI_TOKEN") ?? "";
const CHAT_MODEL = Deno.env.get("CLOUDFLARE_AI_MODEL") || "@cf/meta/llama-4-scout-17b-16e-instruct";
const EMBED_MODEL = Deno.env.get("CLOUDFLARE_EMBED_MODEL") || "@cf/baai/bge-m3";
const MAX_IMAGES = 3;

/**
 * 送進 Cloudflare 的文字一律走這裡：照「字元」截斷（不是 UTF-16 單位），並拿掉落單的 surrogate。
 * 2026-11-01 第一輪：商品描述 .slice() 把表情符號切成一半，Workers AI 回
 * 「8006 Invalid data for body - reason must be valid JSON」，整批貼標失敗。
 */
function clean(v: unknown, max: number): string {
  const s = String(v ?? "").replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "");
  const chars = Array.from(s);
  return chars.length > max ? chars.slice(0, max).join("") : s;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

async function rest(pathAndQuery: string, opts: { method?: string; body?: unknown } = {}) {
  const method = opts.method ?? "GET";
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${pathAndQuery.slice(0, 60)} → ${res.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}
const rpc = (name: string, args: unknown) => rest(`rpc/${name}`, { method: "POST", body: args });

// ── Cloudflare Workers AI ──────────────────────────────────────────────────
async function cfRun(model: string, body: unknown): Promise<any> {
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/ai/run/${model}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${CF_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let parsed: any = null;
  try { parsed = JSON.parse(text); } catch { /* 下面處理 */ }
  if (!res.ok || parsed?.success === false) {
    const msg = parsed?.errors?.map((e: any) => `${e.code ?? ""} ${e.message ?? ""}`).join("; ") || text.slice(0, 300);
    throw new Error(`Cloudflare ${model} ${res.status}: ${msg}`);
  }
  return parsed?.result ?? parsed;
}

async function embed(texts: string[]): Promise<number[][]> {
  const r = await cfRun(EMBED_MODEL, { text: texts });
  const data = r?.data ?? r?.response;
  if (!Array.isArray(data) || data.length !== texts.length) throw new Error(`bge-m3 回傳筆數不對：${texts.length} → ${Array.isArray(data) ? data.length : typeof data}`);
  return data;
}

/** 對話模型＋JSON schema；模型不吃 schema 時退回「只回 JSON」的指示再自己 parse */
async function chatJson(system: string, user: any[] | string, schema: any, maxTokens = 2048): Promise<any> {
  const messages = [{ role: "system", content: system }, { role: "user", content: user }];
  let r: any;
  try {
    r = await cfRun(CHAT_MODEL, { messages, max_tokens: maxTokens, temperature: 0, response_format: { type: "json_schema", json_schema: schema } });
  } catch (e) {
    if (!/response_format|json_schema|schema/i.test(String((e as any)?.message ?? e))) throw e;
    r = await cfRun(CHAT_MODEL, { messages: [{ role: "system", content: system + "\n只回 JSON，不要任何其他文字。" }, messages[1]], max_tokens: maxTokens, temperature: 0 });
  }
  const out = r?.response ?? r;
  if (out && typeof out === "object") return out;
  const s = String(out ?? "");
  const m = s.match(/\{[\s\S]*\}/);
  if (!m) throw new Error(`模型沒回 JSON：${s.slice(0, 200)}`);
  return JSON.parse(m[0]);
}

// ── 標籤字彙（每次 invocation 讀一次） ─────────────────────────────────────
async function loadTags(): Promise<{ code: string; name: string; tag_group: string }[]> {
  return (await rest("product_tags?is_active=eq.true&select=code,name,tag_group&order=tag_group,sort,id")) ?? [];
}
function tagText(tags: { code: string; name: string; tag_group: string }[]) {
  const by = new Map<string, string[]>();
  for (const t of tags) { const l = by.get(t.tag_group) ?? []; l.push(`${t.code}=${t.name}`); by.set(t.tag_group, l); }
  return [...by.entries()].map(([g, l]) => `【${g}】${l.join("、")}`).join("\n");
}
const TAG_RULES =
  "標籤規則：只能用清單裡的 code；每個商品至少 1 個「生鮮」「食品」或「非食品」群的標籤（食品可同時給大類和子類，例如 prepared + prep_dumpling）；" +
  "溫層 frozen / chilled / ambient 只有寫明才給，非食品不給；日本 / 韓國 / 禮盒看得出來就給 jp / kr / gift；看不出是什麼就給空陣列。";

/**
 * 模型貼的標籤照規則再濾一次（2026-11-01 第一輪 Llama 4 Scout 常見的錯）：
 *   - 只留清單裡有的 code；
 *   - 沒有任何「生鮮 / 食品」群標籤（＝非食品）→ 拿掉溫層；
 *   - 同時有非食品群標籤 → 拿掉「熟食調理」這種食品群標籤（手膜被標 prepared）。
 * 日本 / 韓國 / 禮盒判斷錯（加拿大蜂膠標 jp）規則救不了，留給人看。
 */
function fixTags(codes: string[], groupOf: Map<string, string>): string[] {
  let out = [...new Set(codes.filter((c) => groupOf.has(c)))];
  const groups = new Set(out.map((c) => groupOf.get(c)));
  const isFood = groups.has("生鮮") || groups.has("食品");
  const isNonFood = groups.has("非食品");
  if (isNonFood && isFood) out = out.filter((c) => !["生鮮", "食品"].includes(groupOf.get(c)!));
  if (!isFood || isNonFood) out = out.filter((c) => groupOf.get(c) !== "溫層");
  return out;
}

// ── 1. 廠商貼文拆品項 ──────────────────────────────────────────────────────
const ITEMS_SCHEMA = {
  name: "supplier_post_items",
  schema: {
    type: "object",
    properties: {
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            item_name: { type: "string" },
            norm_name: { type: "string" },
            price: { type: ["number", "null"] },
            price_text: { type: "string" },
            spec: { type: "string" },
            deadline_text: { type: "string" },
            tags: { type: "array", items: { type: "string" } },
          },
          required: ["item_name", "norm_name", "price", "tags"],
        },
      },
    },
    required: ["items"],
  },
};

async function imageDataUrl(path: string): Promise<string | null> {
  // 先拿縮小版（Storage 圖片轉換），沒開就拿原圖；太大的不送（模型請求有大小限制）
  const urls = [
    `${SUPABASE_URL}/storage/v1/render/image/public/products/${path}?width=768&quality=70`,
    `${SUPABASE_URL}/storage/v1/object/public/products/${path}`,
  ];
  for (const u of urls) {
    try {
      const res = await fetch(u);
      const type = (res.headers.get("content-type") ?? "").split(";")[0];
      if (!res.ok || !type.startsWith("image/")) continue;
      const buf = new Uint8Array(await res.arrayBuffer());
      if (buf.byteLength > 1_500_000) continue;
      let bin = "";
      for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
      return `data:${type};base64,${btoa(bin)}`;
    } catch { /* 下一個 */ }
  }
  return null;
}

async function parsePost(post: { post_id: number; supplier?: string | null; community?: string | null; body: string; images?: string[] | null }, tagList: string, groupOf: Map<string, string>) {
  const system =
    "你是台灣團購店的選品助理。下面是廠商在 LINE 群組記事本貼的商品貼文（文字＋圖片），把它拆成商品清單：\n" +
    "- 一篇可能有好幾個商品，每個一筆；不是在賣商品的貼文（公告、休假、匯款、出貨通知）→ items 給空陣列。\n" +
    "- item_name：商品名，去掉表情符號與行銷字（免運、爆款、限時）。\n" +
    "- norm_name：標準繁體中文核心品名，用空白分隔 2～4 個關鍵詞；簡體轉繁體、英文翻中文、去掉品牌行銷字與規格。例：「Shine Muscat 晴王葡萄 2kg」→「麝香葡萄 晴王」。\n" +
    "- price：給團購主的價格（團購價／批價／優惠價）的數字，不含 $；看不出來給 null。price_text 放原文那一小段。\n" +
    "- spec：規格（1000克、10入）。deadline_text：截止或出貨時間原文。\n" +
    "- 價格、品名常常只寫在圖上，要看圖。\n" +
    TAG_RULES + "\n標籤清單：\n" + tagList;
  const content: any[] = [{ type: "text", text: `廠商：${clean(post.supplier ?? post.community ?? "", 100)}\n貼文：\n${clean(post.body, 4000)}` }];
  for (const p of (post.images ?? []).slice(0, MAX_IMAGES)) {
    const url = await imageDataUrl(p);
    if (url) content.push({ type: "image_url", image_url: { url } });
  }
  const out = await chatJson(system, content, ITEMS_SCHEMA, 2048);
  const items = Array.isArray(out?.items) ? out.items : [];
  return items
    .filter((it: any) => it && typeof it.item_name === "string" && it.item_name.trim())
    .map((it: any) => ({
      item_name: String(it.item_name).slice(0, 200),
      norm_name: typeof it.norm_name === "string" ? it.norm_name.slice(0, 100) : null,
      price: typeof it.price === "number" && Number.isFinite(it.price) && it.price >= 0 ? it.price : null,
      price_text: typeof it.price_text === "string" ? it.price_text.slice(0, 200) : null,
      spec: typeof it.spec === "string" ? it.spec.slice(0, 200) : null,
      deadline_text: typeof it.deadline_text === "string" ? it.deadline_text.slice(0, 200) : null,
      tags: fixTags(Array.isArray(it.tags) ? it.tags.filter((c: any) => typeof c === "string" && /^[a-z_]+$/.test(c)) : [], groupOf),
    }));
}

// ── 4. 新品貼標 ─────────────────────────────────────────────────────────────
const TAGS_SCHEMA = {
  name: "product_tags",
  schema: {
    type: "object",
    properties: {
      items: { type: "array", items: { type: "object", properties: { id: { type: "integer" }, tags: { type: "array", items: { type: "string" } } }, required: ["id", "tags"] } },
    },
    required: ["items"],
  },
};
async function tagProducts(products: any[], tagList: string, groupOf: Map<string, string>): Promise<Map<number, string[]>> {
  const system = "你是台灣團購店的商品分類員。對每個商品，從標籤清單挑出適用的標籤 code。每個輸入的 id 都要出現在輸出裡。\n" +
    TAG_RULES + "\n標籤清單：\n" + tagList;
  const user = products.map((p) =>
    `id=${p.id} 品名：${clean(p.name, 150)}` + (p.short_name && p.short_name !== p.name ? `｜短名：${clean(p.short_name, 80)}` : "") +
    (p.description ? `｜描述：${clean(String(p.description).replace(/\s+/g, " "), 150)}` : "")).join("\n");
  const out = await chatJson(system, user, TAGS_SCHEMA, 3000);
  const m = new Map<number, string[]>();
  for (const it of out?.items ?? []) m.set(Number(it.id), fixTags(Array.isArray(it.tags) ? it.tags.filter((c: any) => typeof c === "string") : [], groupOf));
  return m;
}

// ── 品類（20261101000220）：最通用的名詞，算「同品類開團頻率」用 ────────────────
const KIND_SCHEMA = {
  name: "kinds",
  schema: {
    type: "object",
    properties: {
      items: { type: "array", items: { type: "object", properties: { k: { type: "string" }, kind: { type: "string" } }, required: ["k", "kind"] } },
    },
    required: ["items"],
  },
};
const KIND_RULES = "每個商品給一個「品類」：最通用、最短的商品名詞（2～6 個字），去掉品牌、產地、口味、做法、份量、規格、行銷字。" +
  "同一種東西一定要用同一個詞；不同的東西不能合在一起（豬排和雞排是不同品類、豬排御用米是米）。看不出來是什麼就回空字串。\n" +
  "例：卡哇伊鮮嫩厚豬排→豬排；日式手工厚切炸豬排→豬排；大登豬排→豬排；鮮嫩無骨雞排→雞排；日本銀座杏子日式豬排御用米→米；" +
  "栗香地瓜→地瓜；台灣本產冷凍秋葵→秋葵；鮮蝦水晶餃→水晶餃；菇菇水晶餃→水晶餃；冰釀滷鴨翅→鴨翅；藤野洗衣機槽清潔粉→洗衣槽清潔劑；" +
  "韓國羅紋百搭襪→襪子；MIZU益生菌潤膚乳液→乳液；起司片→起司片。";

/** 品類標記的 key：item → i123、hot（市場熱門榜單）→ h123、product → p123 */
const kindKey = (r: { target: string; id: number }) => `${r.target === "item" ? "i" : r.target === "hot" ? "h" : "p"}${r.id}`;

async function labelKinds(rows: { target: string; id: number; name: string }[], vocab: string[]): Promise<Map<string, string>> {
  const system = "你是台灣團購店的商品品類員。" + KIND_RULES +
    (vocab.length ? "\n優先用下面已經用過的品類（意思一樣就用同一個詞）：" + vocab.join("、") : "");
  const key = kindKey;
  const user = rows.map((r) => `k=${key(r)} 品名：${clean(r.name, 120)}`).join("\n");
  const out = await chatJson(system, user, KIND_SCHEMA, 2500);
  const m = new Map<string, string>();
  for (const it of out?.items ?? []) {
    if (typeof it?.k === "string") m.set(it.k, clean(String(it.kind ?? "").replace(/\s/g, ""), 8));
  }
  return m;
}

// ── tick ───────────────────────────────────────────────────────────────────
async function tick(started: number) {
  const until = (ms: number) => Date.now() - started < ms;
  const stats: Record<string, any> = { posts: 0, items: 0, product_vectors: 0, item_vectors: 0, tagged: 0, kinds: 0, errors: [] as string[] };
  const err = (where: string, e: unknown) => { const m = `${where}: ${String((e as any)?.message ?? e).slice(0, 300)}`; console.error(m); stats.errors.push(m); };
  const tags = await loadTags();
  const tagList = tagText(tags);
  const groupOf = new Map(tags.map((t) => [t.code, t.tag_group]));

  // 1. 廠商貼文（使用者在等的，最先做；最多用 45 秒）
  while (until(45_000)) {
    const posts = await rpc("rpc_market_post_claim", { p_limit: 2 }) ?? [];
    if (!posts.length) break;
    for (const p of posts) {
      try {
        const items = await parsePost(p, tagList, groupOf);
        const n = await rpc("rpc_market_post_write", { p_post_id: p.post_id, p_items: items, p_error: null });
        stats.posts++; stats.items += Number(n) || 0;
      } catch (e) {
        err(`post ${p.post_id}`, e);
        await rpc("rpc_market_post_write", { p_post_id: p.post_id, p_items: [], p_error: String((e as any)?.message ?? e).slice(0, 400) }).catch(() => {});
      }
    }
  }

  // 2. 商品向量（品項比對要用，先補齊）
  let productBacklog = false;
  while (until(95_000)) {
    const rows = await rpc("rpc_ai_product_embed_claim", { p_limit: 50 }) ?? [];
    if (!rows.length) break;
    productBacklog = true;
    try {
      const vecs = await embed(rows.map((r: any) => clean(r.body, 1000)));
      const n = await rpc("rpc_ai_product_embed_write", {
        p_rows: rows.map((r: any, i: number) => ({ product_id: r.product_id, hash: r.hash, model: EMBED_MODEL, embedding: vecs[i] })),
      });
      stats.product_vectors += Number(n) || 0;
      productBacklog = rows.length === 50;
    } catch (e) { err("product vectors", e); break; }
  }

  // 2b. 市場熱門榜單向量（20261102000010）：一批最多幾百筆，跟商品向量一樣先補
  while (until(100_000)) {
    const rows = await rpc("rpc_ai_hot_embed_claim", { p_limit: 50 }) ?? [];
    if (!rows.length) break;
    try {
      const vecs = await embed(rows.map((r: any) => clean(r.body, 500)));
      const n = await rpc("rpc_ai_hot_embed_write", { p_rows: rows.map((r: any, i: number) => ({ id: r.id, embedding: vecs[i] })) });
      stats.hot_vectors = (stats.hot_vectors ?? 0) + (Number(n) || 0);
    } catch (e) { err("hot vectors", e); break; }
  }

  // 3. 品項向量＋比對（商品向量補齊之後才做，不然比對母體不完整）
  while (!productBacklog && until(105_000)) {
    const rows = await rpc("rpc_ai_item_embed_claim", { p_limit: 50 }) ?? [];
    if (!rows.length) break;
    try {
      const vecs = await embed(rows.map((r: any) => clean(r.body, 1000)));
      const n = await rpc("rpc_ai_item_embed_write", { p_rows: rows.map((r: any, i: number) => ({ item_id: r.item_id, embedding: vecs[i] })) });
      stats.item_vectors += Number(n) || 0;
    } catch (e) { err("item vectors", e); break; }
  }

  // 4. 新品貼標
  while (until(115_000)) {
    const products = await rpc("rpc_product_tag_llm_claim", { p_limit: 30 }) ?? [];
    if (!products.length) break;
    try {
      const m = await tagProducts(products, tagList, groupOf);
      for (const p of products) {
        const codes = m.get(Number(p.id)) ?? [];
        await rpc("rpc_product_tag_llm_write", { p_product_id: p.id, p_tag_codes: codes, p_error: null });
        if (codes.length) stats.tagged++;
      }
    } catch (e) {
      err("tagging", e);
      for (const p of products) await rpc("rpc_product_tag_llm_write", { p_product_id: p.id, p_tag_codes: [], p_error: String((e as any)?.message ?? e).slice(0, 300) }).catch(() => {});
      break;
    }
  }

  // 5. 品類（廠商品項優先、再補商品；用剩下的時間）
  let vocab: string[] | null = null;
  while (until(128_000)) {
    const rows = await rpc("rpc_ai_kind_claim", { p_limit: 40 }) ?? [];
    if (!rows.length) break;
    try {
      if (!vocab) vocab = ((await rpc("rpc_ai_kind_vocab", { p_limit: 300 })) ?? []).map((v: any) => String(v.kind));
      const m = await labelKinds(rows, vocab);
      const n = await rpc("rpc_ai_kind_write", {
        p_rows: rows.map((r: any) => ({ target: r.target, id: r.id, kind: m.get(kindKey(r)) ?? "" })),
      });
      stats.kinds += Number(n) || 0;
      for (const k of m.values()) if (k && !vocab.includes(k)) vocab.push(k);
    } catch (e) {
      err("kinds", e);
      await rpc("rpc_ai_kind_write", {
        p_rows: rows.map((r: any) => ({ target: r.target, id: r.id, kind: "", error: String((e as any)?.message ?? e).slice(0, 300) })),
      }).catch(() => {});
      break;
    }
  }

  stats.ms = Date.now() - started;
  return stats;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const ok = (CRON_SECRET && req.headers.get("x-line-note-secret") === CRON_SECRET) || (SERVICE_KEY && bearer === SERVICE_KEY);
  if (!ok) return json({ error: "unauthorized" }, 401);
  if (!CF_ACCOUNT || !CF_TOKEN) return json({ error: "缺 CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_AI_TOKEN（Supabase → Edge Functions → Secrets）" }, 500);

  const started = Date.now();
  let body: any = {};
  try { body = await req.json(); } catch { /* 空 body 當 tick */ }
  const action = String(body.action ?? "tick");
  try {
    if (action === "tick") return json(await tick(started));
    if (action === "probe") {
      const ids = (Array.isArray(body.post_ids) ? body.post_ids : []).map(Number).filter(Number.isInteger).slice(0, 10);
      const tagRows = await loadTags();
      const tagList = tagText(tagRows);
      const groupOf = new Map(tagRows.map((t) => [t.code, t.tag_group]));
      const posts = await rest(`line_note_market_posts?id=in.(${ids.join(",") || 0})&select=id,text,image_paths,line_note_communities(home_name)`);
      const out = [];
      for (const p of posts ?? []) {
        try {
          out.push({ post_id: p.id, items: await parsePost({ post_id: p.id, community: p.line_note_communities?.home_name, body: p.text, images: p.image_paths }, tagList, groupOf) });
        } catch (e) { out.push({ post_id: p.id, error: String((e as any)?.message ?? e) }); }
      }
      return json({ model: CHAT_MODEL, results: out, ms: Date.now() - started });
    }
    if (action === "kind_probe") {
      // 唯讀：給幾個品名看會標成什麼品類（不寫 DB）
      const names: string[] = Array.isArray(body.names) ? body.names.slice(0, 40) : [];
      const vocab = ((await rpc("rpc_ai_kind_vocab", { p_limit: 300 })) ?? []).map((v: any) => String(v.kind));
      const m = await labelKinds(names.map((n, i) => ({ target: "item", id: i, name: String(n) })), vocab);
      return json(names.map((n, i) => ({ name: n, kind: m.get(`i${i}`) ?? null })));
    }
    if (action === "embed_probe") {
      const texts = (Array.isArray(body.texts) ? body.texts : []).map((t: unknown) => clean(t, 1000)).slice(0, 20);
      const vecs = await embed(texts);
      return json({ model: EMBED_MODEL, dims: vecs[0]?.length ?? 0, n: vecs.length });
    }
    return json({ error: `unknown action ${action}` }, 400);
  } catch (e) {
    return json({ error: String((e as any)?.message ?? e) }, 500);
  }
});
