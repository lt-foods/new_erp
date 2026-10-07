// 後台列表「點進明細再回來，篩選條件還在」的共用小工具 —— 純函式（不碰 React、不碰資料庫），單獨測試：
//   node --test apps/admin/src/lib/listFilters.test.mjs
// React 那一層（第一次渲染就帶回、條件一改就存）在 ./useListFilters.ts。
//
// 條件存在「這個瀏覽器分頁」的 sessionStorage，每個列表一把 key，再綁登入的帳號：
//   - 從明細頁的「← 回…」、按瀏覽器返回、從側欄再點進來，都會帶回；重新整理（F5）也會帶回。
//   - 關掉這個分頁就清掉；別的分頁、別的帳號各管各的。
// ⚠️ 只存篩選／搜尋／排序／分頁這類「條件」。勾選框、送出中、彈窗這種暫時狀態一律不存 ——
//   帶回舊的勾選，等於讓人在沒重新看過的情況下送出。
// 帶回的值逐欄驗證：格式不對（舊版存檔、被手改、選項被拿掉）那一欄就退回預設值，壞資料不會把頁面弄壞。
// sessionStorage 讀寫失敗（無痕模式、封鎖網站資料、容量滿）一律當作沒有存檔，頁面照常用預設值。

/** 存檔格式版本；欄位意義改了就加 1，舊版存檔整份丟掉 */
export const LIST_FILTERS_VERSION = 1;

/** 單一欄位的驗證：值合格就回 true */
export type FieldCheck<V> = (v: unknown) => v is V;

/** 一個列表要存哪些條件：頁面代號（當 key 用）、預設值、每一欄怎麼驗 */
export type ListFilterSpec<T extends Record<string, unknown>> = {
  page: string;
  defaults: T;
  fields: { [K in keyof T]: FieldCheck<T[K]> };
};

/** 讀寫只用到這兩個方法（真的 sessionStorage，或測試用的假物件） */
export type FilterStorage = Pick<Storage, "getItem" | "setItem">;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ── 欄位驗證 ──

/** 值必須是清單裡的其中一個字串（狀態分頁、下拉選單、排序欄位…） */
export function oneOf<V extends string>(allowed: readonly V[]): FieldCheck<V> {
  return (v: unknown): v is V => typeof v === "string" && (allowed as readonly string[]).includes(v);
}

/** 月份篩選：空字串（沒選）或 YYYY-MM */
export const isMonthOrEmpty: FieldCheck<string> = (v: unknown): v is string =>
  typeof v === "string" && (v === "" || /^\d{4}-(0[1-9]|1[0-2])$/.test(v));

/** 日期篩選：空字串（沒選）或真的存在的 YYYY-MM-DD（2 月 30 日這種送進資料庫會報錯，當壞資料） */
export const isDateOrEmpty: FieldCheck<string> = (v: unknown): v is string => {
  if (typeof v !== "string") return false;
  if (v === "") return true;
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const t = new Date(Date.UTC(y, mo - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === mo - 1 && t.getUTCDate() === d;
};

/** 搜尋框文字：上限 200 字，超過當作壞資料 */
export const isSearchText: FieldCheck<string> = (v: unknown): v is string =>
  typeof v === "string" && v.length <= 200;

/** 分頁頁碼：1 起的整數 */
export const isPageNo: FieldCheck<number> = (v: unknown): v is number =>
  typeof v === "number" && Number.isSafeInteger(v) && v >= 1;

export const isBool: FieldCheck<boolean> = (v: unknown): v is boolean => typeof v === "boolean";

/** 「全部」或某一筆的 id（例：供應商下拉） */
export const isIdOrAll: FieldCheck<number | "all"> = (v: unknown): v is number | "all" =>
  v === "all" || (typeof v === "number" && Number.isSafeInteger(v) && v > 0);

// ── 分頁 ──

/**
 * 查詢回來後，頁碼該停在哪一頁：超過最後一頁就改看最後一頁，沒資料就看第 1 頁；沒超過就原樣回傳。
 * （帶回的頁碼、離開期間單子變少、刪掉最後一頁的最後一張，都會超頁 → 停在空白頁、總筆數不到一頁時連分頁鈕都沒有）
 * 總筆數或每頁筆數不是正常數字時不動頁碼（算不出最後一頁，寧可不改）。
 * 回傳值只會 ≤ 原頁碼、最小 1 → 列表「頁碼不同就改頁再查一次」最多收斂到 1，不會一直重查。
 */
export function clampPage(page: number, total: number, pageSize: number): number {
  if (!Number.isFinite(total) || total < 0 || !Number.isFinite(pageSize) || pageSize <= 0) return page;
  const lastPage = Math.max(1, Math.ceil(total / pageSize));
  return page > lastPage ? lastPage : page;
}

// ── 讀寫 ──

/** 一個列表在這個分頁、這個帳號下的 key */
export function listFiltersKey(page: string, userId: string | null | undefined): string {
  return `list-filters:${page}:${userId || "-"}`;
}

/** 只挑規格裡列的欄位存（頁面多傳了別的東西也不會被存進去） */
export function serializeListFilters<T extends Record<string, unknown>>(
  values: T,
  spec: ListFilterSpec<T>,
): string {
  const f: Record<string, unknown> = {};
  for (const k of Object.keys(spec.fields)) f[k] = values[k];
  return JSON.stringify({ v: LIST_FILTERS_VERSION, f });
}

/** 存檔字串 → 條件；整份壞掉或版本不對就全部用預設值，單一欄位不合格就那一欄用預設值 */
export function parseListFilters<T extends Record<string, unknown>>(
  raw: string | null,
  spec: ListFilterSpec<T>,
): T {
  const out: T = { ...spec.defaults };
  if (!raw) return out;
  let doc: unknown;
  try {
    doc = JSON.parse(raw);
  } catch {
    return out;
  }
  if (!isRecord(doc) || doc.v !== LIST_FILTERS_VERSION || !isRecord(doc.f)) return out;
  const saved = doc.f;
  for (const k of Object.keys(spec.fields) as (keyof T & string)[]) {
    if (!Object.prototype.hasOwnProperty.call(saved, k)) continue;
    const v = saved[k];
    if (spec.fields[k](v)) out[k] = v;
  }
  return out;
}

/** 讀上次存的條件；沒有存檔、讀不到（storage 丟錯）一律回預設值 */
export function readListFilters<T extends Record<string, unknown>>(
  storage: FilterStorage | null,
  key: string,
  spec: ListFilterSpec<T>,
): T {
  if (!storage) return { ...spec.defaults };
  let raw: string | null;
  try {
    raw = storage.getItem(key);
  } catch {
    return { ...spec.defaults };
  }
  return parseListFilters(raw, spec);
}

/** 存條件（serializeListFilters 的結果）；寫不進去回 false，不往外丟錯 */
export function writeListFilters(storage: FilterStorage | null, key: string, raw: string): boolean {
  if (!storage) return false;
  try {
    storage.setItem(key, raw);
    return true;
  } catch {
    return false;
  }
}

/** 瀏覽器的 sessionStorage；拿不到（伺服器端、被封鎖時連讀這個屬性都會丟錯）回 null */
export function browserSessionStorage(): FilterStorage | null {
  try {
    return typeof window === "undefined" ? null : window.sessionStorage;
  } catch {
    return null;
  }
}
