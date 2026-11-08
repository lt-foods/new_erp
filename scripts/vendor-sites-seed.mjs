#!/usr/bin/env node
// 第一次把 tools/vendor-scraper/vendors.json + .env 的廠商清單與帳密灌進 vendor_sites（20261108000000）。
// 一次性：之後清單以後台「廠商網站」頁為準。重跑是 upsert（依 key），已有的只補空欄、不覆蓋後台改過的。
//
//   node scripts/vendor-sites-seed.mjs [--dry]
//
// 密碼只從本機 .env 讀，不會進 git。需要 SUPABASE_PROJECT_REF / SUPABASE_ACCESS_TOKEN（Management API）。

import fs from "node:fs";
import { jsonLiteral, sql } from "./lib/supabase-sql.mjs";

const dry = process.argv.includes("--dry");
const vendors = JSON.parse(fs.readFileSync(new URL("../tools/vendor-scraper/vendors.json", import.meta.url), "utf8"));
const envText = fs.existsSync(new URL("../tools/vendor-scraper/.env", import.meta.url))
  ? fs.readFileSync(new URL("../tools/vendor-scraper/.env", import.meta.url), "utf8") : "";
const env = Object.fromEntries(envText.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"))
  .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
const envKey = (s) => s.toUpperCase().replace(/[^A-Z0-9]/g, "_");

const [{ tenant_id }] = sql("SELECT tenant_id FROM suppliers ORDER BY id LIMIT 1");
const rows = Object.entries(vendors).map(([key, v]) => {
  const K = envKey(key), P = envKey(v.platform || "shop2000");
  return {
    key, name: v.name || key, supplier_id: v.supplier_id ?? null, platform: v.platform || "shop2000",
    urls: v.urls ?? (v.url ? [v.url] : []),
    email: env[`VENDOR_${K}_EMAIL`] || env[`${P}_EMAIL`] || null,
    password: env[`VENDOR_${K}_PASSWORD`] || env[`${P}_PASSWORD`] || null,
  };
});
console.error(`${rows.length} 家 → tenant ${tenant_id}${dry ? "（dry run）" : ""}`);
for (const r of rows) console.error(`  ${r.key.padEnd(12)} ${r.name.padEnd(10)} supplier=${r.supplier_id ?? "-"} ${r.urls.length} 個網址 ${r.email ? "有帳密" : "沒帳密"}`);
if (dry) process.exit(0);

const res = sql(`
  INSERT INTO vendor_sites AS v (tenant_id, key, name, supplier_id, platform, urls, email, password)
  SELECT '${tenant_id}'::uuid, x->>'key', x->>'name', (x->>'supplier_id')::bigint, x->>'platform',
         ARRAY(SELECT jsonb_array_elements_text(x->'urls')), x->>'email', x->>'password'
    FROM jsonb_array_elements(${jsonLiteral(rows)}) x
  ON CONFLICT (tenant_id, key) DO UPDATE
     SET supplier_id = COALESCE(v.supplier_id, EXCLUDED.supplier_id),
         urls = CASE WHEN cardinality(v.urls) = 0 THEN EXCLUDED.urls ELSE v.urls END,
         email = COALESCE(v.email, EXCLUDED.email),
         password = COALESCE(v.password, EXCLUDED.password)
  RETURNING key, (xmax = 0) AS inserted`);
console.log(JSON.stringify({ inserted: res.filter((r) => r.inserted).length, updated: res.filter((r) => !r.inserted).length }));
