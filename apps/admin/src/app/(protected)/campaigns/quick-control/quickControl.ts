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

/** 手機團控管的團型（其餘團型要有整團或品項上限才算） */
export const QUICK_CLOSE_TYPES = ["food_train", "fast", "limited"] as const;

/**
 * 清單範圍（同 canQuickUpdateCampaign 的團型／上限條件）放進查詢端：
 * 團型是美食列車／限時／限時限量，或整團上限 > 0，或至少一個品項上限 > 0。
 * 「品項上限」靠查詢另外嵌一份只留 cap_qty > 0 的品項（別名 cap_items），
 * 再用 cap_items.not.is.null 判斷「有沒有這種品項」；這不是 inner join，不會讓同一團重複出現。
 * 有搜尋字時兩組條件用 and(...) 包成同一個 or 參數送出。
 * 回傳值給 supabase-js 的 .or() 用。
 */
export const CAP_ITEMS_EMBED = "cap_items:campaign_items(id)";
export const CAP_ITEMS_FILTER_COLUMN = "cap_items.cap_qty";

export function quickScopeFilter(q: string): string {
  const scope = `close_type.in.(${QUICK_CLOSE_TYPES.join(",")}),total_cap_qty.gt.0,cap_items.not.is.null`;
  const search = campaignSearchOrFilter(q);
  return search ? `and(or(${scope}),or(${search}))` : scope;
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
  status: string;
  close_type: string;
  total_cap_qty: number | string | null;
  campaign_items: { cap_qty?: number | string | null }[] | null;
};

/**
 * 延長／重開／加整團名額背後的 rpc_quick_update_campaign_control 只收這幾種團
 * （20260814000010 那支的守衛，這裡照抄；資料庫沒改之前兩邊要一致）：
 * 狀態只能是草稿／開團中／已關團（已鎖定一律擋），
 * 且是美食列車／限時／限時限量，或有設整團上限、或任一品項有上限。
 * 清單範圍用的是同一組團型／上限條件（quickScopeFilter），所以不合格的一般團不會出現在清單。
 */
export function canQuickUpdateCampaign(row: EligibleCampaign): boolean {
  if (!["draft", "open", "closed"].includes(row.status)) return false;
  return (
    (QUICK_CLOSE_TYPES as readonly string[]).includes(row.close_type)
    || Number(row.total_cap_qty ?? 0) > 0
    || (row.campaign_items ?? []).some((item) => Number(item.cap_qty ?? 0) > 0)
  );
}

/**
 * 全新商品的圖片／描述／品牌，整理成 rpc_upsert_product 要的參數，外加開團封面。
 * 建商品那次跟「發布」那次都要帶同一份，漏帶的那次會把它蓋回空的。
 * 圖片存的是 Storage products 的路徑（同 ProductImagesField），封面也存同一個路徑
 * （讀封面的地方都會把路徑轉成公開網址，見 lib/campaignCover.ts）。全都可以不填。
 */
export function newProductExtras(input: {
  images: string[];
  description: string;
  brandId: number | null;
}): { p_images: string[]; p_description: string | null; p_brand_id: number | null; cover: string | null } {
  const images = input.images.filter((p) => typeof p === "string" && p.trim().length > 0);
  const description = input.description.trim();
  const brandId = Number.isFinite(input.brandId) && (input.brandId ?? 0) > 0 ? input.brandId : null;
  return {
    p_images: images,
    p_description: description || null,
    p_brand_id: brandId,
    cover: images[0] ?? null,
  };
}
