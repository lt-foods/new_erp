"use client";

// 匯出「蝦皮大量上架」用的商品檔（.xlsx）。
// 欄位順序照蝦皮賣家中心「大量上架 → 下載基本範本」的商品資料欄：
// 一個規格一列，同一商品的多列用「商品規格識別碼」綁在一起（我們用 product_code）。
// 蝦皮的「分類」是它自家的分類 ID，我們的商品分類對不上 → 留空，由店家在蝦皮範本裡選。
// 「庫存」也留空：要上多少量是店家自己決定的，不拿門市 / 總倉的 on_hand 硬塞。

export type ShopeeSku = {
  sku_code: string;
  variant_name: string | null;
  weight_g: number | null;
  price: number | null;
};

export type ShopeeProduct = {
  product_code: string;
  name: string;
  description: string | null;
  /** 已轉成公開網址的商品圖（第一張當主圖）*/
  image_urls: string[];
  skus: ShopeeSku[];
};

export const SHOPEE_HEADERS = [
  "分類",
  "商品名稱",
  "商品描述",
  "最低購買數量",
  "主商品貨號",
  "商品規格識別碼",
  "規格名稱 1",
  "選項名稱 1",
  "規格圖片",
  "規格名稱 2",
  "選項名稱 2",
  "價格",
  "庫存",
  "商品選項貨號",
  "尺寸表",
  "主商品圖片",
  "商品圖片 1",
  "商品圖片 2",
  "商品圖片 3",
  "商品圖片 4",
  "商品圖片 5",
  "商品圖片 6",
  "商品圖片 7",
  "商品圖片 8",
  "重量",
];

const SHEET_NAME = "蝦皮上架";

/** 商品描述是 RichTextEditor 的 HTML，蝦皮只吃純文字 */
export function htmlToText(html: string | null): string {
  if (!html) return "";
  return html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h[1-6])>/gi, "\n")
    .replace(/<li[^>]*>/gi, "・")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** 沒有零售價的商品（整個商品一個價都沒有）不匯，回報給使用者 */
export type ShopeeSkip = { product_code: string; name: string; reason: string };

export function buildShopeeRows(products: ShopeeProduct[]): {
  rows: (string | number)[][];
  skipped: ShopeeSkip[];
} {
  const rows: (string | number)[][] = [SHOPEE_HEADERS.slice()];
  const skipped: ShopeeSkip[] = [];

  for (const p of products) {
    const skus = p.skus.filter((s) => s.price !== null);
    if (p.skus.length === 0) {
      skipped.push({ product_code: p.product_code, name: p.name, reason: "沒有規格" });
      continue;
    }
    if (skus.length === 0) {
      skipped.push({ product_code: p.product_code, name: p.name, reason: "沒有零售價" });
      continue;
    }
    const multi = skus.length > 1;
    const desc = htmlToText(p.description) || p.name;
    const images = p.image_urls.slice(0, 9);

    for (const s of skus) {
      const weightKg = s.weight_g && s.weight_g > 0 ? Math.round(s.weight_g) / 1000 : "";
      rows.push([
        "",                                            // 分類（蝦皮分類 ID，店家自選）
        p.name,                                        // 商品名稱
        desc,                                          // 商品描述
        1,                                             // 最低購買數量
        p.product_code,                                // 主商品貨號
        multi ? p.product_code : "",                   // 商品規格識別碼
        multi ? "款式" : "",                            // 規格名稱 1
        multi ? s.variant_name?.trim() || s.sku_code : "", // 選項名稱 1
        "",                                            // 規格圖片
        "",                                            // 規格名稱 2
        "",                                            // 選項名稱 2
        Number(s.price),                               // 價格
        "",                                            // 庫存（店家自填）
        s.sku_code,                                    // 商品選項貨號
        "",                                            // 尺寸表
        images[0] ?? "",                               // 主商品圖片
        ...Array.from({ length: 8 }, (_, i) => images[i + 1] ?? ""), // 商品圖片 1~8
        weightKg,                                      // 重量（kg）
      ]);
    }
  }
  return { rows, skipped };
}

export async function exportShopeeXlsx(
  products: ShopeeProduct[],
  filename: string,
): Promise<{ exported: number; skipped: ShopeeSkip[] }> {
  const { rows, skipped } = buildShopeeRows(products);
  const exported = products.length - skipped.length;
  if (exported === 0) return { exported: 0, skipped };

  // 動態載入：xlsx 近 1MB，不進商品頁主 bundle
  const XLSX = await import("xlsx");
  const ws = XLSX.utils.aoa_to_sheet(rows);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, SHEET_NAME);
  XLSX.writeFile(wb, filename, { bookType: "xlsx" });
  return { exported, skipped };
}
