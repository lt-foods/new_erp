/** 清掉 legacy LINE 匯入殘留的 emoji 佔位字，並收斂多餘空白。
 *  開團名稱／描述常從 LINE 候選池貼文帶出，夾帶 (emoji)/(heart)/(cool) 這類雜訊 token。
 *  有對應 Unicode 的就還原，純佔位的 (emoji) 直接拿掉。
 *  收 null/undefined（名稱欄位多為 nullable），一律回字串。 */
const LINE_SHORTCODES: Array<[RegExp, string]> = [
  [/\(heart\)/gi, "♥"],
  [/\(cool\)/gi, "😎"],
  [/\(joy\)/gi, "😂"],
  [/\(smile\)/gi, "😊"],
  [/\(grin\)/gi, "😁"],
  [/\(wink\)/gi, "😉"],
  [/\(sad\)/gi, "😢"],
  [/\(cry\)/gi, "😭"],
  [/\(angry\)/gi, "😠"],
  [/\(love\)/gi, "😍"],
  [/\(kiss\)/gi, "😘"],
  [/\(ok\)/gi, "👌"],
  [/\(thumbsup\)/gi, "👍"],
  [/\(clap\)/gi, "👏"],
  [/\(fire\)/gi, "🔥"],
  [/\(star\)/gi, "⭐"],
  [/\(sparkle\)/gi, "✨"],
  [/\(emoji\)/gi, ""],
];

export function cleanCampaignText(raw: string | null | undefined): string {
  if (!raw) return "";
  let s = raw;
  for (const [re, rep] of LINE_SHORTCODES) s = s.replace(re, rep);
  return s
    .replace(/[ \t]{2,}/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
