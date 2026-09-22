// 門市管理「客人看得到」勾選框（stores.is_visible_to_customers）的檢查。
//
//   node scripts/check-store-customer-visibility.mjs
//
// ⭐ 測的是**真正的程式**，不是抄一份：直接載入門市管理頁 import 的那一支
//   apps/admin/src/lib/storeCustomerVisibility.ts
//     visibilityAfterKindChange  表單改「類型」時勾選框要變成什麼
//     customerVisibilityStatus   列表「客人看得到」欄的狀態（含「批發但客人還看得到」的醒目標示）
//
// ⭐ 兩個方向都要考：「該取消勾選的有取消」＋「不該勾回去的沒被勾回去」、
//   「該標的有標」＋「不該標的沒標」。只考一邊的測試，規則整個反過來也可能照樣綠。
//
// 載入方式同 scripts/check-store-kind-columns.mjs：Node 22.18 以上會自己把 .ts 的型別去掉；
//   掛一個 resolve hook，告訴 Node .ts 是 ES module 版的 TypeScript（lib 之間沒寫副檔名的 import 也補 .ts）。
//   ⚠ 掛了 hook 之後只能用 await import()：靜態 import 會在 hook 掛上之前就先解析完。
//
// 最後一段「接線檢查」只確認畫面真的在呼叫這兩支、真的把勾選框的值送進資料庫 ——
//   畫面自己另寫一套的話，上面測得再綠也保護不到畫面。規則本身一律在上面用真的函式考。

import assert from "node:assert/strict";
import * as nodeModule from "node:module";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

if (typeof nodeModule.registerHooks !== "function" || !process.features?.typescript) {
  console.error("❌ 這支要 Node 22.18 以上（要有 module.registerHooks 與 .ts 型別去除）。目前是 " + process.version);
  process.exit(2);
}
nodeModule.registerHooks({
  resolve(specifier, context, nextResolve) {
    let r;
    try {
      r = nextResolve(specifier, context);
    } catch (e) {
      if (!specifier.startsWith(".") || /\.[cm]?[jt]sx?$/.test(specifier)) throw e;
      r = nextResolve(`${specifier}.ts`, context);
    }
    return r.url.endsWith(".ts") ? { ...r, format: "module-typescript" } : r;
  },
});

const root = resolve(import.meta.dirname, "..");
const load = (rel) => import(pathToFileURL(resolve(root, rel)).href);
const { visibilityAfterKindChange, customerVisibilityStatus } = await load(
  "apps/admin/src/lib/storeCustomerVisibility.ts",
);

let failed = 0;
let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failed += 1;
    console.error(`  FAIL ${name}\n       ${String(e?.message ?? e).split("\n")[0]}`);
  }
}

// ============================================================
console.log("表單改「類型」（storeCustomerVisibility.visibilityAfterKindChange）");
// ============================================================
// 模擬一次編輯：打開表單時的值 opened，接著依序做 steps（改類型／自己勾），回傳最後畫面上的狀態。
// 改類型的那一下交給真正的函式；「自己勾」不經過它（跟畫面一樣）。
function simulate(opened, steps) {
  let visible = opened;
  let note = false;
  for (const s of steps) {
    if (s.kind) {
      const r = visibilityAfterKindChange(s.kind, opened);
      visible = r.isVisibleToCustomers;
      note = r.showWholesaleNote;
    } else {
      visible = s.check;
    }
  }
  return { visible, note };
}
check("改成批發 → 取消勾選，並出現說明", () => {
  assert.deepEqual(visibilityAfterKindChange("wholesale", true), { isVisibleToCustomers: false, showWholesaleNote: true });
});
check("改成批發（本來就藏著）→ 仍是不勾，並出現說明", () => {
  assert.deepEqual(visibilityAfterKindChange("wholesale", false), { isVisibleToCustomers: false, showWholesaleNote: true });
});
check("改回包子媽分店（打開時是看得到）→ 恢復勾選，說明收起來", () => {
  assert.deepEqual(visibilityAfterKindChange("branch", true), { isVisibleToCustomers: true, showWholesaleNote: false });
});
check("⭐ 改回包子媽分店（打開時是藏著）→ 維持不勾，不可以被自動勾回去", () => {
  assert.deepEqual(visibilityAfterKindChange("branch", false), { isVisibleToCustomers: false, showWholesaleNote: false });
});
check("⭐ 藏著的店：批發 → 自己勾起來 → 再改回包子媽分店 → 回到打開時的「不勾」", () => {
  assert.deepEqual(simulate(false, [{ kind: "wholesale" }, { check: true }, { kind: "branch" }]), { visible: false, note: false });
});
check("看得到的店：批發 → 包子媽分店 → 批發 → 最後是不勾、說明在", () => {
  assert.deepEqual(simulate(true, [{ kind: "wholesale" }, { kind: "branch" }, { kind: "wholesale" }]), { visible: false, note: true });
});
check("批發店打開時就是批發（已經看得到）→ 改成包子媽分店 → 維持看得到", () => {
  assert.deepEqual(simulate(true, [{ kind: "branch" }]), { visible: true, note: false });
});
check("改成批發之後自己勾回來 → 以自己勾的為準（說明留著）", () => {
  assert.deepEqual(simulate(true, [{ kind: "wholesale" }, { check: true }]), { visible: true, note: true });
});
check("新增門市（打開時預設勾選）→ 選批發不勾、改回包子媽分店又勾上", () => {
  assert.equal(simulate(true, [{ kind: "wholesale" }]).visible, false);
  assert.equal(simulate(true, [{ kind: "wholesale" }, { kind: "branch" }]).visible, true);
});

// ============================================================
console.log("列表「客人看得到」欄（storeCustomerVisibility.customerVisibilityStatus）");
// ============================================================
const st = (is_visible_to_customers, is_active, store_kind) =>
  customerVisibilityStatus({ is_visible_to_customers, is_active, store_kind });
check("⭐ 批發 ＋ 啟用中 ＋ 看得到 → 要醒目標示", () => {
  assert.equal(st(true, true, "wholesale"), "wholesale_visible");
});
check("批發 ＋ 啟用中 ＋ 藏起來 → 不標（已經處理好了）", () => {
  assert.equal(st(false, true, "wholesale"), "hidden");
});
check("批發 ＋ 停用 ＋ 看得到 → 不標（停用的店選單本來就不列）", () => {
  assert.equal(st(true, false, "wholesale"), "inactive");
});
check("包子媽分店 ＋ 啟用中 ＋ 看得到 → 看得到、不標", () => {
  assert.equal(st(true, true, "branch"), "visible");
});
check("包子媽分店 ＋ 藏起來（例：9/02、9/08 用 SQL 藏起來的店）→ 藏起來", () => {
  assert.equal(st(false, true, "branch"), "hidden");
});
check("停用 ＋ 藏起來 → 藏起來（照設定講）", () => {
  assert.equal(st(false, false, "branch"), "hidden");
});
check("包子媽分店 ＋ 停用 ＋ 看得到 → 停用中（客人選不到），不標", () => {
  assert.equal(st(true, false, "branch"), "inactive");
});
check("類型是空的（舊資料）→ 當包子媽分店，不標", () => {
  assert.equal(st(true, true, null), "visible");
});

// ============================================================
console.log("接線檢查：門市管理頁真的在用上面兩支、真的把勾選框的值送進資料庫");
// ============================================================
const page = readFileSync(resolve(root, "apps/admin/src/app/(protected)/stores/page.tsx"), "utf8");
check("門市管理頁 import 這支 lib", () => {
  assert.match(page, /from\s+["']@\/lib\/storeCustomerVisibility["']/);
});
check("改類型時問 visibilityAfterKindChange（傳「打開表單時的值」），結果真的寫回勾選框與說明", () => {
  assert.match(page, /visibilityAfterKindChange\(\s*kind\s*,\s*openedVisible\s*\)/);
  assert.match(page, /\[openedVisible\]\s*=\s*useState\(\s*initial\.is_visible_to_customers\s*\)/);
  assert.match(page, /is_visible_to_customers:\s*next\.isVisibleToCustomers/, "改類型沒有把結果寫回勾選框");
  assert.match(page, /setWholesaleNote\(\s*next\.showWholesaleNote\s*\)/, "改類型沒有把結果寫回說明");
  assert.match(page, /\{wholesaleNote && \(/, "說明那一行沒有跟著 wholesaleNote 出現");
});
check("列表：欄位內容、整列醒目底色、上方點名，三處都問 customerVisibilityStatus", () => {
  assert.match(page, /<CustomerVisibilityCell status=\{customerVisibilityStatus\(r\)\} \/>/, "欄位內容沒問 customerVisibilityStatus");
  const n = page.match(/customerVisibilityStatus\(r\)\s*===\s*"wholesale_visible"/g)?.length ?? 0;
  assert.equal(n, 2, `醒目底色＋上方點名應該各問一次，實際 ${n} 處`);
});
check("勾選框綁 is_visible_to_customers、勾了會寫回；存檔送 p_is_visible_to_customers；列表有讀這個欄位", () => {
  assert.match(page, /checked=\{v\.is_visible_to_customers\}/);
  assert.match(page, /onChange=\{\(e\) => up\("is_visible_to_customers", e\.target\.checked\)\}/);
  assert.match(page, /p_is_visible_to_customers:\s*v\.is_visible_to_customers/);
  assert.match(page, /\.select\("[^"]*\bis_visible_to_customers\b[^"]*"\)/);
});
check("新增門市預設勾選（EMPTY 的 is_visible_to_customers 是 true）", () => {
  const empty = page.match(/\nconst EMPTY\b[^=]*=\s*\{([\s\S]*?)\n\};/)?.[1];
  assert.ok(empty, "找不到 const EMPTY = { … }; 這一段");
  assert.match(empty, /\bis_visible_to_customers:\s*true,/);
});

console.log(`\n${passed} 項通過、${failed} 項失敗`);
if (failed > 0) {
  console.error("❌ store customer visibility rules FAILED");
  process.exit(1);
}
console.log("store customer visibility rules ok");
