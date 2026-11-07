import fs from "node:fs";
import path from "node:path";

export const CSV_COLUMNS = [
  "vendor", "psn", "product_code", "name", "category", "subcategory",
  "price_general", "price_member", "price_original",
  "stock", "options", "short_desc", "tags", "free_shipping", "shipping_methods",
  "image", "image_files", "url", "description",
];

export function csvEscape(v) {
  if (v == null) return "";
  const s = Array.isArray(v)
    ? v.map((x) => (x != null && typeof x === "object" ? JSON.stringify(x) : String(x))).join(" | ")
    : typeof v === "object" ? JSON.stringify(v) : String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function writeCsv(file, rows, columns = CSV_COLUMNS) {
  const lines = [columns.join(",")];
  for (const r of rows) lines.push(columns.map((c) => csvEscape(r[c])).join(","));
  fs.writeFileSync(file, "﻿" + lines.join("\n") + "\n", "utf8"); // BOM 給 Excel
}

export function stamp() {
  return new Date().toISOString().replace(/[:T]/g, "-").slice(0, 16);
}

/** 一家廠商一次抓完的結果 → out/<key>/<時間>/products.{json,csv} */
export function writeVendorOutput(outRoot, key, meta, rows, dir = path.join(outRoot, key, stamp())) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "products.json"), JSON.stringify({ ...meta, scraped_at: new Date().toISOString(), count: rows.length, products: rows }, null, 2));
  writeCsv(path.join(dir, "products.csv"), rows);
  return dir;
}
