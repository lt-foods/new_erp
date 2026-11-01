#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// 廠商記事本解析：給「Claude Code 排程任務」用的讀寫工具（20261101000040）。
//
// worker 每天台北 01:13 把勾了「爬選品」的廠商群組貼文存進 line_note_market_posts，
// 這支讓排程 session 當解析員：
//   1. node scripts/supplier-note-routine.mjs status          → 還有幾篇沒解析
//   2. node scripts/supplier-note-routine.mjs claim 20        → 領一批貼文＋解析規則＋標籤清單（JSON）
//   3. （session 自己把每篇拆成商品，寫成 [{ "post_id": 1, "items": [ {...} ] }, ...]）
//   4. node scripts/supplier-note-routine.mjs write <file>    → 寫回；DB 端會順便比對「我賣過最像的 5 個」
//   5. node scripts/supplier-note-routine.mjs release <id,…>  → 這次來不及處理 / 出錯的退回，下次排程重撿
//
// 只呼叫 rpc_market_post_claim / rpc_market_post_write，不收任意 SQL。
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import { jsonLiteral, parseIds, sql } from "./lib/supabase-sql.mjs";

const RULES = [
  "一篇貼文可能有好幾個商品，每個商品一筆。不是在賣商品的貼文（公告、休假、匯款、出貨通知、徵人）→ items 給空陣列。",
  "item_name：貼文裡的商品名，去掉表情符號與行銷字（免運、爆款、限時、🔥）。",
  "norm_name：標準繁體中文核心品名，用空白分隔 2～4 個關鍵詞；簡體轉繁體、英文翻中文、去掉品牌行銷字與規格。例：「Shine Muscat 晴王葡萄 2kg」→「麝香葡萄 晴王」、「老師傅岡山羊肉爐」→「岡山 羊肉爐」。這欄用來比對我們賣過的商品，寫準一點。",
  "price：給團購主的價格（團購價／批價／優惠價／成本價）的數字，不含 $ 和逗號；有好幾個價格取最主要那一個；看不出來給 null。price_text 放原文那一小段。",
  "spec：規格（1000克、10入、2kg/箱）。deadline_text：截止或出貨時間的原文，沒有就省略。",
  "tags：從 tags 清單挑 code，每個商品至少 1 個「生鮮」「食品」或「非食品」群的標籤；溫層（frozen / chilled / ambient）只有貼文寫明才給；日本 / 韓國 / 禮盒看得出來就給 jp / kr / gift。",
];

const MAXLEN = { item_name: 200, norm_name: 100, price_text: 200, spec: 200, deadline_text: 200 };

function cleanItem(it, postId) {
  if (!it || typeof it !== "object") throw new Error(`post ${postId} 的 items 裡有不是物件的東西`);
  const out = {};
  for (const [k, max] of Object.entries(MAXLEN)) {
    if (it[k] == null) continue;
    if (typeof it[k] !== "string") throw new Error(`post ${postId} 的 ${k} 必須是字串`);
    out[k] = it[k].slice(0, max);
  }
  if (!out.item_name || !out.item_name.trim()) throw new Error(`post ${postId} 有商品沒有 item_name`);
  if (it.price != null) {
    const n = Number(it.price);
    if (!Number.isFinite(n) || n < 0) throw new Error(`post ${postId} 的 price 不是數字：${it.price}`);
    out.price = n;
  }
  const tags = Array.isArray(it.tags) ? it.tags : [];
  if (!tags.every((c) => typeof c === "string" && /^[a-z_]+$/.test(c))) throw new Error(`post ${postId} 的標籤 code 不合法`);
  out.tags = tags;
  return out;
}

const [cmd, arg] = process.argv.slice(2);

try {
  if (cmd === "status") {
    const [r] = sql(`
      SELECT count(*) FILTER (WHERE parsed_at IS NULL) AS unparsed,
             count(*) FILTER (WHERE parse_error IS NOT NULL) AS with_error,
             count(*) AS posts,
             (SELECT count(*) FROM line_note_market_items) AS items
        FROM line_note_market_posts`);
    console.log(JSON.stringify(r));
  } else if (cmd === "claim") {
    const n = Math.min(Math.max(Number(arg) || 20, 1), 40);
    const posts = sql(`SELECT * FROM public.rpc_market_post_claim(${n})`);
    const tags = posts.length ? sql(`SELECT code, name, tag_group FROM product_tags WHERE is_active ORDER BY tag_group, sort, id`) : [];
    console.log(JSON.stringify({ rules: RULES, tags, posts }, null, 1));
  } else if (cmd === "write") {
    if (!arg || !fs.existsSync(arg)) throw new Error("用法：write <json 檔>，內容 [{\"post_id\":1,\"items\":[{\"item_name\":\"…\"}]}]");
    const rows = JSON.parse(fs.readFileSync(arg, "utf8"));
    if (!Array.isArray(rows) || rows.length === 0) throw new Error("JSON 必須是非空陣列");
    const payload = rows.map((r) => {
      if (!Number.isInteger(r?.post_id)) throw new Error(`post_id 不是整數：${JSON.stringify(r).slice(0, 100)}`);
      const items = Array.isArray(r.items) ? r.items.map((it) => cleanItem(it, r.post_id)) : [];
      return { post_id: r.post_id, items };
    });
    const res = sql(`SELECT (e->>'post_id')::bigint AS post_id,
                            public.rpc_market_post_write((e->>'post_id')::bigint, e->'items', NULL) AS items
                       FROM jsonb_array_elements(${jsonLiteral(payload)}) e`);
    const items = res.reduce((s, x) => s + Number(x.items || 0), 0);
    console.log(JSON.stringify({ posts: res.length, items, not_products: res.filter((x) => !Number(x.items)).length }));
  } else if (cmd === "release") {
    const ids = parseIds(arg);
    const res = sql(ids.map((id) =>
      `SELECT ${id} AS id, public.rpc_market_post_write(${id}, '[]'::jsonb, 'released by routine')`).join("\nUNION ALL\n"));
    console.log(JSON.stringify({ released: res.length }));
  } else {
    console.error("用法：status | claim [n] | write <json 檔> | release <id,id,…>");
    process.exit(2);
  }
} catch (e) {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
}
