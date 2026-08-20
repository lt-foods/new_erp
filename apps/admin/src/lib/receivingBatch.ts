// 樓下 iPad 收貨頁（wms/receiving/ipad）「一次收多筆、而且會跨採購單」的純邏輯。
//
// ⛔ 抽成獨立模組不是為了整潔，是因為**分組分錯會直接壞帳**，必須能單獨被驗。
//    改這裡之前先讀完下面整段。
//
// ── 為什麼需要分組 ────────────────────────────────────────────────────────
// `rpc_arrive_and_distribute` 是 **per-PO** 的（第一個參數就是 p_po_id，
// 而且 20260820000000:475-484 會擋「品項不屬於這張採購單」）。
// 但樓下的心智模型是「我手上這箱是馬卡龍，我要收它」——
// 他勾的 3 樣東西很可能來自 3 張不同的採購單。
// ⇒ 前端一定要**按採購單分組、逐張呼叫**，⛔ 不可以硬塞成一次。
//
// ── 分組之後三件事一定要「每張單各自一份」 ──────────────────────────────
//   1. **冪等鍵 p_client_request_id：每張單各自一把。**
//      ⛔ 全部共用一把會直接壞掉，而且是很難看懂的壞法：後端
//      20260820000000:349-352 明文擋「同一個識別碼跑到別張採購單」——
//      第一張成功之後，第二張會拿到
//      「收貨識別碼 xxx 先前已用在採購單 #A,不可以再用在 #B」。
//      → 一批 5 張單只有第一張收得進去，其餘 4 張全部報一個看不懂的錯。
//   2. **樂觀鎖 qty_received_base：每一列各自帶自己的已收量。**
//      它是逐項比對的（20260820000000:498-525），不是整張單一個值。
//   3. **成敗要逐張回報。** 3 張成功 1 張被樂觀鎖擋下時，畫面只講一個
//      「成功」或一個「失敗」都會讓樓下誤會成全收了 / 全沒收，
//      兩種誤會都會讓盤點對不起來。所以本模組回傳的是 PoBatch[]，
//      呼叫端必須逐張記錄結果（⛔ 不可以只留一個總結）。
//
// ⚠️ 冪等鍵的沿用／擋下規則本身在 @/lib/receivingSubmission 的 decideSubmission()。
//    本模組的 runBatchSubmit() 負責「每張單各跑一次」的那層編排。

import {
  decideSubmission,
  SUBMISSION_BLOCKED_MESSAGE,
  type Submission,
} from "./receivingSubmission";

/** 一列待收品項（＝一個商品 × 一張採購單）中，送出時真正會用到的欄位。 */
export type BatchItem = {
  po_item_id: number;
  po_id: number;
  sku_id: number;
  /** 採購單原成本。⛔ 不可送 0／null，會把加權平均成本洗掉。 */
  unit_cost: number;
  /** 樂觀鎖基準：畫面上這一項「之前已收」的數字，從資料庫讀來的原值。 */
  qty_already: number;
  /** 這次實到幾件（已經過 parseQty 驗證，> 0）。 */
  qty: number;
  /** 數量與應到不符時的原因；沒有就是 null。 */
  variance_reason: string | null;
};

/** 送給 rpc_arrive_and_distribute 的 p_arrivals 元素。欄位順序固定 —— 見下方註解。 */
export type Arrival = {
  po_item_id: number;
  sku_id: number;
  qty_received: number;
  qty_damaged: number;
  unit_cost: number;
  batch_no: null;
  expiry_date: null;
  variance_reason: string | null;
  qty_received_base: number;
  allocations: never[];
};

export type PoBatch = {
  po_id: number;
  arrivals: Arrival[];
  /** 這張單這次收幾項 */
  lines: number;
  /** 這張單這次收幾件 */
  qty: number;
};

/**
 * 把勾選的品項按採購單分組，並組出每張單自己的 p_arrivals。
 *
 * ⚠️ 兩個「順序」都是刻意固定的，因為 decideSubmission() 是拿 **JSON 字串**
 *    在比對「這次送的內容跟上次一不一樣」：
 *      · 分組後的採購單順序：依 po_id 由小到大
 *      · 單張單裡的品項順序：依 po_item_id 由小到大
 *    ⛔ 不可以改成「照畫面上的順序」—— 使用者搜尋條件一換、排序就變，
 *      同樣的內容會產生不同字串 → 被誤判成「內容改過了」而擋下重試，
 *      樓下會看到一個完全沒道理的「不能再送」。
 * ⓘ Arrival 的欄位順序由下面那個 object literal 唯一決定（只有這一處產生它），
 *   所以同樣內容序列化出來的字串一定相同。
 */
export function groupArrivalsByPo(items: BatchItem[]): PoBatch[] {
  const byPo = new Map<number, BatchItem[]>();
  for (const it of items) {
    const cur = byPo.get(it.po_id);
    if (cur) cur.push(it);
    else byPo.set(it.po_id, [it]);
  }

  return Array.from(byPo.entries())
    .sort((a, b) => a[0] - b[0])
    .map(([po_id, list]) => {
      const sorted = [...list].sort((a, b) => a.po_item_id - b.po_item_id);
      const arrivals: Arrival[] = sorted.map((it) => ({
        po_item_id: it.po_item_id,
        sku_id: it.sku_id,
        qty_received: it.qty,
        // 樓下畫面上沒有「瑕疵」欄位 —— 瑕疵歸辦公室在既有收貨頁處理
        qty_damaged: 0,
        unit_cost: it.unit_cost,
        batch_no: null,
        expiry_date: null,
        variance_reason: it.variance_reason,
        // 樂觀鎖：把「我畫面上看到的已收量」一起送上去，後端在同一把列鎖之下
        // 比對現值。⛔ 這一項是逐列的，不可以整張單共用一個值。
        qty_received_base: it.qty_already,
        // 分店分配一律留給派貨工作台
        allocations: [] as never[],
      }));
      return {
        po_id,
        arrivals,
        lines: arrivals.length,
        qty: arrivals.reduce((s, a) => s + a.qty_received, 0),
      };
    });
}

// ---------------------------------------------------------------- 逐張送出

export type BatchOutcome = {
  po_id: number;
  lines: number;
  qty: number;
  kind: "ok" | "duplicate" | "error";
  gr_no?: string;
  message?: string;
};

/**
 * 逐張採購單送出，回傳**每一張各自的結果**。
 *
 * ⛔ 抽成函式是為了能離線驗證。這一段是本案最容易做錯的地方，
 *    而它的錯法全都是「安靜的」——畫面顯示成功、帳其實不對。
 *
 * 規則（每一條都對應一個真實的壞帳情境）：
 *
 *   ① **一張一張跑，不用 Promise.all。**
 *      失敗要能一張一張講清楚；而且每張單在後端第一步就 FOR UPDATE 自己的
 *      purchase_orders 列，並行只是把排隊搬進資料庫，換不到速度。
 *
 *   ② **一張失敗不中斷其餘的。** 樓下手上的貨是實體的，因為第 2 張出問題
 *      就不收第 3、4 張，只會讓現場更亂。
 *
 *   ③ **成功（含 duplicate）→ 刪掉那張單的冪等鍵**：下一次是全新的一次送出。
 *      ⛔ 不刪的話，樓下要收「今天到的第二批」時會被誤判成重試而**靜默不收**
 *        （比重複收更難發現）。
 *
 *   ④ **失敗 → 保留那張單的冪等鍵與 payload。** 這是重試能成立的前提：
 *      原樣再按一次 = 帶同一把鍵 = 後端認得出來（回既有 GR，不會收第二次）。
 *      ⛔ 失敗就清掉的話，第二次會變成「全新的一次」，
 *        而第一次可能其實已經 commit 了 —— 同一批貨算兩次。
 *
 *   ⑤ **blocked（內容改過了）→ 記成失敗，但一樣不清鍵。**
 *      清掉就等於讓下一按變成全新的一次，洞原封不動回來。
 *      唯一安全的出口是重新載入這張單（呼叫端要提供那顆按鈕）。
 *
 * @param subs 會被**就地修改**（set / delete）。呼叫端傳的就是它那份長期保存的 Map。
 */
export async function runBatchSubmit(args: {
  batches: PoBatch[];
  subs: Map<number, Submission>;
  newId: () => string;
  callRpc: (
    poId: number,
    arrivals: Arrival[],
    requestId: string,
  ) => Promise<{ gr_no?: string; duplicate?: boolean } | null>;
  toMessage: (e: unknown) => string;
}): Promise<BatchOutcome[]> {
  const { batches, subs, newId, callRpc, toMessage } = args;
  const out: BatchOutcome[] = [];

  for (const b of batches) {
    const base = { po_id: b.po_id, lines: b.lines, qty: b.qty };

    //   ⇒ 這張單沒送過   → 新的一把鍵，正常送
    //   ⇒ 內容一模一樣   → 沿用同一把鍵（後端回既有 GR）
    //   ⇒ 內容改過了     → 擋下（規則 ⑤）
    const payload = JSON.stringify({ po: b.po_id, arrivals: b.arrivals });
    const decision = decideSubmission(subs.get(b.po_id) ?? null, payload, newId);
    if (decision.kind === "blocked") {
      out.push({ ...base, kind: "error", message: SUBMISSION_BLOCKED_MESSAGE });
      continue;
    }
    // 先存起來再送：送出去之後才存的話，「網路斷在半路」那一次就沒有鍵可以重試。
    subs.set(b.po_id, { id: decision.id, payload });

    try {
      const res = await callRpc(b.po_id, b.arrivals, decision.id);
      subs.delete(b.po_id); // 規則 ③
      out.push({
        ...base,
        kind: res?.duplicate === true ? "duplicate" : "ok",
        gr_no: res?.gr_no ?? undefined,
      });
    } catch (e) {
      // 規則 ②＋④：記下來、留著鍵、繼續下一張
      out.push({ ...base, kind: "error", message: toMessage(e) });
    }
  }

  return out;
}

// ---------------------------------------------------------------- 搜尋

/**
 * 把搜尋字串切成 token（空白分隔），全部轉小寫。
 *
 * 為什麼要多 token：樓下打「向陽 馬卡龍」時，意思是「向陽那家的馬卡龍」，
 * 當成一整串比對會一個都找不到（品名裡不會有廠商名）。
 * 全形空白也要切 —— iPad 中文輸入法很容易打出全形空白。
 */
export function tokenizeQuery(q: string): string[] {
  return q
    .trim()
    .toLowerCase()
    .split(/[\s　]+/)
    .filter((t) => t.length > 0);
}

/**
 * 把一列的可搜尋文字接成一串（已轉小寫）。
 *
 * ⚠️ 一定要含 variant_name 與 sku_code：
 *   · variant_name —— product_name 常常是上層品名（例：product_name 是
 *     「台南日曬手工麵」、variant_name 才是「(A)關廟刀削麵」），
 *     畫面上印的是兩個接起來，搜尋卻只比對上層品名的話，
 *     樓下照著畫面上看到的字打進去會搜不到，看起來就像搜尋壞掉。
 *     （機制索引「四之六」：/wms/receiving 與 /purchase/orders 兩邊都只比對
 *      products.name，就是踩這個坑；本頁的資料是逐列撈的，沒有這個限制。）
 *   · 廠商名／代碼／單號 —— 老闆要「同一個搜尋框」，打廠商名要找得到那家的貨。
 */
export function buildHaystack(parts: Array<string | null | undefined>): string {
  return parts
    .map((p) => (p ?? "").trim())
    .filter((p) => p.length > 0)
    .join(" ")
    .toLowerCase();
}

/** 所有 token 都要命中（AND）。token 為空＝不過濾。 */
export function matchesQuery(haystack: string, tokens: string[]): boolean {
  if (tokens.length === 0) return true;
  return tokens.every((t) => haystack.includes(t));
}
