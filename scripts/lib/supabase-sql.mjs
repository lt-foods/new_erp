// 給排程腳本用的 SQL 呼叫：走 Supabase Management API（直連 pooler 在這個環境被擋，見 CLAUDE.md）。
// 需要環境變數 SUPABASE_ACCESS_TOKEN、SUPABASE_PROJECT_REF。用 curl 是因為 Node 的 fetch 不吃 HTTPS_PROXY。
import { execFileSync } from "node:child_process";
import fs from "node:fs";

export function sql(query) {
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
  const out = execFileSync("curl", args, { input: JSON.stringify({ query }), encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const body = JSON.parse(out);
  if (!Array.isArray(body)) throw new Error(`SQL 失敗：${body.message ?? out.slice(0, 300)}`);
  return body;
}

/** 把 JSON 安全地塞進 SQL：用隨機 dollar-quote 標籤，內容裡碰巧有同樣標籤就換一個 */
export function jsonLiteral(value) {
  const text = JSON.stringify(value);
  for (;;) {
    const tag = `$j${Math.random().toString(36).slice(2, 10)}$`;
    if (!text.includes(tag)) return `${tag}${text}${tag}::jsonb`;
  }
}

export function parseIds(list) {
  const ids = String(list ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (ids.length === 0 || !ids.every((s) => /^\d+$/.test(s))) throw new Error("id 必須是逗號分隔的整數");
  return ids.map(Number);
}
