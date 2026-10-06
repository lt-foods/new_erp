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
 * 舊的快速操作資格判斷（照 20260814000010 那支 rpc_quick_update_campaign_control 的守衛抄的），
 * 現在只當清單範圍的參考：美食列車／限時／限時限量，或有設整團上限、或任一品項有上限
 * （清單用的是同一組條件 quickScopeFilter，所以不合格的一般團不會出現在清單）。
 * 狀態這段仍照舊版只收草稿／開團中／已關團。
 * 已鎖定的團能不能重開，改由資料庫 rpc_quick_update_campaign_control 判斷
 * （請購還是草稿時可重開，20261001020000）；頁面不用本函式擋重開。
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
 * 全新商品的圖片／描述／品牌，整理成 rpc_upsert_product 要的參數。
 * 建商品那次跟「發布」那次都要帶同一份，漏帶的那次會把它蓋回空的。
 * 圖片存的是 Storage products 的路徑（同 ProductImagesField）。全都可以不填。
 * 開團封面刻意不設：訂單頁的封面小圖不認得 Storage 路徑，
 * 沒封面時各處會自動改用第一個品項的商品主圖（lib/campaignCover.ts）。
 */
export function newProductExtras(input: {
  images: string[];
  description: string;
  brandId: number | null;
}): { p_images: string[]; p_description: string | null; p_brand_id: number | null } {
  const images = input.images.filter((p) => typeof p === "string" && p.trim().length > 0);
  const description = input.description.trim();
  const brandId = Number.isFinite(input.brandId) && (input.brandId ?? 0) > 0 ? input.brandId : null;
  return {
    p_images: images,
    p_description: description || null,
    p_brand_id: brandId,
  };
}

/**
 * 手機團控上傳圖片只收 JPEG／PNG：LINE 記事本發文（line-note-worker collectPostImages）
 * 只帶得上這兩種，WebP／GIF 會被略過。
 */
export const QUICK_IMAGE_ACCEPT = "image/jpeg,image/png";

/**
 * 這個檔案能不能傳、存檔用什麼副檔名；不收就回 null。
 * 先看檔案類型，瀏覽器沒給類型才看檔名。副檔名照 ProductImagesField 取檔名結尾，
 * 檔名結尾不是 jpg／jpeg／png（例如 iPhone 轉檔後檔名還是 .heic）就依類型給 jpg／png。
 */
export function quickImageExt(file: { name: string; type: string }): string | null {
  const nameExt = (file.name.split(".").pop() || "").toLowerCase();
  const type = (file.type || "").toLowerCase();
  const kind = type
    ? type === "image/jpeg" ? "jpg" : type === "image/png" ? "png" : null
    : ["jpg", "jpeg"].includes(nameExt) ? "jpg" : nameExt === "png" ? "png" : null;
  if (!kind) return null;
  if (kind === "jpg" && ["jpg", "jpeg"].includes(nameExt)) return nameExt;
  if (kind === "png" && nameExt === "png") return nameExt;
  return kind;
}

/** 圖片排序：把第 idx 張往前（-1）或往後（+1）換一格；超出範圍原樣回傳 */
export function moveImage<T>(list: T[], idx: number, dir: -1 | 1): T[] {
  const target = idx + dir;
  if (idx < 0 || idx >= list.length || target < 0 || target >= list.length) return list;
  const next = [...list];
  [next[idx], next[target]] = [next[target], next[idx]];
  return next;
}

/**
 * 關團結果要不要警告：rpc_close_campaign 併入／建請購失敗時不會丟錯，
 * 而是照樣關團、回 { action: 'append_failed' | 'create_failed', reason }（20260831000060）。
 * 這兩種回傳警告字（reason 原樣附上，英文也照附）；其他 action 回 null，照一般成功訊息。
 * 有給團名就在前面加「團名」。
 */
export const CLOSE_WARN_ACTIONS = ["append_failed", "create_failed"] as const;

export function closeCampaignWarning(data: unknown, name?: string): string | null {
  if (!data || typeof data !== "object" || Array.isArray(data)) return null;
  const { action, reason } = data as { action?: unknown; reason?: unknown };
  if (typeof action !== "string" || !(CLOSE_WARN_ACTIONS as readonly string[]).includes(action)) return null;
  const why = typeof reason === "string" && reason.trim() ? reason.trim() : "原因不明";
  const who = name ? `「${name}」` : "";
  return `${who}已關團，但沒有併入請購單：${why}。請到請購單頁補請購。`;
}

/**
 * 開新團的「開團時間」怎麼處理（比照商品頁建立開團 CreateCampaignModal）：
 * - 留空 → 馬上開團（跟以前一樣：開團時間 = 現在）。
 * - 填未來時間 → 先存成草稿、開團時間寫這個時間，時間到由 rpc_auto_open_scheduled_campaigns
 *   （20260925010000）自動開團；它只撿「建團當下就排在未來」的草稿，建團時填好就符合。
 * - 填過去／現在的時間 → 擋下，請員工清空（＝馬上開）或改成未來時間。
 * - 開團時間要早於客人收單時間（手機團控沒有另外的客人收單欄，客人收單＝收單時間 endIso）。
 * startInput 是 datetime-local 的值（本地時間），endIso 是收單時間。
 */
export type QuickStartPlan =
  | { ok: true; openNow: boolean; startIso: string }
  | { ok: false; error: string };

export function planQuickStart(startInput: string, endIso: string, nowMs: number): QuickStartPlan {
  const raw = startInput.trim();
  if (!raw) return { ok: true, openNow: true, startIso: new Date(nowMs).toISOString() };
  const startMs = new Date(raw).getTime();
  if (!Number.isFinite(startMs)) return { ok: false, error: "開團時間看不懂，請重選；要馬上開團就清空" };
  if (startMs <= nowMs) return { ok: false, error: "開團時間要在未來；要馬上開團請把開團時間清空" };
  const endMs = new Date(endIso).getTime();
  if (Number.isFinite(endMs) && startMs >= endMs) return { ok: false, error: "開團時間必須早於客人收單時間" };
  return { ok: true, openNow: false, startIso: new Date(startMs).toISOString() };
}

/**
 * 「馬上開」建草稿那一次先寫的開團時間：現在往前 1 天。
 * 自動開團（rpc_auto_open_scheduled_campaigns @ 20260925010000:23-30）只撿
 * start_at >= created_at − 5 分鐘 的草稿；created_at 是建草稿當下，之後不會變，
 * 所以往前 1 天的草稿**永遠**撿不到 —— 加品項、上架做到一半時不會被先開出去
 * （以前寫「現在」會被撿到，可能只帶一部分品項就開團、發記事本）。
 * 不用「往後 1 天」：那種草稿中途失敗留著，隔天就會被自動開出去；
 * 而且收單時間若在 1 天內會撞 end_at > start_at 的檢查（20260422120001:200）。
 * 最後一次存檔一定寫 start_at＝現在、status＝open（rpc_upsert_campaign 更新時
 * start_at = p_start_at 整個覆寫，20260910050000:149）。
 * 排未來時間的團草稿就寫那個時間（等著被自動開），不受影響。
 */
export const QUICK_DRAFT_START_BACKDATE_MS = 24 * 60 * 60 * 1000;

export function draftStartIso(plan: { openNow: boolean; startIso: string }, nowMs: number): string {
  return plan.openNow ? new Date(nowMs - QUICK_DRAFT_START_BACKDATE_MS).toISOString() : plan.startIso;
}

/** 美食列車到開團時間不會自動開（rpc_auto_open_scheduled_campaigns @ 20260925010000:32-33） */
export function autoOpensOnSchedule(closeType: string): boolean {
  return closeType !== "food_train";
}

/** 排程開團的提示字（畫面上、建好後的卡片都用這一句） */
export function scheduledOpenHint(closeType: string): string {
  return autoOpensOnSchedule(closeType)
    ? "時間到系統會自動開團。"
    : "美食列車不會自動開，時間到請在手機團控清單按「開團」。";
}

/** 「10月7日 09:05」（本地時間）；看不懂的時間回空字串 */
export function formatScheduleLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getMonth() + 1}月${d.getDate()}日 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * 建團最後幾步寫什麼、照什麼順序：
 * - 記事本關掉 → 建好草稿後**第一件事**就呼叫 rpc_set_campaign_line_note(false)，
 *   排在加品項、改成開團之前。開團自動發文的 trigger（_line_note_on_campaign_open
 *   @ 20260929000000:21）在團「剛變成 open」那一刻看 line_note_enabled，後寫等於沒關；
 *   rpc_upsert_campaign（20260910050000:48）沒有記事本參數，只能另外寫。
 *   記事本開著不用呼叫（欄位預設就是開，20260927010000:20），行為跟以前一樣。
 * - 馬上開 → 最後一次存檔 status = open；排程 → 仍是 draft（等時間到自動開／美食列車手動開）。
 * - 上架個人賣場照開關寫在最後一次存檔（草稿那次一律先不上架，跟以前一樣）。
 */
export function quickPublishPlan(input: { openNow: boolean; lineNote: boolean; isForShop: boolean }): {
  setLineNoteOffFirst: boolean;
  finalStatus: "open" | "draft";
  isForShop: boolean;
} {
  return {
    setLineNoteOffFirst: !input.lineNote,
    finalStatus: input.openNow ? "open" : "draft",
    isForShop: input.isForShop,
  };
}
