#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// 商品自動貼標：給「Claude Code 排程任務」用的讀寫工具（20261101000020）。
//
// 為什麼不是 Edge Function：老闆只有 Claude Code 訂閱、沒有 API key，訂閱不能放進
// Supabase 函式。所以改由每天一次的 Claude Code 排程 session 當分類員：
//   1. node scripts/product-tag-routine.mjs status          → 還有幾個沒標籤
//   2. node scripts/product-tag-routine.mjs claim 40        → 領一批商品＋標籤清單＋分類規則（JSON）
//   3. （session 自己判斷每個商品的標籤，寫成 [{ "id": 123, "tags": ["meat","frozen"] }, ...]）
//   4. node scripts/product-tag-routine.mjs write <file>    → 寫回
//   5. node scripts/product-tag-routine.mjs release <id,…>  → 這次來不及處理 / 出錯的退回，下次排程重撿
//
// 這支只會呼叫兩支 RPC（rpc_product_tag_llm_claim / rpc_product_tag_llm_write），
// 不收任意 SQL；id 必須是整數、標籤 code 必須是 [a-z_]+，其餘一律拒絕。
// 所以可以放心在權限設定裡把這支整支放行（Bash(node scripts/product-tag-routine.mjs:*)）。
//
// 走 Supabase Management API（直連 pooler 在這個環境被擋，見 CLAUDE.md），
// 需要環境變數 SUPABASE_ACCESS_TOKEN、SUPABASE_PROJECT_REF。
// ─────────────────────────────────────────────────────────────────────────────

import { execFileSync } from "node:child_process";
import fs from "node:fs";

const RULES = [
  "只能用 tags 清單裡的 code，不要發明新的。",
  "每個商品至少 1 個「生鮮」「食品」或「非食品」群的標籤；食品可同時給大類和子類（例如 prepared + prep_dumpling）。",
  "溫層（frozen / chilled / ambient）只給食品與生鮮，以商品的 storage_type 為準：frozen→frozen、refrigerated→chilled、room_temp→ambient；storage_type 是空的才看品名（寫明冷凍→frozen、冷藏/鮮奶/豆腐→chilled）。非食品不給溫層。",
  "屬性（jp / kr / gift）從品名看得出來才給（日本／韓國／禮盒）。",
  "品名看不出是什麼（例如只有貨號）就不要硬貼：tags 給空陣列（30 天後才會再撿）。",
  "只有「這次來不及處理 / 出錯」才用 release（下次排程立刻重撿）。",
];

function sql(query) {
  const ref = process.env.SUPABASE_PROJECT_REF;
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!ref || !token) throw new Error("缺環境變數 SUPABASE_PROJECT_REF / SUPABASE_ACCESS_TOKEN");
  const args = [
    "-sS", "-X", "POST",
    `https://api.supabase.com/v1/projects/${ref}/database/query`,
    "-H", `Authorization: Bearer ${token}`,
    "-H", "Content-Type: application/json",
    "--data-binary", "@-",
  ];
  if (fs.existsSync("/root/.ccr/ca-bundle.crt")) args.unshift("--cacert", "/root/.ccr/ca-bundle.crt");
  const out = execFileSync("curl", args, { input: JSON.stringify({ query }), encoding: "utf8" });
  const body = JSON.parse(out);
  if (!Array.isArray(body)) throw new Error(`SQL 失敗：${body.message ?? out.slice(0, 300)}`);
  return body;
}

function parseIds(list) {
  const ids = String(list ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (ids.length === 0 || !ids.every((s) => /^\d+$/.test(s))) throw new Error("id 必須是逗號分隔的整數");
  return ids.map(Number);
}

const [cmd, arg] = process.argv.slice(2);

try {
  if (cmd === "status") {
    const [r] = sql(`
      SELECT count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)) AS untagged,
             count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)
                                AND p.status <> 'discontinued'
                                AND (p.tag_llm_at IS NULL OR p.tag_llm_at < now() - INTERVAL '30 days')) AS claimable,
             count(*) AS products
        FROM products p`);
    console.log(JSON.stringify(r));
  } else if (cmd === "claim") {
    const n = Math.min(Math.max(Number(arg) || 40, 1), 60);
    const claimed = sql(`SELECT id, name, short_name, description FROM public.rpc_product_tag_llm_claim(${n})`);
    // 溫層以商品主檔的 storage_type 為準（肉品 158/192 是 frozen，從品名猜會猜成常溫）
    const st = claimed.length
      ? new Map(sql(`SELECT id, storage_type::text AS storage_type FROM products WHERE id IN (${claimed.map((p) => Number(p.id)).join(",")})`)
          .map((r) => [Number(r.id), r.storage_type]))
      : new Map();
    const products = claimed.map((p) => ({ ...p, storage_type: st.get(Number(p.id)) ?? null }));
    const tags = sql(`SELECT code, name, tag_group FROM product_tags WHERE is_active ORDER BY tag_group, sort, id`);
    console.log(JSON.stringify({ rules: RULES, tags, products }, null, 1));
  } else if (cmd === "write") {
    if (!arg || !fs.existsSync(arg)) throw new Error("用法：write <json 檔>，內容 [{\"id\":123,\"tags\":[\"meat\"]}]");
    const rows = JSON.parse(fs.readFileSync(arg, "utf8"));
    if (!Array.isArray(rows) || rows.length === 0) throw new Error("JSON 必須是非空陣列");
    const stmts = rows.map((r) => {
      if (!Number.isInteger(r.id)) throw new Error(`id 不是整數：${JSON.stringify(r)}`);
      const codes = Array.isArray(r.tags) ? r.tags : [];
      if (!codes.every((c) => typeof c === "string" && /^[a-z_]+$/.test(c))) throw new Error(`標籤 code 不合法：${JSON.stringify(r)}`);
      const arr = codes.length ? `ARRAY[${codes.map((c) => `'${c}'`).join(",")}]::text[]` : "ARRAY[]::text[]";
      return `SELECT ${r.id} AS id, public.rpc_product_tag_llm_write(${r.id}, ${arr}, NULL) AS written`;
    });
    const res = sql(stmts.join("\nUNION ALL\n"));
    const tagged = res.filter((x) => x.written > 0).length;
    console.log(JSON.stringify({ rows: res.length, tagged, empty: res.length - tagged }));
  } else if (cmd === "release") {
    const ids = parseIds(arg);
    const res = sql(ids.map((id) =>
      `SELECT ${id} AS id, public.rpc_product_tag_llm_write(${id}, ARRAY[]::text[], 'released by routine')`).join("\nUNION ALL\n"));
    console.log(JSON.stringify({ released: res.length }));
  } else {
    console.error("用法：status | claim [n] | write <json 檔> | release <id,id,…>");
    process.exit(2);
  }
} catch (e) {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
}
