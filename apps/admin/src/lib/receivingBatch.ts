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

// ---------------------------------------------------------------- 採購單清單

/** rpc_receiving_workbench 回傳的一張採購單（只留本頁用得到的欄位）。 */
export type WorkbenchPO = {
  id: number;
  po_no: string;
  status: string;
  sent_at: string | null;
  supplier_name: string;
  supplier_code: string | null;
  line_count: number;
};

/**
 * 舊版 `rpc_receiving_workbench()`（v1/v2）對**整份清單**下的 `LIMIT 200`
 * （20260819000000_receiving_workbench_product_names.sql:51-57）。
 * 這個數字也剛好是 v3 留給 `fully_received` 那一半的上限
 * （20260820000200_receiving_workbench_no_truncate.sql:161-173 的 `fr_recent`）。
 *
 * ⛔⛔ 這個常數存在的唯一理由是**偵測**，不是設定 —— 改它不會讓 RPC 多回幾張單。
 *    要真的多回，得改那支 RPC。
 */
export const WORKBENCH_PO_LIMIT = 200;

/**
 * 把 RPC 回來的原始列整理成 WorkbenchPO[]，順便判斷「清單可能被截斷了」。
 *
 * ── ⚠️⚠️ 2026-08-20：這道警告的**前提已經被 #798 拆掉了**，判定跟著收窄 ──────
 *
 * 【本來為什麼要有】v1/v2 的 RPC 把 `sent / partially_received / fully_received`
 *   **混在一起** `ORDER BY sent_at DESC LIMIT 200`。fully_received 只增不減、
 *   sent_at 又比較新 ⇒ 它會把「還沒收完的舊單」一張張擠出前 200 名。
 *   正式庫實測擠掉 151 張、其中 149 張真的在等收（10,013 件）。
 *   而這一頁**偵測不到自己被截**：品項數的截斷警告（fetchRowsFor 的 `expected`）
 *   拿被截後的 `line_count` 加總當基準，兩邊剛好對得起來 → 永遠不會亮。
 *   ⇒ 只能用「回傳筆數頂到上限」去猜，判定寫成 `>= 200`。
 *
 * 【現在】#798（20260820000200，**已套上正式庫**）把 po CTE 改成：
 *   · `sent` / `partially_received` → **全取，不設上限**
 *   · `fully_received`              → 仍只取最近 200 張（`fr_recent`）
 *   ⇒ ①「還沒收完的單被漏掉」在 v3 底下**不可能發生**（老闆驗收：資料庫 275 張、
 *       看得到 275 張）。
 *     ② 剩下那半的 LIMIT 200 對這一頁**完全不可見**：下面的 filter 本來就把
 *       fully_received 濾掉，而且樓下也不會去收一張已經收完的單。
 *   ⇒ 舊的 `>= 200` 在正式庫上是 475 >= 200 ⇒ **永遠亮，而且是確定的假警報**。
 *     ⛔ 永遠亮的警告比沒有警告更糟：它會讓樓下對**所有**警告麻木，
 *       連「數量被別人改過，請退出重看」那種真的該停手的一起無視。
 *
 * ── 那為什麼不整條刪掉？ ─────────────────────────────────────────────────
 * 因為 #798 的 rollback 只有一步：「重跑 20260819000000 的 CREATE OR REPLACE」
 * （20260820000200 自己的檔頭就是這樣寫的）。真被回退時，這一頁會**無聲**退回
 * 「搜不到 ＝ 沒這批貨」—— 正是 10,013 件那次的形狀，而且沒有任何別的地方會叫。
 * 後端不在這一片的範圍，RPC 也沒有回傳版本號或 total_count 可以問。
 * ⇒ 判定從 `>=` 收窄成 `===`，改當**絆線**用：
 *   · v3（現在）：總筆數 ＝ 未收完(全取) ＋ min(200, 已全收)。已全收在正式庫早就
 *     滿 200 ⇒ 總筆數 ＝ 200 ＋ 未收完張數。要剛好等於 200 只有「未收完 0 張」，
 *     而那時畫面本來就顯示「目前沒有待收的貨」。⇒ 實務上**不會亮**。
 *   · 被回退成 v2：符合白名單的單有 979 張 ⇒ 必被截 ⇒ 總筆數**必定剛好 200**
 *     ⇒ **每次都亮**。這一種才是真的「可能漏掉要收的貨」，值得樓下停手。
 *
 * ⚠️⚠️ 它**只**認得「上限剛好還是 200」這一種回退。哪天 RPC 換成別的上限、
 *    或重新對 sent / partially_received 加上限，這裡偵測不到、會靜靜地沒反應。
 *    ⇒ 改那支 RPC 的人**要順手把這裡一起改**，⛔ 不要指望它自己會叫。
 *
 * ⚠️ 判定一定要用**還沒過濾的原始列數**：頁面之後會把 fully_received 濾掉，
 *    拿濾完的長度去比 200 是原 bug 的形狀（用被截斷的結果當作「應該有幾筆」的
 *    基準）。所以過濾在**算完旗標之後**才做。
 * ⛔ 不可以只寫 console：樓下不會開 devtools。
 */
export function normalizeWorkbenchPOs(raw: Array<Record<string, unknown>>): {
  pos: WorkbenchPO[];
  /** 清單可能被 RPC 的 LIMIT 截掉了（猜測性，不是確定）。
   *  v3 底下實務上恆為 false —— 見本函式說明。 */
  listMaybeTruncated: boolean;
} {
  // ⭐ 先用原始長度判定，⛔ 不可以搬到 filter 之後
  // ⭐ 是 `===` 不是 `>=`：v3 回的是 475 筆，`>=` 會變成永遠亮的假警報。
  //   ⛔ 不要「看起來比較保險」就改回 `>=`（理由見上面【現在】那一段）。
  const listMaybeTruncated = raw.length === WORKBENCH_PO_LIMIT;

  const pos = raw
    .map((r) => ({
      id: Number(r.id),
      po_no: String(r.po_no),
      status: String(r.status),
      sent_at: (r.sent_at as string | null) ?? null,
      supplier_name: String(r.supplier_name),
      supplier_code: (r.supplier_code as string | null) ?? null,
      line_count: Number(r.line_count),
    }))
    // 只留還能收的單。rpc_arrive_and_distribute 本身也擋（PO must be
    // sent/partially_received），這裡先濾掉才不會讓樓下看到了才吃錯誤。
    .filter((r) => r.status === "sent" || r.status === "partially_received");

  return { pos, listMaybeTruncated };
}

// ---------------------------------------------------------------- 數量欄判定

/**
 * 實到數量欄的判定：**驗證**，不是清洗。
 *
 * ⛔ 這裡曾經是 `replace(/[^\d.]/g, "")` 的清洗式寫法，那是錯的：
 *    "-5" 會被洗成 "5"、"1e3" 會被洗成 "13" —— 把非法輸入靜默換成
 *    「另一個合法但錯誤的數字」，樓下完全看不出自己打的 -5 變成了 5。
 * ⛔ 也不能指望 RPC 兜底：`20260820000000` 只擋
 *    `qty_received IS NULL OR <= 0`，它收到的 5 是合法的 5，擋不了。
 *
 * 四種結果，每一種畫面上都要有對應的講法：
 *   · `ok`      —— 合法且 > 0，可以送
 *   · `empty`   —— 勾了但沒填。⛔ 不可以靜默當 0 跳過，少收一項樓下不會發現
 *   · `invalid` —— 打了非數字（"-5"、"1e3"、"abc"…）
 *   · `zero`    —— 填的是 0（用「−」按到底、或直接打 0 都會走到這裡）。
 *     ⭐ 這一項是 2026-08-20 複審 P1 補的。後端會擋 `qty_received <= 0`
 *       （20260820000000:440-442），但它是**整張採購單一起炸**：同一批勾的
 *       其他正常品項會被連坐，而且吐的是未中文化的
 *       `arrival sku_id X has invalid qty_received`。
 *       樓下站在貨旁邊看不懂、也不知道是哪一項害的。⇒ 前端先擋。
 */
export type QtyVerdict = "ok" | "empty" | "invalid" | "zero";

// 採購數量是 numeric(18,3)，所以允許小數，但只允許「數字[.數字]」這一種寫法。
const QTY_RE = /^\d+\.?\d*$/;

export function classifyQty(raw: string): { verdict: QtyVerdict; qty: number } {
  const t = raw.trim();
  if (t === "") return { verdict: "empty", qty: 0 };
  if (!QTY_RE.test(t)) return { verdict: "invalid", qty: 0 };
  const n = Number(t);
  if (!Number.isFinite(n) || n < 0) return { verdict: "invalid", qty: 0 };
  if (n === 0) return { verdict: "zero", qty: 0 };
  return { verdict: "ok", qty: n };
}

// ---------------------------------------------------------------- 送出前擋下

/** blockReasonFor() 要看的計數。全部以「已勾選的那幾列」為母體。 */
export type SelectionCounts = {
  lines: number;
  invalid: number;
  empty: number;
  zero: number;
  badCost: number;
  reasonMissing: number;
};

/**
 * 整批擋下的理由；null ＝ 可以送。
 *
 * ⚠️ 這裡是「**人填錯**」的處理方式：擋住送出、講清楚怎麼改。
 *   和「**資料壞**」（fetchRowsFor 的 badData：DB 裡的 qty 是 NaN/Infinity）
 *   刻意不同 —— 那種列是**整列排除掉 + 紅框列出**，其他品項照收。
 *   兩者不衝突，分野是「樓下當場改不改得掉」：
 *     · 資料壞 → 樓下改不掉（要辦公室去修採購單）。擋整批只會讓他站在貨旁邊
 *       什麼都收不了，所以排除該列、其餘照收。
 *     · 人填錯 → 樓下當場就改得掉（改數字或取消勾選）。擋住才逼得出正確的送出；
 *       偷偷略過那一列的話，少收的那項沒有人會發現。
 *   ⛔ 不要把其中一邊改成另一邊的做法，那會讓對應的失敗方式變成靜默的。
 *
 * ⚠️ 順序是刻意的：先講「數字本身不對」（invalid → empty → zero，都是同一個欄位、
 *   最好改），再講「這項根本收不進去」（badCost，要打電話），最後才是差異原因。
 */
export function blockReasonFor(c: SelectionCounts): string | null {
  if (c.lines === 0) return "請先勾選要收的品項。";
  if (c.invalid > 0) return `有 ${c.invalid} 項的數量不是有效數字，請改成數字（例：12）。`;
  if (c.empty > 0) return `有 ${c.empty} 項還沒填數量，請填數字或取消勾選。`;
  if (c.zero > 0)
    return `有 ${c.zero} 項填的數量是 0。要收 0 個的話，請直接取消勾選那幾項。`;
  if (c.badCost > 0)
    return `有 ${c.badCost} 項的成本不正常收不進去，請通知辦公室，並先取消勾選這幾項。`;
  if (c.reasonMissing > 0)
    return `有 ${c.reasonMissing} 項數量跟應到不一樣，要先選一個原因才能送出。`;
  return null;
}

// ---------------------------------------------------------------- 互斥鎖

/**
 * 全頁共用的一把鎖：**整頁重撈 / 單張重撈 / 送出 / 傳到撿貨草稿，四者不可以同時跑。**
 *
 * ⭐ 2026-08-20 複審 P1：原本只有「整頁重撈」與「送出」互斥，
 *   失敗採購單那顆「🔄 重新載入這張單」沒有納入 ⇒ 重撈跑到一半還可以按
 *   「確認收貨」，兩條非同步流程交錯。
 *   後端的樂觀鎖與冪等鍵兜得住帳（失敗方式是吵的紅字，不是靜默壞帳），
 *   但**畫面狀態會變得沒辦法判讀** —— 樓下是戰區，看不懂畫面就會亂按。
 *
 * ⛔ 一定要用 ref 不可以用 state：React 的 setState 是非同步的，
 *   同一個 tick 連按兩下時 state 還沒更新，擋不住第二下。
 *   （state 那份只是給畫面用的鏡像，用來把按鈕變灰、講出為什麼。）
 *
 * ⛔ 只在**使用者按下去的那一層**取鎖，不要塞進 reloadPos() 那種底層函式：
 *   送出流程成功之後自己就會呼叫它，塞在裡面不是自我封鎖就是被自己擋掉。
 *
 * @returns 取不到鎖 → 回傳「目前是誰佔著」（呼叫端可據此給訊息）；
 *          取得到並跑完 → 回傳 null。⚠️ fn 丟出來的例外會原樣往外拋，
 *          但鎖一定會在 finally 放掉（⛔ 不可以改成吞掉例外）。
 */
// ⭐ "draft" ＝ 送出成功後那顆「📋 傳到撿貨草稿」（2026-09-02 加）。
//   它跟送出／重撈用**同一把鎖**，理由與上面那條複審 P1 一樣：
//   傳草稿要逐樣 loadPrefill + insert（好幾趟往返），跑到一半如果還按得動
//   「🔄 重新載入這張單」，畫面上的結果面板會被抽掉，而草稿還在寫。
// ⚠ 新增一個成員就要回頭看**所有讀 busy 的地方**有沒有漏講原因：
//   本 repo 的規則是「按鈕變灰一定要看得出為什麼」（iPad 上沒有 tooltip）。
//   2026-09-02 盤點：**用到這個型別的檔案只有兩支**，兩支都只做等值比較
//   （`busy !== null` / `=== "submit"` / `=== "load"` / `=== "draft"`），
//   ⛔ 沒有任何 switch 需要補 case：
//     · wms/receiving/ipad/page.tsx（收貨頁）
//     · wms/receiving/ipad/po/page.tsx（採購單查看頁）
//   查法：git grep -l "BusyKind" -- apps/admin/src
//   ⚠ ⛔ 不要改用 `git grep "busy ==="` 去盤：hq/inbox、purchase/requests/edit、
//     restock/inbox 各自有**同名但不同型別**的區域 busy state（字串 id / 自己的 union），
//     跟這個型別無關，混進來只會讓人以為漏改了一堆地方。
export type BusyKind = "load" | "submit" | "draft";

export async function runExclusive(
  ref: { current: BusyKind | null },
  kind: BusyKind,
  onChange: (k: BusyKind | null) => void,
  fn: () => Promise<void>,
): Promise<BusyKind | null> {
  const held = ref.current;
  if (held) return held;
  ref.current = kind;
  onChange(kind);
  try {
    await fn();
    return null;
  } finally {
    ref.current = null;
    onChange(null);
  }
}
