#!/usr/bin/env node
// 照後台「廠商網站」清單（vendor_sites，20261108000000）跑爬蟲 + 進候選池。
//
//   node scripts/vendor-sites-run.mjs [key ...] [--no-ingest] [--images main|all] [--limit N] [--dry]
//
// 不給 key = 所有啟用中的廠商，一家一家跑（同時打太多會被平台擋）。每家跑完把時間 / 筆數 / 錯誤回寫到清單。
// 帳密從資料庫讀，不用 vendors.json / .env；需要 SUPABASE_PROJECT_REF / SUPABASE_ACCESS_TOKEN / SUPABASE_URL。
// 在 Claude Code 雲端環境要 NODE_USE_ENV_PROXY=1（Node fetch 走 proxy）。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { sql } from "./lib/supabase-sql.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const keys = args.filter((a) => !a.startsWith("--") && !/^(main|all|\d+)$/.test(a));
const flag = (k) => { const i = args.indexOf(`--${k}`); return i >= 0 ? (args[i + 1]?.startsWith("--") ? true : args[i + 1] ?? true) : undefined; };
const dry = flag("dry") !== undefined;
const noIngest = flag("no-ingest") !== undefined;
const images = flag("images");
const limit = flag("limit");

const where = keys.length ? `AND key IN (${keys.map((k) => `'${k.replace(/'/g, "''")}'`).join(",")})` : "AND is_active";
const sites = sql(`SELECT id, key, name, supplier_id, platform, urls, email, password FROM vendor_sites WHERE TRUE ${where} ORDER BY key`);
if (!sites.length) { console.error("清單裡沒有符合的廠商"); process.exit(2); }
for (const k of keys) if (!sites.some((s) => s.key === k)) console.error(`找不到 ${k}（後台「廠商網站」頁沒有這個代號）`);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "vendor-sites-"));
const outRoot = path.join(here, "..", "tools", "vendor-scraper", "out");
const cli = path.join(here, "..", "tools", "vendor-scraper", "src", "cli.mjs");
const summary = [];

for (const s of sites) {
  const problems = [];
  if (!s.supplier_id) problems.push("沒對到供應商");
  if (!s.email || !s.password) problems.push("沒帳密");
  if (!s.urls?.length) problems.push("沒網址");
  if (problems.length) { console.error(`[${s.key}] 跳過：${problems.join("、")}`); summary.push({ key: s.key, skipped: problems.join("、") }); continue; }
  if (dry) { console.error(`[${s.key}] ${s.name}：${s.urls.length} 個網址`); continue; }

  // 一家一份 vendors.json + 帳密走環境變數（跟手動跑 cli 一樣）
  const vendorsFile = path.join(tmp, `${s.key}.json`);
  fs.writeFileSync(vendorsFile, JSON.stringify({ [s.key]: { name: s.name, platform: s.platform, urls: s.urls, supplier_id: s.supplier_id } }));
  const K = s.key.toUpperCase().replace(/[^A-Z0-9]/g, "_");
  const env = { ...process.env, [`VENDOR_${K}_EMAIL`]: s.email, [`VENDOR_${K}_PASSWORD`]: s.password };
  const cliArgs = [cli, "scrape", s.key, "--vendors", vendorsFile, "--out", outRoot];
  if (images) cliArgs.push("--images", String(images));
  if (limit) cliArgs.push("--limit", String(limit));
  console.error(`[${s.key}] 爬 ${s.name}（${s.urls.length} 個網址）`);
  const r = spawnSync(process.execPath, cliArgs, { env, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  process.stderr.write(r.stderr.split("\n").filter((l) => l && !/UNDICI|trace-warnings|詳細頁 \d|第 \d+ 頁/.test(l)).map((l) => l + "\n").join(""));
  let result = null;
  try { result = JSON.parse(r.stdout.trim().replace(/^[\s\S]*?(\[\s*\{)/, "$1"))[0]; } catch { /* 下面當失敗 */ }
  if (r.status !== 0 || !result || result.error) {
    const msg = result?.error || r.stderr.split("\n").filter(Boolean).slice(-3).join(" | ") || `exit ${r.status}`;
    sql(`SELECT public.rpc_vendor_site_mark_scraped(${s.id}, NULL, ${sqlStr(msg)})`);
    summary.push({ key: s.key, error: msg }); continue;
  }

  let ingest = null;
  if (!noIngest) {
    const ing = spawnSync(process.execPath, [path.join(here, "vendor-site-ingest.mjs"), path.join(result.out, "products.json"), "--no-images"],
      { env: process.env, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    process.stderr.write(ing.stderr.split("\n").filter((l) => l && !/^\s+(圖片|進料) \d/.test(l)).map((l) => l + "\n").join(""));
    try { ingest = JSON.parse(ing.stdout.trim()); } catch { ingest = { error: ing.stderr.split("\n").filter(Boolean).slice(-2).join(" | ") || `exit ${ing.status}` }; }
  }
  const err = ingest?.error ? `進料失敗：${ingest.error}` : null;
  sql(`SELECT public.rpc_vendor_site_mark_scraped(${s.id}, ${Number(result.count) || 0}, ${err ? sqlStr(err) : "NULL"})`);
  summary.push({ key: s.key, count: result.count, ingested: ingest ? { new: ingest.new, kept: ingest.kept, text_changed: ingest.text_changed } : null, error: err });
}
console.log(JSON.stringify(summary, null, 2));
if (summary.some((x) => x.error)) process.exit(1);

function sqlStr(s) { return `'${String(s).replace(/'/g, "''")}'`; }
