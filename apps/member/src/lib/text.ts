/** 清理開團 / 商品文案，供會員端顯示。
 *  文案來源為後台 TipTap 編輯器（存成 HTML），且常夾帶 LINE 匯入殘留：
 *   1. 去除 HTML 標籤（區塊標籤轉換行）、還原常見 HTML entity。
 *   2. 移除「含金額 $ 的小括號」整段，例如
 *        「$69（原價對比：西X町$159／蝦皮最低$116）」→「$69」。
 *      其餘括號（如「(8小包)」「(係指未開封)」「（日本監製）」）一律保留。
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
    // --- 2. 移除「含金額 $ 的小括號」整段（半形 () 與全形（）），其餘括號保留 ---
    .replace(/[（(][^（()）]*[$＄][^（()）]*[)）]/g, "")
    // --- 3. legacy LINE 佔位字 ---
    .replace(/\(heart\)/gi, "♥")
    .replace(/\(emoji\)/gi, "")
    // --- 收斂空白 ---
    .replace(/[ \t]{2,}/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
