// @ts-nocheck
// ─────────────────────────────────────────────────────────────────────────────
// LINE 裝飾表情（deco emoji / sticon）
//
// 小幫手手貼的貼文，金額是用 LINE 的數字表情打的（截圖那種彩色的 $ 7 9），
// 不是純文字。它在 API 上長這樣：
//   contents.text          "一份($)(7)(9)"      ← 每個表情佔一個 (x) 佔位字
//   contents.sticonMetas   [{S,E,productId,sticonId,version,resourceType}, …]
// S / E 是**UTF-16 位移**（JS 字串的原生索引），指向 text 裡那段佔位字。
//
// 下面的對照表不是猜的，是把松山社群 60 篇貼文的 sticonMetas 撈回來統計出來的
// （1,125 筆）。注意 0 是 062 不是 052 —— 1~9 連號到 061 之後才輪到 0。
// ─────────────────────────────────────────────────────────────────────────────

// 金額（會動的那組，小幫手都用這個打價格）
const PRICE = {
  productId: "61f5f6d3e023eb1687b8e333",
  version: 2,
  resourceType: "ANIMATION",
  map: {
    "$": "068",
    "1": "053", "2": "054", "3": "055", "4": "056", "5": "057",
    "6": "058", "7": "059", "8": "060", "9": "061", "0": "062",
  },
} as const;

// 用私有區的字當標記：渲染時把要裝飾的段落包起來，最後一次換成佔位字＋metas。
// 這樣才只動我們自己產的那幾行，不會去改店家寫在文案裡的「（市價$150/盒）」。
export const DECO_OPEN = "";
export const DECO_CLOSE = "";

export function decoPrice(s: string) {
  return `${DECO_OPEN}${s}${DECO_CLOSE}`;
}

// 把標記過的段落換成 LINE 看得懂的 (x) 佔位字 + sticonMetas。
// 表裡沒有的字（例如小數點）原樣留著，不會消失。
export function applyDeco(raw: string): { text: string; sticonMetas: any[] } {
  const metas: any[] = [];
  let out = "";
  let deco = false;
  for (const ch of String(raw ?? "")) {
    if (ch === DECO_OPEN) { deco = true; continue; }
    if (ch === DECO_CLOSE) { deco = false; continue; }
    const sticonId = deco ? (PRICE.map as Record<string, string>)[ch] : undefined;
    if (!sticonId) { out += ch; continue; }
    const S = out.length;                       // out 是 JS 字串 → 本來就是 UTF-16 位移
    out += `(${ch})`;
    metas.push({
      S: String(S), E: String(out.length),
      productId: PRICE.productId, sticonId,
      version: PRICE.version, resourceType: PRICE.resourceType,
    });
  }
  return { text: out, sticonMetas: metas };
}

// 預覽 / 存檔用：把標記拿掉，留下人看得懂的 "$79"
export function stripDeco(raw: string) {
  return String(raw ?? "").replaceAll(DECO_OPEN, "").replaceAll(DECO_CLOSE, "");
}
