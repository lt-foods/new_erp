#!/usr/bin/env node
// 照後台「廠商網站」清單（vendor_sites，20261108000000）爬廠商網站，新上架的商品進候選池。
//
//   node scripts/vendor-sites-run.mjs [key ...] [--all-detail] [--limit N] [--dry]
//
// 每家：先查已經進過候選池的商品代號 → 爬蟲列表照抓、只抓「新的」詳細頁 → 新的進候選池 →
// 回寫清單的「上次抓取」時間 / 列表筆數 / 錯誤。不給 key = 所有啟用中的，一家一家跑（同時打太多會被平台擋）。
// --all-detail：已在候選池的也重抓詳細頁（不重新進料，文字沒變不會重解析）。
//
// 連資料庫兩種方式，有哪個用哪個：
//   - SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY：走 REST / RPC（GitHub Actions 每天自動跑用這個，見 .github/workflows/vendor-sites-daily.yml）
//   - SUPABASE_PROJECT_REF + SUPABASE_ACCESS_TOKEN：走 Management API（本機 / Claude Code 環境）
// 在 Claude Code 雲端環境要 NODE_USE_ENV_PROXY=1（Node fetch 走 proxy）。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { isSellable, payloadOf } from "./lib/vendor-site-payload.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (k) => { const i = args.indexOf(`--${k}`); return i >= 0 ? (args[i + 1]?.startsWith("--") ? true : args[i + 1] ?? true) : undefined; };
const valueFlags = new Set(["limit"]);
const keys = args.filter((a, i) => !a.startsWith("--") && !(i > 0 && valueFlags.has(args[i - 1]?.replace(/^--/, ""))));
const dry = flag("dry") !== undefined;
const allDetail = flag("all-detail") !== undefined;
const limit = flag("limit");

const db = await connect();
const sites = await db.listSites(keys);
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

  const known = allDetail ? [] : await db.knownPsns(s.key);
  console.error(`[${s.key}] ${s.name}：${s.urls.length} 個網址，候選池已有 ${known.length} 筆`);
  if (dry) continue;

  // 一家一份清單檔 + 帳密走環境變數（跟手動跑 cli 一樣）
  const vendorsFile = path.join(tmp, `${s.key}.json`);
  fs.writeFileSync(vendorsFile, JSON.stringify({ [s.key]: { name: s.name, platform: s.platform, urls: s.urls, supplier_id: s.supplier_id } }));
  const knownFile = path.join(tmp, `${s.key}.known.json`);
  fs.writeFileSync(knownFile, JSON.stringify(known));
  const K = s.key.toUpperCase().replace(/[^A-Z0-9]/g, "_");
  const env = { ...process.env, [`VENDOR_${K}_EMAIL`]: s.email, [`VENDOR_${K}_PASSWORD`]: s.password };
  const cliArgs = [cli, "scrape", s.key, "--vendors", vendorsFile, "--out", outRoot];
  if (!allDetail) cliArgs.push("--skip-psns", knownFile);
  if (limit) cliArgs.push("--limit", String(limit));
  const r = spawnSync(process.execPath, cliArgs, { env, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  process.stderr.write(r.stderr.split("\n").filter((l) => l && !/UNDICI|trace-warnings|詳細頁 \d|第 \d+ 頁/.test(l)).map((l) => l + "\n").join(""));
  let result = null;
  try { result = JSON.parse(r.stdout.trim().replace(/^[\s\S]*?(\[\s*\{)/, "$1"))[0]; } catch { /* 下面當失敗 */ }
  if (r.status !== 0 || !result || result.error) {
    const msg = result?.error || r.stderr.split("\n").filter(Boolean).slice(-3).join(" | ") || `exit ${r.status}`;
    await db.markScraped(s.id, null, msg);
    summary.push({ key: s.key, error: msg });
    continue;
  }

  // 新的進候選池（已下架 / 過期分類不進）
  let ingest = { kept: 0, new: 0, text_changed: 0 };
  let err = null;
  try {
    const data = JSON.parse(fs.readFileSync(path.join(result.out, "products.json"), "utf8"));
    const knownSet = new Set(known);
    const payload = data.products.filter((p) => isSellable(p) && (allDetail ? true : !knownSet.has(String(p.psn))))
      .map((p) => payloadOf(p, data.scraped_at));
    for (let i = 0; i < payload.length; i += 50) {
      const t = await db.ingest(s.supplier_id, s.key, payload.slice(i, i + 50));
      for (const k of Object.keys(ingest)) ingest[k] += Number(t?.[k] || 0);
    }
  } catch (e) { err = `進料失敗：${e.message}`; }
  await db.markScraped(s.id, result.listed ?? result.count, err);
  console.error(`[${s.key}] 列表 ${result.listed ?? "?"} 筆、新 ${ingest.new} 筆進候選池${err ? `、${err}` : ""}`);
  summary.push({ key: s.key, listed: result.listed, new: ingest.new, text_changed: ingest.text_changed, error: err });
}
console.log(JSON.stringify(summary, null, 2));
if (summary.some((x) => x.error)) process.exit(1);

// ── 資料庫連線：REST（service_role）或 Management API ────────────────────────
async function connect() {
  const url = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (url && key && key.length > 40) {
    const h = { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
    const get = async (p, headers = {}) => {
      const res = await fetch(`${url}/rest/v1/${p}`, { headers: { ...h, ...headers } });
      if (!res.ok) throw new Error(`GET ${p.slice(0, 60)} → ${res.status} ${(await res.text()).slice(0, 200)}`);
      return res.json();
    };
    const rpc = async (name, body) => {
      const res = await fetch(`${url}/rest/v1/rpc/${name}`, { method: "POST", headers: h, body: JSON.stringify(body) });
      const t = await res.text();
      if (!res.ok) throw new Error(`rpc ${name} → ${res.status} ${t.slice(0, 200)}`);
      return t ? JSON.parse(t) : null;
    };
    return {
      async listSites(ks) {
        const f = ks.length ? `key=in.(${ks.map(encodeURIComponent).join(",")})` : "is_active=eq.true";
        return get(`vendor_sites?select=id,key,name,supplier_id,platform,urls,email,password&${f}&order=key`);
      },
      async knownPsns(k) {
        const out = [];
        for (let from = 0; ; from += 1000) {   // PostgREST 一次最多 1000 列，分頁拿
          const rows = await get(`line_note_market_posts?select=line_post_id&source=eq.vendor_site&line_post_id=like.${encodeURIComponent(`web:${k}:*`)}&order=id`,
                                 { Range: `${from}-${from + 999}` });
          for (const r of rows) out.push(r.line_post_id.slice(`web:${k}:`.length));
          if (rows.length < 1000) break;
        }
        return out;
      },
      ingest: (sid, k, products) => rpc("rpc_vendor_site_market_ingest", { p_supplier_id: sid, p_vendor_key: k, p_products: products }),
      markScraped: (id, count, error) => rpc("rpc_vendor_site_mark_scraped", { p_id: id, p_count: count, p_error: error }),
    };
  }
  const { sql, jsonLiteral } = await import("./lib/supabase-sql.mjs");
  const str = (s) => (s == null ? "NULL" : `'${String(s).replace(/'/g, "''")}'`);
  return {
    async listSites(ks) {
      const where = ks.length ? `key IN (${ks.map(str).join(",")})` : "is_active";
      return sql(`SELECT id, key, name, supplier_id, platform, urls, email, password FROM vendor_sites WHERE ${where} ORDER BY key`);
    },
    async knownPsns(k) {
      return sql(`SELECT substr(line_post_id, ${`web:${k}:`.length + 1}) AS psn FROM line_note_market_posts
                   WHERE source = 'vendor_site' AND line_post_id LIKE ${str(`web:${k}:%`)}`).map((r) => r.psn);
    },
    async ingest(sid, k, products) {
      const [row] = sql(`SELECT public.rpc_vendor_site_market_ingest(${Number(sid)}, ${str(k)}, ${jsonLiteral(products)}) AS r`);
      return row.r;
    },
    async markScraped(id, count, error) {
      sql(`SELECT public.rpc_vendor_site_mark_scraped(${Number(id)}, ${count == null ? "NULL" : Number(count)}, ${str(error)})`);
    },
  };
}
