// 📦 → 📋 「傳到撿貨草稿」的共用邏輯
//
// 這支在解什麼（老闆 2026-08-31 ②、9-01 補充）：
//   「樓下 ipad 進貨按了之後 要多一個鈕是傳送到撿貨草稿」
//   「採購單我想要做查看，但是寫入撿貨草稿要能帶出數量」
//   → 收完貨當場一顆鈕，貨直接進今天的撿貨草稿，樓下接著就能分各店。
//
// 為什麼抽成 lib 而不是寫在頁面裡（兩個理由，缺一不可）：
//   1. **兩個呼叫點**：iPad 收貨頁（送出成功後）與 iPad 採購單查看頁（逐列寫入）。
//      兩邊各寫一份遲早飄移，而飄移的下場是「同一顆鈕在兩頁寫進不一樣的東西」。
//   2. 純計算的部分（capPrefill / buildHandoffCells / handoffMessage）**離線驗得到**
//      —— 這是本 repo 既有的作法（見 pickingDraftView.ts 檔頭與 receivingBatch.ts）。
//
// ⛔⛔ 硬規定（與 20260817000000_picking_drafts.sql 檔頭同一套）：
//   · 只讀寫 picking_drafts / picking_draft_items 兩張草稿自己的表，
//     以及**唯讀** stores 與 loadPrefill 內部那兩張 view。
//   · 不呼叫任何庫存／建單 RPC、不扣庫存、不回寫任何既有表。
//   · ⛔ 一個字都不動 computePrefill / computePrefillEven（老闆 2026-08-17、
//     阿審 2026-09-01 兩次拍板）—— 本檔只在它們**算完之後**再夾一次上限，
//     見 capPrefill。
//
// ⛔ 沒有新增任何 migration：草稿走 PostgREST 直寫 + RLS，本案沿用，
//    不新增 SECURITY DEFINER RPC（那會繞過 RLS，反而讓「這條路碰不到別的表」
//    變成要讀 code 才能相信）。

import {
  loadPrefill,
  type FetchAll,
  type Prefill,
  type PrefillResult,
  type ReadOnlyDb,
} from "./pickingDraftView";

// ============================================================
// 1. 「今天」是哪一天
// ============================================================

// 老闆裁示（2026-09-02 問題 2 選甲）：自動進「今天的草稿」，沒有就自動開一份。
//
// ⭐⭐ 「今天」一律以**台北時區**判定，⛔ 不用裝置本地時區。
//   · 既有慣例有兩種寫法，本檔刻意只採其中一種：
//       - 顯示用日期字串：`new Date().toLocaleDateString("sv-SE")`（裝置本地）
//         —— 草稿列表頁 picking/drafts/page.tsx:41 的 defaultDraftName() 就是這個
//       - timestamptz 查詢邊界：明寫 `+08:00` 字面量
//         —— wms/inbound/page.tsx:399-400（PR #819）
//   · ⛔ **兩種混用會出事**：拿「裝置本地日期」去配「+08:00 邊界」，
//     iPad 時區被設錯（或人在國外）時，算出來的視窗**根本不包含當下這一刻**
//     → 每按一次就開一張新草稿，而且畫面上看不出來。
//   · 所以日期字串與視窗邊界**同一個時區算出來**，結構上不可能對不起來。
//   · 寫法照抄 transfers/settlement/daily/page.tsx:62-72 的 taipeiParts()
//     （Intl + timeZone: "Asia/Taipei"，⛔ 不自己加 8 小時：那種寫法遇到
//       日光節約或時區調整就是錯的，而 Intl 是查表的）。
const TAIPEI_DATE = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Taipei",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** 台北時區的「今天」，格式 YYYY-MM-DD */
export function taipeiToday(now: Date = new Date()): string {
  return TAIPEI_DATE.format(now); // en-CA 給的就是 YYYY-MM-DD
}

/**
 * 台北那一天在 timestamptz 上的半開區間 [from, to)。
 *
 * ⭐ 用半開區間（gte / lt）而不是 `23:59:59.999`：
 *   created_at 是 timestamptz（微秒精度），23:59:59.9995 這種值會掉在
 *   `lte 23:59:59.999` 之外 —— 那一刻建的草稿會變成「今天找不到、明天也找不到」。
 *   ⓘ wms/inbound:400 用的是 lte 23:59:59.999，那裡是使用者手選的日期範圍、
 *     漏掉半毫秒無所謂；這裡是**自動判定要不要開新草稿**，漏掉就多開一張。
 */
export function taipeiDayBounds(dateStr: string): { from: string; to: string } {
  const next = new Date(`${dateStr}T00:00:00+08:00`);
  next.setUTCDate(next.getUTCDate() + 1);
  return {
    from: `${dateStr}T00:00:00+08:00`,
    to: `${taipeiToday(next)}T00:00:00+08:00`,
  };
}

/** 今天這張草稿要叫什麼名字。
 *  ⓘ 形狀刻意與草稿列表頁的 defaultDraftName()（picking/drafts/page.tsx:41）一致
 *    —— 老闆在兩個地方看到的名字要長一樣。差別只有時區來源（見上面那段）。 */
export function draftNameFor(dateStr: string): string {
  return `${dateStr} 撿貨`;
}

// ============================================================
// 2. 這次要帶出多少（純計算）
// ============================================================

/**
 * 把 computePrefill 算好的分配，**再夾一次上限**。
 *
 * 為什麼要這一層（老闆 2026-09-02 問題 3 選甲）：
 *   帶出的數量＝「**這次實收的量**」，不是「這樣商品現在總共可分配多少」。
 *   兩者在「先前收過、還沒派出去」時會差很多：
 *   昨天收 50 沒派、今天收 30 → computePrefill 的 available ＝ 80，
 *   但老闆要的是 30（「剛收的這批」直覺對應）。
 *
 * ⛔⛔ 這支**不是** computePrefill 的替代品，也沒有改它一個字：
 *   分配規則（先來後到、前面吃滿後面掛 0）完全沿用 —— 老闆 2026-08-17 拍板
 *   「貨不夠時讓一家真的能開賣，好過五家都缺貨賣不動」。
 *   這裡只是把「可以分下去的總量」從 available 換成 min(cap, available)，
 *   走同一個貪心迴圈、同一個順序。
 *
 * ⭐ 順序：直接沿用 `pre.byStore` 的插入順序。
 *   那個順序來自 loadPrefill 的 `.order("po_item_id").order("store_id")`，
 *   是 computePrefill 自己逐格分配時用的同一個順序（JS 的 Map 保證維持插入序），
 *   所以 `capPrefill(pre, pre.available)` 的結果與 `pre` **逐格相同** ——
 *   這是可以離線驗證的性質，也是「我沒有偷偷換掉分配規則」的證據。
 *
 * ⚠ `available` 欄位**原封不動回傳**（不是回傳夾過的值）：
 *   它會被寫進 snapshot_available_qty，而那一欄的語意是「這樣商品當下真正的可分配量」，
 *   紅字缺口（rowShortfall，#896）拿它跟需求比。寫成「這次實收」會讓那行紅字說謊。
 *
 * @param cap 這次實收的量。負數／NaN 一律當 0（⛔ 不猜、不放行）。
 */
export function capPrefill(pre: Prefill, cap: number): Prefill {
  const safeCap = Number.isFinite(cap) && cap > 0 ? cap : 0;
  let room = Math.min(safeCap, pre.available);
  const byStore = new Map<number, { demandLeft: number; give: number }>();
  for (const [storeId, v] of pre.byStore) {
    const give = Math.min(v.demandLeft, room);
    byStore.set(storeId, { demandLeft: v.demandLeft, give });
    room -= give;
  }
  return { available: pre.available, byStore };
}

// ============================================================
// 3. 要寫進去的列（純計算）
// ============================================================

export type HandoffStore = { id: number; code: string | null; name: string | null };

/**
 * `HandoffSku.qty` 是**哪一種**實收量。
 *
 * ⭐⭐ 為什麼要有這個參數（阿審 2026-09-02 P1）：兩個入口餵的是**不同的數字**——
 *   · 收貨頁：`this_receipt` ＝ 剛剛那一次送出真的收進來的量
 *   · 採購單查看頁：`cumulative` ＝ 這一列的 `qty_received`（整張單累計）
 *   共用訊息如果一律寫死「這次收」，採購單頁就會把「累計實收 80」講成「這次收 80」，
 *   而老闆看到那句話會以為今天真的到了 80 件。⛔ 這正是本專案最忌諱的畫面斷言。
 * ⇒ 口徑由呼叫端宣告，訊息與快照都跟著它走。
 */
export type QtyBasis = "this_receipt" | "cumulative";

/** 口徑的中文說法。⭐ 兩個都刻意選 4 個字、而且在下面每一個句型裡都讀得通
 *  （「比X少」「比X多」「夾在「X」」「不是X」「X的量」「（X 30、…）」）。 */
export const QTY_BASIS_LABEL: Record<QtyBasis, string> = {
  this_receipt: "這次實收",
  cumulative: "累計實收",
};

/** 這次要傳過去的一樣商品。qty ＝ 這次實收的量（跨採購單同一樣商品已先合併）。 */
export type HandoffSku = {
  sku_id: number;
  sku_code: string | null;
  /** 畫面與快照用的品名（product_name + variant_name） */
  label: string;
  qty: number;
};

/** 這批貨是打哪來的 —— 只寫進 snapshot_extra 當來源記錄，不參與任何計算。 */
export type HandoffSource = {
  po_nos: string[];
  gr_nos: string[];
  /** 送出成功的那一刻（ISO 字串） */
  at: string;
};

/**
 * 一樣商品 → 要 insert 的那一排列（每家分店一列）。
 *
 * ⭐ 欄位**逐項對齊** picking/drafts/edit/page.tsx:798-829 的 addSkus()。
 *   ⛔ 不可以少填任何一個 snapshot 欄位：
 *     · snapshot_demand_qty / snapshot_available_qty 少填 → 紅字缺口
 *       （rowShortfall，pickingDraftView.ts:590「缺一格就整列不顯示」）
 *       會對這一列**整列失效**，而畫面上看不出來是壞掉還是真的沒缺口。
 *     · snapshot_source 少填 → isLegacyDraftCell（同檔 :915）會把這幾列
 *       判成「結單日功能上線前加的舊列」，列印頁會多一句不成立的警語。
 *
 * ⚠ 分店是 **stores 全表（含停用）**，與 addSkus 同一條規則：
 *   停用分店幾乎不會有未派需求 → qty = 0 → buildStoreColumns 會把那一欄藏起來。
 *   真的還有未派需求時那一欄會照樣出現並標「已停用」—— 那正是要保住的東西。
 */
export function buildHandoffCells(args: {
  tenantId: string;
  uid: string | null;
  draftId: number;
  stores: HandoffStore[];
  sku: HandoffSku;
  /** 已經過 capPrefill 夾住的分配 */
  capped: Prefill;
  /** loadPrefill 帶回來的結單日與 extra（原樣沿用，⛔ 不重算） */
  pre: PrefillResult;
  source: HandoffSource;
  /** `sku.qty` 是哪一種實收量（寫進快照，之後才查得出來這一列的數字是什麼口徑） */
  qtyBasis: QtyBasis;
  /** 這一批的快照時間點；同一次傳送的所有列要用**同一個值** */
  snapshotAt: string;
}): Record<string, unknown>[] {
  const { tenantId, uid, draftId, stores, sku, capped, pre, source, qtyBasis, snapshotAt } = args;
  return stores.map((st) => {
    const p = capped.byStore.get(st.id);
    return {
      tenant_id: tenantId,
      draft_id: draftId,
      sku_id: sku.sku_id,
      store_id: st.id,
      // 這家店帶出的量：未派需求，且整列合計不超過「這次實收」（見 capPrefill）
      qty: p?.give ?? 0,
      snapshot_at: snapshotAt,
      snapshot_sku_code: sku.sku_code,
      snapshot_sku_label: sku.label,
      snapshot_store_code: st.code,
      snapshot_store_name: st.name,
      // ⚠ 快照記的是「當下真正的」需求與可分配量，⛔ 不是夾過的那個數字。
      //   紅字缺口要拿這兩個數字比，寫成夾過的值會讓它說謊。
      snapshot_demand_qty: p?.demandLeft ?? 0,
      snapshot_available_qty: capped.available,
      snapshot_close_date: pre.closeDate,
      snapshot_extra: {
        ...pre.extra,
        snapshot_source: "ipad_receiving",
        // 來源記錄：哪張採購單、哪張進貨單、收了幾件、帶出幾件。
        // ⭐ 這是「同一批不要重複加」出問題時唯一查得回去的線索，
        //   也是老闆事後問「這列是怎麼跑進來的」的答案。
        // ⭐⭐ `qty_basis` ⛔ 不可以省（阿審 2026-09-02 P1）：`received_qty` 兩個入口
        //   餵的是不同口徑的數字（收貨頁＝這一次收的、採購單頁＝整張單累計），
        //   不記下來的話，事後看到「received_qty: 80」根本分不出那是哪一種 80。
        handoff: {
          received_qty: sku.qty,
          qty_basis: qtyBasis,
          given_qty: sumGive(capped),
          po_nos: source.po_nos,
          gr_nos: source.gr_nos,
          at: source.at,
        },
      },
      created_by: uid,
      updated_by: uid,
    };
  });
}

/** 這一列實際帶出去的總量（各店 give 相加） */
export function sumGive(pre: Prefill): number {
  let s = 0;
  for (const v of pre.byStore.values()) s += v.give;
  return s;
}

/** 這一列當下的全店未派需求總量 */
export function sumDemand(pre: Prefill): number {
  let s = 0;
  for (const v of pre.byStore.values()) s += v.demandLeft;
  return s;
}

// ============================================================
// 4. 要對老闆說什麼（純計算）
// ============================================================

export type HandoffAdded = {
  name: string;
  /** 這次實收 */
  receivedQty: number;
  /** 實際帶出（各店 give 相加） */
  giveTotal: number;
  /** 當下全店未派需求 */
  demandTotal: number;
  /** 當下可分配量 */
  available: number;
};

export type HandoffReport = {
  draftId: number | null;
  draftName: string | null;
  /** 這張草稿是這次才開的 */
  draftCreated: boolean;
  added: HandoffAdded[];
  /** 本來就在這張草稿裡 → 略過。不算失敗，但**一定要講** */
  skipped: string[];
  /**
   * 我們讀「已經有哪些商品」之後、寫進去之前，被**別人搶先加**進同一張草稿的
   * （DB 的 UNIQUE 擋下來，Postgres 23505）。
   *
   * ⭐⭐ 為什麼要跟 skipped、failed 都分開（阿審 2026-09-02 P2）：
   *   結局跟 skipped 一樣（商品在草稿裡、沒有重複加、原數量沒被動），
   *   但**原因**不一樣，而且會勾起「那我剛剛看到的清單是不是舊的」這個疑問。
   *   · 併進 failed → 會說「沒有傳進草稿」，但它其實在草稿裡 ＝ 說謊
   *   · 併進 skipped → 會說「本來就在」，但按之前它不在 ＝ 也不對
   *   ⇒ 自成一類，並叫他去草稿頁看最新的。
   */
  raced: string[];
  failed: { name: string; reason: string }[];
  /** 整批一樣都沒進去（拿不到身分／撈不到分店／開不了草稿）。⛔ 有值時上面幾個陣列都不算數 */
  fatal: string | null;
  /** 這次送出有幾張採購單是「先前就收過了」→ 沒有被帶進草稿。0 = 沒有 */
  duplicatePos: number;
  /** `added[].receivedQty` 是哪一種實收量 —— 訊息的措辭跟著它走 */
  qtyBasis: QtyBasis;
};

/**
 * 傳送結果要顯示的字。
 *
 * ⭐ 規則與 addBatchMessage（pickingDraftView.ts:779）同一套，⛔ 不另發明：
 *   1. 失敗的**逐樣列出名字**放紅框；成功／略過放藍框；兩框可同時出現
 *   2. 「查詢正常但沒需求」一定要單獨講 —— 它在畫面上跟「讀取失敗」
 *      一樣是一排 0，不講的話分不出這兩件事
 *   3. 被夾住的一定要講**為什麼**被夾（實收 vs 需求），並講出兩個數字
 *   ⓘ 不用 `**粗體**`：這幾段字是純文字渲染，星號會原封不動印出來。
 *
 * ⭐⭐ 所有講到「收了多少」的地方一律用 `L`（＝口徑的中文說法），
 *   ⛔ 不可以再寫死「這次收」——採購單查看頁餵的是**累計實收**，
 *   寫死就會把整張單累計講成今天到的量（阿審 2026-09-02 P1）。
 */
export function handoffMessage(r: HandoffReport): { notice: string | null; error: string | null } {
  if (r.fatal) return { notice: null, error: r.fatal };

  const parts: string[] = [];
  const L = QTY_BASIS_LABEL[r.qtyBasis];
  const where = r.draftName
    ? `〈${r.draftName}〉${r.draftCreated ? "（這是剛開的一張新草稿）" : ""}`
    : "今天的草稿";

  if (r.added.length > 0) {
    const give = r.added.reduce((s, a) => s + a.giveTotal, 0);
    parts.push(
      `已把 ${r.added.length} 樣傳進 ${where}，各店合計帶出 ${give} 件：` +
        `${r.added.map((a) => a.name).join("、")}。`,
    );

    // 沒有任何分店有未派需求 → 建了列但整排都是 0。
    // ⛔ 這件事一定要單獨講：畫面上它跟「讀取失敗」長得一模一樣。
    const none = r.added.filter((a) => a.demandTotal === 0).map((a) => a.name);
    if (none.length > 0) {
      parts.push(
        `其中 ${none.length} 樣查詢正常、但目前沒有任何分店有未派需求` +
          `（列已經建好，各店數量請在草稿頁自己填）：${none.join("、")}。`,
      );
    }

    // 帶出的量 < 實收 —— 兩種原因，措辭要分開，⛔ 不可以混成一句。
    const byDemand = r.added.filter(
      (a) => a.demandTotal > 0 && a.giveTotal < a.receivedQty && a.giveTotal >= a.demandTotal,
    );
    if (byDemand.length > 0) {
      parts.push(
        `其中 ${byDemand.length} 樣帶出的比${L}少，因為各店加起來只缺這麼多：` +
          byDemand
            .map((a) => `${a.name}（${L} ${a.receivedQty}、各店共缺 ${a.demandTotal}、帶出 ${a.giveTotal}）`)
            .join("、") +
          "。",
      );
    }

    // 需求分不完 —— ⭐⭐ 卡在哪一個上限**要分開講**，⛔ 不可以一律說成「夾在實收」。
    //   room = min(實收, 可分配量)（見 capPrefill），所以兩種都可能是真正的瓶頸：
    //     · 可分配量 ≥ 實收 → 是老闆選的甲案在夾（＝設計就是這樣）
    //     · 可分配量 < 實收 → 是**貨已經被派掉了**，跟這顆鈕的設計無關
    //   兩者的下一步完全不同（前者等下批貨、後者要去看是不是已經派過），
    //   講錯就是又一個沒查證的畫面斷言。
    const shortAll = r.added.filter((a) => a.demandTotal > a.giveTotal);
    const numbers = (a: HandoffAdded) =>
      `${a.name}（${L} ${a.receivedQty}、各店共缺 ${a.demandTotal}、` +
      `目前可分配 ${a.available}、帶出 ${a.giveTotal}）`;

    const byReceipt = shortAll.filter((a) => a.receivedQty <= a.available);
    if (byReceipt.length > 0) {
      parts.push(
        `其中 ${byReceipt.length} 樣的需求比${L}多，帶出的量已經夾在「${L}」：` +
          byReceipt.map(numbers).join("、") +
          "。差額請到草稿頁自己補，或等下一批貨到再傳一次。",
      );
    }
    const byAvailable = shortAll.filter((a) => a.receivedQty > a.available);
    if (byAvailable.length > 0) {
      parts.push(
        `其中 ${byAvailable.length} 樣帶出的量卡在「目前可分配量」而不是${L}` +
          `（這批的貨有一部分已經派出去了）：` +
          byAvailable.map(numbers).join("、") +
          "。請到派貨工作台確認是不是已經派過。",
      );
    }
  }

  if (r.skipped.length > 0) {
    parts.push(
      `${r.skipped.length} 樣本來就在這張草稿裡，這次沒有重複加、` +
        `原本填好的數量也沒有被動到：${r.skipped.join("、")}。` +
        `${L}的量要併進去的話，請到草稿頁自己改數量。`,
    );
  }

  // 讀完清單之後才被別人加進去的（DB 的 UNIQUE 擋下來）。
  // ⛔ 不可以併進 skipped 或 failed —— 兩邊都會講成不是事實的話（見 HandoffReport.raced）。
  if (r.raced.length > 0) {
    parts.push(
      `${r.raced.length} 樣在這幾秒之內被另一台裝置（或另一個分頁）加進同一張草稿了，` +
        `所以這次沒有重複加、對方填的數量也沒有被蓋掉：${r.raced.join("、")}。` +
        `請到撿貨草稿頁看一下最新的清單，確認數量是不是你要的。`,
    );
  }

  if (r.duplicatePos > 0) {
    // 「先前就收過了」的採購單：後端回的是舊的那張進貨單，這次填的件數不算數
    //（同 wms/receiving/ipad/page.tsx:1467-1468 已經立好的規則）→ ⛔ 不可以帶進草稿。
    parts.push(
      `另外有 ${r.duplicatePos} 張採購單是「先前就收過了」，` +
        `這次沒有真的收進新的貨，所以也沒有傳進草稿（要的話請到草稿頁自己加）。`,
    );
  }

  let error: string | null = null;
  if (r.failed.length > 0) {
    error =
      `⚠ 有 ${r.failed.length} 樣沒有傳進草稿（貨已經收進來了，只是草稿沒加到）：` +
      r.failed.map((f) => `${f.name}（${f.reason}）`).join("、") +
      "。可以再按一次「傳到撿貨草稿」重試，已經進去的不會重複加。";
  }

  return { notice: parts.length > 0 ? parts.join(" ") : null, error };
}

// ============================================================
// 5. 真的去寫（IO 全部注入，才驗得起來）
// ============================================================

/**
 * 這個錯誤是不是「這一格已經有人建了」（Postgres unique_violation）。
 *
 * ⭐ 為什麼判在這裡、⛔ 不是去改 describeDraftDbError（pickingDraftView.ts:38）：
 *   1. 那支是**兩個 PR 剛動過的熱點檔**（#892、#896），這個 PR 刻意讓它的 diff 維持 0 行。
 *   2. 更重要的是**語意只在這裡成立**：23505 在草稿頁的其他寫入點（改數量、補格子）
 *      代表的是別的事，翻成「這樣商品已經在草稿裡」到那邊就是錯的。
 *      ⇒ 通用的錯誤翻譯器不該知道這件事，知道了就會在別處說謊。
 *
 * ⚠ 只認 `code`，⛔ 不去比對訊息字串：PostgREST 的訊息會帶約束名稱，
 *   而那個名稱是 Postgres 自動產的（`picking_draft_items_draft_id_sku_id_store_id_key`），
 *   改一次表就變了 —— 拿它當判準是把測試綁在會漂移的東西上。
 */
function isUniqueViolation(err: unknown): boolean {
  const code = (err as { code?: unknown } | null | undefined)?.code;
  return code === "23505";
}

/** 需要寫入，所以不能沿用 pickingDraftView 的 ReadOnlyDb */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type DraftDb = { from: (table: string) => any };

export type HandoffDeps = {
  db: DraftDb;
  fetchAll: FetchAll;
  /** 取 tenant_id 與 uid；拿不到要 throw（整批不進去，⛔ 不可以退回空值硬寫） */
  session: () => Promise<{ tenantId: string; uid: string | null }>;
  /** 把 DB 錯誤翻成老闆看得懂的話（傳 pickingDraftView 的 describeDraftDbError 進來） */
  describeError: (e: unknown) => string;
  now?: () => Date;
  /**
   * 每處理完一樣就回報一次（done, total），給畫面顯示「12 / 30」。
   *
   * ⭐ 為什麼需要：這支是**逐樣往返**的（見 handoffToDraft ⑤ 的說明），
   *   30 樣 ≈ 90 趟。iPad 現場等 10 秒卻只看到「傳送中…」三個字，
   *   樓下會以為當掉而去戳別的東西。⛔ 進度不是裝飾，是「還在跑」的證據。
   */
  onProgress?: (done: number, total: number) => void;
};

/** 今天最多看幾張草稿。與草稿列表頁的 LIST_LIMIT（picking/drafts/page.tsx:37）同一個數字。 */
const TODAY_DRAFT_SCAN = 50;

/**
 * 找出「今天那張還能用的草稿」，沒有就開一張。
 *
 * 判定（老闆 2026-09-02 問題 2 選甲「自動進今天的草稿」）——
 * **台北時區的今天建立的草稿裡，最新建立、而且同時滿足下面兩條的那一張**：
 *
 *   ① `status = 'draft'`（還在進行中）
 *      ⛔ 不可以往「已完成／已收起」的草稿塞東西：那張已經印出來給樓下了，
 *        事後多一樣商品＝紙上沒有、系統上有。
 *
 *   ② `dispatched_at IS NULL`（**還沒送到派貨工作台**）
 *      ⭐⭐ 這一條是踩過才知道的：草稿送出去之後 status 會變 `done`，
 *        但老闆可以按「重新開啟」把它轉回 `draft`
 *        —— **而 dispatched_at 永不清空，送出鈕的條件是 `.is("dispatched_at", null)`**
 *        （picking/drafts/edit/page.tsx:349-352,:993；欄位 COMMENT 在
 *          20260818000000_picking_draft_dispatched.sql:59-60 明寫「一旦有值就永遠不清空」）。
 *      ⇒ 往一張「已送出但被重新開啟」的草稿加商品，那幾樣**永遠送不出去**，
 *        而且畫面上完全看不出來 —— 正是本專案最痛的那種靜默丟失。
 *        所以這種草稿一律當成不能用，另開一張。
 *
 * ⭐ 為什麼用 created_at 排序而不是 updated_at：
 *   picking_drafts 的 updated_at 只有那張草稿的**單頭**被 UPDATE 時才會動
 *   （trg_touch_picking_drafts 掛在 picking_drafts 上，明細有自己的 trigger，
 *     20260817000000:176-182）→ 加商品**不會**讓單頭的 updated_at 前進。
 *   拿它當「樓下正在用哪一張」的線索是錯的。
 *
 * ⚠ 已知限制（既有設計，本案沒有加重）：草稿名稱**沒有 unique**
 *   （picking/drafts/page.tsx:40 的註解：「老闆的實務是早上一批、下午一批
 *     → 預設帶日期，重複也沒關係」）。所以：
 *   · 老闆自己下午另開一張，這顆鈕之後就會進**下午那張**（最新的）—— 這是對的。
 *   · 同一天要開第 2 張以上時，名字**通常**會帶「（第N批）」以免同名分不出來。
 *
 * ⚠⚠ 「（第N批）」**不是保證**（阿審 2026-09-02 P2）。這支是「查一次、再寫一次」，
 *   中間沒有鎖也沒有 unique 約束，所以有一段窄縫：
 *   **兩台 iPad 在今天還沒有草稿時同時按，兩邊都查到空清單，就會各建一張
 *   一模一樣叫「YYYY-MM-DD 撿貨」的草稿**（都沒有帶「（第2批）」）。
 *   ⛔ 不要把上面那句「會帶（第N批）」讀成不變式 —— 它只在「查的時候已經看得到前一張」時成立。
 *
 *   **為什麼不修**（選擇不加防重，理由三條）：
 *   1. 要真的保證，需要 DB 的 unique 約束、advisory lock 或一支 RPC —— 三者都要動資料庫，
 *      而本案「零 migration、零新 RPC」是刻意的設計（見檔頭），為了一個名字去破它不划算。
 *   2. **後果只是多一張同名草稿，不會弄丟任何東西**：兩張都在列表上看得到、
 *      各自的明細都完整、⛔ 沒有任何一筆資料被覆蓋或吞掉
 *      （每一格的寫入都受 UNIQUE (draft_id, sku_id, store_id) 保護，而且只 insert 不 update）。
 *   3. 而且**看得見**：成功訊息一定會把草稿名字印出來、新開的還會標
 *      「（這是剛開的一張新草稿）」⇒ 樓下當場就會發現「怎麼開了兩張」，
 *      不是那種要等對帳才發現的錯。
 *   ⇒ 這是**已知且可接受**的競態，不是漏想。真的變成困擾再回頭加 unique。
 */
export async function findOrCreateTodayDraft(
  deps: HandoffDeps,
  ids: { tenantId: string; uid: string | null },
): Promise<{ id: number; name: string; created: boolean }> {
  const today = taipeiToday(deps.now ? deps.now() : new Date());
  const { from, to } = taipeiDayBounds(today);

  // 今天全部的草稿（含已完成／已送出）——⛔ 刻意不在 SQL 就篩掉：
  //   還要用「今天總共幾張」來決定新草稿的名字要不要帶「（第N批）」。
  const { data, error } = await deps.db
    .from("picking_drafts")
    .select("id, name, status, dispatched_at")
    .gte("created_at", from)
    .lt("created_at", to)
    .order("created_at", { ascending: false })
    .order("id", { ascending: false })
    .limit(TODAY_DRAFT_SCAN);
  if (error) throw error;

  const todays = (data ?? []) as {
    id: number;
    name: string;
    status: string;
    dispatched_at: string | null;
  }[];
  const usable = todays.find((d) => d.status === "draft" && d.dispatched_at === null);
  if (usable) return { id: Number(usable.id), name: usable.name, created: false };

  // ⚠ 這裡的「第N批」是**盡力而為**，不是保證：todays 是幾百毫秒前查的，
  //   另一台同時按就會兩邊都拿到同一個 N（見上面那段的窄縫說明）。
  const name =
    todays.length === 0 ? draftNameFor(today) : `${draftNameFor(today)}（第${todays.length + 1}批）`;
  const { data: made, error: insErr } = await deps.db
    .from("picking_drafts")
    .insert({ tenant_id: ids.tenantId, name, created_by: ids.uid, updated_by: ids.uid })
    .select("id, name")
    .single();
  if (insErr) throw insErr;
  return { id: Number((made as { id: number }).id), name, created: true };
}

/**
 * 把「這次收到的商品」傳進今天的撿貨草稿。
 *
 * 流程（⛔ 順序不可以換）：
 *   ① 身分 → ② 分店全表 → ③ 今天的草稿 → ④ 這張草稿已經有哪些商品
 *   → ⑤ 逐樣 loadPrefill + capPrefill + insert
 *
 * ①②③④ 任何一步失敗＝**整批都沒進去**（fatal），因為後面每一樣都要用到它們。
 * ⑤ 是逐樣的：某一樣壞掉，其他樣照樣進得去 —— 與 addSkus 同一條規則
 *   （picking/drafts/edit/page.tsx:747-751 有完整推導）。
 *
 * ⭐⭐ 防重（老闆驗收條件「同一批按兩次不會重複加」）＝
 *   **「這樣商品已經在這張草稿裡就略過」**，⛔ 不是另發明一把批次鍵。
 *   三個理由：
 *   1. 它是 DB 保證的：picking_draft_items 有 UNIQUE (draft_id, sku_id, store_id)
 *      （20260817000000:133）—— 就算前端判斷漏了，第二次也插不進去。
 *   2. 它比批次鍵**強**：批次鍵只擋得住「同一次送出按兩次」；這條連
 *      「不同批次但同一樣商品」都不會重複長出第二份矩陣。
 *   3. 它與草稿頁「加入商品」的行為**一模一樣**（addSkus 的 inDraft 集合），
 *      老闆已經熟悉這個行為，兩個入口不會給他兩種答案。
 *   ⚠ 代價：同一樣商品今天分兩批到貨時，第二批**不會**自動累加。
 *     這是刻意的 —— 要累加就得決定「多出來的量給哪一家」，那是分配決策，
 *     ⛔ 不可以由一顆鈕默默替老闆做。訊息會明講「請到草稿頁自己改數量」。
 */
export async function handoffToDraft(
  deps: HandoffDeps,
  args: {
    skus: HandoffSku[];
    source: HandoffSource;
    /** `skus[].qty` 是哪一種實收量。⛔ 必填：預設值會讓呼叫端「不小心正確」，
     *  而錯的那一邊剛好是不會被發現的那一邊（阿審 2026-09-02 P1）。 */
    qtyBasis: QtyBasis;
    duplicatePos?: number;
  },
): Promise<HandoffReport> {
  const base: HandoffReport = {
    draftId: null,
    draftName: null,
    draftCreated: false,
    added: [],
    skipped: [],
    raced: [],
    failed: [],
    fatal: null,
    duplicatePos: args.duplicatePos ?? 0,
    qtyBasis: args.qtyBasis,
  };

  if (args.skus.length === 0) {
    // ⓘ 措辭刻意不提「收貨」：這支是兩個入口共用的，採購單查看頁沒有「這次收好的」這回事。
    return { ...base, fatal: "沒有任何商品可以傳到撿貨草稿。" };
  }

  // ---- ① 身分 ----
  let ids: { tenantId: string; uid: string | null };
  try {
    ids = await deps.session();
  } catch (e) {
    return { ...base, fatal: `${deps.describeError(e)}（一樣都沒有傳進草稿。）` };
  }

  // ---- ② 分店全表（含停用）----
  // ⛔ 不可以在查詢就 .eq("is_active", true)：與 drafts/edit/page.tsx:195-199 同一條規則
  //   ——「停用但草稿裡有數量」的店會被標成「已刪除」，那是說了一件不是事實的事。
  let stores: HandoffStore[];
  try {
    const { data, error } = await deps.db.from("stores").select("id, code, name").order("code");
    if (error) throw error;
    stores = ((data ?? []) as HandoffStore[]).map((s) => ({
      id: Number(s.id),
      code: s.code,
      name: s.name,
    }));
    // 撈到 0 家店一定要吭聲：靜靜寫下去會建出一張沒有任何分店欄位的草稿列。
    if (stores.length === 0) throw new Error("撈不到任何分店");
  } catch (e) {
    return { ...base, fatal: `撈分店清單失敗：${deps.describeError(e)}（一樣都沒有傳進草稿。）` };
  }

  // ---- ③ 今天的草稿 ----
  let draft: { id: number; name: string; created: boolean };
  try {
    draft = await findOrCreateTodayDraft(deps, ids);
  } catch (e) {
    return { ...base, fatal: `開不了今天的撿貨草稿：${deps.describeError(e)}（一樣都沒有傳進草稿。）` };
  }
  base.draftId = draft.id;
  base.draftName = draft.name;
  base.draftCreated = draft.created;

  // ---- ④ 這張草稿已經有哪些商品 ----
  // ⚠ 走 fetchAll 分頁：一張草稿 = 商品數 × 分店數，50 樣 × 十幾家店就 ~700 列，
  //   PostgREST 預設 1000 列會靜默截斷 —— 截斷的後果是「以為沒加過」而重複嘗試，
  //   雖然 UNIQUE 會擋下來，但錯誤訊息會變成一堆看不懂的 23505。
  // ⭐ 剛開的草稿一定是空的（③ 才 insert 出來的）⇒ 這一趟直接省下來。
  //   省的不只是時間，還少一種失敗方式：新草稿不可能走進下面那個 fatal。
  let inDraft: Set<number>;
  try {
    const cells = draft.created
      ? []
      : await deps.fetchAll<{ sku_id: number }>(() =>
          deps.db
            .from("picking_draft_items")
            .select("sku_id")
            .eq("draft_id", draft.id)
            .order("id", { ascending: true }),
        );
    inDraft = new Set(cells.map((c) => Number(c.sku_id)));
  } catch (e) {
    return {
      ...base,
      fatal:
        `讀不到草稿〈${draft.name}〉現有的商品：${deps.describeError(e)}` +
        `（一樣都沒有傳進草稿 —— 讀不到就不知道哪些已經加過，硬加會重複。）`,
    };
  }

  // ---- ⑤ 逐樣寫入 ----
  //
  // ⚠ 成本：每一樣 ＝ loadPrefill 的 2 次讀 ＋ 1 次寫 ≒ 3 趟往返。
  //   30 樣 ≒ 90 趟。這是**刻意付的代價**，與 addSkus 同一個理由
  //   （picking/drafts/edit/page.tsx:747-751）：逐樣跑才講得出「哪幾樣沒進去」，
  //   合併成一次大查詢就只剩「整批失敗」。⇒ 改用 onProgress 讓等待看得見。
  // ⓘ 有一支批次版的預覽查詢（pickingDraftView 的 SkuPreviewBatch），
  //   但它只算得出每樣的「可分配量」，**沒有各店 demandLeft**，
  //   建不出格子 ⇒ ⛔ 不能拿來取代 loadPrefill。
  const snapshotAt = new Date().toISOString();
  let done = 0;
  const total = args.skus.length;
  deps.onProgress?.(0, total);
  for (const sku of args.skus) {
    if (inDraft.has(sku.sku_id)) {
      base.skipped.push(sku.label);
      deps.onProgress?.(++done, total);
      continue;
    }
    try {
      // ⛔ loadPrefill 刻意不 catch（見該函式）：讀不到需求就**這一樣不加**。
      //   退回「空需求」會建出一排 0，畫面跟「真的沒人要」一模一樣。
      const pre = await loadPrefill({ db: deps.db as ReadOnlyDb, fetchAll: deps.fetchAll }, sku.sku_id);
      const capped = capPrefill(pre, sku.qty);
      const cells = buildHandoffCells({
        tenantId: ids.tenantId,
        uid: ids.uid,
        draftId: draft.id,
        stores,
        sku,
        capped,
        pre,
        source: args.source,
        qtyBasis: args.qtyBasis,
        snapshotAt,
      });
      const { error } = await deps.db.from("picking_draft_items").insert(cells);
      if (error) throw error;

      base.added.push({
        name: sku.label,
        receivedQty: sku.qty,
        giveTotal: sumGive(capped),
        demandTotal: sumDemand(capped),
        available: capped.available,
      });
      // 同一次呼叫裡若同一樣商品出現兩次（理論上不會，來源已合併），第二次就會被略過
      inDraft.add(sku.sku_id);
    } catch (e) {
      // ⭐ 被別人搶先加進去（DB 的 UNIQUE 擋下）自成一類，⛔ 不可以當成一般失敗：
      //   一般失敗會說「沒有傳進草稿」，但這個情況商品**確實在草稿裡**（只是不是我們加的）。
      if (isUniqueViolation(e)) base.raced.push(sku.label);
      else base.failed.push({ name: sku.label, reason: deps.describeError(e) });
    }
    // ⛔ 成功失敗都要往前走一格：進度停住會被當成當掉
    deps.onProgress?.(++done, total);
  }

  return base;
}
