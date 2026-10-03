/**
 * 上傳前在瀏覽器端把圖片縮到 maxDim 內並轉成 JPEG。
 *
 * products bucket 歷史平均 334 kB、最大 5 MB（手機原圖直接上傳），是 2026-10-02
 * egress 爆量的根源之一。顯示端已改走 render 縮圖（lib/imageUrl.ts），這裡把來源也壓小：
 * 1600px / q0.85 的商品照通常 150–300 kB，render 的 origin 讀取也跟著變便宜。
 *
 * - 鋪白底：透明 PNG 轉 JPEG 不會變黑。
 * - 去 EXIF：createImageBitmap 會套用方向後重畫，輸出不帶方向資訊也不會轉錯邊。
 * - 解不開（HEIC 等瀏覽器不支援的格式）就 throw，呼叫端自行決定要不要退回原檔上傳。
 */
export async function encodeJpeg(file: File | Blob, maxDim: number, quality: number): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  try {
    const scale = Math.min(1, maxDim / Math.max(bmp.width, bmp.height));
    const w = Math.max(1, Math.round(bmp.width * scale));
    const h = Math.max(1, Math.round(bmp.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("無法建立 canvas");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(bmp, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((res) => canvas.toBlob(res, "image/jpeg", quality));
    if (!blob) throw new Error("圖片轉檔失敗");
    return blob;
  } finally {
    bmp.close();
  }
}

/** 商品圖上傳用的預設：長邊 1600px、品質 0.85。GIF 保留原檔（轉 JPEG 會失去動畫）。 */
export const PRODUCT_IMAGE_MAX_DIM = 1600;
export const PRODUCT_IMAGE_QUALITY = 0.85;

/** 路徑是 UUID、upsert:false，永遠不會被覆寫 → 可以讓瀏覽器 / CDN 快取一年 */
export const IMMUTABLE_CACHE_CONTROL = "31536000";

export type PreparedUpload = { blob: Blob; ext: string; contentType: string };

/** 商品圖統一前處理：能壓就壓成 JPEG，壓不了（GIF／瀏覽器解不開）就原檔上傳。 */
export async function prepareProductImage(file: File): Promise<PreparedUpload> {
  const origExt = (file.name.split(".").pop() || "jpg").toLowerCase();
  if (file.type === "image/gif" || origExt === "gif") {
    return { blob: file, ext: "gif", contentType: "image/gif" };
  }
  try {
    const blob = await encodeJpeg(file, PRODUCT_IMAGE_MAX_DIM, PRODUCT_IMAGE_QUALITY);
    return { blob, ext: "jpg", contentType: "image/jpeg" };
  } catch {
    return { blob: file, ext: origExt, contentType: file.type || "application/octet-stream" };
  }
}
