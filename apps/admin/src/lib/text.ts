/** 清掉 legacy LINE 匯入殘留的 emoji 佔位字，並收斂多餘空白。
 *  開團名稱／描述常從 LINE 候選池貼文帶出，夾帶 (emoji)/(heart)/(cool) 這類雜訊 token。
 *  有對應 Unicode 的就還原，純佔位的 (emoji) 直接拿掉；單字元的 LINE 客製貼圖
 *  ($)/(0-9)/(/) 多半是文字內容（價格、日期），剝掉括號保留字元。
 *  收 null/undefined（名稱欄位多為 nullable），一律回字串。 */
const LINE_SHORTCODES: Array<[RegExp, string]> = [
  // 有名字的 → Unicode emoji
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
  [/\(ng\)/gi, "🙅"],
  [/\(thumbsup\)/gi, "👍"],
  [/\(thumbsdown\)/gi, "👎"],
  [/\(clap\)/gi, "👏"],
  [/\(pray\)/gi, "🙏"],
  [/\(muscle\)/gi, "💪"],
  [/\(hi\)/gi, "👋"],
  [/\(bye\)/gi, "👋"],
  [/\(fire\)/gi, "🔥"],
  [/\(star\)/gi, "⭐"],
  [/\(sparkle\)/gi, "✨"],
  [/\(sparkles\)/gi, "✨"],
  [/\(check\)/gi, "✅"],
  [/\(cross\)/gi, "❌"],
  [/\(warn\)/gi, "⚠️"],
  [/\(sun\)/gi, "☀️"],
  [/\(moon\)/gi, "🌙"],
  [/\(cloud\)/gi, "☁️"],
  [/\(rain\)/gi, "🌧️"],
  [/\(coffee\)/gi, "☕"],
  [/\(cake\)/gi, "🍰"],
  [/\(gift\)/gi, "🎁"],
  [/\(party\)/gi, "🎉"],
  [/\(music\)/gi, "🎵"],
  [/\(phone\)/gi, "📱"],
  [/\(mail\)/gi, "📧"],
  [/\(pin\)/gi, "📌"],
  [/\(memo\)/gi, "📝"],
  [/\(calendar\)/gi, "📅"],
  [/\(clock\)/gi, "⏰"],
  [/\(bell\)/gi, "🔔"],
  [/\(point\)/gi, "👉"],
  [/\(arrow\)/gi, "➡️"],
  // 單字元 LINE 客製貼圖（多半是文字內容如 $1850、5/24） → 剝掉括號保留字元
  [/\(\$\)/g, "$"],
  [/\(([0-9])\)/g, "$1"],
  [/\(\/\)/g, "/"],
  // 純佔位、無法還原；順手吃掉一個尾隨空白（避免 `(emoji) 條列` 拿掉後留 ` 條列`）
  [/\(emoji\)[ \t]?/gi, ""],
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
