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

/** 一步到位：算不出 LINE@ 就回 null，呼叫端據此決定要不要畫按鈕。 */
export function spotInquiryHref(
  storeLineOaId: string | null | undefined,
  subject: SpotInquirySubject,
): string | null {
  const oa = resolveLineOaId(storeLineOaId);
  if (!oa) return null;
  return buildLineOaMessageUrl(oa, buildSpotInquiryText(subject));
}
