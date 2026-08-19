// 贈品（$0 但刻意送的）判定 —— 全站唯一一份，各頁不要各寫一份。
//
// 兩層標記，讀取時 OR（DB 端 rpc_record_pickup / v_admin_orders_list 用同一套）：
//   1. campaign_items.is_gift       —— 開團層級（促銷活動：一次標，全團訂單生效）
//   2. customer_order_items.is_gift —— 單張訂單層級（櫃台當場標的個案）
//
// 為什麼不在 DB 把 1 同步進 2：有 50 支 migration 會 INSERT customer_order_items
// （轉單 / 拆行 / 配貨…），同步欄位漏一支就是「贈品變回漏填、櫃台被擋」；
// 而且 1 要能追溯生效（促銷開跑之後才想到要標）。詳見 20260819000000 檔頭。

type CampaignGift = { is_gift?: boolean | null; gift_reason?: string | null };

export type GiftFlaggedItem = {
  is_gift?: boolean | null;
  gift_reason?: string | null;
  // PostgREST 的 to-one embed 正常回物件，但同一個 select 在別處被當成陣列過
  // （見 PickupDialog 的 member:members(...)），兩種都收，不要在呼叫端各判一次
  campaign_item?: CampaignGift | CampaignGift[] | null;
};

function campaignGift(it: GiftFlaggedItem | null | undefined): CampaignGift | null {
  const ci = it?.campaign_item;
  if (!ci) return null;
  return Array.isArray(ci) ? (ci[0] ?? null) : ci;
}

/** PostgREST 抓品項時要一起帶的欄位（含開團層級的標記） */
export const GIFT_ITEM_SELECT =
  "is_gift, gift_reason, campaign_item:campaign_items(is_gift, gift_reason)";

export function isGiftLine(it: GiftFlaggedItem | null | undefined): boolean {
  if (!it) return false;
  return !!it.is_gift || !!campaignGift(it)?.is_gift;
}

/** 這一列的贈品標記是不是來自開團設定（＝單張訂單這邊取消不掉） */
export function isCampaignGiftLine(it: GiftFlaggedItem | null | undefined): boolean {
  return !!campaignGift(it)?.is_gift;
}

/** 顯示用的贈品原因；開團層級優先（那是整個團的說法） */
export function giftReasonOf(it: GiftFlaggedItem | null | undefined): string {
  if (!it) return "";
  const ci = campaignGift(it);
  return (ci?.is_gift ? ci.gift_reason : it.gift_reason) || "";
}

/** 🎁 標籤的 title：把來源與原因一起講清楚 */
export function giftTitle(it: GiftFlaggedItem | null | undefined): string {
  if (!isGiftLine(it)) return "";
  const reason = giftReasonOf(it);
  const from = isCampaignGiftLine(it) ? "開團設定的贈品（整個團適用）" : "這張訂單標記的贈品";
  return reason ? `${from}：${reason}` : from;
}
