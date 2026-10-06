// 手機團控純函式測試：node --test "apps/admin/src/app/(protected)/campaigns/quick-control/quickControl.test.mjs"
// （Node 22.18+／24 會直接吃 .ts；測試檔用 .mjs 是為了不進 admin 的型別檢查範圍）
import test from "node:test";
import assert from "node:assert/strict";
import {
  QUICK_IMAGE_ACCEPT,
  QUICK_PAGE_OVERLAP,
  QUICK_DRAFT_START_BACKDATE_MS,
  QUICK_PAGE_SIZE,
  autoOpensOnSchedule,
  campaignSearchOrFilter,
  canQuickUpdateCampaign,
  closeCampaignWarning,
  customerUrlFor,
  draftStartIso,
  formatScheduleLabel,
  mergeCampaignRows,
  moveImage,
  newProductExtras,
  pageWindow,
  planQuickStart,
  quickImageExt,
  quickPublishPlan,
  quickScopeFilter,
  sanitizeCampaignSearch,
  scheduledOpenHint,
  soldQtyByCampaign,
  splitPage,
} from "./quickControl.ts";

test("客人網址：結尾斜線不會變成雙斜線", () => {
  assert.equal(customerUrlFor("https://example.com", 12), "https://example.com/shop/c/12");
  assert.equal(customerUrlFor("https://example.com/", 12), "https://example.com/shop/c/12");
});

test("搜尋字：保留團號的連字號，拿掉會打斷 or() 的符號", () => {
  assert.equal(sanitizeCampaignSearch("  GRP-20260730-016 "), "GRP-20260730-016");
  assert.equal(sanitizeCampaignSearch("a,b.c(d):e"), "a%b%c%d%e");
  assert.equal(sanitizeCampaignSearch("【內部】芒果"), "內部%芒果");
  assert.equal(sanitizeCampaignSearch("芒果   鮮奶"), "芒果 鮮奶");
  assert.equal(sanitizeCampaignSearch("%%%"), "");
  assert.equal(sanitizeCampaignSearch("   "), "");
});

test("搜尋條件：團號或團名，空白不送條件", () => {
  assert.equal(campaignSearchOrFilter("芒果"), "campaign_no.ilike.%芒果%,name.ilike.%芒果%");
  assert.equal(campaignSearchOrFilter("  "), null);
  assert.equal(campaignSearchOrFilter("()"), null);
});

test("清單範圍：團型／整團上限／品項上限，搜尋時用 and 併在同一個條件", () => {
  const scope = "close_type.in.(food_train,fast,limited),total_cap_qty.gt.0,cap_items.not.is.null";
  assert.equal(quickScopeFilter(""), scope);
  assert.equal(quickScopeFilter("   "), scope);
  assert.equal(
    quickScopeFilter("芒果"),
    `and(or(${scope}),or(campaign_no.ilike.%芒果%,name.ilike.%芒果%))`,
  );
});

test("分頁範圍：第一頁從 0 開始，多要一筆判斷下一頁", () => {
  assert.deepEqual(pageWindow(0), { from: 0, to: QUICK_PAGE_SIZE });
  assert.deepEqual(pageWindow(QUICK_PAGE_SIZE), {
    from: QUICK_PAGE_SIZE - QUICK_PAGE_OVERLAP,
    to: QUICK_PAGE_SIZE * 2,
  });
  assert.deepEqual(pageWindow(3), { from: 0, to: 3 + QUICK_PAGE_SIZE });
});

test("切頁：剛好滿一頁沒有下一頁，多一筆才有", () => {
  const w = pageWindow(0);
  const size = w.to - w.from;
  const full = Array.from({ length: size }, (_, i) => i);
  assert.deepEqual(splitPage(full, w), { rows: full, hasMore: false });
  const plusOne = [...full, 999];
  const res = splitPage(plusOne, w);
  assert.equal(res.rows.length, size);
  assert.equal(res.hasMore, true);
  assert.deepEqual(splitPage([], w), { rows: [], hasMore: false });
});

test("載入更多合併：重疊的保留畫面上那筆，新的接在後面", () => {
  const cur = [{ id: 1, v: "畫面" }, { id: 2, v: "畫面" }];
  const inc = [{ id: 2, v: "伺服端" }, { id: 3, v: "伺服端" }, { id: 3, v: "重複" }];
  assert.deepEqual(mergeCampaignRows(cur, inc), [
    { id: 1, v: "畫面" },
    { id: 2, v: "畫面" },
    { id: 3, v: "伺服端" },
  ]);
});

test("已售件數：排除取消／過期／轉出單、非一般單、取消品項", () => {
  const sold = soldQtyByCampaign([
    { campaign_id: 1, status: "confirmed", order_kind: null, customer_order_items: [{ qty: "2", status: "pending" }, { qty: 5, status: "cancelled" }] },
    { campaign_id: 1, status: "ready", order_kind: "normal", customer_order_items: [{ qty: 3, status: "picked_up" }] },
    { campaign_id: 1, status: "cancelled", order_kind: "normal", customer_order_items: [{ qty: 9, status: "pending" }] },
    { campaign_id: 1, status: "transferred_out", order_kind: "normal", customer_order_items: [{ qty: 9, status: "pending" }] },
    { campaign_id: 1, status: "confirmed", order_kind: "restock", customer_order_items: [{ qty: 9, status: "pending" }] },
    { campaign_id: 2, status: "confirmed", order_kind: "normal" },
  ]);
  assert.equal(sold.get(1), 5);
  assert.equal(sold.get(2), 0);
});

test("舊的快速操作資格判斷（清單範圍用；已鎖定能不能重開改由資料庫判斷，頁面不用本函式擋）", () => {
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "fast", total_cap_qty: null, campaign_items: [] }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "limited", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "food_train", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: null, campaign_items: [{ cap_qty: null }] }), false);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: 0, campaign_items: null }), false);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: "10", campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "open", close_type: "regular", total_cap_qty: null, campaign_items: [{ cap_qty: 0 }, { cap_qty: "3" }] }), true);
  // 狀態條件照舊版：已鎖定回 false（重開與否由資料庫判斷，頁面不用這個擋），草稿／已關團照類型判斷
  assert.equal(canQuickUpdateCampaign({ status: "locked", close_type: "fast", total_cap_qty: 10, campaign_items: null }), false);
  assert.equal(canQuickUpdateCampaign({ status: "draft", close_type: "fast", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "closed", close_type: "limited", total_cap_qty: null, campaign_items: null }), true);
  assert.equal(canQuickUpdateCampaign({ status: "closed", close_type: "regular", total_cap_qty: null, campaign_items: null }), false);
});

test("全新商品附加資料：都沒填就全空，不擋開團", () => {
  assert.deepEqual(newProductExtras({ images: [], description: "   ", brandId: null }), {
    p_images: [],
    p_description: null,
    p_brand_id: null,
  });
});

test("全新商品附加資料：濾掉空路徑、不帶封面，描述去頭尾空白但保留換行", () => {
  const out = newProductExtras({ images: ["t/a.jpg", "", "t/b.png"], description: "  第一行\n第二行  ", brandId: 7 });
  assert.deepEqual(out.p_images, ["t/a.jpg", "t/b.png"]);
  assert.equal("cover" in out, false);
  assert.equal(out.p_description, "第一行\n第二行");
  assert.equal(out.p_brand_id, 7);
});

test("全新商品附加資料：品牌不是正整數就當沒選", () => {
  assert.equal(newProductExtras({ images: [], description: "", brandId: Number.NaN }).p_brand_id, null);
  assert.equal(newProductExtras({ images: [], description: "", brandId: 0 }).p_brand_id, null);
});

test("上傳圖片格式：只收 JPEG／PNG", () => {
  assert.equal(QUICK_IMAGE_ACCEPT, "image/jpeg,image/png");
  assert.equal(quickImageExt({ name: "a.JPG", type: "image/jpeg" }), "jpg");
  assert.equal(quickImageExt({ name: "a.jpeg", type: "image/jpeg" }), "jpeg");
  assert.equal(quickImageExt({ name: "a.png", type: "image/png" }), "png");
  assert.equal(quickImageExt({ name: "a.webp", type: "image/webp" }), null);
  assert.equal(quickImageExt({ name: "a.gif", type: "image/gif" }), null);
  assert.equal(quickImageExt({ name: "IMG_1.HEIC", type: "image/heic" }), null);
});

test("上傳圖片格式：類型是 JPEG 但檔名不是，副檔名依類型給", () => {
  assert.equal(quickImageExt({ name: "IMG_1.HEIC", type: "image/jpeg" }), "jpg");
  assert.equal(quickImageExt({ name: "noext", type: "image/png" }), "png");
});

test("上傳圖片格式：瀏覽器沒給類型就看檔名", () => {
  assert.equal(quickImageExt({ name: "a.jpg", type: "" }), "jpg");
  assert.equal(quickImageExt({ name: "a.png", type: "" }), "png");
  assert.equal(quickImageExt({ name: "a.webp", type: "" }), null);
  assert.equal(quickImageExt({ name: "noext", type: "" }), null);
});

test("圖片排序：往前往後換一格，超出範圍不動", () => {
  assert.deepEqual(moveImage(["a", "b", "c"], 1, -1), ["b", "a", "c"]);
  assert.deepEqual(moveImage(["a", "b", "c"], 1, 1), ["a", "c", "b"]);
  const list = ["a", "b"];
  assert.equal(moveImage(list, 0, -1), list);
  assert.equal(moveImage(list, 1, 1), list);
});

test("關團結果：併入／建請購失敗要警告，原因原樣附上", () => {
  assert.equal(
    closeCampaignWarning({ closed: true, action: "append_failed", reason: "請購單 PR001 的商品是舊資料" }),
    "已關團，但沒有併入請購單：請購單 PR001 的商品是舊資料。請到請購單頁補請購。",
  );
  assert.equal(
    closeCampaignWarning({ closed: true, pr_id: null, action: "create_failed", reason: "tenant mismatch" }, "芒果團"),
    "「芒果團」已關團，但沒有併入請購單：tenant mismatch。請到請購單頁補請購。",
  );
  assert.equal(
    closeCampaignWarning({ action: "append_failed", reason: "  " }),
    "已關團，但沒有併入請購單：原因不明。請到請購單頁補請購。",
  );
  assert.equal(closeCampaignWarning({ action: "create_failed" }), "已關團，但沒有併入請購單：原因不明。請到請購單頁補請購。");
});

test("關團結果：其他 action 或沒有回傳都不警告", () => {
  for (const action of ["appended", "created", "created_secondary", "deferred", "store_receiving"]) {
    assert.equal(closeCampaignWarning({ closed: true, action, reason: "x" }), null);
  }
  assert.equal(closeCampaignWarning(null), null);
  assert.equal(closeCampaignWarning(undefined), null);
  assert.equal(closeCampaignWarning("append_failed"), null);
  assert.equal(closeCampaignWarning([{ action: "append_failed" }]), null);
  assert.equal(closeCampaignWarning({}), null);
});

// 開團時間：datetime-local 的值是本地時間，測試一律用本地時間組出來，不受機器時區影響
const NOW = new Date(2026, 9, 6, 12, 0).getTime();
const END = new Date(2026, 9, 9, 23, 59).toISOString();

test("開團時間：留空＝馬上開，開團時間就是現在（跟以前一樣）", () => {
  assert.deepEqual(planQuickStart("", END, NOW), { ok: true, openNow: true, startIso: new Date(NOW).toISOString() });
  assert.deepEqual(planQuickStart("   ", END, NOW), { ok: true, openNow: true, startIso: new Date(NOW).toISOString() });
});

test("開團時間：未來時間＝排程（草稿），開團時間照填的寫", () => {
  assert.deepEqual(planQuickStart("2026-10-07T09:05", END, NOW), {
    ok: true,
    openNow: false,
    startIso: new Date(2026, 9, 7, 9, 5).toISOString(),
  });
});

test("開團時間：現在或過去要擋，請清空或改未來", () => {
  const pastOrNow = ["2026-10-06T12:00", "2026-10-06T11:59", "2026-01-01T00:00"];
  for (const v of pastOrNow) {
    const res = planQuickStart(v, END, NOW);
    assert.equal(res.ok, false, v);
    assert.match(res.error, /清空/);
  }
});

test("開團時間：要早於客人收單時間（同時也擋）", () => {
  assert.deepEqual(planQuickStart("2026-10-09T23:59", END, NOW), { ok: false, error: "開團時間必須早於客人收單時間" });
  assert.deepEqual(planQuickStart("2026-10-10T08:00", END, NOW), { ok: false, error: "開團時間必須早於客人收單時間" });
  assert.equal(planQuickStart("2026-10-09T23:58", END, NOW).ok, true);
});

test("開團時間：看不懂的值要擋", () => {
  assert.equal(planQuickStart("abc", END, NOW).ok, false);
});

test("排程提示：美食列車不會自動開，其他會", () => {
  assert.equal(autoOpensOnSchedule("food_train"), false);
  for (const t of ["fast", "limited", "regular"]) assert.equal(autoOpensOnSchedule(t), true);
  assert.equal(scheduledOpenHint("fast"), "時間到系統會自動開團。");
  assert.match(scheduledOpenHint("food_train"), /美食列車不會自動開.*開團/);
});

test("排程卡片時間：○月○日 ○○:○○（本地時間）", () => {
  assert.equal(formatScheduleLabel(new Date(2026, 9, 7, 9, 5).toISOString()), "10月7日 09:05");
  assert.equal(formatScheduleLabel(new Date(2026, 11, 25, 23, 0).toISOString()), "12月25日 23:00");
  assert.equal(formatScheduleLabel("not a date"), "");
});

test("建團最後幾步：記事本關掉要先寫（開團前），開著不用多呼叫", () => {
  assert.deepEqual(quickPublishPlan({ openNow: true, lineNote: true, isForShop: true }), {
    setLineNoteOffFirst: false,
    finalStatus: "open",
    isForShop: true,
  });
  assert.deepEqual(quickPublishPlan({ openNow: true, lineNote: false, isForShop: true }), {
    setLineNoteOffFirst: true,
    finalStatus: "open",
    isForShop: true,
  });
  assert.deepEqual(quickPublishPlan({ openNow: false, lineNote: false, isForShop: false }), {
    setLineNoteOffFirst: true,
    finalStatus: "draft",
    isForShop: false,
  });
});

test("草稿那次的開團時間：馬上開往前 1 天（自動開團撿不到），排程照填的時間", () => {
  // 自動開團只撿 start_at >= created_at − 5 分鐘（20260925010000:27）；created_at ≈ 現在
  const createdAt = NOW;
  const now = planQuickStart("", END, NOW);
  assert.equal(now.ok, true);
  const draft = draftStartIso(now, NOW);
  assert.equal(draft, new Date(NOW - QUICK_DRAFT_START_BACKDATE_MS).toISOString());
  assert.ok(new Date(draft).getTime() < createdAt - 5 * 60 * 1000, "撿不到");
  // 往前而不是往後：收單時間再近也不會撞 end_at > start_at
  assert.ok(new Date(draft).getTime() < new Date(END).getTime());

  const scheduled = planQuickStart("2026-10-07T09:05", END, NOW);
  assert.equal(scheduled.ok, true);
  assert.equal(draftStartIso(scheduled, NOW), new Date(2026, 9, 7, 9, 5).toISOString());
});
