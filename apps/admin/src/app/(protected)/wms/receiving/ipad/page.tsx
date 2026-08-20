"use client";

// 📦 樓下收貨（iPad 專用頁）—— 搜尋驅動 + 批次收貨
//
// 為什麼要有這一頁：收貨原本只能辦公室用電腦按，樓下拿 iPad 做不了
//   —— 桌機側欄吃掉寬度、9 欄表格要左右拉、按鈕比手指小。
//
// ⭐ 2026-08-20 改版（老闆實際用過之後）：原本是「選廠商 → 選採購單 → 核對品項」
//   三層選擇，老闆原話：「我搜尋馬卡龍竟然是出現廠商，然後點進去滿滿的 PO 單號，
//   我要一個一個找。天啊!!一天要進快一百樣耶。」「樓下是戰區 時間就是金錢。」
//   → 樓下的心智模型是「**我手上這箱是馬卡龍，我要收它**」，
//     舊流程卻要他先想「這是誰送的、在哪張單」——方向完全相反。
//   → 改成：搜尋框常駐最上面，搜尋結果**直接就是品項清單**（一列 = 商品 × 採購單），
//     每列可勾選，勾好一次送出。廠商與單號降成小字備註。
//   ⛔ 改回「先選廠商」之前請先想清楚：一天 100 樣 × 三層 = 不可能用。
//
// ⛔ 這一頁只碰自己。現有 /wms/receiving（進貨待辦）與
//    /purchase/orders/receive（辦公室收貨頁）一行不改；後端 RPC 一行不改。
//
// 設計約束（都有出處，改之前先看）：
//   1. 走 rpc_arrive_and_distribute（最新版 20260820000000_arrive_idempotent_and_stale_guard.sql）。
//      ⛔ 不可以改用 rpc_adjust_po_item_received —— 那支是「絕對值覆蓋」語意
//      （20260729000020_po_adjust_received_creates_gr.sql:9-14 檔頭寫明），
//      樓下多台 iPad 同時收同一張單會互相蓋掉（A 填 5、B 填 3 → 結果是 3 不是 8）。
//      arrive 是累加語意（每次收貨建一張 GR），符合分批到貨的現實，也才有 variance_reason。
//   2. ⭐⭐ **這支 RPC 是 per-PO 的**，而搜尋結果會跨採購單
//      ⇒ 送出時一定要**按採購單分組、逐張呼叫**（分組邏輯在 @/lib/receivingBatch）。
//      由此衍生三件事，⛔ 缺一不可：
//        · 每張單**各自一把冪等鍵**（共用會被後端 20260820000000:349-352 擋掉，
//          一批 5 張只有第一張收得進去）
//        · 每一列**各自帶 qty_received_base**（樂觀鎖是逐項比對的）
//        · **成敗逐張顯示**（3 成功 1 失敗只講一句話，樓下會以為全收了或全沒收，
//          兩種誤會都讓盤點對不起來）
//   3. 樓下畫面不出現：單價 / 批號 / 效期 / 瑕疵數 / 供應商發票號 / 備註 / 分店分配。
//      unit_cost 仍照 purchase_order_items.unit_cost 原值帶給 RPC（不可送 0 或 null，
//      成本會影響加權平均成本）；分店分配一律留給派貨工作台。
//   4. 觸控：所有可點元素 min-h-[44px] min-w-[44px] + touch-manipulation
//      （機制索引七之五；touch-manipulation 消掉 iOS ~350ms 的 double-tap 等待）。
//      輸入框 ≥16px，否則 iOS 一 focus 就把整頁放大。
//   5. ⛔ 重要資訊不可以只放在 title tooltip —— iPad 上根本沒有 tooltip
//      （picking/drafts/edit/page.tsx:859 有同樣的教訓註解）。
//   6. 側欄：不改全站 layout.tsx（會炸到所有頁面所有使用者），改用本頁自己
//      fixed 全屏蓋掉。用 z-40：Modal 與 layout 手機抽屜都是 z-50，不會被遮住。
//      本頁自己的確認視窗用 z-50，蓋得住自己這一層。
//   7. 權限：這一頁多開了一個入口，所以**不可以比舊入口寬**。舊入口
//      /wms/receiving 在 layout 的 BRANCH_HIDDEN_HREFS 裡對分店帳號隱藏，
//      本頁照同一條判定（isBranchAccount）擋掉分店帳號並給返回出口。
//      ⚠ 刻意**不**再加 role.ts 的 isHqRole()：它的 HQ_ROLES 不含 assistant，
//        舊入口不擋 assistant，加了會比舊入口窄、可能把樓下倉管整個鎖在外面。
//      ⚠ 真正的守衛應該在 RPC（GRANT ... TO authenticated 是既有的洞，
//        現行兩頁一樣沒有頁面層守衛）—— 那是獨立議題，不在這一片處理。
//   8. 數量與成本：非法輸入一律明講並擋住，⛔ 不做任何靜默轉換或猜值
//      （見 @/lib/receivingBatch 的 classifyQty / blockReasonFor 與本檔 costOk 的註解）。
//   9. 防「同一批貨算兩次」有**三道，缺一不可**（前兩道在 20260820000000 那支
//      migration，第三道在 @/lib/receivingSubmission）：
//      · 冪等鍵 p_client_request_id —— 防「網路斷掉、其實成功了、樓下再按一次」
//      · 樂觀鎖 qty_received_base —— 防「兩台 iPad 各拿過期數字按全到」
//      · decideSubmission() —— 防「送出失敗後就地改內容再送」
//      ⭐ 批次化之後這三道**沒有被拿掉，而是每張採購單各自跑一份**
//        （subsRef 是 Map<po_id, Submission>，見它的宣告處）。
//      ⛔ 不要以為其中一個能取代另一個：冪等鍵只認得同一次送出（兩台是兩個
//        不同的值），樂觀鎖擋得住但吐的是紅字（樓下會以為失敗而再按），
//        而兩者都對「這次沒送進來的品項」視而不見。
//      ⛔ 也不要把它們改成「加一把鎖就好」：RPC 第一步的 FOR UPDATE 本來就
//        讓同一張單排隊了，排隊不會讓第二台手上的數字變新。

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { translateRpcError } from "@/lib/rpcError";
import { type Submission } from "@/lib/receivingSubmission";
import {
  blockReasonFor,
  buildHaystack,
  classifyQty,
  groupArrivalsByPo,
  matchesQuery,
  normalizeWorkbenchPOs,
  runBatchSubmit,
  runExclusive,
  tokenizeQuery,
  WORKBENCH_PO_LIMIT,
  type BatchItem,
  type BusyKind,
  type WorkbenchPO,
} from "@/lib/receivingBatch";
import { publicProductUrl } from "@/lib/campaignCover";
import { useAuth } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

// ---------------------------------------------------------------- types

// ⓘ WorkbenchPO 與它的整理／截斷判定都在 @/lib/receivingBatch（那裡才驗得到）。

/** 一列 ＝ 一個商品 × 一張採購單。這一頁的主角。 */
type Row = {
  po_item_id: number;
  po_id: number;
  po_no: string;
  supplier_name: string;
  /** 送單日期。同一個商品開了好幾張單時，這是樓下唯一分得出來的線索。 */
  sent_at: string | null;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  image_url: string | null;
  qty_ordered: number;
  qty_already: number;
  /** 應到 ＝ 訂購 − 之前已收。「全到」填的就是這個數字（不是訂購量）。 */
  remaining: number;
  /** 採購單原本的成本。樓下看不到、不能改，但一定要原值帶給 RPC。 */
  unit_cost: number;
  /** 搜尋用（已小寫）：品名 / 規格 / 商品編號 / 廠商 / 單號 */
  haystack: string;
};

/** 使用者對某一列輸入的東西。**這個 map 裡有 key ＝ 這一列被勾選了。** */
type Entry = { qty: string; reason: string };

/** 一張採購單的送出結果。⛔ 一定要逐張留著，不可以只留一個總結。 */
type PoOutcome = {
  po_id: number;
  po_no: string;
  supplier_name: string;
  lines: number;
  qty: number;
  kind: "ok" | "duplicate" | "error";
  gr_no?: string;
  message?: string;
};

// 數量不符時的常用原因（一鍵填進既有 variance_reason 欄位，不新增資料表）
const REASON_PRESETS = ["缺貨", "破損", "送錯", "多送"] as const;

// 一次抓 purchase_order_items 的分頁大小與頁數上限。
//
// ⚠️ PostgREST 預設單次最多回 1000 列（見 @/lib/fetchAllRows 檔頭）。
//   本頁一開始就把「所有待收採購單的所有品項」拉下來，是為了讓搜尋**零延遲**
//   （樓下一天要搜近百次，每次都等一趟 round-trip 是不能用的）。
// ⚠️ 頁數上限 8 ＝ 最多 8000 列。超過就截斷，而截斷**一定要講出來**：
//   搜不到的東西看起來像「系統沒這筆」，那是最糟的失敗方式。
//   偵測方式見 fetchRowsFor()：workbench 的 line_count 是精確的品項列數，
//   拿它跟實際抓回來的列數比對即可，⛔ 不必猜。
const ITEM_PAGE_SIZE = 1000;
const ITEM_MAX_PAGES = 8;

// skus 用 .in("id", …) 撈，分批送。
// ⚠️ 兩個上限同時要顧：單批 < 1000 列（PostgREST 截斷）、URL 不能太長（414）。
//   300 個 id ≈ 2KB query string，兩邊都安全。
const SKU_CHUNK = 300;

// 一次最多畫幾張卡片。
//
// ⚠️ 這不是美觀問題，是**會不會當機**的問題：搜尋框空白時符合條件的就是全部
//   待收品項（可能好幾千項），每張卡片都有一張圖，iPad 一次畫幾千張會直接卡死。
// ⚠️ 被截掉的部分**一定要講**，而且「全選」只能作用在**畫出來的這幾項**上
//   （見 toggleSelectAll）—— 讓人按一個「全選 500 項」卻只有 200 項看得到，
//   正是本頁最危險的失敗方式（送出的東西畫面上看不到）。
const RENDER_LIMIT = 200;

// ---------------------------------------------------------------- helpers

/** images[0] 可能是字串或 { url }（比照 campaigns/quick-control/page.tsx:207-212） */
function productImageUrl(images: unknown): string | null {
  if (!Array.isArray(images) || images.length === 0) return null;
  const first = images[0] as unknown;
  const path = typeof first === "string" ? first : (first as { url?: string | null })?.url ?? null;
  return publicProductUrl(path);
}

// ⓘ 實到數量的驗證在 @/lib/receivingBatch 的 classifyQty()
//   （四種結果 ok / empty / invalid / zero，那裡有完整推導，而且驗得到）。

/**
 * 成本必須是正數才可以入庫。
 *
 * NEW-ERP 的 `purchase_order_items.unit_cost` 是 NUMERIC(18,4) **NOT NULL**
 * （20260422120004_purchase_schema.sql:102，之後沒有 migration 改過），
 * 所以 NULL 的情境不存在；**但它沒有 CHECK (> 0)，0 是合法值**。
 * 採購單填 0 或漏填時，這一頁會用 0 成本入庫，而樓下看不到單價、
 * 錯了永遠不會發現（辦公室現行收貨頁至少看得到也改得掉）。
 * → 這是本頁特有的風險，成本不正常的品項一律收不進去。
 *
 * ⚠ 擋的範圍：**只擋「這次真的要收」的那幾列**，不是整批。
 *   兩種擋法對帳的保護完全等價（成本異常的品項兩者都收不進去），
 *   差別只在猜錯時的代價：擋整批會讓樓下站在貨旁邊什麼都收不了。
 * ⛔ 但絕不可以放行：「擋錯了」的代價是一通電話，「放過了」的代價是
 *   0 成本入庫拉低加權平均、靜默壞帳而且畫面上看不出來。
 */
function costOk(cost: number): boolean {
  return Number.isFinite(cost) && cost > 0;
}

/** 分店帳號判定 —— 與 (protected)/layout.tsx:134 的 isBranchUser() 等價。
 *  ⚠ 那支住在全站 layout（禁改），這裡照抄一份；改那邊要記得改這邊。
 *  ⚠ layout 的 BRANCH_HIDDEN_HREFS 是精確字串比對（Set.has），
 *    /wms/receiving/ipad 不會自動繼承「進貨待辦」對分店的隱藏，故本頁自己擋。 */
function isBranchAccount(user: { app_metadata?: Record<string, unknown> } | null | undefined): boolean {
  const stores = user?.app_metadata?.stores;
  if (!Array.isArray(stores) || stores.length === 0) return false;
  return !stores.includes("總倉");
}

/**
 * 這一次送出的識別碼（冪等鍵）。
 *
 * 為什麼要有它：iPad 現場的網路會斷。後端已經入庫、但 HTTP 回應在路上掉了，
 * 前端只看得到「失敗」，樓下照畫面指示再按一次 → 同一批貨被算兩次
 * （rpc_arrive_and_distribute 是累加語意，每按一次建一張 GR）。
 * 帶著同一個識別碼重試，後端就認得出「這是同一次送出」，回傳原本那張 GR。
 *
 * 寫法比照 members/import/page.tsx:103-105（randomUUID 在很舊的 iOS Safari 沒有）。
 */
function newRequestId(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `r_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

/** 商品名一律帶 variant_name：product_name 常常是上層品名，只印它現場會抓錯貨
 *  （機制索引：G00213-01 的 product_name 是「台南日曬手工麵」，
 *   真正的東西「(A)關廟刀削麵」在 variant_name）。 */
function rowTitle(r: {
  product_name: string | null;
  variant_name: string | null;
  sku_code: string | null;
  sku_id: number;
}): string {
  const main = r.product_name?.trim() || r.sku_code || `#${r.sku_id}`;
  const sub = r.variant_name?.trim();
  return sub ? `${main} / ${sub}` : main;
}

/** 數量顯示：整數就不要拖著 .000（numeric(18,3) 的浮點尾巴很難看） */
function fmtQty(n: number): string {
  return Number.isInteger(n) ? String(n) : String(Number(n.toFixed(3)));
}

function chunk<T>(list: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

// 觸控目標統一寫法（機制索引七之五：用 min-h 撐高、不要加 py）
const BTN_BASE =
  "inline-flex items-center justify-center gap-1 rounded-xl font-semibold touch-manipulation " +
  "min-h-[56px] min-w-[56px] px-4 text-base disabled:cursor-not-allowed disabled:opacity-40";
const BTN_PRIMARY = `${BTN_BASE} bg-blue-600 text-white active:bg-blue-700`;
const BTN_GHOST = `${BTN_BASE} border border-zinc-300 bg-white text-zinc-800 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:active:bg-zinc-800`;
const BTN_SMALL =
  "inline-flex items-center justify-center gap-1 rounded-lg font-semibold touch-manipulation " +
  "min-h-[44px] px-3 text-sm disabled:cursor-not-allowed disabled:opacity-40";

// ---------------------------------------------------------------- 資料載入

type RawItem = {
  id: number;
  po_id: number;
  sku_id: number;
  qty_ordered: number;
  qty_received: number | null;
  unit_cost: number;
  stockout_at: string | null;
};

type RawSku = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  product: { images: unknown } | { images: unknown }[] | null;
};

type FetchResult = {
  rows: Row[];
  /** 商品資料沒撈回來的品項數（樓下靠圖片與品名辨貨，缺漏不能無聲） */
  missingSku: number;
  /** 數量資料異常、被排除掉的列（見下方 badData 的說明） */
  badData: string[];
  /** 被 PostgREST 列數上限截斷時 = 缺了幾列；沒截斷就是 0 */
  truncated: number;
};

/**
 * 把「這些採購單的所有待收品項」攤平成 Row[]。
 *
 * ⚠️ 為什麼一次撈全部而不是逐張單撈：本頁的核心是**搜尋要即時**。
 *   逐張撈的話，使用者每打一次字就要等一趟網路，那正是老闆嫌慢的原因。
 *
 * ⚠️ 掃描成本：`purchase_order_items.po_id` **沒有索引**（機制索引四之七），
 *   所以 `.in("po_id", …)` 是全表掃描。但**改版前這一頁就已經有一次同樣的掃描**
 *   （舊版拿它數斷貨列數），這裡是把那一次擴充成「順便把欄位帶回來」，
 *   ⇒ 掃描次數不增反減（舊版之後還要逐張單再各掃一次）。
 *   ⛔ 不要為了省事改成 LEFT JOIN LATERAL 或逐 PO 查詢，那才是真的退步。
 *
 * ⚠️ skus 沒辦法用 PostgREST 內嵌一起撈：`purchase_order_items.sku_id`
 *   **沒有 FOREIGN KEY 指向 skus**（20260422120004_purchase_schema.sql:96 是
 *   純 BIGINT NOT NULL），PostgREST 找不到關聯。所以照舊分兩段查。
 */
async function fetchRowsFor(pos: WorkbenchPO[]): Promise<FetchResult> {
  if (pos.length === 0) return { rows: [], missingSku: 0, badData: [], truncated: 0 };

  const sb = getSupabase();
  const poIds = pos.map((p) => p.id);
  // line_count 是 rpc_receiving_workbench 精確算出來的品項列數
  //（20260819000000:100 的 COUNT(poi.id)）→ 拿它當「應該抓到幾列」的基準，
  // 就能明確判斷有沒有被列數上限截掉，⛔ 不必用「剛好 8000 列」這種猜法。
  const expected = pos.reduce((s, p) => s + p.line_count, 0);

  const raw = await fetchAllRows<RawItem>(
    () =>
      sb
        .from("purchase_order_items")
        .select("id, po_id, sku_id, qty_ordered, qty_received, unit_cost, stockout_at")
        .in("po_id", poIds)
        // 分頁一定要有穩定的 total order，否則跨頁會漏列／重複列
        // （@/lib/fetchAllRows 檔頭的要求）。id 是 PRIMARY KEY，唯一且穩定。
        .order("id"),
    ITEM_PAGE_SIZE,
    ITEM_MAX_PAGES,
  );

  const truncated = Math.max(0, expected - raw.length);

  // 已斷貨的品項不列出來（比照現有收貨頁 receive/page.tsx:197-199）
  const live = raw.filter((r) => !r.stockout_at);

  const skuMap = new Map<
    number,
    { code: string | null; product: string | null; variant: string | null; img: string | null }
  >();
  const skuIds = Array.from(new Set(live.map((r) => r.sku_id)));
  for (const ids of chunk(skuIds, SKU_CHUNK)) {
    const { data: skus, error } = await sb
      .from("skus")
      .select("id, sku_code, product_name, variant_name, product:products(images)")
      .in("id", ids);
    if (error) throw new Error(error.message);
    for (const s of (skus as RawSku[] | null) ?? []) {
      const prod = Array.isArray(s.product) ? s.product[0] ?? null : s.product;
      skuMap.set(s.id, {
        code: s.sku_code,
        product: s.product_name,
        variant: s.variant_name,
        img: productImageUrl(prod?.images),
      });
    }
  }

  const poMap = new Map(pos.map((p) => [p.id, p]));
  const rows: Row[] = [];
  const badData: string[] = [];

  for (const r of live) {
    const po = poMap.get(r.po_id);
    if (!po) continue; // 撈回來的單不在清單裡（理論上不會發生）→ 略過，不要憑空生一列
    const s = skuMap.get(r.sku_id);
    const ordered = Number(r.qty_ordered);
    const already = Number(r.qty_received ?? 0);

    // ⚠️ 這兩個值不能是 NaN/Infinity，⛔ 尤其 already ——
    //   它會被當成 qty_received_base 送給後端做樂觀鎖比對，
    //   而 JSON.stringify(NaN) 是 **null** → 後端讀成 SQL NULL
    //   → `IF v_base IS NOT NULL` 不成立 → **樂觀鎖被靜默跳過**。
    //   防重複收貨的那道防線就這樣無聲消失了，畫面上完全看不出來。
    //   正常 Postgres numeric 不會給出這種值，所以這裡是「壞了就不准收」，
    //   不是猜一個值頂替（猜錯會變成錯的庫存，比收不了貨嚴重）。
    // ⚠️ 改版後的做法是**排除這一列並把它列出來**，不是像舊版那樣整批不給收：
    //   舊版一次只開一張單，整張擋住還算合理；現在一次是全部待收品項，
    //   一列壞掉就讓樓下什麼都收不了，代價差太多。
    //   ⛔ 但一定要**吵**：badData 會在畫面最上面用紅框列出來，不是靜默跳過。
    if (!Number.isFinite(ordered) || !Number.isFinite(already)) {
      const label = rowTitle({
        product_name: s?.product ?? null,
        variant_name: s?.variant ?? null,
        sku_code: s?.code ?? null,
        sku_id: r.sku_id,
      });
      badData.push(`${po.po_no}／${label}`);
      continue;
    }

    rows.push({
      po_item_id: r.id,
      po_id: r.po_id,
      po_no: po.po_no,
      supplier_name: po.supplier_name,
      sent_at: po.sent_at,
      sku_id: r.sku_id,
      sku_code: s?.code ?? null,
      product_name: s?.product ?? null,
      variant_name: s?.variant ?? null,
      image_url: s?.img ?? null,
      qty_ordered: ordered,
      qty_already: already,
      remaining: Math.max(0, ordered - already),
      unit_cost: Number(r.unit_cost),
      haystack: buildHaystack([
        s?.product,
        s?.variant,
        s?.code,
        po.supplier_name,
        po.supplier_code,
        po.po_no,
      ]),
    });
  }

  // 同一個商品的不同採購單排在一起 —— 老闆的原話是「同規格下有很多，
  // 要有核取方塊可以全選」，排在一起才勾得動。
  rows.sort(
    (a, b) =>
      rowTitle(a).localeCompare(rowTitle(b), "zh-Hant") ||
      a.supplier_name.localeCompare(b.supplier_name, "zh-Hant") ||
      a.po_no.localeCompare(b.po_no) ||
      a.po_item_id - b.po_item_id,
  );

  return { rows, missingSku: Math.max(0, skuIds.length - skuMap.size), badData, truncated };
}

/**
 * 待收採購單清單。整理與「可能被截斷」的判定都在 normalizeWorkbenchPOs()。
 *
 * ⭐ 這支 RPC 從 #798（20260820000200）起，`sent / partially_received`
 *   **全取、不設上限** ⇒ 這一頁要收的貨不會再被截掉。
 *   `fully_received` 那半仍限 200 張，但下面 normalizeWorkbenchPOs 本來就把它濾掉。
 *   ⇒ listMaybeTruncated 現在是「RPC 被回退成舊版」的絆線，不是常態警告。
 */
async function fetchWorkbenchPOs(): Promise<{
  pos: WorkbenchPO[];
  listMaybeTruncated: boolean;
}> {
  const sb = getSupabase();
  const { data, error } = await sb.rpc("rpc_receiving_workbench");
  if (error) throw new Error(error.message);
  return normalizeWorkbenchPOs((data ?? []) as Array<Record<string, unknown>>);
}

// ---------------------------------------------------------------- 逐列判定

type RowCheck = {
  selected: boolean;
  received: number;
  /** 打了非數字（"-5"、"1e3"、"abc"…）→ 明確擋下，⛔ 不靜默轉換 */
  invalid: boolean;
  /** 勾了但數量欄是空的 → 擋下。⛔ 不可以靜默當作 0 跳過，少收一項樓下不會發現 */
  empty: boolean;
  /** 勾了但數量填 0（用「−」按到底也會走到這裡）→ 擋下。
   *  ⛔ 不可以放行讓後端擋：後端是**整張採購單一起炸**，同批其他正常品項會被連坐，
   *     而且訊息是未中文化的 `arrival sku_id X has invalid qty_received`。 */
  zero: boolean;
  /** 採購單成本 <= 0 或不是數字 → 這一列收不進去 */
  badCost: boolean;
  isOver: boolean;
  isShort: boolean;
  requiresReason: boolean;
  reasonMissing: boolean;
};

/** 每一列的判定：實到 ≠ 應到（且實到 > 0）就要填原因
 *  —— 與現有收貨頁 receive/page.tsx:321-324 同一條規則，
 *     不照做的話前端校驗會跟辦公室那頁不一致。 */
function checkRow(row: Row, entry: Entry | undefined): RowCheck {
  const badCost = !costOk(row.unit_cost);
  if (!entry) {
    return {
      selected: false,
      received: 0,
      invalid: false,
      empty: false,
      zero: false,
      badCost,
      isOver: false,
      isShort: false,
      requiresReason: false,
      reasonMissing: false,
    };
  }
  const { verdict, qty: received } = classifyQty(entry.qty);
  const invalid = verdict === "invalid";
  const empty = verdict === "empty";
  const zero = verdict === "zero";
  // ⚠️ 「多／少了幾件要填原因」一律以 received > 0 為前提：填 0 是「不收」，
  //   不是「少收」—— 它由 zero 直接擋掉，不該再叫人去選一個差異原因。
  const isOver = received > row.remaining;
  const isShort = received > 0 && received < row.remaining;
  const requiresReason = received > 0 && (isOver || isShort);
  return {
    selected: true,
    received,
    invalid,
    empty,
    zero,
    badCost,
    isOver,
    isShort,
    requiresReason,
    reasonMissing: requiresReason && !entry.reason.trim(),
  };
}

// ---------------------------------------------------------------- page

export default function IpadReceivingPage() {
  const { user, loading: authLoading } = useAuth();
  const branchBlocked = !authLoading && isBranchAccount(user);

  const [pos, setPos] = useState<WorkbenchPO[] | null>(null);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [missingSkuCount, setMissingSkuCount] = useState(0);
  const [badData, setBadData] = useState<string[]>([]);
  const [truncated, setTruncated] = useState(0);
  /** 採購單清單可能被後端 RPC 的 LIMIT 截掉了。
   *  ⭐ #798 之後這在正常情況下**恆為 false**，是「RPC 被回退成舊版」的絆線
   *    （判定與推導見 @/lib/receivingBatch 的 normalizeWorkbenchPOs）。 */
  const [poListMaybeTruncated, setPoListMaybeTruncated] = useState(false);

  const [search, setSearch] = useState("");
  const [showSelectedOnly, setShowSelectedOnly] = useState(false);
  const [showDone, setShowDone] = useState(false);

  // 有 key ＝ 這一列被勾選。**跨搜尋保留**（見 onSearch 附近的說明）。
  const [entries, setEntries] = useState<Record<number, Entry>>({});

  const [confirmOpen, setConfirmOpen] = useState(false);
  const [outcomes, setOutcomes] = useState<PoOutcome[] | null>(null);
  /** 送出後重撈失敗 → 畫面上的「之前已收」可能過期。要講出來但不必卡死
   *  （樂觀鎖會擋，失敗方式是吵的）。 */
  const [staleWarning, setStaleWarning] = useState<string | null>(null);
  const [reloadingPo, setReloadingPo] = useState<number | null>(null);

  /**
   * ⭐ 全頁**只有一把鎖**：整頁重撈 / 單張重撈 / 送出，三者互斥。
   *   規則本身在 @/lib/receivingBatch 的 runExclusive()（那裡有完整推導，
   *   而且驗得到）。這裡只有兩份存放處：
   *     · busyRef —— 真正的鎖。⛔ 一定要用 ref，state 擋不住同一 tick 連點
   *       （比照 purchase/orders/receive/page.tsx:104）。
   *     · busy    —— 給畫面用的鏡像。按鈕變灰、而且**要看得出來為什麼**
   *       （iPad 沒有 tooltip，停用原因只能寫在畫面上）。
   *
   * ⚠️ 為什麼三者非互斥不可：重撈會清掉那幾張單的 entries 與 subsRef（冪等鍵），
   *   跑在送出中途等於把防重複的鍵抽掉；反過來送出中途重撈，畫面上的
   *   「之前已收」會在送出的一連串 await 中間被換掉。
   *   帳本身有後端的樂觀鎖兜著（失敗是吵的），但畫面會變得沒辦法判讀。
   */
  const busyRef = useRef<BusyKind | null>(null);
  const [busy, setBusy] = useState<BusyKind | null>(null);
  const submitting = busy === "submit";

  /**
   * 每一張採購單自己的冪等鍵 ＋ 當時送出的內容。
   *
   * ⭐⭐ 批次化最重要的一行就是這裡的 **Map<po_id, …>**：
   *   舊版一次只收一張單，所以是單一個 ref；現在一次會跨多張，
   *   ⛔ **絕對不可以退回成共用一把**——後端 20260820000000:349-352 明文擋
   *   「同一個識別碼跑到別張採購單」，共用的結果是第一張收得進去、
   *   其餘每一張都吐「收貨識別碼 xxx 先前已用在採購單 #A」這種天書。
   *
   * 生命週期跟舊版逐字相同，只是「每張單各跑一份」
   * （判斷邏輯本身在 @/lib/receivingSubmission，那裡有完整推導）：
   *   1. **送出時才產**（不是勾選時）：沒送出過就沒有東西要防重。
   *   2. **失敗不換**：重試要帶同一個值，後端才認得出「這是同一次送出」。
   *      ⭐ 只有「交易真的 commit 了」那個值才會被後端記住 —— 沒寫進去的失敗
   *      （成本擋、找不到品項…）重試會被當成全新的一次，正確。
   *   3. **內容改了就整個擋下來**（2026-08-20 複審 P0 改法；前一版是「換新鍵」，
   *      那是錯的 —— 換新鍵之後，第二次沒送進來的品項不會被任何防線檢查）。
   *      id 與 payload 綁在同一個物件裡，**一起存、一起清**，避免只換一半。
   *   4. **那張單成功就清掉它那一格**：下一次送出是全新的一次。
   *   5. **重撈成功時才清**（⭐ 這條是刻意的，順序也是刻意的）：
   *      能沿用同一把鍵的情境只有「人還站在畫面上、看著紅字再按一次」。
   *      一旦重新讀到最新的 qty_received，舊的值就該丟 —— 否則
   *      若上一次其實成功了、而樓下這回是要收**今天到的第二批**，
   *      會被誤判成重試而**靜默不收**（比重複收更難發現）。
   *      ⚠️ 但一定要**等重撈成功之後**才清：重撈失敗時畫面上還是舊資料，
   *         這時把它清掉，等於讓人拿著過期的 base 重新送一次。
   *   ⓘ 萬一將來有人漏了第 5 條，後端還有一道：同一個值用到別張採購單會直接報錯
   *      （不是靜默放行），失敗方式是吵的、不是安靜的。
   */
  const subsRef = useRef<Map<number, Submission>>(new Map());

  const searchRef = useRef<HTMLInputElement | null>(null);
  const mainRef = useRef<HTMLElement | null>(null);

  // rows 的即時鏡像。⚠️ 送出是一連串 await，中途 rows 會被 reloadPos 換掉；
  // 直接用 render 當下閉包裡的 rows 會拿到過期的清單（清錯 entries）。
  // ⛔ 不要改成把 rows 放進 useCallback 依賴 —— 那只會讓函式重建，
  //    已經開跑的那一次 async 流程手上還是舊的那份。
  const rowsRef = useRef<Row[]>([]);
  useEffect(() => {
    rowsRef.current = rows ?? [];
  }, [rows]);

  // ------------------------------------------------------------ 載入

  // ⚠ 第一件事就 await，不在 effect body 同步 setState
  //   （react-hooks/set-state-in-effect；repo 既有寫法見
  //    picking/drafts/edit/page.tsx:180）。
  //   「正在載入」的視覺回饋不靠 state：第一次是 rows === null，
  //   按 🔄 那次由 SpinButton 自己顯示 spinner。
  // ⛔ 併發守衛走 runExclusive（ref，不是 state）：送出是一連串 await，
  //   中途若讓 loadAll 跑起來，它會把 entries 與 subsRef 清掉 ——
  //   那正是「冪等鍵被中途清掉」的洞。
  const loadAll = useCallback(async () => {
    await runExclusive(busyRef, "load", setBusy, async () => {
      try {
        const { pos: list, listMaybeTruncated } = await fetchWorkbenchPOs();
        const res = await fetchRowsFor(list);
        setError(null);
        setPos(list);
        setPoListMaybeTruncated(listMaybeTruncated);
        setRows(res.rows);
        setMissingSkuCount(res.missingSku);
        setBadData(res.badData);
        setTruncated(res.truncated);
        // ⭐ 到這裡才代表「畫面上的已收量是剛剛從資料庫讀回來的」，
        //    舊的冪等鍵與使用者填的數字到這一刻才可以丟（理由見 subsRef 第 5 條）。
        subsRef.current = new Map();
        setEntries({});
        setStaleWarning(null);
        setOutcomes(null);
      } catch (e) {
        setError(translateRpcError(e));
        // ⛔ 失敗時**不要**把 rows 清成 []：那會讓畫面看起來像「今天沒有待收的貨」，
        //    而事實是「沒載到」。維持原狀 + 紅字，樓下才知道要重試。
        // ⛔ 也不要清 subsRef／entries：那兩個只有在**重撈成功**之後才可以丟
        //    （見 subsRef 第 5 條）。
        // ⛔ poListMaybeTruncated 也不要清成 false：載入失敗時畫面上還是上一次
        //    那份清單，上一次的判定仍然成立。清掉等於把警告偷偷關掉。
      }
    });
  }, []);

  useEffect(() => {
    // 身分還沒確定、或已判定是分店帳號 → 不要去撈資料
    if (authLoading || branchBlocked) return;
    let cancelled = false;
    void (async () => {
      // ⚠ 先讓出一個 microtask 再呼叫 loadAll()。
      //   loadAll 的第一個 await 之前雖然沒有 setState，但它的 catch 有 ——
      //   而 getSupabase() 這種同步例外會讓那個 catch 在 effect body 的**同一個 tick**
      //   跑到，就是 react-hooks/set-state-in-effect 講的連鎖 render。
      //   ⛔ 不要改成 eslint-disable：那條規則講的事情是真的。
      await Promise.resolve();
      if (!cancelled) await loadAll();
    })();
    return () => {
      cancelled = true;
    };
  }, [loadAll, authLoading, branchBlocked]);

  /**
   * 只重撈某幾張採購單的品項，換掉 rows 裡對應的列。
   *
   * ⚠️ 成功之後才可以清掉那幾張單的冪等鍵與使用者輸入（subsRef 第 5 條）。
   *    失敗就整支 throw，由呼叫端決定要不要卡住。
   *
   * ⛔⛔ 這一支**故意不自己取互斥鎖**，鎖在呼叫端取：
   *    runSubmit() 成功之後自己就會呼叫它（那時鎖已經在自己手上），
   *    塞在這裡不是自我封鎖就是被自己擋掉。
   *    ⇒ 使用者按得到的入口（OutcomePanel 的「🔄 重新載入這張單」）
   *      **一定要包在 runExclusive 裡**，否則就是複審抓到的那條 P1。
   */
  const reloadPos = useCallback(
    async (poIds: number[]) => {
      if (poIds.length === 0) return;
      // ⛔ 找不到要重撈的單就**丟出錯誤**，不可以靜默 return：
      //   呼叫端會把「沒有丟錯」當成重撈成功，接著清掉冪等鍵 ——
      //   而畫面上其實還是舊資料，等於讓人拿過期的 base 再送一次。
      const targets = (pos ?? []).filter((p) => poIds.includes(p.id));
      if (targets.length !== poIds.length) {
        throw new Error("待收清單已經變動，找不到要重新載入的採購單。請按最上面的 🔄 重新整理。");
      }
      const res = await fetchRowsFor(targets);
      const touched = new Set(poIds);
      setRows((cur) => {
        const kept = (cur ?? []).filter((r) => !touched.has(r.po_id));
        const merged = [...kept, ...res.rows];
        merged.sort(
          (a, b) =>
            rowTitle(a).localeCompare(rowTitle(b), "zh-Hant") ||
            a.supplier_name.localeCompare(b.supplier_name, "zh-Hant") ||
            a.po_no.localeCompare(b.po_no) ||
            a.po_item_id - b.po_item_id,
        );
        return merged;
      });
      // 「這幾項資料異常、收不了」的清單也要跟著換掉那幾張單的部分，
      // ⛔ 不可以放著不管：那幾列會從清單裡消失，只剩一張過期的紅框在講別的事。
      // （badData 的字串一律是 `${po_no}／品名`，所以用單號前綴就換得掉。）
      setBadData((cur) => {
        const prefixes = targets.map((p) => `${p.po_no}／`);
        return [...cur.filter((t) => !prefixes.some((pre) => t.startsWith(pre))), ...res.badData];
      });
      // ⚠️ missingSkuCount 是整頁的一個總數，沒辦法只換這幾張單的部分 ——
      //    部分重撈之後它可能偏舊。它只是「有東西沒圖沒名字，去問辦公室」的提示，
      //    偏舊不會讓人收錯貨；要精確就得按 🔄 重新整理。

      // 重撈成功 → 這幾張單的冪等鍵與使用者輸入都可以丟了（subsRef 第 5 條）
      for (const id of poIds) subsRef.current.delete(id);
      setEntries((cur) => {
        const next = { ...cur };
        // ⚠️ 用 rowsRef（重撈前的那份）來找出要清掉的 key：重撈之後某些
        //   po_item_id 可能已經不在清單裡（收齊了、或被斷貨），
        //   拿新的那份去清會留下清不掉的孤兒 entry。
        for (const r of rowsRef.current) if (touched.has(r.po_id)) delete next[r.po_item_id];
        return next;
      });
    },
    [pos],
  );

  // ------------------------------------------------------------ 搜尋 / 篩選

  const tokens = useMemo(() => tokenizeQuery(search), [search]);

  const visible = useMemo(() => {
    if (!rows) return [];
    if (showSelectedOnly) return rows.filter((r) => entries[r.po_item_id]);
    return rows.filter((r) => matchesQuery(r.haystack, tokens));
  }, [rows, tokens, showSelectedOnly, entries]);

  const pendingAll = useMemo(() => visible.filter((r) => r.remaining > 0), [visible]);
  const finishedAll = useMemo(() => visible.filter((r) => r.remaining <= 0), [visible]);

  // ⚠️ 只畫前 RENDER_LIMIT 項（理由見該常數）。以下所有「全選 / 這 N 項」
  //    一律以**畫出來的這幾項**為準，⛔ 不可以用 pendingAll ——
  //    勾到看不見的東西是本頁最危險的失敗方式。
  const pending = useMemo(() => pendingAll.slice(0, RENDER_LIMIT), [pendingAll]);
  const finished = useMemo(() => finishedAll.slice(0, RENDER_LIMIT), [finishedAll]);
  const overflow = pendingAll.length - pending.length + (finishedAll.length - finished.length);

  const selectedRows = useMemo(
    () => (rows ?? []).filter((r) => entries[r.po_item_id]),
    [rows, entries],
  );

  /** 已勾但**畫面上真的看不到**的列。
   *  ⚠️ 基準是「真正畫出來的那幾張卡片」，不是 visible ——
   *     visible 還包含被 RENDER_LIMIT 截掉、沒畫出來的部分。
   *  ⛔ 這個數字一定要顯示出來：「送出的東西畫面上看不到」是本頁最危險的失敗方式。 */
  const hiddenSelected = useMemo(() => {
    const shown = new Set([...pending, ...finished].map((r) => r.po_item_id));
    return selectedRows.filter((r) => !shown.has(r.po_item_id));
  }, [pending, finished, selectedRows]);

  // 已收齊的列預設收起來；但只要裡面有勾選的就強制攤開，
  // 免得「要送出的東西畫面上看不到」。
  const finishedHasSelected = useMemo(
    () => finished.some((r) => entries[r.po_item_id]),
    [finished, entries],
  );
  const doneVisible = showDone || finishedHasSelected;

  const summary = useMemo(() => {
    let qty = 0;
    let invalid = 0;
    let empty = 0;
    let zero = 0;
    let reasonMissing = 0;
    const badCost: Row[] = [];
    const poIds = new Set<number>();
    for (const r of selectedRows) {
      const c = checkRow(r, entries[r.po_item_id]);
      poIds.add(r.po_id);
      if (c.invalid) invalid += 1;
      if (c.empty) empty += 1;
      if (c.zero) zero += 1;
      if (c.reasonMissing) reasonMissing += 1;
      if (c.received > 0 && c.badCost) badCost.push(r);
      qty += c.received;
    }
    return {
      lines: selectedRows.length,
      qty,
      invalid,
      empty,
      zero,
      reasonMissing,
      badCost,
      poCount: poIds.size,
    };
  }, [selectedRows, entries]);

  // 擋下的規則與文案在 @/lib/receivingBatch 的 blockReasonFor()（驗得到）。
  const blockReason = useMemo(
    () =>
      blockReasonFor({
        lines: summary.lines,
        invalid: summary.invalid,
        empty: summary.empty,
        zero: summary.zero,
        badCost: summary.badCost.length,
        reasonMissing: summary.reasonMissing,
      }),
    [summary],
  );

  // ------------------------------------------------------------ 勾選

  function toggleRow(row: Row) {
    setEntries((cur) => {
      if (cur[row.po_item_id]) {
        const next = { ...cur };
        delete next[row.po_item_id];
        return next;
      }
      // ⭐ 勾起來就直接把「應到」填進數量欄，而且是**看得見地填**。
      //   老闆要的是「勾一勾 → 一次全到＋確認」，所以填這件事必須發生在勾的當下，
      //   ⛔ 不可以藏在送出按鈕裡偷偷補 —— 那樣樓下永遠不知道自己送了什麼數字。
      //   已收齊的列（應到 0）留空，逼他自己填（那是超收，本來就該想一下）。
      return {
        ...cur,
        [row.po_item_id]: { qty: row.remaining > 0 ? fmtQty(row.remaining) : "", reason: "" },
      };
    });
  }

  function patchEntry(rowId: number, patch: Partial<Entry>) {
    setEntries((cur) => {
      // 直接在數量欄打字 = 也算勾選（不然打了字卻不會送出，最難發現的那種錯）
      const prev: Entry = cur[rowId] ?? { qty: "", reason: "" };
      return { ...cur, [rowId]: { ...prev, ...patch } };
    });
  }

  /** 全選 / 取消全選 —— **只作用在目前看得到的結果上**，不是整個資料庫。
   *  已收齊的列（應到 0）不納入全選：它們是超收情境，要人自己想一下才勾。 */
  const allPendingSelected = pending.length > 0 && pending.every((r) => entries[r.po_item_id]);
  function toggleSelectAll() {
    setEntries((cur) => {
      const next = { ...cur };
      if (allPendingSelected) {
        for (const r of pending) delete next[r.po_item_id];
      } else {
        for (const r of pending) {
          if (!next[r.po_item_id]) next[r.po_item_id] = { qty: fmtQty(r.remaining), reason: "" };
        }
      }
      return next;
    });
  }

  function clearSelection() {
    setEntries({});
    setShowSelectedOnly(false);
  }

  // ------------------------------------------------------------ 送出

  async function runSubmit() {
    if (blockReason) {
      setError(blockReason);
      return;
    }
    // ⚠️ 清單正在重撈（整頁或單張）時不准送：重撈會把那幾張單的 entries 與
    //   冪等鍵清掉，兩件事交錯會送出跟畫面對不上的內容。
    //   按鈕本來就會變灰，這裡是同一 tick 連點的第二道（見 busyRef 的說明）。
    const held = await runExclusive(busyRef, "submit", setBusy, async () => {
      await doSubmit();
    });
    if (held === "load") {
      setError("清單正在重新載入，等它跑完再按「確認收貨」。");
    }
  }

  async function doSubmit() {
    setError(null);
    setStaleWarning(null);

    try {
      const { data: userRes } = await getSupabase().auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      const items: BatchItem[] = selectedRows.map((r) => {
        const e = entries[r.po_item_id];
        const c = checkRow(r, e);
        return {
          po_item_id: r.po_item_id,
          po_id: r.po_id,
          sku_id: r.sku_id,
          unit_cost: r.unit_cost,
          qty_already: r.qty_already,
          qty: c.received,
          variance_reason: e?.reason.trim() ? e.reason.trim() : null,
        };
      });

      const batches = groupArrivalsByPo(items);
      const poMeta = new Map(rowsRef.current.map((r) => [r.po_id, r]));

      // ⭐ 逐張送出的規則（每張各自的冪等鍵、失敗保留鍵、一張失敗不中斷其餘）
      //   全部在 runBatchSubmit 裡，那裡有完整推導，而且可以離線驗證。
      //   ⛔ 不要把那段邏輯搬回這裡：它每一種錯法都是「安靜的」。
      const raw = await runBatchSubmit({
        batches,
        subs: subsRef.current,
        newId: newRequestId,
        toMessage: translateRpcError,
        callRpc: async (poId, arrivals, requestId) => {
          const { data, error: rpcErr } = await getSupabase().rpc("rpc_arrive_and_distribute", {
            p_po_id: poId,
            p_arrivals: arrivals,
            p_operator: operator,
            // 樓下不填發票號與備註
            p_invoice_no: null,
            p_notes: null,
            p_client_request_id: requestId,
          });
          if (rpcErr) throw rpcErr;
          return data as { gr_no?: string; duplicate?: boolean } | null;
        },
      });

      const results: PoOutcome[] = raw.map((o) => {
        const meta = poMeta.get(o.po_id);
        return {
          ...o,
          po_no: meta?.po_no ?? `#${o.po_id}`,
          supplier_name: meta?.supplier_name ?? "",
        };
      });
      const donedPoIds = raw.filter((o) => o.kind !== "error").map((o) => o.po_id);

      // 成功的那幾張：清掉使用者輸入（貨已經收了，留著只會被誤按第二次），
      // 並重撈它們的最新已收量。
      // ⚠️ 失敗的那幾張**刻意不動**：保留原樣才能「原內容再按一次」＝ 帶同一把鍵重試。
      if (donedPoIds.length > 0) {
        const done = new Set(donedPoIds);
        setEntries((cur) => {
          const next = { ...cur };
          for (const r of rowsRef.current) if (done.has(r.po_id)) delete next[r.po_item_id];
          return next;
        });
        try {
          await reloadPos(donedPoIds);
        } catch (e) {
          // 重撈失敗不卡死：這幾張的冪等鍵在送出成功時就清掉了（與舊版同一條規則），
          // 而畫面上的「之前已收」可能過期 —— 拿過期的 base 再送會被**樂觀鎖擋下**，
          // 失敗方式是吵的紅字，不是靜默壞帳。所以這裡只要講清楚就好。
          setStaleWarning(
            `剛剛收的單重新載入失敗（${translateRpcError(e)}）。` +
              `畫面上的「之前已收」可能不是最新的 —— 要再收同一張採購單之前，` +
              `請先按最上面搜尋框旁邊的 🔄 重新整理。`,
          );
        }
      }

      setOutcomes(results);
      setShowSelectedOnly(false);
      // 收完自動回到搜尋框，準備收下一樣
      // ⚠️ select() 而不是清空：同一批貨常常要連收好幾樣，字留著他可以直接接著看；
      //   要換關鍵字時直接打字就會整段取代掉。
      // ⚠️ 用 setTimeout 不用 requestAnimationFrame：rAF 在頁面不可見時**完全不會觸發**
      //   （實測 document.visibilityState === "hidden" 時 600ms 內一次都沒跑）。
      //   iPad 螢幕鎖住、或樓下切去別的 App 再切回來，焦點就永遠回不到搜尋框。
      //   延遲 0 只是為了排在這一次 render 之後。
      // ⓘ iOS 上「非使用者手勢中的 focus()」不見得會把鍵盤叫出來（送出是一串 await，
      //   手勢早就結束了）。游標一定會回到搜尋框，鍵盤則看系統臉色 —— 這是已知限制。
      setTimeout(() => {
        mainRef.current?.scrollTo({ top: 0 });
        searchRef.current?.focus();
        searchRef.current?.select();
      }, 0);
    } catch (e) {
      setError(translateRpcError(e));
    }
    // ⓘ 鎖的釋放在 runExclusive 的 finally，⛔ 不要在這裡再放一次。
  }

  /** 按下「確認收貨」。已勾但畫面上看不到的列 → 先攤開讓他看過再送。 */
  function onSubmitClick() {
    if (blockReason) {
      setError(blockReason);
      return;
    }
    if (hiddenSelected.length > 0) {
      setConfirmOpen(true);
      return;
    }
    void runSubmit();
  }

  // ------------------------------------------------------------ render

  // 分店帳號：明確擋下並給出口。⛔ 不可以白畫面、不可以無聲失敗。
  if (authLoading || branchBlocked) {
    return (
      <div className="fixed inset-x-0 top-0 z-40 flex h-[100dvh] flex-col items-center justify-center gap-5 bg-zinc-100 px-6 text-center dark:bg-zinc-950">
        {authLoading ? (
          <p className="text-lg text-zinc-500">載入中…</p>
        ) : (
          <>
            <div className="text-5xl">🔒</div>
            <div className="text-2xl font-bold">這個功能限總部使用</div>
            <p className="max-w-md text-base text-zinc-600 dark:text-zinc-400">
              收貨是把貨收進總倉，分店帳號不能用這一頁。
              分店的收貨請走「進貨入庫」。
            </p>
            <div className="flex flex-wrap justify-center gap-3">
              <Link href="/wms/inbound" className={`${BTN_PRIMARY} text-lg`}>
                去進貨入庫
              </Link>
              <Link href="/" className={`${BTN_GHOST} text-lg`}>
                回首頁
              </Link>
            </div>
          </>
        )}
      </div>
    );
  }

  return (
    // 蓋掉桌機側欄：不改全站 layout.tsx（會炸到所有頁面所有使用者），改用本頁自己全屏。
    // z-40 → Modal / 手機抽屜（都是 z-50）仍蓋得住這一頁。
    // 高度用 dvh 不用 vh：iPad 工具列收合時 vh 會比實際可視高度大，底部按鈕會被切掉。
    <div className="fixed inset-x-0 top-0 z-40 flex h-[100dvh] flex-col bg-zinc-100 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      {/* ⭐ 搜尋列放在 header（flex 容器的固定列，不參與捲動）—— 老闆原話：
          「搜尋框就不能固定最上面嗎 不管動作到那一頁就直接搜」。
          ⛔ 不要把它移進下面的 <main>，那裡會捲走。 */}
      <header className="shrink-0 border-b border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
        <div className="flex items-center gap-3">
          <div className="relative min-w-0 flex-1">
            {/* 字級 ≥16px：低於 16px 的輸入框一 focus，iOS 就把整頁放大 */}
            <input
              ref={searchRef}
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                // 打字就代表要看搜尋結果了，自動退出「只看已勾選」
                setShowSelectedOnly(false);
              }}
              // ⛔ 不用 type="search"：iOS 會自己加一個小小的原生 ✕，
              //    跟右邊那顆 44px 的清除鈕重疊，而原生那顆戴手套按不到。
              type="text"
              enterKeyHint="search"
              autoComplete="off"
              autoCorrect="off"
              spellCheck={false}
              placeholder="🔍 打商品名或廠商名"
              aria-label="搜尋商品或廠商"
              className="min-h-[56px] w-full rounded-xl border-2 border-zinc-300 bg-white px-4 pr-14 text-lg dark:border-zinc-600 dark:bg-zinc-950"
            />
            {search && (
              <button
                type="button"
                onClick={() => {
                  setSearch("");
                  searchRef.current?.focus();
                }}
                aria-label="清除搜尋"
                className="absolute right-1 top-1/2 min-h-[44px] min-w-[44px] -translate-y-1/2 touch-manipulation rounded-lg text-2xl text-zinc-400 active:bg-zinc-100 dark:active:bg-zinc-800"
              >
                ✕
              </button>
            )}
          </div>
          <SpinButton
            type="button"
            onClick={loadAll}
            // ⛔ 送出中或已經有一次重撈在跑時要變灰：runExclusive 會靜默擋掉，
            //   按了沒反應比按不下去更難懂。
            disabled={busy !== null}
            className={`${BTN_GHOST} shrink-0`}
            aria-label="重新整理"
          >
            {/* SpinButton 會自己在 promise 未完成時顯示 spinner，不必另外接 loading state */}
            🔄
          </SpinButton>
          {/* 出口：不然樓下會被困在這一頁出不去 */}
          <Link href="/wms/receiving" className={`${BTN_GHOST} shrink-0`}>
            離開
          </Link>
        </div>

        {/* 已勾選的狀態列。⛔ 一定要常駐：勾了什麼、有幾樣不在畫面上，
            都必須看得見（「送出的東西畫面上看不到」是本頁最危險的失敗方式）。 */}
        {summary.lines > 0 && (
          <div className="mt-2 flex flex-wrap items-center gap-2 text-base">
            <span className="font-bold">
              已勾 {summary.lines} 項 · {fmtQty(summary.qty)} 件
              {summary.poCount > 1 && (
                <span className="ml-1 font-normal text-zinc-600 dark:text-zinc-400">
                  （跨 {summary.poCount} 張採購單）
                </span>
              )}
            </span>
            {hiddenSelected.length > 0 && !showSelectedOnly && (
              <span className="rounded-lg bg-amber-100 px-2 py-1 text-sm font-bold text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                其中 {hiddenSelected.length} 項不在這次搜尋結果裡
              </span>
            )}
            <button
              type="button"
              onClick={() => setShowSelectedOnly((v) => !v)}
              className={`${BTN_SMALL} ${
                showSelectedOnly
                  ? "bg-blue-600 text-white active:bg-blue-700"
                  : "border border-zinc-300 bg-white text-zinc-800 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
              }`}
            >
              {showSelectedOnly ? "← 回搜尋結果" : "只看已勾選"}
            </button>
            <button
              type="button"
              onClick={clearSelection}
              className={`${BTN_SMALL} border border-zinc-300 bg-white text-zinc-800 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100`}
            >
              清除勾選
            </button>
          </div>
        )}
      </header>

      <main ref={mainRef} className="flex-1 overflow-y-auto overscroll-contain px-4 pb-6 pt-4">
        {/* ⚠️⚠️ 採購單清單可能被截斷 —— **絆線，正常情況下不會出現**。
            #798（20260820000200）之後，未收完的單全取、不再被截
            ⇒ 這條只在「RPC 被回退成舊版」時才會亮（判定與推導見
            @/lib/receivingBatch 的 normalizeWorkbenchPOs()）。
            ⛔ 這條**不給關**（沒有「知道了」按鈕）：關掉的那一刻就等於沒做。
            ⛔ 文案一律講「可能」—— 剛好 200 張不代表真的被截，但寧可多提醒不要漏。
            ⚠️ 放在 main 的最上面而不是 header：header 要留給搜尋框（這一頁的全部）。
              真正致命的那一刻是「搜不到」，所以下面 visible.length === 0 的空狀態
              **也印一次**，⛔ 兩處不可以只留一處。 */}
        {poListMaybeTruncated && (
          <div className="mb-4 rounded-xl border-2 border-amber-500 bg-amber-50 p-4 dark:border-amber-600 dark:bg-amber-950/50">
            <div className="text-lg font-bold text-amber-900 dark:text-amber-200">
              ⚠️ 採購單太多，比較舊的單可能沒有顯示
            </div>
            <p className="mt-1 text-base text-amber-900 dark:text-amber-200">
              系統一次最多只讀得到 {WORKBENCH_PO_LIMIT} 張採購單。
              <strong>搜不到你手上這批貨的話，不要當成沒有</strong>
              —— 請找辦公室用電腦查那張單。
            </p>
            {/* ⭐ 這條亮起來＝後端取單方式被換回舊版了，樓下自己修不了。
                所以這裡給的是「要轉達什麼給誰」，不是叫樓下想辦法。 */}
            <p className="mt-1 text-sm text-amber-800 dark:text-amber-300">
              這條提醒正常不會出現。看到它請告訴辦公室：
              「進貨待辦的取單方式被改回舊版了，要 20260820000200 那一版。」
            </p>
          </div>
        )}

        {error && (
          <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-base font-medium text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            ⚠ {error}
          </div>
        )}

        {/* ⭐ 逐張採購單的結果。⛔ 不可以只顯示一個「成功」或一個「失敗」：
            3 張成功 1 張被擋下時，樓下會以為全收了或全沒收，兩種誤會都會讓盤點對不起來。 */}
        {outcomes && outcomes.length > 0 && (
          <OutcomePanel
            outcomes={outcomes}
            busyPo={reloadingPo}
            // ⛔ 送出中、或別張單正在重撈時，這幾顆全部要變灰
            //   （不是只灰掉自己那一顆）—— 見 busyRef 的說明。
            locked={busy !== null}
            onDismiss={() => setOutcomes(null)}
            // ⭐ 2026-08-20 複審 P1：這條路徑以前**沒有取互斥鎖**，
            //   重撈跑到一半還按得下「確認收貨」。現在跟整頁重撈走同一把鎖。
            onReloadPo={async (poId) => {
              await runExclusive(busyRef, "load", setBusy, async () => {
                setReloadingPo(poId);
                setError(null);
                try {
                  await reloadPos([poId]);
                  setOutcomes((cur) => (cur ? cur.filter((o) => o.po_id !== poId) : cur));
                } catch (e) {
                  setError(translateRpcError(e));
                } finally {
                  setReloadingPo(null);
                }
              });
            }}
          />
        )}

        {staleWarning && (
          <div className="mb-4 rounded-xl border-2 border-amber-400 bg-amber-50 p-4 text-base font-medium text-amber-900 dark:border-amber-700 dark:bg-amber-950/50 dark:text-amber-200">
            ⚠ {staleWarning}
          </div>
        )}

        {truncated > 0 && (
          <div className="mb-4 rounded-xl border-2 border-rose-400 bg-rose-50 p-4 text-base font-bold text-rose-800 dark:border-rose-700 dark:bg-rose-950/50 dark:text-rose-200">
            ⛔ 待收品項太多，這次少載了 {truncated} 項（上限 {ITEM_PAGE_SIZE * ITEM_MAX_PAGES} 項）。
            <span className="font-normal">
              {" "}
              搜不到的東西不代表沒有這筆貨，請通知辦公室先把收完／不會再到的採購單結掉。
            </span>
          </div>
        )}

        {badData.length > 0 && (
          <div className="mb-4 rounded-xl border-2 border-rose-400 bg-rose-50 p-4 dark:border-rose-700 dark:bg-rose-950/50">
            <div className="text-lg font-bold text-rose-800 dark:text-rose-200">
              ⛔ 這 {badData.length} 項的數量資料異常，沒有列出來，這一頁收不了
            </div>
            <p className="mt-1 text-base text-rose-800 dark:text-rose-200">
              請通知辦公室檢查採購單。其他品項可以照收。
            </p>
            <ul className="mt-2 list-disc pl-5 text-base text-rose-800 dark:text-rose-200">
              {badData.slice(0, 5).map((t) => (
                <li key={t}>{t}</li>
              ))}
              {badData.length > 5 && <li>…等 {badData.length} 項</li>}
            </ul>
          </div>
        )}

        {missingSkuCount > 0 && (
          <div className="mb-4 rounded-xl border-2 border-amber-400 bg-amber-50 p-4 text-base font-medium text-amber-900 dark:border-amber-700 dark:bg-amber-950/50 dark:text-amber-200">
            ⚠ 有 {missingSkuCount} 項的商品資料沒載入（可能沒有圖片和品名），請通知辦公室。
          </div>
        )}

        {summary.badCost.length > 0 && (
          <div className="mb-4 rounded-xl border-2 border-rose-400 bg-rose-50 p-4 dark:border-rose-700 dark:bg-rose-950/50">
            <div className="text-lg font-bold text-rose-800 dark:text-rose-200">
              ⛔ 勾選的品項裡有 {summary.badCost.length} 項收不進去
            </div>
            <p className="mt-1 text-base text-rose-800 dark:text-rose-200">
              成本不正常，請通知辦公室修正採購單。
              <strong>取消勾選這幾項，就可以先收其他的。</strong>
            </p>
            <ul className="mt-2 list-disc pl-5 text-base text-rose-800 dark:text-rose-200">
              {summary.badCost.slice(0, 5).map((r) => (
                <li key={r.po_item_id}>
                  {rowTitle(r)}（{r.po_no}）
                </li>
              ))}
              {summary.badCost.length > 5 && <li>…等 {summary.badCost.length} 項</li>}
            </ul>
          </div>
        )}

        {rows === null ? (
          <p className="p-6 text-center text-base text-zinc-500">載入中…</p>
        ) : (
          <>
            <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
              <div className="text-base text-zinc-600 dark:text-zinc-400">
                {showSelectedOnly
                  ? `已勾選 ${visible.length} 項`
                  : tokens.length > 0
                    ? `找到 ${visible.length} 項`
                    : `待收 ${visible.length} 項`}
              </div>
              {pending.length > 0 && (
                <SpinButton type="button" onClick={toggleSelectAll} className={BTN_GHOST}>
                  {allPendingSelected ? "取消全選" : `全選這 ${pending.length} 項`}
                </SpinButton>
              )}
            </div>

            {/* ⛔ 沒畫完一定要講：不然「全選這 200 項」看起來像全選了 500 筆結果 */}
            {overflow > 0 && (
              <div className="mb-3 rounded-xl border-2 border-amber-400 bg-amber-50 p-3 text-base font-medium text-amber-900 dark:border-amber-700 dark:bg-amber-950/50 dark:text-amber-200">
                ⚠ 符合的有 {visible.length} 項，畫面上只列出前 {pending.length + finished.length} 項
                （還有 {overflow} 項沒列出來）。上面的「全選」只會勾到列出來的這些。
                <strong> 請打更完整的商品名或廠商名縮小範圍。</strong>
              </div>
            )}

            {visible.length === 0 && (
              <div className="p-6 text-center">
                <p className="text-base text-zinc-500">
                  {rows.length === 0
                    ? "目前沒有待收的貨"
                    : showSelectedOnly
                      ? "還沒勾選任何品項"
                      : `找不到「${search.trim()}」。可以試商品名、規格、商品編號或廠商名。`}
                </p>
                {/* ⭐⭐ 這裡是採購單清單被截斷時**真正致命的那一刻**：
                    「搜不到」會被當成「系統沒這批貨」，然後貨就這樣沒收。
                    ⛔ 所以上面那條警告之外，這裡一定要再講一次。
                    ⚠️ 但**一定要跟著 poListMaybeTruncated 一起關**：#798 之後未收完的
                      單全取，「搜不到」就真的等於沒有 —— 這時候還印這句，等於教樓下
                      不要相信搜尋結果，反而會把人推去做多餘的電話查詢。
                      ⇒ 這句的正確與否，完全綁在那條絆線上。 */}
                {poListMaybeTruncated && !showSelectedOnly && (
                  <p className="mx-auto mt-3 max-w-xl rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-base font-bold text-amber-900 dark:border-amber-600 dark:bg-amber-950/50 dark:text-amber-200">
                    ⚠️ 搜不到不代表沒有這批貨！採購單太多的時候，比較舊的單不會顯示在這一頁。
                    請找辦公室用電腦查。
                  </p>
                )}
              </div>
            )}

            <ul className="flex flex-col gap-4">
              {pending.map((r) => (
                <ItemCard
                  key={r.po_item_id}
                  row={r}
                  entry={entries[r.po_item_id]}
                  onToggle={() => toggleRow(r)}
                  onPatch={(p) => patchEntry(r.po_item_id, p)}
                />
              ))}
            </ul>

            {finished.length > 0 && (
              <>
                <SpinButton
                  type="button"
                  onClick={() => setShowDone((v) => !v)}
                  disabled={finishedHasSelected}
                  className={`${BTN_GHOST} mt-4`}
                >
                  {doneVisible ? "▲ 收起已收齊的" : `▼ 顯示已收齊的 ${finished.length} 項`}
                </SpinButton>
                {/* ⛔ 停用原因要看得見，不可以只放 title：iPad 上沒有 tooltip */}
                {finishedHasSelected && (
                  <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
                    下面「已收齊」的品項裡有勾選的，先攤開著不收起來，免得要送出的東西畫面上看不到。
                  </p>
                )}
                {doneVisible && (
                  <ul className="mt-4 flex flex-col gap-4">
                    {finished.map((r) => (
                      <ItemCard
                        key={r.po_item_id}
                        row={r}
                        entry={entries[r.po_item_id]}
                        onToggle={() => toggleRow(r)}
                        onPatch={(p) => patchEntry(r.po_item_id, p)}
                      />
                    ))}
                  </ul>
                )}
              </>
            )}
          </>
        )}
      </main>

      <footer className="shrink-0 border-t border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0 text-base">
            <div className="font-semibold">
              已勾 {summary.lines} 項 · {fmtQty(summary.qty)} 件
            </div>
            <div className="truncate text-sm text-zinc-600 dark:text-zinc-400">
              {summary.poCount > 1
                ? `會分成 ${summary.poCount} 張採購單各送一次，成敗會一張一張顯示`
                : "勾好按右邊確認就入庫"}
            </div>
          </div>
          <SpinButton
            type="button"
            onClick={onSubmitClick}
            // ⭐ 2026-08-20 複審 P1：busy 涵蓋「整頁重撈」與「單張重撈」，
            //   ⛔ 不可以退回成只看 submitting —— 那就是重撈與送出交錯的那條路。
            disabled={!!blockReason || busy !== null}
            className={`${BTN_BASE} min-w-[170px] bg-emerald-600 text-lg text-white active:bg-emerald-700 disabled:bg-zinc-300 dark:disabled:bg-zinc-700`}
          >
            {submitting
              ? "送出中…"
              : busy === "load"
                ? "重新載入中…"
                : `✅ 確認收貨${summary.lines > 0 ? ` (${summary.lines})` : ""}`}
          </SpinButton>
        </div>
        {/* ⛔ 停用原因一定要看得見，不可以只放 title：iPad 上沒有 tooltip */}
        {blockReason ? (
          <p className="mt-2 text-sm font-medium text-rose-600 dark:text-rose-400">{blockReason}</p>
        ) : busy === "load" ? (
          <p className="mt-2 text-sm font-medium text-amber-700 dark:text-amber-300">
            清單正在重新載入，等它跑完才能送出（免得送出的內容跟畫面上看到的對不起來）。
          </p>
        ) : null}
      </footer>

      {confirmOpen && (
        <ConfirmSheet
          rows={selectedRows}
          entries={entries}
          hiddenCount={hiddenSelected.length}
          onCancel={() => {
            setConfirmOpen(false);
            setShowSelectedOnly(true);
          }}
          onConfirm={async () => {
            setConfirmOpen(false);
            await runSubmit();
          }}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------- 逐張結果

function OutcomePanel({
  outcomes,
  busyPo,
  locked,
  onDismiss,
  onReloadPo,
}: {
  outcomes: PoOutcome[];
  /** 正在重撈的那一張（顯示「載入中…」用） */
  busyPo: number | null;
  /** 全頁有別的非同步流程在跑（送出／別張重撈）→ 這裡的按鈕全部要停用 */
  locked: boolean;
  onDismiss: () => void;
  onReloadPo: (poId: number) => Promise<void>;
}) {
  const ok = outcomes.filter((o) => o.kind !== "error").length;
  const bad = outcomes.length - ok;
  return (
    <div className="mb-4 rounded-2xl border-2 border-zinc-300 bg-white p-4 dark:border-zinc-700 dark:bg-zinc-900">
      <div className="flex items-start justify-between gap-3">
        <div className="text-lg font-bold">
          {bad === 0
            ? `✅ ${ok} 張採購單都收好了`
            : ok === 0
              ? `⛔ ${bad} 張都沒收成功`
              : `⚠️ ${ok} 張成功、${bad} 張沒成功`}
        </div>
        <SpinButton type="button" onClick={onDismiss} className={BTN_SMALL}>
          知道了
        </SpinButton>
      </div>

      {/* ⛔ 上面那一行**永遠只是摘要**，下面這份逐張清單才是重點，不可以省略。 */}
      <ul className="mt-3 flex flex-col gap-3">
        {outcomes.map((o) => (
          <li
            key={o.po_id}
            className={`rounded-xl border-2 p-3 ${
              o.kind === "error"
                ? "border-rose-400 bg-rose-50 dark:border-rose-700 dark:bg-rose-950/40"
                : o.kind === "duplicate"
                  ? "border-sky-300 bg-sky-50 dark:border-sky-800 dark:bg-sky-950/40"
                  : "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950/30"
            }`}
          >
            <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <span className="text-xl">
                {o.kind === "error" ? "⛔" : o.kind === "duplicate" ? "☑️" : "✅"}
              </span>
              <span className="font-mono text-lg font-bold">{o.po_no}</span>
              <span className="text-sm text-zinc-600 dark:text-zinc-400">{o.supplier_name}</span>
            </div>

            {o.kind === "ok" && (
              <div className="mt-1 text-base">
                收了 {o.lines} 項 · {fmtQty(o.qty)} 件
                {o.gr_no && (
                  <span className="ml-2 font-mono text-sm text-zinc-600 dark:text-zinc-400">
                    進貨單 {o.gr_no}
                  </span>
                )}
              </div>
            )}

            {/* ⛔ duplicate 時不可以顯示這次填的件數：後端回的是先前那張進貨單，
                數字不見得一樣，講出來會讓人以為又收了一批。 */}
            {o.kind === "duplicate" && (
              <div className="mt-1 text-base">
                這張先前就收過了，系統沒有再收一次（庫存不會多算）。
                {o.gr_no && (
                  <span className="ml-1 font-mono text-sm text-zinc-600 dark:text-zinc-400">
                    進貨單 {o.gr_no}
                  </span>
                )}
              </div>
            )}

            {o.kind === "error" && (
              <>
                <div className="mt-1 text-base font-medium text-rose-800 dark:text-rose-200">
                  沒收進去（這張的 {o.lines} 項 · {fmtQty(o.qty)} 件都沒入庫）：{o.message}
                </div>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <SpinButton
                    type="button"
                    disabled={locked}
                    onClick={() => onReloadPo(o.po_id)}
                    className={`${BTN_SMALL} bg-amber-600 text-white active:bg-amber-700`}
                  >
                    {busyPo === o.po_id ? "載入中…" : "🔄 重新載入這張單"}
                  </SpinButton>
                  <span className="text-sm text-zinc-600 dark:text-zinc-400">
                    {/* ⛔ 停用原因要看得見，不可以只放 title：iPad 上沒有 tooltip */}
                    {locked && busyPo !== o.po_id
                      ? "現在有別的動作在跑，等它跑完再按這裡。"
                      : "重新載入會把這張單的勾選清掉、重讀一次「之前已收」，再照最新的數字重收。"}
                  </span>
                </div>
              </>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

// ---------------------------------------------------------------- 送出前確認

/**
 * 已勾但不在目前搜尋結果裡的列 → 送出前攤開來讓他看過。
 *
 * 為什麼需要：勾選是**跨搜尋保留**的（打「馬卡龍」勾兩樣、再打「布丁」勾三樣，
 * 最後一次送出 —— 這正是一天要收一百樣時最省事的用法）。
 * 代價是「畫面上看不到的東西也會被送出去」，所以送出前一定要有一次確認。
 * ⚠️ 只在**真的有看不到的列**時才擋一下：單純搜一次、勾一勾、送出的常見情境
 *    不應該多一次點擊（老闆原話：樓下是戰區，時間就是金錢）。
 */
function ConfirmSheet({
  rows,
  entries,
  hiddenCount,
  onCancel,
  onConfirm,
}: {
  rows: Row[];
  entries: Record<number, Entry>;
  hiddenCount: number;
  onCancel: () => void;
  onConfirm: () => Promise<void>;
}) {
  const groups = useMemo(() => {
    const map = new Map<number, { po_no: string; supplier_name: string; rows: Row[] }>();
    for (const r of rows) {
      const g = map.get(r.po_id);
      if (g) g.rows.push(r);
      else map.set(r.po_id, { po_no: r.po_no, supplier_name: r.supplier_name, rows: [r] });
    }
    return Array.from(map.values());
  }, [rows]);

  return (
    // z-50：蓋得住本頁自己的 z-40 全屏層（機制索引四之八的慣例）
    <div className="fixed inset-0 z-50 flex flex-col bg-black/50 p-4">
      <div className="mx-auto flex max-h-full w-full max-w-2xl flex-col overflow-hidden rounded-2xl bg-white dark:bg-zinc-900">
        <div className="shrink-0 border-b border-zinc-300 p-4 dark:border-zinc-700">
          <div className="text-xl font-bold">確認要收這些嗎？</div>
          <p className="mt-1 text-base text-amber-800 dark:text-amber-300">
            有 {hiddenCount} 項是之前搜尋時勾的，現在畫面上看不到 —— 一起列在下面。
          </p>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto p-4">
          {groups.map((g) => (
            <div key={g.po_no} className="mb-4">
              <div className="text-base font-bold">
                <span className="font-mono">{g.po_no}</span>
                <span className="ml-2 font-normal text-zinc-600 dark:text-zinc-400">
                  {g.supplier_name}
                </span>
              </div>
              <ul className="mt-1 flex flex-col gap-1">
                {g.rows.map((r) => (
                  <li key={r.po_item_id} className="flex items-baseline justify-between gap-3 text-base">
                    <span className="min-w-0 flex-1 truncate">{rowTitle(r)}</span>
                    <span className="shrink-0 font-mono font-bold">
                      {entries[r.po_item_id]?.qty || "0"} 件
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="flex shrink-0 flex-wrap justify-end gap-3 border-t border-zinc-300 p-4 dark:border-zinc-700">
          <SpinButton type="button" onClick={onCancel} className={BTN_GHOST}>
            先看一下
          </SpinButton>
          <SpinButton
            type="button"
            onClick={onConfirm}
            className={`${BTN_BASE} bg-emerald-600 text-lg text-white active:bg-emerald-700`}
          >
            ✅ 全部收貨
          </SpinButton>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- 品項卡

function ItemCard({
  row,
  entry,
  onToggle,
  onPatch,
}: {
  row: Row;
  entry: Entry | undefined;
  onToggle: () => void;
  onPatch: (patch: Partial<Entry>) => void;
}) {
  const check = checkRow(row, entry);
  const exact =
    check.selected && check.received > 0 && !check.invalid && !check.isOver && !check.isShort;
  const cardCls =
    check.badCost || check.invalid || check.reasonMissing || check.empty || check.zero
      ? "border-rose-400 bg-rose-50 dark:border-rose-700 dark:bg-rose-950/40"
      : exact
        ? "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950/30"
        : check.selected
          ? "border-blue-400 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/30"
          : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900";

  // ⛔ 非法輸入時不做加減：那等於把打錯的字悄悄換成一個數字。
  function step(delta: number) {
    if (check.invalid) return;
    onPatch({ qty: fmtQty(Math.max(0, check.received + delta)) });
  }

  return (
    <li className={`rounded-2xl border-2 p-4 ${cardCls}`}>
      <div className="flex items-start gap-3">
        {/* 核取方塊做成大方塊，⚠️ 不是 12px 的原生小方框：戴手套的手指按不到。
            整塊（含圖與品名）都可點，勾錯的成本比按不到低。 */}
        <button
          type="button"
          onClick={onToggle}
          role="checkbox"
          aria-checked={check.selected}
          aria-label={`選取 ${rowTitle(row)}`}
          className={`flex min-h-[56px] min-w-[56px] shrink-0 touch-manipulation items-center justify-center rounded-xl border-2 text-3xl ${
            check.selected
              ? "border-blue-600 bg-blue-600 text-white"
              : "border-zinc-400 bg-white text-transparent dark:bg-zinc-800"
          }`}
        >
          ✓
        </button>

        {row.image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={row.image_url}
            alt={rowTitle(row)}
            loading="lazy"
            onClick={onToggle}
            className="h-24 w-24 shrink-0 touch-manipulation rounded-xl border border-zinc-200 object-cover dark:border-zinc-800"
          />
        ) : (
          // 無圖佔位：尺寸與有圖時一致，卡片不會破版
          <div
            onClick={onToggle}
            className="flex h-24 w-24 shrink-0 touch-manipulation items-center justify-center rounded-xl border border-zinc-200 bg-zinc-50 text-zinc-300 dark:border-zinc-800 dark:bg-zinc-950"
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5} className="h-10 w-10">
              <path strokeLinecap="round" strokeLinejoin="round" d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M9 8V6.5a3 3 0 0 1 6 0V8" />
            </svg>
          </div>
        )}

        <div className="min-w-0 flex-1" onClick={onToggle}>
          <div className="text-xl font-bold leading-snug">{rowTitle(row)}</div>
          <div className="mt-1 text-lg">
            應到 <span className="font-mono text-3xl font-bold">{fmtQty(row.remaining)}</span> 件
            {row.qty_already > 0 && (
              <span className="ml-2 text-sm text-zinc-600 dark:text-zinc-400">
                （訂 {fmtQty(row.qty_ordered)} · 之前已收 {fmtQty(row.qty_already)}）
              </span>
            )}
          </div>
          {/* ⭐ 廠商與單號降成小字備註 —— 它們不再是「要先選的東西」。
              但**不可以拿掉**：一列 = 商品 × 採購單，同一個商品會出現好幾列，
              沒有單號就分不出自己在收哪一張。 */}
          <div className="mt-1 truncate text-sm text-zinc-500">
            {row.supplier_name} · <span className="font-mono">{row.po_no}</span>
            {row.sent_at && (
              <span className="ml-2">{new Date(row.sent_at).toLocaleDateString("zh-TW")} 送單</span>
            )}
            {row.sku_code && <span className="ml-2 font-mono">{row.sku_code}</span>}
          </div>
        </div>
      </div>

      {/* 數量列只在勾選之後出現：沒勾的列保持乾淨，一頁塞得下更多樣東西。 */}
      {check.selected && (
        <div className="mt-4 flex flex-wrap items-center gap-2">
          <SpinButton
            type="button"
            onClick={() => step(-1)}
            disabled={check.invalid || check.received <= 0}
            className={`${BTN_GHOST} text-2xl`}
            aria-label="減一"
          >
            −
          </SpinButton>
          {/* text-2xl 遠大於 16px：低於 16px 的輸入框一 focus，iOS 會把整頁放大。
              ⛔ onChange 不做任何清洗，原字照存 —— 打錯就要看得到自己打錯了。 */}
          <input
            inputMode="decimal"
            value={entry?.qty ?? ""}
            onChange={(e) => onPatch({ qty: e.target.value })}
            placeholder="0"
            aria-label="實到數量"
            aria-invalid={check.invalid}
            className={`min-h-[56px] w-28 rounded-xl border-2 bg-white px-3 text-center font-mono text-2xl font-bold dark:bg-zinc-800 ${
              check.invalid || check.empty || check.zero
                ? "border-rose-500 text-rose-700 dark:border-rose-600 dark:text-rose-300"
                : "border-zinc-300 dark:border-zinc-600"
            }`}
          />
          <SpinButton
            type="button"
            onClick={() => step(1)}
            disabled={check.invalid}
            className={`${BTN_GHOST} text-2xl`}
            aria-label="加一"
          >
            ＋
          </SpinButton>
          <SpinButton
            type="button"
            onClick={() => onPatch({ qty: fmtQty(row.remaining) })}
            className={`${exact ? `${BTN_BASE} bg-emerald-600 text-white active:bg-emerald-700` : BTN_PRIMARY} ml-auto min-w-[110px] text-lg`}
          >
            {exact ? "✓ 全到" : "全到"}
          </SpinButton>
        </div>
      )}

      {/* ⛔ 提示要看得見，不可以只放 title：iPad 上沒有 tooltip */}
      {check.empty && (
        <p className="mt-2 text-base font-bold text-rose-700 dark:text-rose-300">
          ⚠ 勾了但還沒填數量。按「全到」，或用 ＋／− 填一個數字；不收的話請取消勾選。
        </p>
      )}

      {check.invalid && (
        <p className="mt-2 text-base font-bold text-rose-700 dark:text-rose-300">
          ⚠ 「{entry?.qty}」不是有效數字，請只填數字（例：12）。
        </p>
      )}

      {/* ⭐ 2026-08-20 複審 P1：填 0 以前前端不擋，會送到後端才炸，
          而且是**整張採購單一起失敗**（同批其他正常品項被連坐），
          訊息還是未中文化的 `arrival sku_id X has invalid qty_received`。
          ⛔ 樓下看不懂、也不知道是哪一項害的 ⇒ 在這裡就講清楚怎麼辦。 */}
      {check.zero && (
        <p className="mt-2 text-base font-bold text-rose-700 dark:text-rose-300">
          ⚠ 填 0 等於什麼都沒收，這樣送不出去。這一項如果不收，請按左邊的大方塊
          <strong>取消勾選</strong>；有收到就把件數填上去。
        </p>
      )}

      {/* 卡片一律標紅（不等勾選才講）：讓樓下在點貨前就知道這項收不進去。 */}
      {check.badCost && (
        <p className="mt-2 text-base font-bold text-rose-700 dark:text-rose-300">
          ⛔ 這一項的成本不正常，收不進去，請通知辦公室。其他品項可以照收。
        </p>
      )}

      {check.requiresReason && (
        <div className="mt-4 rounded-xl border-2 border-amber-400 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950/50">
          <div className="text-base font-bold text-amber-900 dark:text-amber-200">
            {check.isOver
              ? `⚠ 比應到多了 ${fmtQty(check.received - row.remaining)} 件 —— 選一個原因`
              : `⚠ 比應到少了 ${fmtQty(row.remaining - check.received)} 件 —— 選一個原因`}
          </div>
          <div className="mt-2 flex flex-wrap gap-2">
            {REASON_PRESETS.map((r) => {
              const on = (entry?.reason ?? "").trim() === r;
              return (
                <SpinButton
                  key={r}
                  type="button"
                  onClick={() => onPatch({ reason: on ? "" : r })}
                  className={
                    on
                      ? `${BTN_BASE} bg-amber-600 text-white active:bg-amber-700`
                      : `${BTN_BASE} border-2 border-amber-400 bg-white text-amber-900 active:bg-amber-100 dark:bg-zinc-900 dark:text-amber-200`
                  }
                >
                  {r}
                </SpinButton>
              );
            })}
          </div>
          <input
            value={entry?.reason ?? ""}
            onChange={(e) => onPatch({ reason: e.target.value })}
            placeholder="或自己打（例：司機說明天補）"
            aria-label="差異原因"
            className="mt-2 min-h-[56px] w-full rounded-xl border border-amber-400 bg-white px-3 text-base dark:border-amber-700 dark:bg-zinc-900"
          />
        </div>
      )}
    </li>
  );
}
