// 手機團控的純函式（不碰 React、不碰資料庫），單獨測試：
//   node --test "apps/admin/src/app/(protected)/campaigns/quick-control/quickControl.test.mjs"

/** 清單一次載入幾團 */
export const QUICK_PAGE_SIZE = 50;
/**
 * 「載入更多」往回多抓幾筆重疊，再用 id 去重。
 * 清單照 updated_at 排序、用位移分頁；在畫面上關團／重開會讓該團在伺服端換位置或跑出篩選，
 * 位移就會錯開幾筆。多抓一段重疊，錯開幾筆也不會漏掉。
 */
export const QUICK_PAGE_OVERLAP = 10;

/** 客人下單頁網址（全頁只准用這一支組網址） */
export function customerUrlFor(baseUrl: string, campaignId: number): string {
  return `${baseUrl.replace(/\/$/, "")}/shop/c/${campaignId}`;
}

/**
 * 搜尋字清理：PostgREST 的 or() 用逗號、點、括號、冒號分隔條件，
 * 只留文字、數字、空白、底線、連字號；其他符號（例如【】）換成萬用字元 %，
 * 讓「內部 xx」也對得到「內部】xx」。全是符號時回空字串。
 */
export function sanitizeCampaignSearch(q: string): string {
  return q
    .replace(/[^\p{L}\p{N}\s_-]+/gu, "%")
    .replace(/\s+/g, " ")
    .replace(/%+/g, "%")
    .replace(/^[\s%]+|[\s%]+$/g, "");
}

/** 伺服端搜尋條件（團號、團名）；沒有可搜的字回 null */
export function campaignSearchOrFilter(q: string): string | null {
  const term = sanitizeCampaignSearch(q);
  if (!term) return null;
  return `campaign_no.ilike.%${term}%,name.ilike.%${term}%`;
}

/**
 * 這次要跟伺服端要的範圍（.range(from, to)，兩端都含）。
 * 會多要一筆，用來判斷後面還有沒有下一頁。
 */
export function pageWindow(loaded: number): { from: number; to: number } {
  const safeLoaded = Math.max(0, Math.floor(loaded));
  return {
    from: Math.max(0, safeLoaded - QUICK_PAGE_OVERLAP),
    to: safeLoaded + QUICK_PAGE_SIZE,
  };
}

/** 把多要的那一筆切掉，順便回報還有沒有下一頁 */
export function splitPage<T>(data: T[], window: { from: number; to: number }): { rows: T[]; hasMore: boolean } {
  const size = window.to - window.from;
  return { rows: data.slice(0, size), hasMore: data.length > size };
}

/** 載入更多時合併：已在畫面上的保留（含剛操作過的最新狀態），新的接在後面 */
export function mergeCampaignRows<T extends { id: number }>(current: T[], incoming: T[]): T[] {
  const seen = new Set(current.map((r) => r.id));
  const next = [...current];
  for (const row of incoming) {
    if (seen.has(row.id)) continue;
    seen.add(row.id);
    next.push(row);
  }
  return next;
}

type SoldOrder = {
  campaign_id: number;
  status: string;
  order_kind: string | null;
  customer_order_items?: { qty: number | string; status: string }[];
};

/** 已售件數（口徑同 rpc_quick_update_campaign_control 的 v_sold_qty） */
export function soldQtyByCampaign(orders: SoldOrder[]): Map<number, number> {
  const sold = new Map<number, number>();
  for (const order of orders) {
    if (["cancelled", "expired", "transferred_out"].includes(order.status)) continue;
    if ((order.order_kind ?? "normal") !== "normal") continue;
    const qty = (order.customer_order_items ?? [])
      .filter((item) => !["cancelled", "expired"].includes(item.status))
      .reduce((sum, item) => sum + Number(item.qty ?? 0), 0);
    sold.set(order.campaign_id, (sold.get(order.campaign_id) ?? 0) + qty);
  }
  return sold;
}

type EligibleCampaign = {
  close_type: string;
  total_cap_qty: number | string | null;
  campaign_items: { cap_qty?: number | string | null }[] | null;
};

/**
 * 延長／重開／加整團名額背後的 rpc_quick_update_campaign_control 只收這幾種團
 * （20260814000010 那支的守衛，這裡照抄；資料庫沒改之前兩邊要一致）：
 * 美食列車／限時／限時限量，或有設整團上限、或任一品項有上限。
 * 沒設上限的一般團按下去會被資料庫擋掉，所以畫面先不給按。
 */
export function canQuickUpdateCampaign(row: EligibleCampaign): boolean {
  return (
    row.close_type === "food_train"
    || row.close_type === "fast"
    || row.close_type === "limited"
    || Number(row.total_cap_qty ?? 0) > 0
    || (row.campaign_items ?? []).some((item) => Number(item.cap_qty ?? 0) > 0)
  );
}
