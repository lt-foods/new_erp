/** 清理開團 / 商品文案，供會員端顯示。
 *  文案來源為後台 TipTap 編輯器（存成 HTML），且常夾帶 LINE 匯入殘留：
 *   1. 去除 HTML 標籤（區塊標籤轉換行）、還原常見 HTML entity。
 *   2. 金額被「逐位數包小括號」的殘留：$ / ＄ 後面一連串 (數字) 去括號合併，例如
 *        「$(2)(0)(0)」→「$200」、「$(1)(5)(9)」→「$159」。
 *      其餘括號（「(8小包)」「(係指未開封)」「（日本監製）」、列點「(1)」、正常 $159 等）一律保留。
 *   3. 清掉 legacy LINE 佔位字 (emoji)/(heart)，並收斂多餘空白。
 *  收 null/undefined（名稱欄位多為 nullable），一律回字串。 */
export function cleanCampaignText(raw: string | null | undefined): string {
  if (!raw) return "";
  return raw
    // --- 1. HTML（TipTap）→ 純文字 ---
    .replace(/<\/(p|div|h[1-6]|li|tr|blockquote)\s*>/gi, "\n") // 區塊結束 → 換行
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "")                                   // 去掉其餘所有標籤
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/(&#0*39;|&apos;)/gi, "'")
    // --- 2. 金額逐位括號合併：$(2)(0)(0) → $200（只動緊接 $/＄ 的 (數字) 串，其餘括號不碰）---
    .replace(/([$＄])((?:\s*[（(]\s*[0-9]\s*[)）])+)/g, (_, sign, run) => sign + run.replace(/\D/g, ""))
    // --- 3. legacy LINE 佔位字 ---
    .replace(/\(heart\)/gi, "♥")
    .replace(/\(emoji\)/gi, "")
    // --- 收斂空白 ---
    .replace(/[ \t]{2,}/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
