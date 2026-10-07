// 後台列表保存篩選條件：純函式測試
//   node --test apps/admin/src/lib/listFilters.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  LIST_FILTERS_VERSION,
  browserSessionStorage,
  clampPage,
  isBool,
  isDateOrEmpty,
  isIdOrAll,
  isMonthOrEmpty,
  isPageNo,
  isSearchText,
  listFiltersKey,
  oneOf,
  parseListFilters,
  readListFilters,
  serializeListFilters,
  writeListFilters,
} from "./listFilters.ts";

const SPEC = {
  page: "test-list",
  defaults: { month: "", status: "", search: "", from: "", page: 1, supplier: "all", pivot: false },
  fields: {
    month: isMonthOrEmpty,
    status: oneOf(["", "draft", "sent"]),
    search: isSearchText,
    from: isDateOrEmpty,
    page: isPageNo,
    supplier: isIdOrAll,
    pivot: isBool,
  },
};

const GOOD = { month: "2026-09", status: "sent", search: "鮭魚", from: "2026-09-01", page: 3, supplier: 12, pivot: true };

/** 假的 sessionStorage：可以設定讀或寫時丟錯 */
function fakeStorage({ throwOnGet = false, throwOnSet = false } = {}) {
  const map = new Map();
  return {
    map,
    getItem(k) {
      if (throwOnGet) throw new Error("SecurityError: access denied");
      return map.has(k) ? map.get(k) : null;
    },
    setItem(k, v) {
      if (throwOnSet) throw new Error("QuotaExceededError");
      map.set(k, String(v));
    },
  };
}

test("存了再讀：每個欄位原樣帶回", () => {
  const raw = serializeListFilters(GOOD, SPEC);
  assert.deepEqual(parseListFilters(raw, SPEC), GOOD);
});

test("只存規格裡列的欄位：頁面多傳的暫時狀態（勾選、送出中）不會被存進去", () => {
  const raw = serializeListFilters({ ...GOOD, selected: [1, 2], sending: true }, SPEC);
  const doc = JSON.parse(raw);
  assert.equal(doc.v, LIST_FILTERS_VERSION);
  assert.deepEqual(Object.keys(doc.f).sort(), Object.keys(SPEC.fields).sort());
  assert.equal("selected" in doc.f, false);
  assert.equal("sending" in doc.f, false);
});

test("沒有存檔：全部用預設值", () => {
  assert.deepEqual(parseListFilters(null, SPEC), SPEC.defaults);
  assert.deepEqual(parseListFilters("", SPEC), SPEC.defaults);
});

test("壞資料：不是 JSON、不是物件、版本不對 → 整份丟掉用預設值", () => {
  for (const raw of [
    "{壞掉",
    "null",
    "[]",
    "123",
    '"2026-09"',
    JSON.stringify({ v: LIST_FILTERS_VERSION + 1, f: GOOD }),
    JSON.stringify({ v: 0, f: GOOD }),
    JSON.stringify({ f: GOOD }),
    JSON.stringify({ v: LIST_FILTERS_VERSION, f: null }),
    JSON.stringify({ v: LIST_FILTERS_VERSION, f: [1, 2] }),
    JSON.stringify(GOOD), // 沒有包版本的舊格式
  ]) {
    assert.deepEqual(parseListFilters(raw, SPEC), SPEC.defaults, raw);
  }
});

test("單一欄位不合格：只有那一欄退回預設值，其他照樣帶回", () => {
  const raw = JSON.stringify({
    v: LIST_FILTERS_VERSION,
    f: { ...GOOD, status: "removed_status", page: 0 },
  });
  assert.deepEqual(parseListFilters(raw, SPEC), { ...GOOD, status: "", page: 1 });
});

test("缺欄位、多欄位：缺的用預設值、多的忽略", () => {
  const raw = JSON.stringify({ v: LIST_FILTERS_VERSION, f: { month: "2026-08", extra: "x" } });
  const got = parseListFilters(raw, SPEC);
  assert.deepEqual(got, { ...SPEC.defaults, month: "2026-08" });
  assert.equal("extra" in got, false);
});

test("帶回的結果是新物件，改它不會動到預設值", () => {
  const got = parseListFilters(null, SPEC);
  got.month = "2026-01";
  assert.equal(SPEC.defaults.month, "");
});

test("月份驗證", () => {
  for (const ok of ["", "2026-09", "2026-12", "2027-01"]) assert.equal(isMonthOrEmpty(ok), true, ok);
  for (const bad of ["2026-13", "2026-00", "2026-9", "2026-09-01", "202609", " 2026-09", null, 202609, undefined]) {
    assert.equal(isMonthOrEmpty(bad), false, String(bad));
  }
});

test("日期驗證", () => {
  for (const ok of ["", "2026-09-01", "2026-12-31", "2028-02-29"]) assert.equal(isDateOrEmpty(ok), true, ok);
  for (const bad of [
    "2026-09", "2026-9-1", "2026-09-32", "2026-02-30", "2026-02-29", "2026-13-01", "2026-00-10",
    "2026/09/01", "2026-09-01T00:00", null, 0,
  ]) {
    assert.equal(isDateOrEmpty(bad), false, String(bad));
  }
});

test("搜尋文字、頁碼、布林、id 驗證", () => {
  assert.equal(isSearchText(""), true);
  assert.equal(isSearchText("PO-2026"), true);
  assert.equal(isSearchText("字".repeat(200)), true);
  assert.equal(isSearchText("字".repeat(201)), false);
  assert.equal(isSearchText(123), false);

  assert.equal(isPageNo(1), true);
  assert.equal(isPageNo(25), true);
  for (const bad of [0, -1, 1.5, "2", NaN, Infinity, null]) assert.equal(isPageNo(bad), false, String(bad));

  assert.equal(isBool(true), true);
  assert.equal(isBool(false), true);
  assert.equal(isBool("true"), false);
  assert.equal(isBool(1), false);

  assert.equal(isIdOrAll("all"), true);
  assert.equal(isIdOrAll(7), true);
  for (const bad of [0, -3, 1.2, "7", "ALL", null]) assert.equal(isIdOrAll(bad), false, String(bad));

  const tab = oneOf(["all", "draft"]);
  assert.equal(tab("draft"), true);
  assert.equal(tab("Draft"), false);
  assert.equal(tab(undefined), false);
});

test("key：每頁一把、再分帳號；沒有帳號時給固定字", () => {
  assert.equal(listFiltersKey("purchase-orders", "u1"), "list-filters:purchase-orders:u1");
  assert.notEqual(listFiltersKey("purchase-orders", "u1"), listFiltersKey("purchase-orders", "u2"));
  assert.notEqual(listFiltersKey("purchase-orders", "u1"), listFiltersKey("purchase-requests", "u1"));
  assert.equal(listFiltersKey("x", null), "list-filters:x:-");
  assert.equal(listFiltersKey("x", undefined), "list-filters:x:-");
});

test("讀寫：寫進去再讀回來；別的 key 不受影響", () => {
  const st = fakeStorage();
  const key = listFiltersKey(SPEC.page, "u1");
  assert.equal(writeListFilters(st, key, serializeListFilters(GOOD, SPEC)), true);
  assert.deepEqual(readListFilters(st, key, SPEC), GOOD);
  assert.deepEqual(readListFilters(st, listFiltersKey(SPEC.page, "u2"), SPEC), SPEC.defaults);
});

test("無痕／封鎖：讀的時候丟錯 → 回預設值、不往外丟", () => {
  const st = fakeStorage({ throwOnGet: true });
  assert.deepEqual(readListFilters(st, "k", SPEC), SPEC.defaults);
});

test("容量滿／封鎖：寫的時候丟錯 → 回 false、不往外丟", () => {
  const st = fakeStorage({ throwOnSet: true });
  assert.equal(writeListFilters(st, "k", serializeListFilters(GOOD, SPEC)), false);
});

test("沒有 storage（伺服器端）：讀回預設值、寫回 false", () => {
  assert.deepEqual(readListFilters(null, "k", SPEC), SPEC.defaults);
  assert.equal(writeListFilters(null, "k", "{}"), false);
  // node 裡沒有 window
  assert.equal(browserSessionStorage(), null);
});

test("瀏覽器連讀 window.sessionStorage 這個屬性都丟錯時 → 回 null", () => {
  const had = Object.prototype.hasOwnProperty.call(globalThis, "window");
  const fakeWindow = {};
  Object.defineProperty(fakeWindow, "sessionStorage", {
    get() {
      throw new Error("SecurityError: The operation is insecure.");
    },
  });
  globalThis.window = fakeWindow;
  try {
    assert.equal(browserSessionStorage(), null);
  } finally {
    if (!had) delete globalThis.window;
  }
});

test("頁碼夾回範圍：沒超過最後一頁就不動", () => {
  assert.equal(clampPage(1, 90, 20), 1);
  assert.equal(clampPage(3, 90, 20), 3);
  assert.equal(clampPage(5, 90, 20), 5); // 90 筆、每頁 20 → 最後一頁是 5
  assert.equal(clampPage(2, 40, 20), 2); // 剛好整除
});

test("頁碼夾回範圍：超過最後一頁 → 改看最後一頁", () => {
  assert.equal(clampPage(6, 90, 20), 5);
  assert.equal(clampPage(9, 30, 20), 2);
  assert.equal(clampPage(5, 3, 20), 1); // 換條件後只剩 3 筆（不到一頁）→ 第 1 頁
  assert.equal(clampPage(3, 40, 20), 2); // 剛好整除時最後一頁是 2，不是 3
});

test("頁碼夾回範圍：沒資料 → 第 1 頁（不會變成第 0 頁）", () => {
  assert.equal(clampPage(4, 0, 20), 1);
  assert.equal(clampPage(1, 0, 30), 1);
});

test("頁碼夾回範圍：總筆數或每頁筆數不正常 → 不動頁碼", () => {
  for (const total of [NaN, -1, Infinity, undefined, null, "30"]) {
    assert.equal(clampPage(4, total, 20), 4, String(total));
  }
  for (const size of [0, -20, NaN]) {
    assert.equal(clampPage(4, 90, size), 4, String(size));
  }
});

test("頁碼夾回範圍：反覆套用會收斂（列表「頁碼不同就改頁再查一次」不會無限重查）", () => {
  // 同一個條件（總筆數不變）：最多改一次頁，再套一次就不動
  for (const [page, total] of [[25, 3], [9, 30], [6, 90], [3, 0], [2, 40]]) {
    const once = clampPage(page, total, 20);
    assert.equal(clampPage(once, total, 20), once, `${page} 頁 / ${total} 筆`);
  }
  // 每次重查時單子都又變少：頁碼只往小的方向走、最小 1
  let page = 25;
  for (const total of [500, 120, 41, 25, 0]) {
    const next = clampPage(page, total, 20);
    assert.ok(next <= page && next >= 1, `${page}→${next}`);
    page = next;
  }
  assert.equal(page, 1);
});
