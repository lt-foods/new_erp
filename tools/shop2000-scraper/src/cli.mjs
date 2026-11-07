#!/usr/bin/env node
// shop2000：廠商商品爬蟲 CLI。
//
//   node src/cli.mjs login  [vendor]                 只測登入
//   node src/cli.mjs scrape [vendor ...] [--out out] [--no-detail] [--limit N] [--pages N] [--delay 400] [--raw]
//   node src/cli.mjs scrape --url <分類或商品網址>     不在 vendors.json 裡的也能抓
//
// vendor 是 vendors.json 的 key（不給 = 全部）。帳密從 .env 讀：SHOP2000_EMAIL / SHOP2000_PASSWORD，
// 要對某家用不同帳號 → SHOP2000_<KEY>_EMAIL / SHOP2000_<KEY>_PASSWORD。
// 輸出：out/<vendor>/<時間>/products.json、products.csv（+ --raw 時的 raw/*.html）。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Shop2000Client } from "./shop2000.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const args = { _: [], flags: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (key.startsWith("no-")) args.flags[key.slice(3)] = false;
      else if (next !== undefined && !next.startsWith("--")) { args.flags[key] = next; i++; }
      else args.flags[key] = true;
    } else args._.push(a);
  }
  return args;
}

function loadVendors() {
  return JSON.parse(fs.readFileSync(path.join(here, "..", "vendors.json"), "utf8"));
}

function credsFor(key) {
  const K = key.toUpperCase().replace(/[^A-Z0-9]/g, "_");
  const email = process.env[`SHOP2000_${K}_EMAIL`] || process.env.SHOP2000_EMAIL;
  const password = process.env[`SHOP2000_${K}_PASSWORD`] || process.env.SHOP2000_PASSWORD;
  if (!email || !password) {
    throw new Error(`缺帳密：請在 .env 設 SHOP2000_EMAIL / SHOP2000_PASSWORD（或 SHOP2000_${K}_EMAIL / _PASSWORD）`);
  }
  return { email, password };
}

function csvEscape(v) {
  if (v == null) return "";
  const s = Array.isArray(v)
    ? v.map((x) => (x != null && typeof x === "object" ? JSON.stringify(x) : String(x))).join(" | ")
    : typeof v === "object" ? JSON.stringify(v) : String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function writeCsv(file, rows, columns) {
  const lines = [columns.join(",")];
  for (const r of rows) lines.push(columns.map((c) => csvEscape(r[c])).join(","));
  fs.writeFileSync(file, "﻿" + lines.join("\n") + "\n", "utf8"); // BOM 給 Excel
}

const CSV_COLUMNS = [
  "vendor", "psn", "product_code", "name", "category", "subcategory",
  "price_general", "price_member", "price_original",
  "stock", "options", "short_desc", "tags", "free_shipping", "shipping_methods",
  "image", "url", "description",
];

function stamp() {
  return new Date().toISOString().replace(/[:T]/g, "-").slice(0, 16);
}

/** 把列表項 + 詳細頁合成一列 */
function mergeRow(vendorKey, vendorName, item, detail) {
  const options = detail?.spec_groups?.length
    ? detail.spec_groups.flatMap((g) => g.options.map((o) => `${o.name}${o.stock != null ? `=${o.stock}` : ""}`))
    : item.options.map((o) => `${o.name}${o.stock != null ? `=${o.stock}` : ""}`);
  return {
    vendor: vendorName,
    vendor_key: vendorKey,
    psn: item.psn,
    product_code: detail?.product_code ?? null,
    name: item.name || detail?.name,
    category: detail?.category ?? null,
    subcategory: detail?.subcategory ?? null,
    price_general: detail?.price_general ?? item.price_general,
    price_member: detail?.price_member ?? item.price_member,
    price_original: detail?.price_original ?? item.price_original,
    stock: detail?.stock ?? item.stock,
    options,
    spec: detail?.spec_groups ?? null,
    short_desc: detail?.short_desc || item.short_desc,
    tags: item.tags,
    free_shipping: detail?.free_shipping ?? null,
    shipping_methods: detail?.shipping_methods ?? [],
    payment_methods: detail?.payment_methods ?? [],
    image: detail?.image || item.image,
    images: detail?.images?.length ? detail.images : item.images,
    url: item.url,
    description: detail?.description ?? null,
    description_html: detail?.description_html ?? null,
  };
}

async function scrapeVendor(key, vendor, flags) {
  const log = (m) => console.error(`[${key}] ${m}`);
  const client = new Shop2000Client({ url: vendor.url, ...credsFor(key), delayMs: Number(flags.delay ?? 400), log });
  const outDir = path.join(flags.out || path.join(here, "..", "out"), key, stamp());
  fs.mkdirSync(outDir, { recursive: true });
  const rawDir = path.join(outDir, "raw");
  if (flags.raw) fs.mkdirSync(rawDir, { recursive: true });
  const saveRaw = (name, html) => flags.raw && fs.writeFileSync(path.join(rawDir, name), html, "utf8");

  const u = new URL(vendor.url);
  const m = u.pathname.match(/\/product\/(p?)(\d+)\/?$/);
  if (!m) throw new Error(`看不懂的網址（要 /product/<分類id> 或 /product/p<商品id>）：${vendor.url}`);

  let items;
  let category = null;
  if (m[1] === "p") {
    items = [{ psn: m[2], name: "", url: vendor.url, image: null, images: [], short_desc: "", tags: [], options: [], stock: null }];
  } else {
    const listing = await client.scrapeCategory(m[2], {
      maxPages: flags.pages ? Number(flags.pages) : Infinity,
      onRawPage: (html, p) => saveRaw(`list-${m[2]}-p${p}.html`, html),
    });
    category = listing.category;
    items = listing.items;
  }
  if (flags.limit) items = items.slice(0, Number(flags.limit));

  const rows = [];
  const wantDetail = flags.detail !== false;
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    let detail = null;
    if (wantDetail) {
      try {
        detail = await client.scrapeDetail(it.psn, { onRaw: (html) => saveRaw(`p${it.psn}.html`, html) });
        if (!detail.category && category) detail.category = category;
      } catch (e) {
        log(`詳細頁失敗 p${it.psn}：${e.message}`);
      }
      if ((i + 1) % 20 === 0 || i === items.length - 1) log(`詳細頁 ${i + 1}/${items.length}`);
    }
    rows.push(mergeRow(key, vendor.name, it, detail));
  }

  fs.writeFileSync(path.join(outDir, "products.json"), JSON.stringify({ vendor: vendor.name, key, url: vendor.url, category, scraped_at: new Date().toISOString(), count: rows.length, products: rows }, null, 2));
  writeCsv(path.join(outDir, "products.csv"), rows, CSV_COLUMNS);
  log(`完成：${rows.length} 筆 → ${outDir}`);
  return { outDir, rows };
}

async function main() {
  const { _: [cmd, ...rest], flags } = parseArgs(process.argv.slice(2));
  if (!cmd || cmd === "help" || flags.help) {
    console.log(fs.readFileSync(new URL(import.meta.url)).toString().split("\n").slice(1, 11).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    return;
  }
  const vendors = loadVendors();
  let targets;
  if (flags.url) {
    targets = [["adhoc", { name: new URL(flags.url).hostname, url: flags.url }]];
  } else {
    const keys = rest.length ? rest : Object.keys(vendors);
    targets = keys.map((k) => {
      if (!vendors[k]) throw new Error(`vendors.json 裡沒有 "${k}"，有的是：${Object.keys(vendors).join(", ")}`);
      return [k, vendors[k]];
    });
  }

  if (cmd === "login") {
    for (const [key, v] of targets) {
      const c = new Shop2000Client({ url: v.url, ...credsFor(key), log: (m) => console.error(`[${key}] ${m}`) });
      await c.login();
    }
    return;
  }
  if (cmd === "scrape") {
    const summary = [];
    for (const [key, v] of targets) {
      try {
        const r = await scrapeVendor(key, v, flags);
        summary.push({ vendor: v.name, count: r.rows.length, out: r.outDir });
      } catch (e) {
        console.error(`[${key}] 失敗：${e.message}`);
        summary.push({ vendor: v.name, error: e.message });
      }
    }
    console.log(JSON.stringify(summary, null, 2));
    if (summary.some((s) => s.error)) process.exit(1);
    return;
  }
  throw new Error(`未知指令：${cmd}`);
}

main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
