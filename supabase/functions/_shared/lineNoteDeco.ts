// @ts-nocheck
// ─────────────────────────────────────────────────────────────────────────────
// 貼文文字的整理與金額凸顯
//
// 金額用 emoji 數字凸顯：$120 → 💲1️⃣2️⃣0️⃣（鍵帽數字 = 數字 + U+FE0F + U+20E3）。
//
// 原本（#938）想照小幫手手貼的樣子用 LINE 的裝飾表情（contents.sticonMetas），
// 帶著發出去，社群裡看到的還是普通數字（2026-09-10 實測）——
// 那是 LINE 客戶端自己的貼圖管線，從外面打 API 模擬不出來、也沒辦法驗證。
// 所以改用哪台手機都畫得出來的 Unicode emoji；預覽跟存進 DB 的就是貼出去的那份字。
//
// 只裝飾我們自己標記的段落（decoPrice 包起來的）；文案裡「（市價$150/盒）」那種一個字不動。
// ─────────────────────────────────────────────────────────────────────────────

const EMOJI: Record<string, string> = { "$": "💲" };
for (const d of "0123456789") EMOJI[d] = `${d}️⃣`;

// 用私有區的字當標記：渲染時把要裝飾的段落包起來，最後一次換成 emoji。
export const DECO_OPEN = "\uE000";
export const DECO_CLOSE = "\uE001";

export function decoPrice(s: string) {
  return `${DECO_OPEN}${s}${DECO_CLOSE}`;
}

// 把標記過的段落換成 emoji；表裡沒有的字（例如小數點）原樣留著，不會消失。
export function applyDeco(raw: string): string {
  let out = "";
  let deco = false;
  for (const ch of String(raw ?? "")) {
    if (ch === DECO_OPEN) { deco = true; continue; }
    if (ch === DECO_CLOSE) { deco = false; continue; }
    out += deco ? (EMOJI[ch] ?? ch) : ch;
  }
  return out;
}

// 文案裡自己寫的價格也一併凸顯（匯進來的團、富文字說明，品項與價格都寫在 description 裡）：
// - 自己獨立一行的「$109」
// - 小幫手的錢袋寫法「💰195」「💰 一盒 $275」「💰一包99元」→ 💰 後面那個數字
// 行內的「（市價$150/盒）」不動 —— 那不是這團的售價。已經標過的行不再標。
export function decoTextPrices(text: string) {
  return String(text ?? "").split("\n")
    .map((line) => {
      if (line.includes(DECO_OPEN)) return line;
      if (/^\s*\$\d+\s*$/.test(line)) return line.replace(/\$\d+/, (m) => decoPrice(m));
      return line.replace(/💰([^\d\n$💰]{0,6})(\$?\d+)/g, (_, gap, price) => `💰${gap}${decoPrice(price)}`);
    })
    .join("\n");
}

// 團說明是富文字編輯器（TipTap）存的 HTML —— 線上 132 團、近兩個月 87 團都是
// 「<p>…</p><p><strong>$100</strong></p>」這種。原樣貼出去，客人在 LINE 上看到的就是
// 一串 <p><strong>。轉成純文字：換行照 <br> 與段落結尾、清單項目前面補「• 」、
// 其他標籤全拿掉、實體字元還原。不像 HTML 的字串原樣回傳（沒有標籤就不碰，
// 免得把文案裡的「<3」之類吃掉）。
export function htmlToText(s: string) {
  const t = String(s ?? "");
  if (!/<[a-z][^>]*>/i.test(t)) return t;
  return t
    .replace(/\r?\n/g, "")                                  // 編輯器不靠換行字元排版
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>\s*<\/li>/gi, "\n")                     // <li><p>…</p></li> 只算一個換行
    .replace(/<\/(p|div|h[1-6]|li|blockquote|pre|tr)>/gi, "\n")
    .replace(/<li[^>]*>/gi, "• ")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&amp;/gi, "&")                                // 最後才還原 &，不然 &amp;lt; 會被拆兩次
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// 從記事本抓回來的舊文會帶 LINE 裝飾表情的佔位字：($)(3)(5) = $35、(9)(/)(9) = 9/9、
// (emoji) = 一個貼圖。原樣貼出去客人會看到一串「($)(3)(5)」，所以還原成看得懂的字。
// 帶 ($) 的那段原文就是小幫手用彩色數字打的金額 → 順手標起來，貼出去一樣是凸顯的
// （「一個($)(1)(2)(5)」寫在行內，獨立一行的規則抓不到它）。日期那種沒有 $ 的維持純文字。
export function stripLineDeco(s: string) {
  return String(s ?? "")
    .replace(/(?:\((?:\$|[0-9]|\/)\)){2,}/g, (m) => {
      const plain = m.replace(/[()]/g, "");
      return m.includes("($)") ? decoPrice(plain) : plain;
    })
    .replace(/\((?:emoji|好吃|讚|哭|笑|愛心)\)/g, "")
    .replace(/[ \t]+\n/g, "\n");
}
