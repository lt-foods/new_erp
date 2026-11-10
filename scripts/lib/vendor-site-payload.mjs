// 廠商網站商品 → 候選池貼文的組法（scripts/vendor-site-ingest.mjs 與 scripts/vendor-sites-run.mjs 共用）。
// 貼文文字：第一行品名、第二行價格（_market_post_quick_candidate 靠這兩行），後面規格 / 代碼 / 分類 / 說明；
// item：結構化欄位，存進 line_note_market_posts.vendor_item（20261107000060），market-ai 30 個一批直接用。

import { skipCategoryReason } from "../../tools/vendor-scraper/src/platforms/shop2000.mjs";

export function priceLine(p) {
  const price = p.price_member ?? p.price_general;
  let l = `會員價 $${price}`;
  if (p.price_general != null && p.price_member != null && p.price_general !== p.price_member) l += `（一般價 $${p.price_general}）`;
  if (p.price_original != null && p.price_original !== price) l += `（原價 $${p.price_original}）`;
  return l;
}

export function itemOf(p) {
  const price = p.price_member ?? p.price_general ?? null;
  const specs = (p.spec ?? []).map((g) => `${g.name}：${g.options.map((o) => o.name).join("、")}`);
  return {
    name: p.name,
    price,
    price_text: price != null ? priceLine(p) : null,
    spec: (specs.length ? specs.join("；") : (p.options ?? []).join("、")) || null,
    category: [p.category, p.subcategory].filter(Boolean).join(" / ") || null,
    short_desc: p.short_desc || null,
    product_code: p.product_code || null,
  };
}

export function composeText(p) {
  const lines = [p.name];
  if ((p.price_member ?? p.price_general) != null) lines.push(priceLine(p));
  const specs = (p.spec ?? []).map((g) => `${g.name}：${g.options.map((o) => o.name + (o.stock != null ? `(庫存${o.stock})` : "")).join("、")}`);
  if (specs.length) lines.push("規格：" + specs.join("；"));
  else if (p.options?.length) lines.push("規格：" + p.options.join("、"));
  if (p.product_code) lines.push(`商品代碼：${p.product_code}`);
  if (p.category) lines.push(`分類：${[p.category, p.subcategory].filter(Boolean).join(" / ")}`);
  if (p.free_shipping) lines.push(p.free_shipping);
  else if (p.tags?.length) lines.push(p.tags.join("、"));
  if (p.short_desc) lines.push(p.short_desc);
  if (p.stock != null) lines.push(`庫存：${p.stock}`);
  if (p.description) lines.push("", p.description);
  lines.push("", `來源：${p.url}`);
  return lines.join("\n").slice(0, 8000);
}

/** 已下架 / 待處理 / 已過收單日的分類不進料（跟爬蟲同一套） */
export function isSellable(p) {
  return !(skipCategoryReason(p.category) || skipCategoryReason(p.subcategory));
}

/** rpc_vendor_site_market_ingest 的 p_products 元素 */
export function payloadOf(p, scrapedAt, imagePaths = []) {
  return { psn: String(p.psn), name: p.name, url: p.url, text: composeText(p), image_paths: imagePaths, scraped_at: scrapedAt, item: itemOf(p) };
}
