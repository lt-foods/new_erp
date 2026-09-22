// 門市類型（PR #983）：撿貨矩陣「哪些分店欄要出現／哪些格子收得下」的檢查。
//
//   node scripts/check-store-kind-columns.mjs
//
// ⭐ 測的是**真正的程式**，不是抄一份。直接載入畫面 import 的那兩支：
//   apps/admin/src/lib/pickingDraftView.ts   撿貨草稿（編輯＋列印）要有哪些分店欄（buildStoreColumns）
//   apps/admin/src/lib/pickingMatrixRules.ts 修正數量彈窗要有哪些分店欄（buildPickModalColumns）、
//                                            派貨工作台哪些格子規劃器收得下（plannerCanTakeCell）
//   （#983 第一版測的是自己抄的複本 buildColumnsLikeSource —— 真的程式被改壞照樣綠，審查 P2-4。）
//
// ⭐ 兩個方向都要考：「該出現的有出現」＋「不該出現的沒出現」。只考一邊的測試，
//   規則整個反過來也可能照樣綠。
//
// 載入方式：Node 22.18 以上會自己把 .ts 的型別去掉；lib 之間的 import 沒寫副檔名
//   （Next.js 的寫法，例：pickingDraftView.ts 的 `from "./storeOrder"`），
//   所以掛一個 resolve hook：找不到時補 .ts，並告訴 Node 這是 ES module 版的 TypeScript。
//   ⚠ 掛了 hook 之後只能用 await import()：靜態 import 會在 hook 掛上之前就先解析完。
//
// 最後一段「接線檢查」只確認畫面真的在呼叫這幾支 —— 畫面自己另寫一套的話，
//   上面測得再綠也保護不到畫面。規則本身一律在上面用真的函式考，不靠比對字串。

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
const { buildStoreColumns } = await load("apps/admin/src/lib/pickingDraftView.ts");
const { buildPickModalColumns, buildDemandPoSkuStore, plannerCanTakeCell, poSkuStoreKey } = await load(
  "apps/admin/src/lib/pickingMatrixRules.ts",
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
const ids = (cols) => cols.map((c) => Number(c.id));
const stateOf = (cols, id) => cols.find((c) => Number(c.id) === id)?.state;

// 共用的分店：包子媽分店 / 批發 / 停用的包子媽分店 / 停用的批發
const STORES = [
  { id: 1, code: "LELE-三峽", name: "三峽店", is_active: true, store_kind: "branch" },
  { id: 2, code: "W001", name: "團媽甲", is_active: true, store_kind: "wholesale" },
  { id: 3, code: "S003", name: "收掉的店", is_active: false, store_kind: "branch" },
  { id: 4, code: "W004", name: "收掉的團媽", is_active: false, store_kind: "wholesale" },
];

// ============================================================
console.log("撿貨草稿（pickingDraftView.buildStoreColumns）");
// ============================================================
const cell = (store_id, qty) => ({
  sku_id: 10,
  store_id,
  qty,
  snapshot_sku_code: "SKU",
  snapshot_sku_label: "商品",
  snapshot_store_code: `#${store_id}`,
  snapshot_store_name: `快照店 ${store_id}`,
});
check("包子媽分店：草稿沒量也顯示", () => {
  assert.equal(stateOf(buildStoreColumns(STORES, [], new Map()), 1), "active");
});
check("批發：草稿沒量不顯示（含「加入商品時建的 qty = 0 列」）", () => {
  assert.ok(!ids(buildStoreColumns(STORES, [], new Map())).includes(2));
  assert.ok(!ids(buildStoreColumns(STORES, [cell(2, 0)], new Map())).includes(2));
});
check("批發：草稿有量要顯示", () => {
  assert.equal(stateOf(buildStoreColumns(STORES, [cell(2, 4)], new Map()), 2), "active");
});
check("停用：草稿沒量不顯示（包子媽分店、批發都一樣）", () => {
  const got = ids(buildStoreColumns(STORES, [cell(3, 0)], new Map()));
  assert.ok(!got.includes(3) && !got.includes(4), `實際欄位：${got.join(",")}`);
});
check("停用：草稿有量要顯示並標停用（包子媽分店、批發都一樣）", () => {
  const cols = buildStoreColumns(STORES, [cell(3, 1), cell(4, 2)], new Map());
  assert.equal(stateOf(cols, 3), "inactive");
  assert.equal(stateOf(cols, 4), "inactive");
});
check("查不到的店：有量要顯示並標已刪除；查詢失敗標無法確認", () => {
  const cols = buildStoreColumns(STORES, [cell(99, 2)], new Map());
  assert.equal(stateOf(cols, 99), "missing");
  assert.equal(cols.find((c) => c.id === 99)?.name, "快照店 99");
  assert.equal(stateOf(buildStoreColumns(STORES, [cell(100, 0)], null), 100), "unknown");
});

// ============================================================
console.log("總倉收件匣「修正數量」（pickingMatrixRules.buildPickModalColumns）");
// ============================================================
const modal = (rowStoreIds, newCellStoreIds, showWholesale) =>
  buildPickModalColumns({ allStores: STORES, rowStoreIds, newCellStoreIds, showWholesale });
check("開關關 ＋ 批發不在這張單上 → 不顯示，而且算進「藏了幾家」", () => {
  const r = modal([1], [], false);
  assert.ok(!ids(r.columns).includes(2), `實際欄位：${ids(r.columns).join(",")}`);
  assert.equal(r.hiddenWholesaleCount, 1);
  assert.equal(r.optionalWholesaleCount, 1);
});
check("開關開 → 批發顯示，「藏了幾家」歸零", () => {
  const r = modal([1], [], true);
  assert.equal(stateOf(r.columns, 2), "active");
  assert.equal(r.hiddenWholesaleCount, 0);
});
check("開關開 ＋ 批發但已停用 → 仍不顯示（開關只叫得出啟用中的）", () => {
  const got = ids(modal([], [], true).columns);
  assert.ok(!got.includes(4) && !got.includes(3), `實際欄位：${got.join(",")}`);
});
check("開關關 ＋ 已經填了新數量 → 仍顯示（不可以看不到卻照樣送出）", () => {
  const r = modal([], [2], false);
  assert.equal(stateOf(r.columns, 2), "active");
  assert.equal(r.hiddenWholesaleCount, 0);
});
check("批發本單有列 → 開關關也顯示", () => {
  assert.equal(stateOf(modal([2], [], false).columns, 2), "active");
});
check("包子媽分店 → 開關開關都顯示（本單沒列也一樣）", () => {
  assert.equal(stateOf(modal([], [], false).columns, 1), "active");
  assert.equal(stateOf(modal([], [], true).columns, 1), "active");
});
check("停用但本單有列 → 顯示並標停用", () => {
  assert.equal(stateOf(modal([3], [], false).columns, 3), "inactive");
});
check("被硬刪的店本單有列 → 顯示並標已刪除", () => {
  const col = modal([77], [], false).columns.find((c) => c.id === 77);
  assert.equal(col?.state, "missing");
  assert.equal(col?.is_active, false);
  assert.equal(col?.name, "分店 #77");
});
check("store_id 是字串（PostgREST 可能這樣回）也認得出本單有列", () => {
  assert.equal(stateOf(modal(["2"], [], false).columns, 2), "active");
});

// ============================================================
console.log("派貨工作台：規劃器收不收得下這一格（pickingMatrixRules.plannerCanTakeCell）");
// ============================================================
// 商品 500 有兩張採購單：PO 10 只有店 1 有需求列；PO 11 有一列沒分店（store_id NULL）。
const DEMAND = [
  { po_id: 10, sku_id: 500, store_id: 1 },
  { po_id: 11, sku_id: 500, store_id: null },
  { po_id: 11, sku_id: 501, store_id: 2 },
];
const demandSet = buildDemandPoSkuStore(DEMAND);
const canTake = (storeId, poIds, storeDemandLeft) =>
  plannerCanTakeCell({ poIds, skuId: 500, storeId, demandPoSkuStore: demandSet, storeDemandLeft });
check("有訂（採購單上有這家店的需求列）→ 收得下，就算未派需求已經是 0（第一輪可多給有訂的店）", () => {
  assert.equal(canTake(1, [10, 11], 0), true);
});
check("沒訂（兩張採購單都沒有這家店的列、也沒有未派需求）→ 收不下", () => {
  assert.equal(canTake(3, [10, 11], 0), false);
});
check("只看這樣商品的採購單：別的商品有列不算", () => {
  // 店 2 只在商品 501 有列，商品 500 對它來說是沒訂
  assert.equal(canTake(2, [10, 11], 0), false);
});
check("需求列在別張採購單上 → 只要這樣商品的採購單有一張有列就收得下", () => {
  assert.equal(canTake(1, [11, 10], 0), true);
  assert.equal(canTake(1, [11], 0), false);
});
check("還有未派需求 → 收得下（第二輪跨團借調的進場條件）", () => {
  assert.equal(canTake(3, [10, 11], 2), true);
});
check("store_id 為 NULL 的需求列不算任何一家店", () => {
  assert.equal(demandSet.size, 2);
  assert.ok(!demandSet.has(poSkuStoreKey(11, 500, null)));
});

// ============================================================
console.log("接線檢查：畫面真的在用上面這幾支（另寫一套的話，上面測得再綠也保護不到畫面）");
// ============================================================
const src = (rel) => readFileSync(resolve(root, rel), "utf8");
const pickModal = src("apps/admin/src/components/PickModal.tsx");
const wms = src("apps/admin/src/app/(protected)/wms/picking/page.tsx");
const draftEdit = src("apps/admin/src/app/(protected)/picking/drafts/edit/page.tsx");
const draftPrint = src("apps/admin/src/app/(protected)/picking/drafts/print/page.tsx");
check("修正數量彈窗的欄位來自 buildPickModalColumns", () => {
  assert.match(pickModal, /from\s+["']@\/lib\/pickingMatrixRules["']/);
  assert.match(pickModal, /\bbuildPickModalColumns\s*\(/);
});
check("派貨工作台：規劃器與矩陣都問 cellTakeable（plannerCanTakeCell）", () => {
  assert.match(wms, /from\s+["']@\/lib\/pickingMatrixRules["']/);
  assert.match(wms, /\bplannerCanTakeCell\s*\(/);
  assert.match(wms, /buildDemandPoSkuStore\s*\(/);
  assert.match(wms, /!cellTakeable\(sk,\s*st\.store_id\)/, "規劃器分「沒訂／缺 N」要問 cellTakeable");
  assert.match(wms, /disabled=\{!takeable\}/, "矩陣格子要依 cellTakeable 鎖住");
});
check("撿貨草稿（編輯、列印）的欄位來自 buildStoreColumns", () => {
  assert.match(draftEdit, /\bbuildStoreColumns\s*\(/);
  assert.match(draftPrint, /\bbuildStoreColumns\s*\(/);
});

console.log(`\n${passed} 項通過、${failed} 項失敗`);
if (failed > 0) {
  console.error("❌ store kind column rules FAILED");
  process.exit(1);
}
console.log("store kind column rules ok");
