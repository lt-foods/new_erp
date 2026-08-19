"use client";

// 📦 樓下收貨（iPad 專用頁）
//
// 為什麼要有這一頁：收貨現在只能辦公室用電腦按，樓下拿 iPad 做不了
//   —— 桌機側欄吃掉寬度、9 欄表格要左右拉、按鈕比手指小。
//   這一頁讓樓下倉管站在貨旁邊就能收完。
//
// ⛔ 這一頁是「新增」，現有 /wms/receiving 與 /purchase/orders/receive 一行不改。
//    辦公室維持用電腦開既有收貨頁處理單價／批號／效期／發票號／分店分配。
//
// 設計約束（都有出處，改之前先看）：
//   1. 走 rpc_arrive_and_distribute（最新版 20260512000002_arrive_no_auto_wave.sql:20）。
//      ⛔ 不可以改用 rpc_adjust_po_item_received —— 那支是「絕對值覆蓋」語意
//      （20260729000020_po_adjust_received_creates_gr.sql:9-14 檔頭寫明），
//      樓下多台 iPad 同時收同一張單會互相蓋掉（A 填 5、B 填 3 → 結果是 3 不是 8）。
//      arrive 是累加語意（每次收貨建一張 GR），符合分批到貨的現實，也才有 variance_reason。
//   2. 樓下畫面不出現：單價 / 批號 / 效期 / 瑕疵數 / 供應商發票號 / 備註 / 分店分配。
//      unit_cost 仍照 purchase_order_items.unit_cost 原值帶給 RPC（不可送 0 或 null，
//      成本會影響加權平均成本）；分店分配一律留給派貨工作台。
//   3. 觸控：所有可點元素 min-h-[44px] min-w-[44px] + touch-manipulation
//      （機制索引七之五；touch-manipulation 消掉 iOS ~350ms 的 double-tap 等待）。
//      輸入框 ≥16px，否則 iOS 一 focus 就把整頁放大。
//   4. ⛔ 重要資訊不可以只放在 title tooltip —— iPad 上根本沒有 tooltip
//      （picking/drafts/edit/page.tsx:859 有同樣的教訓註解）。
//   5. 側欄：不改全站 layout.tsx（會炸到所有頁面所有使用者），改用本頁自己
//      fixed 全屏蓋掉。用 z-40：Modal 與 layout 手機抽屜都是 z-50，不會被遮住。
//   6. 權限：這一頁多開了一個入口，所以**不可以比舊入口寬**。舊入口
//      /wms/receiving 在 layout 的 BRANCH_HIDDEN_HREFS 裡對分店帳號隱藏，
//      本頁照同一條判定（isBranchAccount）擋掉分店帳號並給返回出口。
//      ⚠ 刻意**不**再加 role.ts 的 isHqRole()：它的 HQ_ROLES 不含 assistant，
//        舊入口不擋 assistant，加了會比舊入口窄、可能把樓下倉管整個鎖在外面。
//      ⚠ 真正的守衛應該在 RPC（GRANT ... TO authenticated 是既有的洞，
//        現行兩頁一樣沒有頁面層守衛）—— 那是獨立議題，不在這一片處理。
//   7. 數量與成本：非法輸入一律明講並擋住，⛔ 不做任何靜默轉換或猜值
//      （見 parseQty / costOk 的註解）。
//   8. 防「同一批貨算兩次」有**三道，缺一不可**（前兩道在 20260820000000 那支
//      migration，第三道在 @/lib/receivingSubmission）：
//      · 冪等鍵 p_client_request_id —— 防「網路斷掉、其實成功了、樓下再按一次」
//        （見 submissionRef 的生命週期註解）
//      · 樂觀鎖 qty_received_base —— 防「兩台 iPad 各拿過期數字按全到」
//        （見 submit() 組 arrivals 的地方）
//      · decideSubmission() —— 防「送出失敗後就地改內容再送」。
//        ⚠️ 這道是 2026-08-20 複審補的，因為前兩道**都只看得到這次送進來的品項**：
//        第二次若把第一次已收的品項清成 0，那些品項不在 payload 裡，
//        兩道後端防線都不會檢查它 → 靜默重複入庫（見該模組檔頭的完整推導）。
//      ⛔ 不要以為其中一個能取代另一個：冪等鍵只認得同一次送出（兩台是兩個
//        不同的值），樂觀鎖擋得住但吐的是紅字（樓下會以為失敗而再按），
//        而兩者都對「這次沒送進來的品項」視而不見。
//      ⛔ 也不要把它們改成「加一把鎖就好」：RPC 第一步的 FOR UPDATE 本來就
//        讓同一張單排隊了，排隊不會讓第二台手上的數字變新。

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import {
  decideSubmission,
  SUBMISSION_BLOCKED_MESSAGE,
  type Submission,
} from "@/lib/receivingSubmission";
import { publicProductUrl } from "@/lib/campaignCover";
import { useAuth } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

// ---------------------------------------------------------------- types

type WorkbenchPO = {
  id: number;
  po_no: string;
  status: string;
  sent_at: string | null;
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  total_qty_ordered: number;
  total_qty_received: number;
  line_count: number;
  product_names: string[];
};

type SupplierGroup = {
  supplier_id: number;
  supplier_name: string;
  supplier_code: string | null;
  pos: WorkbenchPO[];
  remaining: number;
};

type ItemForm = {
  po_item_id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  image_url: string | null;
  qty_ordered: number;
  qty_already: number;
  remaining: number;
  /** 採購單原本的成本。樓下看不到、不能改，但一定要原值帶給 RPC。 */
  unit_cost: number;
  /** 實到；字串是為了讓輸入框可以是空的（空 = 這項還沒核對，不會送出） */
  qty: string;
  variance_reason: string;
};

type Step = "supplier" | "po" | "items" | "done";

// 數量不符時的常用原因（一鍵填進既有 variance_reason 欄位，不新增資料表）
const REASON_PRESETS = ["缺貨", "破損", "送錯", "多送"] as const;

// ---------------------------------------------------------------- helpers

/** images[0] 可能是字串或 { url }（比照 campaigns/quick-control/page.tsx:207-212） */
function productImageUrl(images: unknown): string | null {
  if (!Array.isArray(images) || images.length === 0) return null;
  const first = images[0] as unknown;
  const path = typeof first === "string" ? first : (first as { url?: string | null })?.url ?? null;
  return publicProductUrl(path);
}

// 採購數量是 numeric(18,3)，所以允許小數，但只允許「數字[.數字]」這一種寫法。
const QTY_RE = /^\d+\.?\d*$/;

/**
 * 實到數量：**驗證**，不是清洗。
 *
 * ⛔ 這裡曾經是 `replace(/[^\d.]/g, "")` 的清洗式寫法，那是錯的：
 *    "-5" 會被洗成 "5"、"1e3" 會被洗成 "13" —— 把非法輸入靜默換成
 *    「另一個合法但錯誤的數字」，樓下完全看不出自己打的 -5 變成了 5。
 * ⛔ 也不能指望 RPC 兜底：`20260512000002_arrive_no_auto_wave.sql` 只擋
 *    `qty_received IS NULL OR <= 0`，它收到的 5 是合法的 5，擋不了。
 * → 非法輸入一律回 invalid，由畫面明講並擋住送出。
 */
function parseQty(raw: string): { qty: number; invalid: boolean } {
  const t = raw.trim();
  if (t === "") return { qty: 0, invalid: false }; // 空 = 這項還沒核對，不送出
  if (!QTY_RE.test(t)) return { qty: 0, invalid: true };
  const n = Number(t);
  if (!Number.isFinite(n) || n < 0) return { qty: 0, invalid: true };
  return { qty: n, invalid: false };
}

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
 * ⚠ 擋的範圍：**只擋「這次真的要收」（qty > 0）的那幾項**，不是整張單。
 *   兩種擋法對帳的保護完全等價（成本異常的品項兩者都收不進去），
 *   差別只在猜錯時的代價：擋整張單會讓樓下站在貨旁邊什麼都收不了，
 *   只擋該項則其他品項照收。安全性相同時取卡死範圍小的那個。
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

/** 商品名一律帶 variant_name：product_name 常常是上層品名，只印它現場會抓錯貨 */
function itemTitle(it: ItemForm): string {
  const main = it.product_name?.trim() || it.sku_code || `#${it.sku_id}`;
  const sub = it.variant_name?.trim();
  return sub ? `${main} / ${sub}` : main;
}

// 觸控目標統一寫法（機制索引七之五：用 min-h 撐高、不要加 py）
const BTN_BASE =
  "inline-flex items-center justify-center gap-1 rounded-xl font-semibold touch-manipulation " +
  "min-h-[56px] min-w-[56px] px-4 text-base disabled:cursor-not-allowed disabled:opacity-40";
const BTN_PRIMARY = `${BTN_BASE} bg-blue-600 text-white active:bg-blue-700`;
const BTN_GHOST = `${BTN_BASE} border border-zinc-300 bg-white text-zinc-800 active:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:active:bg-zinc-800`;

// ---------------------------------------------------------------- page

export default function IpadReceivingPage() {
  const { user, loading: authLoading } = useAuth();
  const branchBlocked = !authLoading && isBranchAccount(user);

  const [step, setStep] = useState<Step>("supplier");
  const [rows, setRows] = useState<WorkbenchPO[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");

  const [supplier, setSupplier] = useState<SupplierGroup | null>(null);
  const [po, setPO] = useState<WorkbenchPO | null>(null);
  const [items, setItems] = useState<ItemForm[] | null>(null);
  const [loadingItems, setLoadingItems] = useState(false);
  const [missingSkuCount, setMissingSkuCount] = useState(0); // 商品資料沒撈回來的品項數
  const [showDone, setShowDone] = useState(false); // 是否顯示「已收齊」的品項
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<
    { gr_no: string; po_no: string; qty: number; lines: number; duplicate: boolean } | null
  >(null);

  // 同步防重入鎖：React state 是非同步的，擋不住同一 tick 連點
  // （比照 purchase/orders/receive/page.tsx:104）
  const submitLock = useRef(false);

  // 這一次送出的冪等鍵 ＋ 當時送出的內容。生命週期是整個修法的重點，
  // ⛔ 改之前先讀完這五條（判斷邏輯本身在 @/lib/receivingSubmission，那裡有完整推導）：
  //   1. **送出時才產**（不是開單時）：沒送出過就沒有東西要防重。
  //   2. **失敗不換**：重試要帶同一個值，後端才認得出「這是同一次送出」。
  //      ⭐ 只有「交易真的 commit 了」那個值才會被後端記住 —— 沒寫進去的失敗
  //      （成本擋、找不到品項…）重試會被當成全新的一次，正確。
  //   3. **內容改了就整個擋下來**（2026-08-20 複審 P0 改法；前一版是「換新鍵」，
  //      那是錯的 —— 換新鍵之後，第二次沒送進來的品項不會被任何防線檢查）。
  //      id 與 payload 綁在同一個 ref 裡，**一起存、一起清**，避免只換一半。
  //   4. **成功就清掉**：下一次送出是全新的一次。
  //   5. **openPO() 重撈成功時才清**（⭐ 這條是刻意的，順序也是刻意的）：
  //      能沿用同一個值的情境只有「人還站在核對畫面上、看著紅字再按一次」。
  //      一旦重新載入這張單、拿到最新的 qty_received，舊的值就該丟 —— 否則
  //      若上一次其實成功了、而樓下這回是要收**今天到的第二批**，
  //      會被誤判成重試而**靜默不收**（比重複收更難發現）。
  //      ⚠️ 但一定要**等重撈成功之後**才清：重撈失敗時畫面上還是舊資料，
  //         這時把 ref 與 mustReopen 清掉，等於讓人拿著過期的 base 重新送一次。
  //   ⓘ 萬一將來有人漏了第 5 條，後端還有一道：同一個值用到別張採購單會直接報錯
  //      （不是靜默放行），失敗方式是吵的、不是安靜的。
  const submissionRef = useRef<Submission | null>(null);

  // 送出失敗、而且使用者把內容改掉了 → 這張單只剩「重新載入」一條安全的路。
  // ⚠️ 這是 state 不是 ref：它要讓底部把「確認收貨」換成「重新載入這張單」，
  //    必須觸發 render。真正擋住送出的是 submit() 裡的 decideSubmission()，
  //    這個旗標只負責把唯一安全的出口做成一顆按鈕（⛔ 不可以反過來只靠 UI 擋）。
  const [mustReopen, setMustReopen] = useState(false);

  const loadWorkbench = useCallback(async () => {
    const sb = getSupabase();
    const { data, error: e } = await sb.rpc("rpc_receiving_workbench");
    if (e) throw new Error(e.message);
    const list = ((data ?? []) as Array<Record<string, unknown>>)
      .map((r) => ({
        id: Number(r.id),
        po_no: String(r.po_no),
        status: String(r.status),
        sent_at: (r.sent_at as string | null) ?? null,
        supplier_id: Number(r.supplier_id),
        supplier_name: String(r.supplier_name),
        supplier_code: (r.supplier_code as string | null) ?? null,
        total_qty_ordered: Number(r.total_qty_ordered),
        total_qty_received: Number(r.total_qty_received),
        line_count: Number(r.line_count),
        product_names: Array.isArray(r.product_names)
          ? (r.product_names as unknown[]).map((n) => String(n))
          : [],
      }))
      // 只留還能收的單。rpc_arrive_and_distribute 本身也擋
      // （PO must be sent/partially_received），這裡先濾掉才不會讓樓下點了才吃錯誤。
      .filter((r) => r.status === "sent" || r.status === "partially_received");

    if (list.length === 0) return list;

    // 全部品項都已斷貨的 PO 不列出來 —— 點進去會是空的，樓下白跑一趟。
    //
    // ⚠ 方向刻意選「數斷貨的列」而不是「數還活著的列」：
    //   rpc_receiving_workbench 沒回斷貨資訊，只能另外查一次。斷貨列很少，
    //   遠低於 PostgREST 預設 1000 列上限；萬一真的被截斷，結果是**少算**
    //   斷貨數 → 少排除幾張單（多顯示），而不是把還有貨要收的單藏起來。
    //   反過來查「還活著的列」被截斷就會讓真的要收的單消失，那是更糟的 bug。
    // ⚠ 查詢失敗一律 fail-open（不排除任何單），不讓這個附屬功能擋住收貨。
    try {
      const { data: so, error: soErr } = await sb
        .from("purchase_order_items")
        .select("po_id")
        .in("po_id", list.map((r) => r.id))
        .not("stockout_at", "is", null);
      if (soErr) return list;
      const stockoutCount = new Map<number, number>();
      for (const row of (so as Array<{ po_id: number }> | null) ?? []) {
        const k = Number(row.po_id);
        stockoutCount.set(k, (stockoutCount.get(k) ?? 0) + 1);
      }
      // line_count 是該 PO 的**全部**品項數（RPC 的 poi CTE 沒有濾斷貨），
      // 所以「斷貨數 === line_count」就代表整張單沒有東西可收。
      return list.filter((r) => (stockoutCount.get(r.id) ?? 0) < r.line_count);
    } catch {
      return list;
    }
  }, []);

  useEffect(() => {
    // 身分還沒確定、或已判定是分店帳號 → 不要去撈資料
    if (authLoading || branchBlocked) return;
    let cancelled = false;
    (async () => {
      try {
        const list = await loadWorkbench();
        if (!cancelled) {
          setRows(list);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [loadWorkbench, authLoading, branchBlocked]);

  // 依廠商分組；搜尋同時比對廠商名 / 代碼 / 該廠商所有待收商品名
  const groups = useMemo<SupplierGroup[]>(() => {
    if (!rows) return [];
    const q = search.trim().toLowerCase();
    const map = new Map<number, SupplierGroup>();
    for (const r of rows) {
      let g = map.get(r.supplier_id);
      if (!g) {
        g = {
          supplier_id: r.supplier_id,
          supplier_name: r.supplier_name,
          supplier_code: r.supplier_code,
          pos: [],
          remaining: 0,
        };
        map.set(r.supplier_id, g);
      }
      g.pos.push(r);
      g.remaining += Math.max(0, r.total_qty_ordered - r.total_qty_received);
    }
    let list = Array.from(map.values());
    if (q) {
      list = list.filter((g) => {
        const haystack = [
          g.supplier_name,
          g.supplier_code ?? "",
          ...g.pos.map((p) => p.po_no),
          ...g.pos.flatMap((p) => p.product_names),
        ]
          .join(" ")
          .toLowerCase();
        return haystack.includes(q);
      });
    }
    return list.sort((a, b) => a.supplier_name.localeCompare(b.supplier_name, "zh-Hant"));
  }, [rows, search]);

  // 進到某張單：撈品項明細（已斷貨不列入，比照現有收貨頁 receive/page.tsx:197-199）
  const openPO = useCallback(async (target: WorkbenchPO) => {
    setLoadingItems(true);
    setError(null);
    // ⛔ 舊的冪等鍵與 mustReopen **不在這裡清**（2026-08-20 改）。
    //    要等下面真的重撈到最新的 qty_received、setItems 成功之後才清。
    //    原本清在這一行，配上新的「重新載入這張單」按鈕會開一個洞：
    //    重撈失敗時畫面上留著舊的 items（＝過期的 qty_already），
    //    ref 卻已經被清空、mustReopen 也被關掉 → 使用者可以拿過期的 base
    //    重新送一次，正好繞過本次要修的那條靜默重複入庫路徑。
    try {
      const sb = getSupabase();
      const { data: raw, error: e1 } = await sb
        .from("purchase_order_items")
        .select("id, sku_id, qty_ordered, qty_received, unit_cost, stockout_at")
        .eq("po_id", target.id)
        .order("id");
      if (e1) throw new Error(e1.message);

      type RawItem = {
        id: number;
        sku_id: number;
        qty_ordered: number;
        qty_received: number | null;
        unit_cost: number;
        stockout_at: string | null;
      };
      const live = ((raw as RawItem[] | null) ?? []).filter((r) => !r.stockout_at);

      type RawSku = {
        id: number;
        sku_code: string | null;
        product_name: string | null;
        variant_name: string | null;
        product: { images: unknown } | { images: unknown }[] | null;
      };
      const skuMap = new Map<number, { code: string | null; product: string | null; variant: string | null; img: string | null }>();
      const skuIds = Array.from(new Set(live.map((r) => r.sku_id)));
      if (skuIds.length > 0) {
        const { data: skus, error: e2 } = await sb
          .from("skus")
          .select("id, sku_code, product_name, variant_name, product:products(images)")
          .in("id", skuIds);
        if (e2) throw new Error(e2.message);
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

      const forms: ItemForm[] = live.map((r) => {
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
        if (!Number.isFinite(ordered) || !Number.isFinite(already)) {
          throw new Error(
            `採購單品項 #${r.id} 的數量資料異常（訂購 ${String(r.qty_ordered)}、已收 ${String(r.qty_received)}），` +
              `這張單先不要收，請通知辦公室檢查。`,
          );
        }
        return {
          po_item_id: r.id,
          sku_id: r.sku_id,
          sku_code: s?.code ?? null,
          product_name: s?.product ?? null,
          variant_name: s?.variant ?? null,
          image_url: s?.img ?? null,
          qty_ordered: ordered,
          qty_already: already,
          remaining: Math.max(0, ordered - already),
          unit_cost: Number(r.unit_cost),
          // ⛔ 預設留空，不預先填滿：這一頁的用途是「核對」，
          //    預填等於鼓勵不看貨就送出，錯的庫存比漏收難救。
          qty: "",
          variance_reason: "",
        };
      });

      // 商品資料沒撈回來 → 樓下靠圖片與品名辨貨，缺漏時不能無聲
      // （`.in("id", skuIds)` 吃 PostgREST 的列數上限，與現行收貨頁同風險）
      setMissingSkuCount(Math.max(0, skuIds.length - skuMap.size));
      setPO(target);
      setItems(forms);
      setShowDone(false);
      setStep("items");
      // ⭐ 到這裡才代表「畫面上的已收量是剛剛從資料庫讀回來的」，
      //    舊的冪等鍵與「必須重新載入」的旗標到這一刻才可以丟
      //    （理由見 submissionRef 宣告處第 5 條）。
      submissionRef.current = null;
      setMustReopen(false);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setLoadingItems(false);
    }
  }, []);

  function patchItem(idx: number, patch: Partial<ItemForm>) {
    setItems((cur) => {
      if (!cur) return cur;
      const next = [...cur];
      next[idx] = { ...next[idx], ...patch };
      return next;
    });
  }

  function fillAllArrived() {
    setItems((cur) => (cur ? cur.map((f) => (f.remaining > 0 ? { ...f, qty: String(f.remaining) } : f)) : cur));
  }

  function clearAll() {
    setItems((cur) => (cur ? cur.map((f) => ({ ...f, qty: "", variance_reason: "" })) : cur));
  }

  // 每一項的判定：實到 ≠ 應到（且實到 > 0）就要填原因
  // —— 與現有收貨頁 receive/page.tsx:321-324 同一條規則，
  //    不照做的話 RPC 送出前的前端校驗會不一致。
  const checks = useMemo(() => {
    if (!items) return null;
    return items.map((f) => {
      const { qty: received, invalid } = parseQty(f.qty);
      const isOver = received > f.remaining;
      const isShort = received > 0 && received < f.remaining;
      const requiresReason = received > 0 && (isOver || isShort);
      return {
        received,
        invalid,
        // 卡片層：只要成本不正常就標，讓樓下點貨前就知道
        // （擋送出的範圍另外算，只算 received > 0 的 —— 見 summary）
        badCost: !costOk(f.unit_cost),
        isOver,
        isShort,
        requiresReason,
        reasonMissing: requiresReason && !f.variance_reason.trim(),
      };
    });
  }, [items]);

  const summary = useMemo(() => {
    if (!items || !checks) return null;
    let lines = 0;
    let qty = 0;
    let missing = 0;
    let invalid = 0;
    items.forEach((f, i) => {
      const c = checks[i];
      if (c.invalid) invalid += 1;
      if (c.received > 0) {
        lines += 1;
        qty += c.received;
        if (c.reasonMissing) missing += 1;
      }
    });
    // 成本異常 → 只擋「這次真的要收」的那幾項（見 costOk 檔頭）。
    // ⛔ 不可以靜默跳過：擋住的品項一定要在畫面上講出來，
    //    樓下看不到單價，全靠這個提示才知道有東西沒收到。
    const badCost = items.filter((f, i) => checks[i].received > 0 && !costOk(f.unit_cost));
    return { lines, qty, missing, invalid, badCost, total: items.length };
  }, [items, checks]);

  // 已收齊的品項預設收起來；但只要有人在裡面填了數字就強制顯示，
  // 免得「送出去的東西畫面上看不到」。
  const hiddenHasQty = useMemo(() => {
    if (!items || !checks) return false;
    return items.some((f, i) => f.remaining <= 0 && checks[i].received > 0);
  }, [items, checks]);
  const doneVisible = showDone || hiddenHasQty;

  async function submit() {
    if (!items || !checks || !po || submitLock.current) return;
    submitLock.current = true;
    setError(null);
    setSubmitting(true);
    try {
      // ── 送出前的三道硬擋，順序＝從「最該先修好」往下 ──────────────
      // ⛔ 三道都是「整批不送」，不是靜默把有問題的那一項跳過送其他的 ——
      //    少收一項樓下不會發現，那才是真正會壞帳的失敗模式。
      // ⚠ 但第 2 道的**觸發範圍**只看「這次真的要收」（qty > 0）的品項：
      //    沒填數量的品項就算成本異常，也不會擋住你收這張單的其他品項
      //    （2026-08-19 從「擋整張單」改成這樣，理由見 costOk 檔頭）。

      // 1. 非法數量（"-5"、"1e3"、"abc"…）。RPC 只擋 qty <= 0，
      //    擋不住「前端把 -5 變成 5」，所以一定要在這裡攔。
      const invalidCount = checks.filter((c) => c.invalid).length;
      if (invalidCount > 0) {
        throw new Error(`有 ${invalidCount} 項的數量不是有效數字，請改成數字（例：12）再送出。`);
      }

      // 2. 成本異常（unit_cost 沒有 CHECK > 0，0 是合法值 → 會用 0 成本入庫）
      //    只擋這次要收的那幾項；其他品項照收（見 costOk 檔頭）。
      const badCost = items.filter((f, i) => checks[i].received > 0 && !costOk(f.unit_cost));
      if (badCost.length > 0) {
        throw new Error(
          `有 ${badCost.length} 個品項的成本不正常，收不進去，請通知辦公室修正採購單。` +
            `把這幾項的數量清成 0 就可以先收其他品項。（${badCost
              .slice(0, 3)
              .map(itemTitle)
              .join("、")}${badCost.length > 3 ? " 等" : ""}）`,
        );
      }

      const arrivals = items
        .map((f, i) => ({ f, c: checks[i] }))
        .filter(({ c }) => c.received > 0)
        .map(({ f, c }) => ({
          po_item_id: f.po_item_id,
          sku_id: f.sku_id,
          qty_received: c.received,
          // 樓下畫面上沒有「瑕疵」欄位 —— 瑕疵歸辦公室在既有收貨頁處理
          qty_damaged: 0,
          // 帶採購單原本的成本（上面第 2 道已保證 > 0）。
          // ⛔ 不可送 0 或 null，也⛔不可以自己猜一個成本：unit_cost > 0 才會
          // 重算加權平均成本（apply_movement_to_balance），送 0 會把成本洗掉。
          unit_cost: f.unit_cost,
          batch_no: null,
          expiry_date: null,
          variance_reason: f.variance_reason.trim() || null,
          // 樂觀鎖：把「我畫面上看到的已收量」一起送上去，後端在同一把列鎖之下
          // 比對現值，不一樣就整批擋下並叫人重新整理。
          //
          // 為什麼需要：樓下是共用帳號、多台 iPad。兩台各自開同一張單、
          // 各自看著自己那份（可能已經過期的）剩餘量按「全到」，兩邊都會通過，
          // qty_received 被連續累加兩次 → 庫存翻倍、成本算兩次、應付廠商多算，
          // 而且畫面上完全不會報錯。
          // ⛔ 這件事**不是**靠「排隊」能解的：rpc_arrive_and_distribute 第一步
          //   就對 purchase_orders 下了 FOR UPDATE，同一張單本來就會排隊；
          //   但排隊只保證後跑，不會讓第二台手上的數字變新。
          //   只有把「當時看到的值」送上去比對才擋得住。
          qty_received_base: f.qty_already,
          // 分店分配一律留給派貨工作台
          allocations: [] as Array<{ store_id: number; qty: number }>,
        }));

      if (arrivals.length === 0) throw new Error("請至少填一項實到數量");

      const missing = checks.filter((c) => c.reasonMissing).length;
      if (missing > 0) throw new Error(`有 ${missing} 項數量跟應到不一樣，要先選原因才能送出。`);

      const { data: userRes } = await getSupabase().auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      // 冪等鍵。完整推導在 @/lib/receivingSubmission 的檔頭，這裡只講結論：
      //
      //   ⇒ 沒送過       → 新的一把鍵，正常送
      //   ⇒ 內容一模一樣 → 沿用同一把鍵（後端回既有 GR，明講「先前已經收過了」）
      //   ⇒ 內容改過了   → **擋下**，只給「重新載入這張單」一條路
      //
      // ⚠️⚠️ 2026-08-20 複審 P0：第三條原本是「換一把新的鍵」，理由寫的是
      //   「換新鍵不會重複收貨，因為 base 對不上、樂觀鎖會擋」。**那句話是錯的。**
      //   上面的 arrivals 是 `filter(received > 0)` 現算的，只包含這次有填數量的品項；
      //   後端樂觀鎖也只逐項比對有送進來的品項。
      //   ⇒ 第一次送 A=5 已 commit、回應斷掉 → 樓下把 A 清成 0、改填 B 再送
      //     → 第二次 payload 裡沒有 A → **沒有任何一道防線會檢查 A**
      //     → B 收成功、畫面顯示成功，而 A 早就悄悄入過一次帳。
      //   關鍵認知：**送出失敗之後，畫面上那份數字已經不可信**（可能成功、可能沒有，
      //   前端分不出來）。讓他改內容再送本質上是在猜；唯一安全的動作是重讀現況。
      //
      // ⓘ payload 直接存 JSON 字串、不做 hash：這裡只需要「一不一樣」，
      //   不需要抗碰撞；長度也就幾百 bytes。arrivals 的欄位順序是固定的
      //   （上面只有一個 object literal 產生它），所以同樣內容的字串一定相同。
      const payload = JSON.stringify({ po: po.id, arrivals });
      const decision = decideSubmission(submissionRef.current, payload, newRequestId);
      if (decision.kind === "blocked") {
        // ⛔ 這裡只設旗標、不清 submissionRef：清掉的話下一次按就變成「全新的一次」，
        //    洞會原封不動回來。只有 openPO 重撈成功才有資格清。
        setMustReopen(true);
        throw new Error(SUBMISSION_BLOCKED_MESSAGE);
      }
      submissionRef.current = { id: decision.id, payload };

      const { data, error: rpcErr } = await getSupabase().rpc("rpc_arrive_and_distribute", {
        p_po_id: po.id,
        p_arrivals: arrivals,
        p_operator: operator,
        // 樓下不填發票號與備註
        p_invoice_no: null,
        p_notes: null,
        p_client_request_id: submissionRef.current.id,
      });
      if (rpcErr) throw new Error(translateRpcError(rpcErr));

      const out = (data as { gr_no?: string; duplicate?: boolean } | null) ?? {};
      const isDup = out.duplicate === true;
      setResult({
        gr_no: out.gr_no ?? "",
        po_no: po.po_no,
        // ⚠ 重試被認出來時，這次填的數字**不是**實際收進去的數字
        //   （後端回的是先前那張 GR，不會照這次的數量再收一次）。
        //   所以 duplicate 時不可以拿本地數字當結果講，成功畫面另外處理。
        qty: arrivals.reduce((s, a) => s + a.qty_received, 0),
        lines: arrivals.length,
        duplicate: isDup,
      });
      // 這一次（不管是新收還是被認出來的重試）都已經落地 → 清掉冪等鍵，
      // 下一次送出才不會被誤判成重試。
      submissionRef.current = null;
      // ⛔ 成功後**不釋放** submitLock，並且切到成功畫面（那一頁沒有送出鈕）。
      //    要再收下一張單一定得走 startNext()，那裡才會解鎖。
      setItems(null);
      setPO(null);
      setStep("done");
    } catch (e) {
      setError(translateRpcError(e));
      submitLock.current = false; // 失敗才解鎖，讓人修正後重試
    } finally {
      setSubmitting(false);
    }
  }

  async function startNext() {
    setResult(null);
    setError(null);
    setSearch("");
    setSupplier(null);
    setMissingSkuCount(0);
    setStep("supplier");
    setRows(null);
    submitLock.current = false;
    submissionRef.current = null; // 保險：submit 成功時已經清過
    setMustReopen(false);
    try {
      setRows(await loadWorkbench());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setRows([]);
    }
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
    // 蓋掉桌機側欄：不改全站 layout.tsx，改用本頁自己全屏。
    // z-40 → Modal / 手機抽屜（都是 z-50）仍蓋得住這一頁。
    // 高度用 dvh 不用 vh：iPad 工具列收合時 vh 會比實際可視高度大，底部按鈕會被切掉。
    <div className="fixed inset-x-0 top-0 z-40 flex h-[100dvh] flex-col bg-zinc-100 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      <Header
        step={step}
        supplier={supplier}
        po={po}
        onBack={() => {
          setError(null);
          if (step === "items") {
            setItems(null);
            setPO(null);
            setMissingSkuCount(0);
            setStep("po");
          } else if (step === "po") {
            setSupplier(null);
            setStep("supplier");
          }
        }}
      />

      <main className="flex-1 overflow-y-auto overscroll-contain px-4 pb-6 pt-4">
        {error && (
          <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-base font-medium text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
            ⚠ {error}
          </div>
        )}

        {step === "supplier" && (
          <SupplierStep
            rows={rows}
            groups={groups}
            search={search}
            onSearch={setSearch}
            onPick={(g) => {
              setSupplier(g);
              setStep("po");
            }}
          />
        )}

        {step === "po" && supplier && (
          <POStep supplier={supplier} busy={loadingItems} onPick={openPO} />
        )}

        {step === "items" && items && checks && (
          <ItemsStep
            items={items}
            checks={checks}
            doneVisible={doneVisible}
            forcedOpen={hiddenHasQty}
            missingSkuCount={missingSkuCount}
            badCost={summary?.badCost ?? []}
            onToggleDone={() => setShowDone((v) => !v)}
            onPatch={patchItem}
            onFillAll={fillAllArrived}
            onClearAll={clearAll}
          />
        )}

        {step === "done" && result && <DoneStep result={result} onNext={startNext} />}
      </main>

      {step === "items" && summary && (
        <footer className="border-t border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
          <div className="flex items-center justify-between gap-3">
            <div className="text-base">
              <div className="font-semibold">
                已核對 {summary.lines} / {summary.total} 項
              </div>
              <div className="text-sm text-zinc-600 dark:text-zinc-400">
                合計 <span className="font-mono font-bold">{summary.qty}</span> 件
                {summary.missing > 0 && (
                  <span className="ml-2 font-semibold text-rose-600 dark:text-rose-400">
                    · {summary.missing} 項還沒選原因
                  </span>
                )}
              </div>
            </div>
            {/* 送出失敗又改過內容 → 只給「重新載入」這一條路。
                ⚠ 這裡是把唯一安全的動作做成一顆按鈕，不是安全機制本身：
                  真正擋住送出的是 submit() 裡的 decideSubmission()。 */}
            {mustReopen && po ? (
              <SpinButton
                type="button"
                onClick={() => openPO(po)}
                disabled={loadingItems}
                className={`${BTN_BASE} min-w-[160px] bg-amber-600 text-lg text-white active:bg-amber-700 disabled:bg-zinc-300 dark:disabled:bg-zinc-700`}
              >
                {loadingItems ? "載入中…" : "🔄 重新載入這張單"}
              </SpinButton>
            ) : (
              <SpinButton
                type="button"
                onClick={submit}
                disabled={
                  summary.lines === 0 ||
                  summary.missing > 0 ||
                  summary.invalid > 0 ||
                  summary.badCost.length > 0 ||
                  submitting
                }
                className={`${BTN_BASE} min-w-[160px] bg-emerald-600 text-lg text-white active:bg-emerald-700 disabled:bg-zinc-300 dark:disabled:bg-zinc-700`}
              >
                {submitting ? "送出中…" : "✅ 確認收貨"}
              </SpinButton>
            )}
          </div>
          {/* ⛔ 停用原因一定要看得見，不可以只放 title：iPad 上沒有 tooltip */}
          {mustReopen ? (
            // ⚠️ mustReopen 時**只留這一句**。下面那四句全部是在教人「改數量」，
            //    而改數量正是這個狀態下被擋住的動作 —— 兩種提示並排會互相打架，
            //    樓下照著紅字改了半天還是送不出去。
            <p className="mt-2 text-sm font-bold text-amber-700 dark:text-amber-400">
              重新載入會把數量清空、重新讀一次「之前已收」——
              請照最新的數字重新點一次貨再收。
            </p>
          ) : (
            <>
              {summary.badCost.length > 0 && (
                <p className="mt-2 text-sm font-bold text-rose-600 dark:text-rose-400">
                  有 {summary.badCost.length} 項的成本不正常收不進去，請通知辦公室。
                  把那幾項的數量清成 0，就可以先收其他品項。
                </p>
              )}
              {summary.invalid > 0 && (
                <p className="mt-2 text-sm font-medium text-rose-600 dark:text-rose-400">
                  有 {summary.invalid} 項的數量不是有效數字，請改成數字（例：12）。
                </p>
              )}
              {summary.lines === 0 && summary.invalid === 0 && summary.badCost.length === 0 && (
                <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
                  還沒有任何一項填數量。點商品卡上的「全到」，或用 ＋／− 調數量。
                </p>
              )}
              {summary.missing > 0 && (
                <p className="mt-2 text-sm font-medium text-rose-600 dark:text-rose-400">
                  有 {summary.missing} 項數量跟應到不一樣，要先選一個原因才能送出。
                </p>
              )}
            </>
          )}
        </footer>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- header

function Header({
  step,
  supplier,
  po,
  onBack,
}: {
  step: Step;
  supplier: SupplierGroup | null;
  po: WorkbenchPO | null;
  onBack: () => void;
}) {
  const canBack = step === "po" || step === "items";
  return (
    <header className="flex items-center gap-3 border-b border-zinc-300 bg-white px-4 py-3 dark:border-zinc-700 dark:bg-zinc-900">
      {canBack ? (
        <SpinButton type="button" onClick={onBack} className={`${BTN_GHOST} shrink-0`}>
          ← 返回
        </SpinButton>
      ) : null}
      <div className="min-w-0 flex-1">
        <div className="truncate text-lg font-bold">
          {step === "supplier" && "📦 樓下收貨 · ① 選廠商"}
          {step === "po" && `② 選採購單 · ${supplier?.supplier_name ?? ""}`}
          {step === "items" && `③ 核對數量 · ${po?.po_no ?? ""}`}
          {step === "done" && "✅ 收貨完成"}
        </div>
        {step === "items" && po && (
          <div className="truncate text-sm text-zinc-600 dark:text-zinc-400">{po.supplier_name}</div>
        )}
      </div>
      {/* 出口：不然樓下會被困在這一頁出不去 */}
      <Link href="/wms/receiving" className={`${BTN_GHOST} shrink-0`}>
        離開
      </Link>
    </header>
  );
}

// ---------------------------------------------------------------- ① 選廠商

function SupplierStep({
  rows,
  groups,
  search,
  onSearch,
  onPick,
}: {
  rows: WorkbenchPO[] | null;
  groups: SupplierGroup[];
  search: string;
  onSearch: (v: string) => void;
  onPick: (g: SupplierGroup) => void;
}) {
  return (
    <div className="flex flex-col gap-4">
      {/* 字級 ≥16px：低於 16px 的輸入框一 focus，iOS 就把整頁放大 */}
      <input
        value={search}
        onChange={(e) => onSearch(e.target.value)}
        placeholder="🔍 搜廠商或商品名"
        className="min-h-[56px] w-full rounded-xl border border-zinc-300 bg-white px-4 text-base dark:border-zinc-700 dark:bg-zinc-900"
      />

      {rows === null ? (
        <p className="p-6 text-center text-base text-zinc-500">載入中…</p>
      ) : groups.length === 0 ? (
        <p className="p-6 text-center text-base text-zinc-500">
          {rows.length === 0 ? "目前沒有待收的貨" : "沒有符合的廠商或商品"}
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {groups.map((g) => (
            <li key={g.supplier_id}>
              <SpinButton
                type="button"
                onClick={() => onPick(g)}
                className={`${BTN_GHOST} w-full justify-between py-3 text-left`}
              >
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-xl font-bold">{g.supplier_name}</span>
                  <span className="block text-sm font-normal text-zinc-600 dark:text-zinc-400">
                    {g.pos.length} 張單 · 還沒到 {g.remaining} 件
                  </span>
                </span>
                <span className="shrink-0 text-2xl text-zinc-400">›</span>
              </SpinButton>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- ② 選採購單

function POStep({
  supplier,
  busy,
  onPick,
}: {
  supplier: SupplierGroup;
  busy: boolean;
  onPick: (p: WorkbenchPO) => Promise<void>;
}) {
  return (
    <ul className="flex flex-col gap-3">
      {supplier.pos.map((p) => {
        const left = Math.max(0, p.total_qty_ordered - p.total_qty_received);
        const preview = p.product_names.slice(0, 4).join("、");
        return (
          <li key={p.id}>
            <SpinButton
              type="button"
              disabled={busy}
              onClick={() => onPick(p)}
              className={`${BTN_GHOST} w-full flex-col items-start gap-1 py-3 text-left`}
            >
              <span className="flex w-full items-baseline justify-between gap-2">
                <span className="font-mono text-lg font-bold">{p.po_no}</span>
                <span className="shrink-0 text-sm font-normal text-zinc-600 dark:text-zinc-400">
                  {p.sent_at ? new Date(p.sent_at).toLocaleDateString("zh-TW") : "—"}
                </span>
              </span>
              <span className="text-sm font-normal text-zinc-600 dark:text-zinc-400">
                {p.line_count} 項 · 還沒到 {left} 件
                {p.status === "partially_received" && (
                  <span className="ml-2 rounded bg-amber-100 px-2 py-0.5 font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                    收過一部分
                  </span>
                )}
              </span>
              {preview && (
                <span className="w-full truncate text-sm font-normal text-zinc-500">
                  {preview}
                  {p.product_names.length > 4 ? " …" : ""}
                </span>
              )}
            </SpinButton>
          </li>
        );
      })}
    </ul>
  );
}

// ---------------------------------------------------------------- ③ 核對數量

type Check = {
  received: number;
  /** 打了非數字（"-5"、"1e3"、"abc"…）→ 明確擋下，⛔ 不靜默轉換 */
  invalid: boolean;
  /** 採購單成本 <= 0 或不是數字 → 這一項收不進去（卡片一律標示；
   *  但只有 received > 0 時才擋住送出，其他品項照收 —— 見 summary.badCost） */
  badCost: boolean;
  isOver: boolean;
  isShort: boolean;
  requiresReason: boolean;
  reasonMissing: boolean;
};

function ItemsStep({
  items,
  checks,
  doneVisible,
  forcedOpen,
  missingSkuCount,
  badCost,
  onToggleDone,
  onPatch,
  onFillAll,
  onClearAll,
}: {
  items: ItemForm[];
  checks: Check[];
  doneVisible: boolean;
  /** 已收齊區塊裡有人填了數字 → 強制攤開，收不起來（收起來會讓送出的東西看不到） */
  forcedOpen: boolean;
  /** 商品資料沒撈回來的品項數（樓下靠圖片與品名辨貨，缺漏不能無聲） */
  missingSkuCount: number;
  /** 這次真正被擋住的品項（有填數量 且 成本不正常）。⛔ 不是全部成本異常的品項 */
  badCost: ItemForm[];
  onToggleDone: () => void;
  onPatch: (idx: number, patch: Partial<ItemForm>) => void;
  onFillAll: () => void;
  onClearAll: () => void;
}) {
  const pending = items.map((f, i) => ({ f, c: checks[i], i })).filter(({ f }) => f.remaining > 0);
  const finished = items.map((f, i) => ({ f, c: checks[i], i })).filter(({ f }) => f.remaining <= 0);

  return (
    <div className="flex flex-col gap-4">
      {badCost.length > 0 && (
        <div className="rounded-xl border-2 border-rose-400 bg-rose-50 p-4 dark:border-rose-700 dark:bg-rose-950/50">
          <div className="text-lg font-bold text-rose-800 dark:text-rose-200">
            ⛔ 這 {badCost.length} 項收不進去
          </div>
          <p className="mt-1 text-base text-rose-800 dark:text-rose-200">
            成本不正常，請通知辦公室修正採購單。
            <strong>把這幾項的數量清成 0，就可以先收這張單的其他品項。</strong>
          </p>
          <ul className="mt-2 list-disc pl-5 text-base text-rose-800 dark:text-rose-200">
            {badCost.slice(0, 5).map((f) => (
              <li key={f.po_item_id}>{itemTitle(f)}</li>
            ))}
            {badCost.length > 5 && <li>…等 {badCost.length} 項</li>}
          </ul>
        </div>
      )}

      {missingSkuCount > 0 && (
        <div className="rounded-xl border-2 border-amber-400 bg-amber-50 p-4 text-base font-medium text-amber-900 dark:border-amber-700 dark:bg-amber-950/50 dark:text-amber-200">
          ⚠ 有 {missingSkuCount} 項的商品資料沒載入（可能沒有圖片和品名），請通知辦公室。
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        <SpinButton type="button" onClick={onFillAll} className={BTN_GHOST}>
          全部都到齊
        </SpinButton>
        <SpinButton type="button" onClick={onClearAll} className={BTN_GHOST}>
          全部清空
        </SpinButton>
      </div>

      {pending.length === 0 && finished.length === 0 && (
        <p className="p-6 text-center text-base text-zinc-500">這張單沒有可收的品項</p>
      )}

      <ul className="flex flex-col gap-4">
        {pending.map(({ f, c, i }) => (
          <ItemCard key={f.po_item_id} item={f} check={c} onPatch={(p) => onPatch(i, p)} />
        ))}
      </ul>

      {finished.length > 0 && (
        <>
          <SpinButton
            type="button"
            onClick={onToggleDone}
            disabled={forcedOpen}
            className={BTN_GHOST}
          >
            {doneVisible ? "▲ 收起已收齊的" : `▼ 顯示已收齊的 ${finished.length} 項`}
          </SpinButton>
          {/* ⛔ 停用原因要看得見，不可以只放 title：iPad 上沒有 tooltip */}
          {forcedOpen && (
            <p className="-mt-2 text-sm text-zinc-600 dark:text-zinc-400">
              下面「已收齊」的品項裡有填了數字的，先攤開著不收起來，免得要送出的東西畫面上看不到。
            </p>
          )}
          {doneVisible && (
            <ul className="flex flex-col gap-4">
              {finished.map(({ f, c, i }) => (
                <ItemCard key={f.po_item_id} item={f} check={c} onPatch={(p) => onPatch(i, p)} />
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}

function ItemCard({
  item,
  check,
  onPatch,
}: {
  item: ItemForm;
  check: Check;
  onPatch: (patch: Partial<ItemForm>) => void;
}) {
  const exact = check.received > 0 && !check.invalid && !check.isOver && !check.isShort;
  const cardCls =
    check.badCost || check.invalid || check.reasonMissing
      ? "border-rose-400 bg-rose-50 dark:border-rose-700 dark:bg-rose-950/40"
      : exact
        ? "border-emerald-400 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950/30"
        : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900";

  // ⛔ 非法輸入時不做加減：那等於把打錯的字悄悄換成一個數字。
  function step(delta: number) {
    if (check.invalid) return;
    onPatch({ qty: String(Math.max(0, check.received + delta)) });
  }

  return (
    <li className={`rounded-2xl border-2 p-4 ${cardCls}`}>
      <div className="flex items-start gap-4">
        {item.image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={item.image_url}
            alt={itemTitle(item)}
            loading="lazy"
            className="h-24 w-24 shrink-0 rounded-xl border border-zinc-200 object-cover dark:border-zinc-800"
          />
        ) : (
          // 無圖佔位：尺寸與有圖時一致，卡片不會破版
          <div className="flex h-24 w-24 shrink-0 items-center justify-center rounded-xl border border-zinc-200 bg-zinc-50 text-zinc-300 dark:border-zinc-800 dark:bg-zinc-950">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5} className="h-10 w-10">
              <path strokeLinecap="round" strokeLinejoin="round" d="M5 8h14l-1 11a2 2 0 0 1-2 1.8H8A2 2 0 0 1 6 19L5 8Z" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M9 8V6.5a3 3 0 0 1 6 0V8" />
            </svg>
          </div>
        )}
        <div className="min-w-0 flex-1">
          <div className="text-xl font-bold leading-snug">{itemTitle(item)}</div>
          {item.sku_code && (
            <div className="mt-0.5 font-mono text-sm text-zinc-500">{item.sku_code}</div>
          )}
          <div className="mt-2 text-lg">
            應到 <span className="font-mono text-3xl font-bold">{item.remaining}</span> 件
          </div>
          {item.qty_already > 0 && (
            <div className="text-sm text-zinc-600 dark:text-zinc-400">
              訂 {item.qty_ordered} · 之前已收 {item.qty_already}
            </div>
          )}
        </div>
      </div>

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
          value={item.qty}
          onChange={(e) => onPatch({ qty: e.target.value })}
          placeholder="0"
          aria-label="實到數量"
          aria-invalid={check.invalid}
          className={`min-h-[56px] w-28 rounded-xl border-2 bg-white px-3 text-center font-mono text-2xl font-bold dark:bg-zinc-800 ${
            check.invalid
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
          onClick={() => onPatch({ qty: String(item.remaining) })}
          className={`${exact ? `${BTN_BASE} bg-emerald-600 text-white active:bg-emerald-700` : BTN_PRIMARY} ml-auto min-w-[110px] text-lg`}
        >
          {exact ? "✓ 全到" : "全到"}
        </SpinButton>
      </div>

      {/* ⛔ 提示要看得見，不可以只放 title：iPad 上沒有 tooltip */}
      {check.invalid && (
        <p className="mt-2 text-base font-bold text-rose-700 dark:text-rose-300">
          ⚠ 「{item.qty}」不是有效數字，請只填數字（例：12）。這一項現在不會被送出。
        </p>
      )}

      {/* 卡片一律標紅（不等填了數字才講）：讓樓下在點貨前就知道這項收不進去。
          只有「這次真的要收」的才會擋住送出，其他品項照收。 */}
      {check.badCost && (
        <p className="mt-2 text-base font-bold text-rose-700 dark:text-rose-300">
          ⛔ 這一項的成本不正常，這次不會被收，請通知辦公室。這張單的其他品項可以照收。
        </p>
      )}

      {check.requiresReason && (
        <div className="mt-4 rounded-xl border-2 border-amber-400 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950/50">
          <div className="text-base font-bold text-amber-900 dark:text-amber-200">
            {check.isOver
              ? `⚠ 比應到多了 ${check.received - item.remaining} 件 —— 選一個原因`
              : `⚠ 比應到少了 ${item.remaining - check.received} 件 —— 選一個原因`}
          </div>
          <div className="mt-2 flex flex-wrap gap-2">
            {REASON_PRESETS.map((r) => {
              const on = item.variance_reason.trim() === r;
              return (
                <SpinButton
                  key={r}
                  type="button"
                  onClick={() => onPatch({ variance_reason: on ? "" : r })}
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
            value={item.variance_reason}
            onChange={(e) => onPatch({ variance_reason: e.target.value })}
            placeholder="或自己打（例：司機說明天補）"
            aria-label="差異原因"
            className="mt-2 min-h-[56px] w-full rounded-xl border border-amber-400 bg-white px-3 text-base dark:border-amber-700 dark:bg-zinc-900"
          />
        </div>
      )}
    </li>
  );
}

// ---------------------------------------------------------------- ④ 完成

function DoneStep({
  result,
  onNext,
}: {
  result: { gr_no: string; po_no: string; qty: number; lines: number; duplicate: boolean };
  onNext: () => Promise<void>;
}) {
  // duplicate ＝ 這次送出被後端認出是「同一次送出的重試」，貨先前就已經收進去了。
  // ⛔ 這種時候不可以顯示本次填的件數：後端回的是先前那張進貨單，
  //    數字不見得一樣，講出來會讓人以為又收了一批。
  const dup = result.duplicate;
  return (
    <div className="mx-auto flex max-w-lg flex-col items-center gap-5 py-10 text-center">
      <div className="text-6xl">{dup ? "☑️" : "✅"}</div>
      <div className="text-2xl font-bold">{dup ? "這批貨先前已經收過了" : "收貨完成"}</div>
      <div
        className={
          dup
            ? "rounded-2xl border-2 border-sky-300 bg-sky-50 px-6 py-4 text-lg dark:border-sky-800 dark:bg-sky-950/40"
            : "rounded-2xl border-2 border-emerald-300 bg-emerald-50 px-6 py-4 text-lg dark:border-emerald-800 dark:bg-emerald-950/40"
        }
      >
        <div className="font-mono font-bold">{result.po_no}</div>
        {!dup && (
          <div className="mt-1">
            {result.lines} 項 · 共 <span className="font-mono font-bold">{result.qty}</span> 件
          </div>
        )}
        {result.gr_no && (
          <div className="mt-1 font-mono text-sm text-zinc-600 dark:text-zinc-400">
            進貨單 {result.gr_no}
          </div>
        )}
      </div>
      <p className="text-base text-zinc-600 dark:text-zinc-400">
        {dup
          ? "剛剛那一次其實已經送出成功了（可能是網路斷掉才顯示失敗）。系統沒有再收一次，庫存不會多算。要確認實際收了多少，看上面那張進貨單。"
          : "這批貨已經進總倉。分店要分多少，辦公室會在派貨工作台處理。"}
      </p>
      <div className="flex flex-wrap justify-center gap-3">
        <SpinButton type="button" onClick={onNext} className={`${BTN_PRIMARY} text-lg`}>
          收下一張單
        </SpinButton>
        <Link href="/wms/receiving" className={`${BTN_GHOST} text-lg`}>
          離開
        </Link>
      </div>
    </div>
  );
}
