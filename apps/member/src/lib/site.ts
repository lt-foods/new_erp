/**
 * 站台層級的常數（分享預覽卡 / OG tag 用）。
 *
 * metadataBase 一定要是絕對網址：OG 圖不能用相對路徑，爬蟲沒有「當前網域」
 * 的概念。網址從 NEXT_PUBLIC_SITE_URL 讀，沒設就用線上的 member app 網域
 * （Vercel project 名字叫 new-erp-admin，但部署的其實是會員站，
 * 見 HANDOFF-2026-04-24）。
 */
export const SITE_URL = (
  process.env.NEXT_PUBLIC_SITE_URL ?? "https://new-erp-admin.vercel.app"
).replace(/\/$/, "");

export const SITE_NAME = "包子媽生鮮小舖";

/** 沒有商品圖時的退路：店家 banner（1800×600），LINE 與 FB 都吃得下 */
export const SITE_OG_IMAGE = "/brand/banner.jpg";
