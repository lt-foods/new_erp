// 同一團、同一樣商品掛兩張以上採購單（20261015000000）：純函式＋撿貨草稿讀取流程的測試
//   node --test apps/admin/src/lib/pickingMultiPo.test.mjs
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
//
// 分兩段：
//   一、pickingMultiPo.ts 的純函式（它一個 import 都沒有，直接載得進來）
//   二、pickingDraftView.ts／pickingDraftHandoff.ts 的讀取流程（loadPrefill、handoffToDraft），
//       餵假的 db 進去，證明「中招／檢查失敗 → 各店全部 0」、「沒中招 → 跟原本一模一樣」。
//       ⓘ 這兩支 lib 有不帶副檔名的 import（"./storeOrder"、"./pickingDraftView"），
//         node 自己解不到 → 用 node:module 的 registerHooks 補一個「找不到就試 .ts」，只在這個測試裡生效。
import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import {
  MULTI_PO_VIEW,
  WORKBENCH_MULTI_PO_FAILED_TEXT,
  blockPrefill,
  isMultiPoBlocked,
  multiPoAddedMessage,
  multiPoBatchMessage,
  multiPoCheckFor,
  multiPoEvenMessage,
  multiPoExtra,
  multiPoHitPhrase,
  multiPoHitsBySku,
  multiPoRowMark,
  multiPoRowText,
  workbenchMultiPoText,
} from "./pickingMultiPo.ts";

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (e) {
      if (e?.code === "ERR_MODULE_NOT_FOUND" && specifier.startsWith(".") && !/\.[cm]?[jt]s$/.test(specifier)) {
        return nextResolve(`${specifier}.ts`, context);
      }
      throw e;
    }
  },
});
const view = await import(new URL("./pickingDraftView.ts", import.meta.url).href);
const handoff = await import(new URL("./pickingDraftHandoff.ts", import.meta.url).href);

// ============================================================
// 共用假資料：2026-10-13 那一樣的形狀 —— 一團、兩張採購單 19＋1、8 家店共 20 件
// ============================================================
const SKU = 1001;
const STORES = [1, 2, 3, 4, 5, 6, 7, 8];
const REAL = { 1: 2, 2: 8, 3: 3, 4: 1, 5: 1, 6: 2, 7: 2, 8: 1 }; // 各店真正的訂單量，合計 20
// 需求表每張採購單都帶一次整團量（20260908000000:62-72 的行為）。順序＝loadPrefill 的 po_item_id, store_id
const ICE_DEMAND = [
  ...STORES.map((s) => ({ po_id: 1, po_item_id: 11, store_id: s, demand_qty: REAL[s], wave_qty: 0, gr_qty: 19, po_sku_already_wave: 0 })),
  ...STORES.map((s) => ({ po_id: 2, po_item_id: 12, store_id: s, demand_qty: REAL[s], wave_qty: 0, gr_qty: 1, po_sku_already_wave: 0 })),
];
const ICE_VIEW_ROW = {
  sku_id: SKU,
  campaign_id: 1,
  campaign_no: "GRP-20260914-056",
  po_item_ids: [11, 12],
  po_nos: ["PO2609302038", "PO2609302039"],
};

/** 假的 supabase：from(table) 之後任何鏈式呼叫都回自己，await 時交給 handler 決定回什麼 */
function fakeDb(handler) {
  const log = [];
  return {
    log,
    from(table) {
      const q = { table, calls: [], insert: null };
      log.push(q);
      const b = new Proxy(
        {},
        {
          get(_, prop) {
            if (prop === "then") {
              return (resolve, reject) => Promise.resolve().then(() => handler(q)).then(resolve, reject);
            }
            return (...args) => {
              q.calls.push([prop, ...args]);
              if (prop === "insert") q.insert = args[0];
              return b;
            };
          },
        },
      );
      return b;
    },
  };
}
const eqOf = (q, col) => q.calls.find((c) => c[0] === "eq" && c[1] === col)?.[2];
/** 跟 @/lib/fetchAllRows 同一個合約：有 error 就丟、沒有就回 data */
const fetchAll = async (builder) => {
  const { data, error } = await builder();
  if (error) throw error;
  return data ?? [];
};
/** 撿貨草稿 loadPrefill 會打的三張表 */
function draftDb({ demand = ICE_DEMAND, viewRows = [ICE_VIEW_ROW], viewError = null, demandError = null } = {}) {
  return fakeDb((q) => {
    if (q.table === "v_picking_demand_by_po") {
      if (demandError) return { data: null, error: demandError };
      return { data: demand, error: null };
    }
    if (q.table === MULTI_PO_VIEW) {
      if (viewError) return { data: null, error: viewError };
      return { data: viewRows.filter((r) => Number(r.sku_id) === Number(eqOf(q, "sku_id"))), error: null };
    }
    if (q.table === "v_po_demand_by_store") return { data: [], error: null };
    throw new Error(`測試沒有準備這張表：${q.table}`);
  });
}
const VIEW_MISSING = { code: "PGRST205", message: "Could not find the table 'public.v_picking_multi_po_campaigns' in the schema cache" };
const gives = (pre) => [...pre.byStore.values()].map((v) => v.give);
const sum = (a) => a.reduce((s, x) => s + x, 0);

// ============================================================
// 一、純函式
// ============================================================

test("中招判斷：檢查表的採購單品項要跟需求表有交集才算", () => {
  const rows = [
    ICE_VIEW_ROW,
    // 早就派完的舊團：兩個品項都不在需求表上 → 不算
    { sku_id: 2002, campaign_id: 9, campaign_no: "GRP-OLD", po_item_ids: [901, 902], po_nos: ["PO-A", "PO-B"] },
    // 只要有一個還在需求表上就算（第一張派完、第二張才到的情況）
    { sku_id: "3003", campaign_id: "7", campaign_no: "GRP-HALF", po_item_ids: ["701", "702"], po_nos: ["PO-Y", "PO-X", "PO-X"] },
    // 欄位是 null 也不會炸
    { sku_id: 4004, campaign_id: 8, campaign_no: null, po_item_ids: null, po_nos: null },
  ];
  const hits = multiPoHitsBySku(rows, [11, "702", null, undefined]);
  assert.deepEqual([...hits.keys()].sort(), [1001, 3003]);
  assert.deepEqual(hits.get(1001), [{ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }]);
  // id 是字串也對得上；單號去重、排序
  assert.deepEqual(hits.get(3003), [{ campaign_no: "GRP-HALF", po_nos: ["PO-X", "PO-Y"] }]);
  assert.equal(hits.has(2002), false);
  // 需求表一列都沒有 → 一個都不算
  assert.equal(multiPoHitsBySku(rows, []).size, 0);
});

test("multiPoCheckFor：讀不到 ≠ 沒中招；沒有需求列就不必擋", () => {
  const ok = { ok: true, rows: [ICE_VIEW_ROW] };
  assert.deepEqual(multiPoCheckFor(SKU, ok, [11, 12]), {
    kind: "hit",
    hits: [{ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }],
  });
  assert.deepEqual(multiPoCheckFor(SKU, ok, [99]), { kind: "clear" });
  // ⛔ 讀失敗：只要有需求列，就是 failed（不可以是 clear）
  assert.deepEqual(multiPoCheckFor(SKU, { ok: false, reason: "壞了" }, [11]), { kind: "failed", reason: "壞了" });
  // 需求列一列都沒有：本來就帶不出數字，讀失敗也不標 failed（不然 SQL 沒貼前每樣沒需求的都多一句紅字）
  assert.deepEqual(multiPoCheckFor(SKU, { ok: false, reason: "壞了" }, []), { kind: "clear" });
  // 檢查表有別樣商品的列，不會串過來
  assert.deepEqual(
    multiPoCheckFor(5005, { ok: true, rows: [ICE_VIEW_ROW] }, [11, 12]),
    { kind: "clear" },
  );
  assert.equal(isMultiPoBlocked({ kind: "clear" }), false);
  assert.equal(isMultiPoBlocked({ kind: "hit", hits: [] }), true);
  assert.equal(isMultiPoBlocked({ kind: "failed", reason: "" }), true);
});

test("blockPrefill：每家店 give 歸零、available 不變、分店一家都不少、不改到傳進來的物件", () => {
  const pre = view.computePrefill(ICE_DEMAND);
  // 先確認 bug 的形狀：需求兩倍、照店的編號先來後到 → 前兩家吃光 20 件
  assert.equal(pre.available, 20);
  assert.deepEqual(gives(pre), [4, 16, 0, 0, 0, 0, 0, 0]);
  const before = JSON.stringify([...pre.byStore.entries()]);

  const blocked = blockPrefill({ ...pre, extra: { a: 1 } });
  assert.equal(blocked.available, 20);
  assert.deepEqual([...blocked.byStore.keys()], [...pre.byStore.keys()]);
  for (const v of blocked.byStore.values()) assert.deepEqual(v, { demandLeft: 0, give: 0 });
  assert.deepEqual(blocked.extra, { a: 1 }); // 其他欄位原樣帶著
  assert.equal(JSON.stringify([...pre.byStore.entries()]), before); // 原物件沒被改

  // ⭐ 下游會從 demandLeft 重算 give 的兩支，吃歸零後的結果一定只會算出 0
  assert.deepEqual(gives(view.computePrefillEven(blocked, STORES)), [0, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(gives(handoff.capPrefill(blocked, 20)), [0, 0, 0, 0, 0, 0, 0, 0]);
});

test("snapshot_extra 的記號：中招寫 multi_po、檢查失敗寫 multi_po_check、沒中招什麼都不寫", () => {
  assert.deepEqual(multiPoExtra({ kind: "hit", hits: [{ campaign_no: "G1", po_nos: ["P1", "P2"] }] }), {
    multi_po: [{ campaign_no: "G1", po_nos: ["P1", "P2"] }],
  });
  assert.deepEqual(multiPoExtra({ kind: "failed", reason: "x" }), { multi_po_check: "failed" });
  assert.deepEqual(multiPoExtra({ kind: "clear" }), {});
});

test("提示文字：中招、檢查失敗、正常三種分得出來", () => {
  const hit = { kind: "hit", hits: [{ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }] };
  const failed = { kind: "failed", reason: "檢查表還沒建立" };
  const a = multiPoAddedMessage("冰絲內衣", hit);
  const b = multiPoAddedMessage("冰絲內衣", failed);
  assert.equal(multiPoAddedMessage("冰絲內衣", { kind: "clear" }), null); // 正常 → 沿用原本那四句
  assert.match(a, /GRP-20260914-056/);
  assert.match(a, /PO2609302038、PO2609302039/);
  assert.match(a, /各店數量全部留 0/);
  assert.match(a, /照訂單樞紐/);
  assert.doesNotMatch(a, /檢查失敗/);
  assert.match(b, /多張採購單檢查失敗，數量請照訂單樞紐自己填/);
  assert.match(b, /檢查表還沒建立/);
  assert.doesNotMatch(b, /GRP-/);
  assert.notEqual(a, b);
  // 不可以有 markdown 粗體（純文字渲染，星號會原樣印出來）
  for (const t of [a, b]) assert.doesNotMatch(t, /\*\*/);

  // ⚖ 平均
  assert.match(multiPoEvenMessage("冰絲內衣", hit), /這次沒有改動任何數量.*GRP-20260914-056/);
  assert.match(multiPoEvenMessage("冰絲內衣", failed), /這次沒有改動任何數量：多張採購單檢查失敗/);
  assert.equal(multiPoEvenMessage("冰絲內衣", { kind: "clear" }), null);

  // 一次好幾樣：只列被擋的那幾樣
  const batch = multiPoBatchMessage(
    [
      { name: "甲", check: hit },
      { name: "乙", check: { kind: "clear" } },
      { name: "丙", check: failed },
    ],
    "加入",
  );
  assert.match(batch, /這 2 樣已經加入，但各店數量全部留 0/);
  assert.match(batch, /甲——團 GRP-20260914-056 有 2 張採購單（PO2609302038、PO2609302039）；丙——多張採購單檢查失敗（檢查表還沒建立）。/);
  assert.doesNotMatch(batch, /乙/);
  assert.match(batch, /容易派錯店；檢查失敗時不知道有沒有重複。請照訂單樞紐自己填各店數量。$/);
  // 只有中招、沒有檢查失敗 → 不提檢查失敗
  const onlyHit = multiPoBatchMessage([{ name: "甲", check: hit }], "傳進草稿");
  assert.equal(
    onlyHit,
    "⚠ 這 1 樣已經傳進草稿，但各店數量全部留 0：甲——團 GRP-20260914-056 有 2 張採購單（PO2609302038、PO2609302039）。" +
      "同一團有多張採購單時，系統帶出的各店數量會重複算、容易派錯店。請照訂單樞紐自己填各店數量。",
  );
  assert.equal(multiPoBatchMessage([{ name: "乙", check: { kind: "clear" } }], "加入"), null);

  // 同一張採購單裡兩列：不可以講成「1 張採購單」
  assert.equal(
    multiPoHitPhrase({ campaign_no: "G", po_nos: ["P"] }),
    "團 G 的採購單 P 有兩列以上這樣商品",
  );
});

test("草稿表格上的 ⚠：從 snapshot_extra 讀回來；形狀不對的略過、不炸", () => {
  assert.equal(multiPoRowMark([{ snapshot_source: "add_sku" }, null, undefined]), null);
  const mark = multiPoRowMark([
    { multi_po: [{ campaign_no: "G2", po_nos: ["P3"] }, { campaign_no: "G1", po_nos: ["P2", "P1"] }] },
    { multi_po: [{ campaign_no: "G1", po_nos: ["P1"] }] }, // 同一團重複 → 合併
    { multi_po: "壞掉的值" },
    { multi_po: [null, { campaign_no: 5 }, { campaign_no: "" }] },
  ]);
  assert.deepEqual(mark, {
    hits: [
      { campaign_no: "G1", po_nos: ["P1", "P2"] },
      { campaign_no: "G2", po_nos: ["P3"] },
    ],
    failed: false,
  });
  assert.match(multiPoRowText(mark), /⚠ 同一團多張採購單：團 G1 有 2 張採購單（P1、P2）；團 G2 的採購單 P3 有兩列以上這樣商品/);
  const failedMark = multiPoRowMark([{ multi_po_check: "failed" }]);
  assert.deepEqual(failedMark, { hits: [], failed: true });
  assert.equal(multiPoRowText(failedMark), "⚠ 加入時多張採購單檢查失敗，數量請照訂單樞紐自己填。");
});

test("派貨工作台的紅字", () => {
  assert.equal(
    workbenchMultiPoText({ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }),
    "⚠ 同一團有 2 張採購單（PO2609302038、PO2609302039；團 GRP-20260914-056），各店預設數量會重複算，請照訂單樞紐改",
  );
  assert.equal(WORKBENCH_MULTI_PO_FAILED_TEXT, "多張採購單檢查失敗，同一團多張採購單的商品可能被重複算");
});

// ============================================================
// 二、撿貨草稿的讀取流程（loadPrefill）
// ============================================================

test("loadPrefill 中招：各店全部 0、available 不變、記號寫進 extra、兩支查詢同時發出", async () => {
  const db = draftDb();
  const pre = await view.loadPrefill({ db, fetchAll }, SKU);
  assert.equal(pre.multiPo.kind, "hit");
  assert.deepEqual(pre.multiPo.hits, [{ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }]);
  assert.equal(pre.available, 20);
  assert.deepEqual([...pre.byStore.keys()], STORES);
  assert.equal(sum(gives(pre)), 0);
  assert.deepEqual(pre.extra.multi_po, [{ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }]);
  // 檢查表在需求表之前就發出去了（同時發，不多排一趟）
  assert.deepEqual(db.log.map((q) => q.table).slice(0, 2), [MULTI_PO_VIEW, "v_picking_demand_by_po"]);
  // 需求表多選了 po_item_id，其他條件跟原本一樣
  const demandQ = db.log.find((q) => q.table === "v_picking_demand_by_po");
  assert.deepEqual(demandQ.calls.find((c) => c[0] === "select"), [
    "select",
    "po_id, po_item_id, store_id, demand_qty, wave_qty, gr_qty, po_sku_already_wave",
  ]);
  assert.equal(eqOf(demandQ, "has_stock_left"), true);
  assert.equal(eqOf(demandQ, "has_demand_left"), true);
});

test("loadPrefill 檢查表讀不到：⛔ 不可以照常帶數字 —— 一樣全部 0，並標 failed", async () => {
  const pre = await view.loadPrefill({ db: draftDb({ viewError: VIEW_MISSING }), fetchAll }, SKU);
  assert.equal(pre.multiPo.kind, "failed");
  assert.match(pre.multiPo.reason, /v_picking_multi_po_campaigns 還沒建立/);
  assert.equal(sum(gives(pre)), 0);
  assert.equal(pre.available, 20);
  assert.equal(pre.extra.multi_po_check, "failed");
  assert.equal(pre.extra.multi_po, undefined);
  // 別種錯誤也一樣擋（原因照原文帶出來）
  const pre2 = await view.loadPrefill(
    { db: draftDb({ viewError: { code: "57014", message: "canceling statement due to statement timeout" } }), fetchAll },
    SKU,
  );
  assert.equal(pre2.multiPo.kind, "failed");
  assert.match(pre2.multiPo.reason, /statement timeout/);
  assert.equal(sum(gives(pre2)), 0);
});

test("loadPrefill 沒中招：結果跟原本 computePrefill 一模一樣（含舊團的列不會誤擋）", async () => {
  // 兩團各一張採購單的正常商品：檢查表沒有它的列
  const normal = [
    { po_id: 5, po_item_id: 51, store_id: 1, demand_qty: 3, wave_qty: 0, gr_qty: 4, po_sku_already_wave: 0 },
    { po_id: 5, po_item_id: 51, store_id: 2, demand_qty: 2, wave_qty: 1, gr_qty: 4, po_sku_already_wave: 1 },
    { po_id: 6, po_item_id: 61, store_id: 3, demand_qty: 5, wave_qty: 0, gr_qty: 2, po_sku_already_wave: 0 },
  ];
  const oldCampaign = { sku_id: SKU, campaign_id: 9, campaign_no: "GRP-OLD", po_item_ids: [901, 902], po_nos: ["PO-A", "PO-B"] };
  const pre = await view.loadPrefill({ db: draftDb({ demand: normal, viewRows: [oldCampaign] }), fetchAll }, SKU);
  const expected = view.computePrefill(normal);
  assert.deepEqual(pre.multiPo, { kind: "clear" });
  assert.equal(pre.available, expected.available);
  assert.deepEqual([...pre.byStore.entries()], [...expected.byStore.entries()]);
  assert.equal(pre.extra.multi_po, undefined);
  assert.equal(pre.extra.multi_po_check, undefined);
});

test("loadPrefill：需求表讀失敗照樣整個丟出去（原本的行為不變）；沒有需求列時不標檢查失敗", async () => {
  await assert.rejects(
    view.loadPrefill({ db: draftDb({ demandError: { code: "XX000", message: "boom" } }), fetchAll }, SKU),
    (e) => e?.message === "boom",
  );
  const pre = await view.loadPrefill({ db: draftDb({ demand: [], viewError: VIEW_MISSING }), fetchAll }, SKU);
  assert.deepEqual(pre.multiPo, { kind: "clear" });
  assert.equal(pre.byStore.size, 0);
  assert.equal(pre.extra.multi_po_check, undefined);
});

test("後來才補的格子（lateCellSnapshot）：中招／檢查失敗時需求快照寫 null，記號跟著寫", async () => {
  const hit = await view.loadPrefill({ db: draftDb(), fetchAll }, SKU);
  const s1 = view.lateCellSnapshot(hit, 3, "2026-10-15T00:00:00Z");
  assert.equal(s1.snapshot_demand_qty, null);
  assert.equal(s1.snapshot_available_qty, 20);
  assert.equal(s1.snapshot_extra.snapshot_source, "cell_created_later");
  assert.ok(Array.isArray(s1.snapshot_extra.multi_po));

  const failed = await view.loadPrefill({ db: draftDb({ viewError: VIEW_MISSING }), fetchAll }, SKU);
  const s2 = view.lateCellSnapshot(failed, 3, "2026-10-15T00:00:00Z");
  assert.equal(s2.snapshot_demand_qty, null);
  assert.equal(s2.snapshot_extra.multi_po_check, "failed");

  const clear = await view.loadPrefill({ db: draftDb({ viewRows: [] }), fetchAll }, SKU);
  // 沒中招時照原本的寫法（這份假資料檢查表是空的，所以拿到的是需求表兩倍的 3+3＝6：證明沒中招時一個字都沒改）
  assert.equal(view.lateCellSnapshot(clear, 3, "2026-10-15T00:00:00Z").snapshot_demand_qty, 6);
});

test("加入商品的訊息：中招那一樣講紅字，⛔ 不會被說成「沒有需求」，也不會被算成失敗", () => {
  const hit = { kind: "hit", hits: [{ campaign_no: "GRP-20260914-056", po_nos: ["PO2609302038", "PO2609302039"] }] };
  // 只加一樣
  const one = view.addBatchMessage({
    added: [{ name: "冰絲內衣", demandTotal: 0, giveTotal: 0, available: 20, multiPo: hit }],
    skipped: [],
    failed: [],
  });
  assert.equal(one.notice, null);
  assert.match(one.error, /已加入「冰絲內衣」，但各店數量全部留 0.*GRP-20260914-056/);
  assert.doesNotMatch(one.error, /沒有任何未派需求/);
  // 只加一樣、檢查失敗
  const oneFailed = view.addBatchMessage({
    added: [{ name: "冰絲內衣", demandTotal: 0, giveTotal: 0, available: 20, multiPo: { kind: "failed", reason: "x" } }],
    skipped: [],
    failed: [],
  });
  assert.match(oneFailed.error, /多張採購單檢查失敗，數量請照訂單樞紐自己填/);
  // 只加一樣、正常 → 原本那四句（藍框）
  const oneOk = view.addBatchMessage({
    added: [{ name: "正常", demandTotal: 5, giveTotal: 5, available: 9, multiPo: { kind: "clear" } }],
    skipped: [],
    failed: [],
  });
  assert.equal(oneOk.error, null);
  assert.equal(oneOk.notice, "已加入「正常」，帶出各店未派需求共 5 件。");

  // 一次好幾樣：中招的不進「沒有需求」那一類；失敗與中招各自一段
  const many = view.addBatchMessage({
    added: [
      { name: "冰絲內衣", demandTotal: 0, giveTotal: 0, available: 20, multiPo: hit },
      { name: "沒需求", demandTotal: 0, giveTotal: 0, available: 3, multiPo: { kind: "clear" } },
      { name: "正常", demandTotal: 5, giveTotal: 5, available: 9, multiPo: { kind: "clear" } },
    ],
    skipped: [],
    failed: [{ name: "壞掉", reason: "連線中斷" }],
  });
  assert.match(many.notice, /其中 1 樣查詢正常、但目前沒有任何未派需求（各店數量請自己填）：沒需求。/);
  assert.doesNotMatch(many.notice, /：冰絲內衣。|冰絲內衣（要/);
  assert.match(many.error, /這 1 樣「沒有」加入草稿：壞掉/);
  assert.match(many.error, /這 1 樣已經加入，但各店數量全部留 0：冰絲內衣——團 GRP-20260914-056/);

  // addOutcomeMessage 的新兩種跟原本四種都不一樣
  const kinds = ["failed", "none", "clamped", "ok", "multi_po", "multi_po_failed"];
  const texts = kinds.map((kind) =>
    view.addOutcomeMessage({
      kind,
      productName: "X",
      demandTotal: 5,
      giveTotal: 3,
      available: 3,
      reason: "r",
      multiPo: kind === "multi_po" ? hit : kind === "multi_po_failed" ? { kind: "failed", reason: "r" } : undefined,
    }),
  );
  assert.equal(new Set(texts).size, kinds.length);
  // 漏傳檢查結果也不會退回成功的句子
  assert.match(view.addOutcomeMessage({ kind: "multi_po", productName: "X" }), /多張採購單檢查失敗/);
});

// ============================================================
// 三、iPad「傳到撿貨草稿」（handoffToDraft）
// ============================================================

function handoffDeps({ viewRows = [ICE_VIEW_ROW], viewError = null } = {}) {
  const inserted = [];
  const db = fakeDb((q) => {
    if (q.table === "stores") return { data: STORES.map((id) => ({ id, code: `S0${id}`, name: `店${id}` })), error: null };
    if (q.table === "picking_drafts" && q.insert) return { data: { id: 77, name: q.insert.name }, error: null };
    if (q.table === "picking_drafts") return { data: [], error: null };
    if (q.table === "picking_draft_items" && q.insert) {
      inserted.push(...q.insert);
      return { error: null };
    }
    if (q.table === "v_picking_demand_by_po") {
      const sku = Number(eqOf(q, "sku_id"));
      return { data: sku === SKU ? ICE_DEMAND : NORMAL_DEMAND, error: null };
    }
    if (q.table === MULTI_PO_VIEW) {
      if (viewError) return { data: null, error: viewError };
      return { data: viewRows.filter((r) => Number(r.sku_id) === Number(eqOf(q, "sku_id"))), error: null };
    }
    if (q.table === "v_po_demand_by_store") return { data: [], error: null };
    throw new Error(`測試沒有準備這張表：${q.table}`);
  });
  return {
    inserted,
    deps: {
      db,
      fetchAll,
      session: async () => ({ tenantId: "t", uid: "u" }),
      describeError: (e) => String(e?.message ?? e),
      now: () => new Date("2026-10-15T02:00:00Z"),
    },
  };
}
const NORMAL_SKU = 2002;
const NORMAL_DEMAND = [
  { po_id: 5, po_item_id: 51, store_id: 1, demand_qty: 3, wave_qty: 0, gr_qty: 6, po_sku_already_wave: 0 },
  { po_id: 5, po_item_id: 51, store_id: 2, demand_qty: 2, wave_qty: 0, gr_qty: 6, po_sku_already_wave: 0 },
];
const HANDOFF_ARGS = {
  skus: [
    { sku_id: SKU, sku_code: "G02671-01", label: "冰絲內衣", qty: 20 },
    { sku_id: NORMAL_SKU, sku_code: "N-1", label: "正常商品", qty: 6 },
  ],
  source: { po_nos: ["PO2609302038", "PO2609302039"], gr_nos: ["GR1"], at: "2026-10-15T02:00:00Z" },
  qtyBasis: "this_receipt",
};

test("iPad 傳到草稿：中招那一樣照樣寫進去但全部 0（⛔ capPrefill 不會把 0 蓋回兩倍），訊息另成一類", async () => {
  const { deps, inserted } = handoffDeps();
  const report = await handoff.handoffToDraft(deps, HANDOFF_ARGS);
  const ice = inserted.filter((c) => c.sku_id === SKU);
  const normal = inserted.filter((c) => c.sku_id === NORMAL_SKU);
  assert.equal(ice.length, 8);
  assert.deepEqual(ice.map((c) => c.qty), [0, 0, 0, 0, 0, 0, 0, 0]);
  for (const c of ice) {
    assert.equal(c.snapshot_demand_qty, null);
    assert.equal(c.snapshot_available_qty, 20);
    assert.ok(Array.isArray(c.snapshot_extra.multi_po));
    assert.equal(c.snapshot_extra.snapshot_source, "ipad_receiving");
    assert.equal(c.snapshot_extra.handoff.given_qty, 0);
  }
  // 正常商品照原本的算法（3、2，其他店 0）
  assert.deepEqual(normal.map((c) => c.qty), [3, 2, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(normal.slice(0, 2).map((c) => c.snapshot_demand_qty), [3, 2]);

  // 回報：兩樣都算「已傳進去」（收貨頁靠 added 判斷這批傳過了沒），中招那一樣不算失敗
  assert.equal(report.added.length, 2);
  assert.equal(report.failed.length, 0);
  assert.equal(report.added[0].multiPo.kind, "hit");
  const msg = handoff.handoffMessage(report);
  assert.match(msg.notice, /已把 2 樣傳進 〈2026-10-15 撿貨〉（這是剛開的一張新草稿），各店合計帶出 5 件/);
  // ⛔ 中招那一樣不可以被講成「被夾住」或「沒有需求」
  assert.doesNotMatch(msg.notice, /冰絲內衣（/);
  assert.match(msg.error, /這 1 樣已經傳進草稿，但各店數量全部留 0：冰絲內衣——團 GRP-20260914-056 有 2 張採購單/);
  assert.doesNotMatch(msg.error, /沒有傳進草稿/);
});

test("iPad 傳到草稿：檢查表讀不到 → 有需求的商品全部 0（含原本正常的那樣），訊息講檢查失敗", async () => {
  const { deps, inserted } = handoffDeps({ viewError: VIEW_MISSING });
  const report = await handoff.handoffToDraft(deps, HANDOFF_ARGS);
  assert.equal(sum(inserted.map((c) => c.qty)), 0);
  for (const c of inserted) {
    assert.equal(c.snapshot_demand_qty, null);
    assert.equal(c.snapshot_extra.multi_po_check, "failed");
  }
  const msg = handoff.handoffMessage(report);
  assert.match(msg.error, /這 2 樣已經傳進草稿，但各店數量全部留 0/);
  assert.match(msg.error, /多張採購單檢查失敗/);
  assert.equal(report.failed.length, 0);
});
