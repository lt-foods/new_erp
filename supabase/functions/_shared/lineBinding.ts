// 限量商品下單前的「店家 LINE 一鍵綁定」—— 綁定碼的產生 / 訊息格式 / 解析。
//
// 這支被兩個 function 共用，格式只能在這裡改：
//   liff-api  (start_line_binding)：generateBindCode + buildBindMessage 發碼
//   line-webhook：extractBindCode 從會員送進 OA 的訊息裡把碼撈出來核銷
// 兩邊各自部署，若訊息格式跟解析對不上，綁定會整條靜默失效 —— 所以
// buildBindMessage 與 BIND_CODE_RE 必須永遠成對維護在這個檔案裡。

/** 綁定碼有效時間（分鐘）。過期後前端要重新按一次下單取得新碼 */
export const BIND_CODE_TTL_MIN = 30;

// 32 個字元、去除易混淆的 0/O/1/I。crypto 亂數 byte % 32 沒有 modulo bias（256 = 32×8）
const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/** 產生 6 碼綁定碼（使用者不用手打，只是跟著預填訊息一起送出） */
export function generateBindCode(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) out += CODE_CHARS[b % CODE_CHARS.length];
  return out;
}

/** 預填進 OA 對話框的訊息本文。會員只要按「送出」，不需要理解綁定碼是什麼 */
export function buildBindMessage(code: string): string {
  return `我要綁定商城會員，完成後就可以下單限量商品 🛍️\n綁定碼：${code}`;
}

// 只認「綁定碼：XXXXXX」這個片段，前後多打字（或 LINE 自動加的東西）不影響
const BIND_CODE_RE = /綁定碼[:：]\s*([A-HJ-NP-Z2-9]{6})/;

/** 從訊息文字裡撈綁定碼；沒有就回 null（= 一般訊息，走原本的 account link 邀請） */
export function extractBindCode(text: string): string | null {
  const m = BIND_CODE_RE.exec(text ?? "");
  return m ? m[1] : null;
}
