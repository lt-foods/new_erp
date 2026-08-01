import { initLiff } from "./liff";

/**
 * 現貨專區「LINE 詢問」訊息與連結。
 *
 * ⚠ 金額隱藏的第二道關卡：
 *   跨店商品的金額在 App 上是藏起來的，訊息裡當然也不能帶 —— 否則等於
 *   從另一個出口把價格漏出去。所以本店 / 跨店是兩套範本，別合併。
 *
 * 訊息一律發給「會員所在店」的 LINE@，跨店商品也是：
 *   會員只跟自己的店結帳，跨店的貨本來就是自己的店走互助板去別店調，
 *   所以跨店那則的收尾是「幫我調貨」而不是「還有貨嗎」。
 */

export type SpotInquirySubject = {
  /** 商品顯示名（含規格），例：上海小籠湯包-附蒸籠紙／一包 */
  title: string;
  /** 釋出店名，跨店時要寫進訊息讓店員知道去哪調 */
  storeName: string | null;
  /** true = 自己所在店家釋出 */
  isMyStore: boolean;
  /** 單價；只有 isMyStore 才會有值 */
  unitPrice: number | null;
};

/**
 * 解析要發給哪個 LINE@。
 * 順序：會員所在店自己的 LINE@ → 租戶層預設（環境變數）→ null（呼叫端不顯示按鈕）。
 */
export function resolveLineOaId(storeLineOaId: string | null | undefined): string | null {
  const perStore = (storeLineOaId ?? "").trim();
  if (perStore) return perStore;
  const fallback = (process.env.NEXT_PUBLIC_LINE_OA_ID ?? "").trim();
  return fallback || null;
}

/** 組詢問訊息本文。本店帶金額、跨店不帶。 */
export function buildSpotInquiryText(s: SpotInquirySubject): string {
  if (s.isMyStore) {
    const priceLine = s.unitPrice != null ? `\n金額：$${s.unitPrice.toLocaleString()}` : "";
    return `您好，我想詢問今日現貨\n「${s.title}」${priceLine}\n請問店家目前還有貨嗎？`;
  }
  const from = s.storeName ? `（${s.storeName}釋出）` : "";
  return `您好，我想詢問今日現貨\n「${s.title}」${from}\n請問可以幫我調貨嗎？`;
}

/**
 * LINE 官方帳號「開對話並預填訊息」的 universal link。
 * LINE app 內、外部瀏覽器、PWA standalone 都吃這個格式。
 * basicId 需含 @（會被 encode 成 %40）。
 */
export function buildLineOaMessageUrl(basicId: string, text: string): string {
  const id = basicId.startsWith("@") ? basicId : `@${basicId}`;
  return `https://line.me/R/oaMessage/${encodeURIComponent(id)}/?${encodeURIComponent(text)}`;
}

export type SendResult = "sent_in_liff" | "opened_line" | "copied" | "failed";

/**
 * 把詢問訊息送出去。App 有兩種跑法，走的路不一樣：
 *
 * 1. **LIFF（LINE 內建瀏覽器）** → `liff.sendMessages()`
 *    以使用者身分把文字直接送進「開啟這個 LIFF 的那個聊天室」（也就是 OA 的對話）。
 *    使用者不會被踢出 App，送完停在原地。
 *    需要 LIFF app 有開 `chat_message.write` scope、而且是從聊天室 / 圖文選單進來的
 *    （有 chat context）。條件不符 SDK 會 reject → 自動掉到第 2 條。
 *
 * 2. **PWA / 一般瀏覽器（或 LIFF 條件不符）** → 開 `line.me/R/oaMessage` universal link
 *    跳到 LINE 開啟與該 LINE@ 的對話並預填文字，使用者自己按送出。
 *
 * 3. **連 LINE@ id 都沒設定** → 把訊息複製到剪貼簿，請使用者自己貼給店家。
 *    以前這種情況是「整顆按鈕不畫」，但實際上線時 20 間啟用中的店 line_oa_basic_id
 *    全是 NULL、env 也沒設，結果功能整個看不見、像壞掉。按鈕一律要在，
 *    最差也要留一條路給使用者走。
 *
 * 三條都走不通才回 "failed"，呼叫端顯示錯誤。
 */
export async function sendLineInquiry(
  storeLineOaId: string | null | undefined,
  subject: SpotInquirySubject,
): Promise<SendResult> {
  const text = buildSpotInquiryText(subject);

  // 1. LIFF 內：直接送進當前聊天室
  try {
    const liff = await initLiff();
    if (liff?.isInClient() && typeof liff.sendMessages === "function") {
      await liff.sendMessages([{ type: "text", text }]);
      return "sent_in_liff";
    }
  } catch {
    // 沒 scope / 沒 chat context / 使用者取消 → 掉到 universal link
  }

  // 2. 退路：universal link 開 LINE 對話並預填
  const oa = resolveLineOaId(storeLineOaId);
  if (!oa) {
    // 3. 最後退路：沒有任何 LINE@ 可以指向 → 複製訊息，讓使用者自己貼
    try {
      await navigator.clipboard.writeText(text);
      return "copied";
    } catch {
      return "failed";
    }
  }
  const url = buildLineOaMessageUrl(oa, text);
  try {
    const liff = await initLiff();
    // LIFF 內要用 openWindow(external) 才會跳出 LINE 內建瀏覽器開對話
    if (liff?.isInClient() && typeof liff.openWindow === "function") {
      liff.openWindow({ url, external: true });
      return "opened_line";
    }
  } catch {
    // 落到一般 window.open
  }
  // 用 location 導頁而不是 window.open：非同步之後才開新視窗會被彈出視窗
  // 阻擋器擋掉（已經不算 user gesture）。universal link 用導頁一樣會交棒給
  // LINE app，PWA 本身留在原地。
  window.location.href = url;
  return "opened_line";
}

/**
 * 這台裝置的這次瀏覽是不是跑在 LIFF 裡。
 * CTA 本身兩種情況都是同一顆 button（實際走哪條由 sendLineInquiry 決定），
 * 這支只用來換按鈕底下那行說明文字。
 */
export async function isInLiffClient(): Promise<boolean> {
  try {
    const liff = await initLiff();
    return !!liff?.isInClient();
  } catch {
    return false;
  }
}
