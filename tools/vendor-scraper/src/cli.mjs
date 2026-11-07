#!/usr/bin/env node
// vendor-scraper：廠商網站商品爬蟲 CLI（登入 → 抓分類/商品頁 → JSON / CSV）。
//
//   node src/cli.mjs vendors                         列出 vendors.json 的廠商與網址
//   node src/cli.mjs login  [vendor ...]             只測登入
//   node src/cli.mjs scrape [vendor ...] [--out out] [--no-detail] [--limit N] [--pages N] [--delay 400] [--raw]
//   node src/cli.mjs scrape --url <網址> [--vendor key] [--platform shop2000]   臨時抓一個不在清單裡的頁面
//
// vendor 是 vendors.json 的 key（不給 = 全部）。每家可以列多個網址（urls），一次全抓。
// 帳密從 .env 讀：VENDOR_<KEY>_EMAIL / VENDOR_<KEY>_PASSWORD，沒有就退回 <PLATFORM>_EMAIL / <PLATFORM>_PASSWORD。
// 輸出：out/<vendor>/<時間>/products.json、products.csv（+ --raw 時的 raw/*.html）。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { platforms, detectPlatform } from "./platforms/index.mjs";
import { writeVendorOutput } from "./output.mjs";

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

function envKey(s) {
  return s.toUpperCase().replace(/[^A-Z0-9]/g, "_");
}

function credsFor(key, platformName) {
  const K = envKey(key);
  const P = envKey(platformName);
  const email = process.env[`VENDOR_${K}_EMAIL`] || process.env[`${P}_EMAIL`];
  const password = process.env[`VENDOR_${K}_PASSWORD`] || process.env[`${P}_PASSWORD`];
  if (!email || !password) {
    throw new Error(`缺帳密：請在 .env 設 VENDOR_${K}_EMAIL / VENDOR_${K}_PASSWORD（或平台共用的 ${P}_EMAIL / ${P}_PASSWORD）`);
  }
  return { email, password };
}

/** vendors.json 一筆 → { key, name, platform, urls } */
function resolveVendor(key, v, flags) {
  const urls = v.urls ?? (v.url ? [v.url] : []);
  if (!urls.length) throw new Error(`${key}：vendors.json 沒有 url / urls`);
  const platform = platforms[flags.platform || v.platform] ?? detectPlatform(urls[0]);
  if (!platform) throw new Error(`${key}：認不出平台，請在 vendors.json 填 "platform"（有的：${Object.keys(platforms).join(", ")}）`);
  return { key, name: v.name || key, platform, urls };
}

async function scrapeVendor(vendor, flags) {
  const log = (m) => console.error(`[${vendor.key}] ${m}`);
  const outRoot = flags.out || path.join(here, "..", "out");
  const rawFiles = [];
  const rows = [];
  const categories = [];
  let client = null;
  let clientOrigin = null;

  for (const url of vendor.urls) {
    // 同一家的網址通常同一個 origin，cookie 可共用；換 origin 就重建 client
    const origin = new URL(url).origin;
    if (!client || origin !== clientOrigin) {
      client = vendor.platform.createClient({ url, ...credsFor(vendor.key, vendor.platform.name), delayMs: Number(flags.delay ?? 400), log });
      clientOrigin = origin;
    }
    log(`抓 ${url}`);
    const r = await client.scrape(url, {
      maxPages: flags.pages ? Number(flags.pages) : Infinity,
      limit: flags.limit ? Number(flags.limit) : undefined,
      detail: flags.detail !== false,
      onRaw: flags.raw ? (name, html) => rawFiles.push([name, html]) : undefined,
    });
    if (r.category) categories.push({ url, category: r.category, count: r.items.length });
    for (const row of r.items) rows.push({ vendor: vendor.name, vendor_key: vendor.key, source_url: url, ...row });
  }

  // 同一個商品掛在多個分類 → 只留第一次出現的
  const seen = new Set();
  const uniq = rows.filter((r) => (seen.has(r.psn) ? false : (seen.add(r.psn), true)));

  const dir = writeVendorOutput(outRoot, vendor.key, { vendor: vendor.name, key: vendor.key, platform: vendor.platform.name, urls: vendor.urls, categories }, uniq);
  if (rawFiles.length) {
    const rawDir = path.join(dir, "raw");
    fs.mkdirSync(rawDir, { recursive: true });
    for (const [name, html] of rawFiles) fs.writeFileSync(path.join(rawDir, name), html, "utf8");
  }
  log(`完成：${uniq.length} 筆 → ${dir}`);
  return { dir, count: uniq.length };
}

function selectVendors(rest, flags) {
  if (flags.url) {
    const key = flags.vendor || "adhoc";
    const all = loadVendors();
    const base = all[key] || { name: new URL(flags.url).hostname, platform: flags.platform };
    return [resolveVendor(key, { ...base, url: undefined, urls: [flags.url] }, flags)];
  }
  const vendors = loadVendors();
  const keys = rest.length ? rest : Object.keys(vendors);
  return keys.map((k) => {
    if (!vendors[k]) throw new Error(`vendors.json 裡沒有 "${k}"，有的是：${Object.keys(vendors).join(", ")}`);
    return resolveVendor(k, vendors[k], flags);
  });
}

async function main() {
  const { _: [cmd, ...rest], flags } = parseArgs(process.argv.slice(2));
  if (!cmd || cmd === "help" || flags.help) {
    console.log(fs.readFileSync(new URL(import.meta.url)).toString().split("\n").slice(1, 11).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    return;
  }

  if (cmd === "vendors") {
    for (const v of selectVendors(rest, flags)) console.log(`${v.key}\t${v.name}\t${v.platform.name}\n  ${v.urls.join("\n  ")}`);
    return;
  }
  if (cmd === "login") {
    for (const v of selectVendors(rest, flags)) {
      const c = v.platform.createClient({ url: v.urls[0], ...credsFor(v.key, v.platform.name), log: (m) => console.error(`[${v.key}] ${m}`) });
      await c.login();
    }
    return;
  }
  if (cmd === "scrape") {
    const summary = [];
    for (const v of selectVendors(rest, flags)) {
      try {
        const r = await scrapeVendor(v, flags);
        summary.push({ vendor: v.name, count: r.count, out: r.dir });
      } catch (e) {
        console.error(`[${v.key}] 失敗：${e.message}`);
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
