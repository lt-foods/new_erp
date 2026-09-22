import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const source = readFileSync(resolve(root, "apps/admin/src/lib/pickingDraftView.ts"), "utf8");
const wmsSource = readFileSync(resolve(root, "apps/admin/src/app/(protected)/wms/picking/page.tsx"), "utf8");

assert.match(source, /store_kind\?: string \| null/, "StoreRow 要帶 store_kind");
assert.match(source, /c\.store_kind !== "wholesale"/, "批發欄位要用 store_kind 判斷");
assert.match(source, /withQty\.has\(c\.id\)/, "有量的欄位不能被藏掉");
assert.match(wmsSource, /\(s\.store_kind \?\? "branch"\) !== "branch"/, "工作台 allStores 只能先放全表 branch");
assert.match(wmsSource, /const master = masterById\.get\(r\.store_id\)/, "工作台要把 demand 出現的批發/其他店補回 allStores");

function storeIdsWithQty(cells) {
  const sum = new Map();
  const hasQty = new Set();
  for (const c of cells) {
    const id = Number(c.store_id);
    const n = Number(c.qty);
    if (!Number.isFinite(n)) {
      hasQty.add(id);
      continue;
    }
    if (n !== 0) hasQty.add(id);
    sum.set(id, (sum.get(id) ?? 0) + n);
  }
  for (const [id, v] of sum) if (v > 0) hasQty.add(id);
  return hasQty;
}

function buildColumnsLikeSource(allStores, cells, known) {
  const listedIds = new Set(allStores.map((s) => Number(s.id)));
  const knownById = known ? new Map(Array.from(known, ([k, v]) => [Number(k), v])) : null;
  const cols = allStores.map((s) => ({
    ...s,
    id: Number(s.id),
    state: s.is_active === false ? "inactive" : "active",
  }));
  const extraIds = Array.from(new Set(cells.map((c) => Number(c.store_id)))).filter(
    (id) => !listedIds.has(id),
  );
  const extras = extraIds.map((id) => {
    const snap = cells.find((c) => Number(c.store_id) === id);
    const fallback = {
      id,
      code: snap?.snapshot_store_code ?? `#${id}`,
      name: snap?.snapshot_store_name ?? `分店 #${id}`,
    };
    if (!knownById) return { ...fallback, state: "unknown" };
    const hit = knownById.get(id);
    if (hit) return { ...hit, id, state: "inactive" };
    return { ...fallback, state: "missing" };
  });
  const withQty = storeIdsWithQty(cells);
  return [...cols, ...extras]
    .filter((c) => c.state !== "inactive" || withQty.has(c.id))
    .filter((c) => c.state !== "active" || c.store_kind !== "wholesale" || withQty.has(c.id));
}

const stores = [
  { id: 1, code: "S001", name: "中和店", is_active: true, store_kind: "branch" },
  { id: 2, code: "W001", name: "批發客", is_active: true, store_kind: "wholesale" },
  { id: 3, code: "S003", name: "停用店", is_active: false, store_kind: "branch" },
];
const cell = (store_id, qty) => ({
  sku_id: 10,
  store_id,
  qty,
  snapshot_sku_code: "SKU",
  snapshot_sku_label: "商品",
  snapshot_store_code: `#${store_id}`,
  snapshot_store_name: `快照店 ${store_id}`,
});

let cols = buildColumnsLikeSource(stores, [], new Map());
assert(cols.some((c) => c.id === 1), "包子媽分店沒量也要顯示");
assert(!cols.some((c) => c.id === 2), "批發沒量不顯示");
assert(!cols.some((c) => c.id === 3), "停用店沒量不顯示");

cols = buildColumnsLikeSource(stores, [cell(2, 4), cell(3, 1)], new Map());
assert.equal(cols.find((c) => c.id === 2)?.state, "active", "批發有量要顯示");
assert.equal(cols.find((c) => c.id === 3)?.state, "inactive", "停用店有量要顯示並標停用");

cols = buildColumnsLikeSource(stores, [cell(99, 2)], new Map());
assert.equal(cols.find((c) => c.id === 99)?.state, "missing", "已刪除店有量要顯示並標已刪除");

cols = buildColumnsLikeSource(stores, [cell(100, 0)], null);
assert.equal(cols.find((c) => c.id === 100)?.state, "unknown", "無法確認的店不可被藏掉");

console.log("store kind column rules ok");
