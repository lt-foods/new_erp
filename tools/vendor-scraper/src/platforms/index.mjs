// 平台登錄表。新平台：在這個資料夾加 <name>.mjs、export `platform`（介面見 shop2000.mjs 底部），然後登記在這裡。
import { platform as shop2000 } from "./shop2000.mjs";

export const platforms = { shop2000 };

/** vendors.json 沒寫 platform 時，用網址猜 */
export function detectPlatform(url) {
  return Object.values(platforms).find((p) => p.match(url)) ?? null;
}
