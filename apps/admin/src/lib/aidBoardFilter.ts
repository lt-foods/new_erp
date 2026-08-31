// 互助交流板的「打字搜尋」與「分店篩選」—— 兩個入口共用的唯一一份條件。
//
// 為什麼要獨立成一支 lib：板上對 mutual_aid_board 的查詢有**兩個**入口，各查各的 ——
// 列表頁 inventory/mutual-aid/page.tsx，以及列印頁 inventory/mutual-aid/print/page.tsx
// （它不吃列表頁的結果，自己重新查一次資料庫）。條件複製成兩份、哪天只改到其中一份，
// 就會變成「畫面上篩到剩 3 筆、按列印印出來是全部」—— 而且紙已經拿在手上了，
// 完全看不出來哪裡不對。條件收在這裡，兩邊只可能一起對、或一起錯。
//
// ⛔ 這兩個條件一定要**送後端**，不可以改成把列撈回來再 Array.filter：
//    歷史分頁一次只讀 20 筆（列表頁的 HISTORY_PAGE），在那 20 筆裡篩，
//    會讓「其實有 500 筆歷史」的店看起來一筆貼文都沒有。那是靜默的錯，
//    比沒有這個功能還糟 —— 使用者不會知道自己被騙了。

import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * 關鍵字換算 sku_id 時一次最多取幾筆。
 *
 * 500 不是隨手挑的，是本 repo 對 `.in()` 的既有慣例
 * （campaigns/page.tsx:336-340「避免 .in() 把 URL 塞爆」，該頁三處都切 500）：
 * postgrest-js 的 `.in()` 走 query string，一個 5 位數 id 編碼後約 8 字元
 * （逗號會變 %2C）→ 500 個 ≈ 4KB，還在安全範圍內。
 *
 * ⚠ 另一個非它不可的理由：PostgREST 單次 select 的 max_rows 就是 1000
 * （supabase/config.toml、lib/fetchAllRows.ts 檔頭有實測），不寫 limit 一樣會被
 * 截在 1000，只是截得**沒有聲音**。寫死 500 並回報有沒有截到，至少是講得出來的。
 */
export const AID_SEARCH_SKU_LIMIT = 500;

export type AidBoardFilters = {
  /** 只看這家店貼的（mutual_aid_board.offering_store_id）；null = 全部門市 */
  storeId: number | null;
  /** 打字搜尋的關鍵字；空字串 = 不搜尋 */
  keyword: string;
};

/**
 * PostgREST 的 `or()` 用逗號分條件、括號分群，`%` 是 ilike 的萬用字元 ——
 * 這四個字元原樣送進去會把查詢字串切壞（例如打「(」會讓整發查詢 400）。
 *
 * 這個寫法源自全 repo 搜尋框的共同慣例（products / campaigns / orders / stores /
 * members… 共 15 處，互助板自己的 SkuSearchInput 也是同一行），⛔ 不要另外發明一套。
 *
 * ⭐ 但比那 15 處**多擋一個 `*`**（2026-08-31 審查抓到）：PostgREST 為了讓人不必在
 *    網址裡編碼 `%`，官方允許用 `*` 當 like/ilike 的萬用字元別名（URL Grammar 把
 *    `*` 列為 reserved）。不擋的話，使用者搜「5*10 規格」會被展開成萬用字元，
 *    撈回一堆不相關的商品，還可能把真正要找的那個擠出 500 筆上限之外。
 *    ⛔ 那 15 處的同一個洞**不要在這個 PR 一起改** —— 那是全站的舊缺口，
 *       另開技術債單處理，不要把這個功能 PR 擴大成全站掃射。
 *
 * 兩個**刻意不擋**的字元，不是漏掉：
 *   - `'` 單引號：這裡組的是 query string、不是 SQL，PostgREST 的 logic value
 *     只有 `,` `(` `)` 是結構字元，`'` 會被當成一般文字帶進 ilike。擋掉反而會讓
 *     「Lay's」這種帶撇號的品名搜不到。（2026-08-31 阿審查 PostgREST 文件與
 *     QueryParams.hs 原始碼確認過。）
 *   - `_` 底線：它在 SQL LIKE 是「任一個字元」，確實會多撈一點點。但擋掉的代價
 *     更大 —— 本系統真的有商品編號帶底線（例：`__叉燒肉(克)`），把 `_` 換成空白
 *     會讓「A_B」變成「A B」而**再也對不到 A_B**。多撈一格 vs 整個找不到，
 *     照「漏的時候往哪邊倒」的原則選多撈。
 */
export function safeAidKeyword(raw: string): string {
  return raw.replace(/[%*,()]/g, " ").trim();
}

export type AidKeywordCondition = {
  /** 丟給 `.or()` 的字串；null = 這個關鍵字不必加條件（空字串／只打了特殊字元） */
  or: string | null;
  /** 符合關鍵字的商品**超過上限被截掉了** → 結果可能不完整，畫面必須講出來 */
  skuTruncated: boolean;
};

/**
 * 關鍵字 → 貼文查詢要加的 `.or()` 條件。**兩段式**，因為商品名不在板上：
 * mutual_aid_board 只有 `sku_id`，品名是列表頁第二段另外查 `skus` 補的
 * （page.tsx:236）→ 沒辦法一發查完，得先把關鍵字換成 sku_id 清單。
 */
export async function buildAidKeywordCondition(
  sb: SupabaseClient,
  keyword: string,
): Promise<AidKeywordCondition> {
  const safe = safeAidKeyword(keyword);
  if (!safe) return { or: null, skuTruncated: false };

  // ⚠ 這一發**不可以**加 `.eq("status", "active")` 濾商品。
  //   SkuSearchInput（page.tsx:1246）有加是對的 —— 那是「要挑一個商品來貼文」，
  //   本來就只該挑還在賣的。但這裡是「回頭找貼文」，歷史貼文引用的商品
  //   很可能早就停用了，濾掉的話「歷史」分頁會搜不到它們，而且畫面上
  //   長得跟「真的沒這筆」一模一樣。
  //
  // ⚠ error 一定要接（2026-08-31 審查抓到）。只取 data 的話，這發查詢失敗
  //   （斷網、RLS、逾時）會被 `data ?? []` 當成「0 個商品命中」，接著只靠
  //   spot_title / note 去查板子 —— 靠商品名命中的貼文**安靜地消失**，
  //   畫面只是「結果比較少」，沒有任何錯誤提示。那正好是本檔檔頭寫的那種
  //   靜默錯誤。丟出去讓呼叫端既有的 catch 去顯示。
  //
  // 取 LIMIT+1 筆是為了分辨「剛好 500 筆」與「超過 500 筆」：
  // 用 `>= 500` 判斷的話，資料庫剛好只有 500 筆符合時會跳假警告。
  // 多的那一筆只用來判斷，不會送進 in.() 條件。
  const { data, error } = await sb
    .from("skus")
    .select("id")
    .or(`sku_code.ilike.%${safe}%,product_name.ilike.%${safe}%,variant_name.ilike.%${safe}%`)
    .limit(AID_SEARCH_SKU_LIMIT + 1);
  if (error) throw new Error(error.message);
  const matched = ((data ?? []) as { id: number }[]).map((s) => s.id);
  const skuTruncated = matched.length > AID_SEARCH_SKU_LIMIT;
  const skuIds = skuTruncated ? matched.slice(0, AID_SEARCH_SKU_LIMIT) : matched;

  // 手打的手動現貨**沒有 sku_id**，名字只存在 spot_title
  // （sku_id 在 20260802000040 放寬成 nullable；page.tsx:212 的 select 也證實）
  // → 少了 spot_title 這一條，手動現貨就整批搜不到。
  const conds = [`spot_title.ilike.%${safe}%`, `note.ilike.%${safe}%`];

  // `in.(...)` 放在 `or()` 裡是 PostgREST 支援的寫法，本 repo 已經在用
  //（hq/inbox/page.tsx:451 `status.in.(draft,confirmed),and(...)`）。
  // ⛔ 空清單不能寫成 `in.()` —— 那是語法錯誤，整發查詢會 400，
  //    而「關鍵字一個商品都沒對到」是很常見的情況，不是例外。
  if (skuIds.length > 0) conds.unshift(`sku_id.in.(${skuIds.join(",")})`);

  return { or: conds.join(","), skuTruncated };
}

/**
 * 把兩個篩選套到「查 mutual_aid_board 的那發查詢」上。
 * ⭐ 列表頁與列印頁都只能走這支，不要各自 `.eq()` / `.or()`。
 *
 * q 收 supabase query builder。泛型只用來把型別原樣還給呼叫端；內部轉 any 是
 * 本 repo 對「拿 query builder 當參數」的既有寫法（lib/fetchAllRows.ts:11），
 * PostgrestFilterBuilder 的泛型串不進來。
 */
type AidQueryBuilder = {
  eq(column: string, value: unknown): AidQueryBuilder;
  or(filters: string): AidQueryBuilder;
};

export async function applyAidBoardFilters<Q>(
  sb: SupabaseClient,
  q: Q,
  f: AidBoardFilters,
): Promise<{ q: Q; skuTruncated: boolean }> {
  let out = q as unknown as AidQueryBuilder;
  if (f.storeId != null) out = out.eq("offering_store_id", f.storeId);
  const kw = await buildAidKeywordCondition(sb, f.keyword);
  if (kw.or) out = out.or(kw.or);
  return { q: out as unknown as Q, skuTruncated: kw.skuTruncated };
}

/**
 * 列表頁 → 列印頁的網址參數（接在既有的 `?type=…&view=…` 後面，含開頭的 `&`）。
 *
 * ⚠ kw 一定要 `encodeURIComponent`：它是使用者打的自由文字，帶一個 `&` 或 `#`
 *   就會把後面的參數整段吃掉 —— 印出來會變成「沒篩到那個關鍵字」的全部清單，
 *   剛好是本案最想避免的那種錯。既有的 type / view 沒編碼是因為它們是固定的
 *   列舉值，不是使用者打的字。
 */
export function aidBoardFilterParams(f: AidBoardFilters): string {
  const parts: string[] = [];
  if (f.storeId != null) parts.push(`store=${f.storeId}`);
  const safe = safeAidKeyword(f.keyword);
  if (safe) parts.push(`kw=${encodeURIComponent(safe)}`);
  return parts.length > 0 ? `&${parts.join("&")}` : "";
}

/**
 * 列印頁反過來把參數讀回 AidBoardFilters。
 * get 直接吃 `useSearchParams().get`（它回來的值已經解過碼）。
 * 判法對齊列印頁既有的 id 參數寫法（print/page.tsx:103-104）。
 */
export function parseAidBoardFilters(get: (key: string) => string | null): AidBoardFilters {
  const storeParam = Number(get("store"));
  return {
    storeId: Number.isFinite(storeParam) && storeParam > 0 ? storeParam : null,
    keyword: get("kw") ?? "",
  };
}
