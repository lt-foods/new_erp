#!/usr/bin/env node
// 廠商網站商品 → 候選池（① 進料，來源 vendor_site；20261107000000）。
//
//   node scripts/vendor-site-ingest.mjs <products.json> [--supplier <id>] [--no-images] [--limit N] [--dry]
//
// 輸入是 tools/vendor-scraper 的 products.json（有 image_files 的話優先用本機檔，否則抓 image 網址）。
// 做三件事：
//   1. 主圖上傳到 storage bucket `products`：vendor-site/<vendor_key>/<psn>/1.jpg（已存在就跳過）
//   2. 把品名／價格／規格／說明組成貼文文字（第一行品名、第二行價格 — _market_post_quick_candidate 靠這個）
//   3. 呼叫 rpc_vendor_site_market_ingest(supplier_id, vendor_key, products)，每 50 筆一批
// 之後 market-ai 跟廠商 LINE 貼文一樣：拆品項 → 向量媒合 → 品類 → 預估（候選池頁的「預估」欄）。
//
// 需要：SUPABASE_PROJECT_REF / SUPABASE_ACCESS_TOKEN（Management API 跑 SQL）、SUPABASE_URL、
//       SUPABASE_SERVICE_ROLE_KEY（上傳圖片；沒給就從 Management API 的 api-keys 拿）。
// supplier_id 從 tools/vendor-scraper/vendors.json 的 supplier_id 讀，或 --supplier 指定。

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { jsonLiteral, sql } from "./lib/supabase-sql.mjs";
// 貼文組法、「這個分類還能不能下單」跟每天自動跑（vendor-sites-run.mjs）共用
import { isSellable, payloadOf } from "./lib/vendor-site-payload.mjs";

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith("--"));
const flag = (k) => { const i = args.indexOf(`--${k}`); return i >= 0 ? (args[i + 1]?.startsWith("--") ? true : args[i + 1] ?? true) : undefined; };
if (!file) { console.error("用法：node scripts/vendor-site-ingest.mjs <products.json> [--supplier <id>] [--no-images] [--limit N] [--dry] [--include-all]"); process.exit(2); }

const data = JSON.parse(fs.readFileSync(file, "utf8"));
const vendorKey = data.key;
if (!vendorKey) throw new Error("products.json 缺 key（vendor key）");
let supplierId = Number(flag("supplier"));
if (!supplierId) {
  const vendors = JSON.parse(fs.readFileSync(new URL("../tools/vendor-scraper/vendors.json", import.meta.url), "utf8"));
  supplierId = Number(vendors[vendorKey]?.supplier_id);
}
if (!supplierId) throw new Error(`不知道 ${vendorKey} 對應哪個 supplier：vendors.json 加 supplier_id 或用 --supplier`);

const CA = fs.existsSync("/root/.ccr/ca-bundle.crt") ? ["--cacert", "/root/.ccr/ca-bundle.crt"] : [];
const SUPABASE_URL = process.env.SUPABASE_URL;
let serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

function curl(extra, { input } = {}) {
  return execFileSync("curl", ["-sS", ...CA, ...extra], { input, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function loadServiceKey() {
  if (serviceKey && serviceKey.length > 100) return serviceKey;
  const ref = process.env.SUPABASE_PROJECT_REF, token = process.env.SUPABASE_ACCESS_TOKEN;
  const out = curl(["-H", `Authorization: Bearer ${token}`, `https://api.supabase.com/v1/projects/${ref}/api-keys?reveal=true`]);
  const row = JSON.parse(out).find((k) => k.name === "service_role");
  if (!row) throw new Error("api-keys 裡找不到 service_role");
  serviceKey = row.api_key;
  return serviceKey;
}

/** 上傳一張圖到 products bucket，回 storage path；已存在就直接回路徑 */
function uploadImage(product, idx = 1) {
  const psn = String(product.psn);
  const localRel = product.image_files?.[idx - 1];
  const localAbs = localRel ? path.resolve(path.dirname(file), localRel) : null;
  const srcUrl = idx === 1 ? product.image : product.images?.[idx - 1];
  if (!localAbs && !srcUrl) return null;
  const ext = ((localAbs || srcUrl).match(/\.(jpe?g|png|gif|webp)(?:$|\?)/i)?.[1] || "jpg").toLowerCase().replace("jpeg", "jpg");
  const storagePath = `vendor-site/${vendorKey}/${psn}/${idx}.${ext}`;
  const key = loadServiceKey();
  const head = curl(["-o", "/dev/null", "-w", "%{http_code}", "-I", `${SUPABASE_URL}/storage/v1/object/public/products/${storagePath}`]);
  if (head === "200") return storagePath;
  let body;
  if (localAbs && fs.existsSync(localAbs)) body = fs.readFileSync(localAbs);
  else {
    const tmp = path.join(process.env.TMPDIR || "/tmp", `vsi-${psn}-${idx}`);
    curl(["-L", "-o", tmp, "-A", "Mozilla/5.0", srcUrl]);
    body = fs.readFileSync(tmp); fs.unlinkSync(tmp);
  }
  if (!body?.length) return null;
  if (body.length > 5 * 1024 * 1024) { console.error(`  跳過 ${storagePath}：${(body.length / 1048576).toFixed(1)}MB 超過 bucket 上限`); return null; }
  const mime = { jpg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp" }[ext] || "image/jpeg";
  const out = curl(["-X", "POST", `${SUPABASE_URL}/storage/v1/object/products/${storagePath}`,
    "-H", `apikey: ${key}`, "-H", `Authorization: Bearer ${key}`, "-H", `Content-Type: ${mime}`, "-H", "x-upsert: true",
    "--data-binary", "@-"], { input: body });
  const res = JSON.parse(out);
  if (res.error || res.statusCode) throw new Error(`上傳 ${storagePath} 失敗：${res.message || out}`);
  return storagePath;
}

const limit = Number(flag("limit")) || Infinity;
const withImages = flag("no-images") === undefined;
const dry = flag("dry") !== undefined;
const includeAll = flag("include-all") !== undefined;
const sellable = includeAll ? data.products
  : data.products.filter(isSellable);
if (sellable.length < data.products.length) {
  console.error(`[${vendorKey}] 跳過 ${data.products.length - sellable.length} 筆（分類已下架 / 已過收單日；要全進加 --include-all）`);
}
const products = sellable.slice(0, limit);
console.error(`[${vendorKey}] ${products.length} 筆 → supplier ${supplierId}${dry ? "（dry run）" : ""}`);

const payload = [];
let uploaded = 0, imgFail = 0;
for (let i = 0; i < products.length; i++) {
  const p = products[i];
  let image_paths = [];
  if (withImages && !dry) {
    try { const sp = uploadImage(p, 1); if (sp) { image_paths = [sp]; uploaded++; } }
    catch (e) { imgFail++; console.error(`  圖片 p${p.psn}：${e.message}`); }
  }
  payload.push(payloadOf(p, data.scraped_at, image_paths));
  if ((i + 1) % 50 === 0 || i === products.length - 1) console.error(`  圖片 ${i + 1}/${products.length}（上傳/已有 ${uploaded}、失敗 ${imgFail}）`);
}

if (dry) { console.log(JSON.stringify(payload.slice(0, 2), null, 2)); process.exit(0); }

const totals = { kept: 0, new: 0, text_changed: 0 };
for (let i = 0; i < payload.length; i += 50) {
  const batch = payload.slice(i, i + 50);
  const [row] = sql(`SELECT public.rpc_vendor_site_market_ingest(${supplierId}, '${vendorKey}', ${jsonLiteral(batch)}) AS r`);
  for (const k of Object.keys(totals)) totals[k] += Number(row.r[k] || 0);
  console.error(`  進料 ${Math.min(i + 50, payload.length)}/${payload.length}`);
}
console.log(JSON.stringify({ vendor: vendorKey, supplier_id: supplierId, images_uploaded: uploaded, images_failed: imgFail, ...totals }, null, 2));
