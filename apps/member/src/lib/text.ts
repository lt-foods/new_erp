/** 清掉 legacy LINE 匯入殘留的佔位字 (emoji)/(heart)，並收斂多餘空白。
 *  開團名稱與描述都從候選池的 LINE 貼文文字帶出，常夾帶這兩個雜訊 token。
 *  刻意只動這兩個明確雜訊 —— (A)/(B)/($)/（暗色）等是有意義內容，不碰。
 *  收 null/undefined（名稱欄位多為 nullable），一律回字串。 */
export function cleanCampaignText(raw: string | null | undefined): string {
  if (!raw) return "";
  return raw
    .replace(/\(heart\)/gi, "♥")
    .replace(/\(emoji\)/gi, "")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
