// 店家按「取消訂單／刪除品項」之前：總倉已經叫貨的，先跳一次提醒（老闆 2026-10-15：不擋，只讓店家知道）。
//
// 後端：rpc_order_cancel_po_notice(p_order_id, p_item_id)（20261016000000_picking_post_po_cancel_to_store.sql A9）
//   回「這張單（或這一項）現在取消，會照派原店」的品項；沒有列＝不用提醒。
//   條件跟派車那邊（v_picking_post_po_cancelled）同一套 ⇒ 跳提醒的，取消後真的會照派原店，提醒不會說錯。
//
// 三種結果分得開：
//   沒有列         ⇒ 不跳，直接進原本的取消流程（還沒叫貨、一團兩張、分界前的舊單…都照今天）
//   有列           ⇒ 跳提醒；停用店另一套文字（那幾件不派，留在派貨工作台給總倉決定）
//   查詢失敗       ⇒ 跳「無法確認是否已叫貨，仍要取消嗎？」，按確定照常取消（不擋）
//   （8 秒沒回也算查詢失敗，免得取消鈕一直轉）
//
// ⛔ 只在原本的「輸入原因」視窗之前多問一次；原本的取消流程、文字一個字都不改。
// ⓘ 一個 import 都沒有：`node --test` 直接吃 .ts 驗得到；supabase 由呼叫端傳進來。

/** rpc_order_cancel_po_notice 的一列。id、數量經 PostgREST 可能是字串 → 用的時候 Number() */
export type CancelPoNoticeRow = {
  order_item_id: number | string;
  sku_id: number | string;
  sku_label: string | null;
  qty: number | string | null;
  po_id: number | string | null;
  po_no: string | null;
  store_active: boolean | null;
};

export type CancelPoNotice =
  | { kind: "rows"; rows: CancelPoNoticeRow[] }
  | { kind: "failed"; reason: string };

export const CANCEL_PO_NOTICE_TEXT =
  "總倉已經叫貨。取消只會取消客人的訂單，貨到了會直接進本店【內部】帳號，月結照算。";
export const CANCEL_PO_NOTICE_INACTIVE_TEXT =
  "總倉已經叫貨；這家店已停用，取消後這幾件會留在派貨工作台給總倉決定。";
export const CANCEL_PO_NOTICE_FAILED_TEXT = "無法確認是否已叫貨，仍要取消嗎？";
/** 問後端最多等多久（毫秒）；超過就當查詢失敗 */
export const CANCEL_PO_NOTICE_TIMEOUT_MS = 8000;

/**
 * 組提醒文字；回 null ＝不用跳提醒。
 *   question ＝最後一行要問什麼（例：「確定要取消這張訂單嗎？」）
 * 同一樣商品先把正負件數加總，再只列淨件數大於 0 的：
 *   抵減單那種負數行取消後不會多派貨，要先從同商品扣掉（+10、−2 ⇒ 提醒 8 件）；
 *   扣完不大於 0 ⇒ 「貨到了會進本店」那句不成立，不列（整張都這樣就不跳）。
 */
export function cancelPoNoticeText(notice: CancelPoNotice, question: string): string | null {
  if (notice.kind === "failed") return CANCEL_PO_NOTICE_FAILED_TEXT;
  const active = sumBySku(notice.rows.filter((r) => r.store_active !== false));
  const inactive = sumBySku(notice.rows.filter((r) => r.store_active === false));
  if (active.length === 0 && inactive.length === 0) return null;
  const lines: string[] = [];
  if (active.length > 0) {
    lines.push(CANCEL_PO_NOTICE_TEXT, "", "已叫貨的品項：", ...itemLines(active));
  }
  if (inactive.length > 0) {
    if (lines.length > 0) lines.push("");
    lines.push(CANCEL_PO_NOTICE_INACTIVE_TEXT, "", "已叫貨的品項：", ...itemLines(inactive));
  }
  lines.push("", question);
  return lines.join("\n");
}

type SkuQty = { label: string; qty: number };

/**
 * 同一樣商品合併（正負件數一起加），只留淨件數大於 0 的。
 * 加總後四捨五入到小數 3 位（件數是 NUMERIC(18,3)），免得 0.3−0.1−0.2 這種浮點尾數被當成「還有 0 件」。
 */
function sumBySku(rows: CancelPoNoticeRow[]): SkuQty[] {
  const bySku = new Map<string, SkuQty>();
  for (const r of rows) {
    const key = String(r.sku_id);
    const cur = bySku.get(key);
    if (cur) cur.qty += toNum(r.qty);
    else bySku.set(key, { label: (r.sku_label ?? "").trim() || "（未命名商品）", qty: toNum(r.qty) });
  }
  return Array.from(bySku.values())
    .map((x) => ({ label: x.label, qty: Math.round(x.qty * 1000) / 1000 }))
    .filter((x) => x.qty > 0);
}

function itemLines(items: SkuQty[]): string[] {
  return items.map((x) => `・${x.label} × ${formatQty(x.qty)}`);
}

/** 呼叫端只要有 rpc 就能用（不 import supabase，測試可以餵假的） */
type RpcClient = {
  rpc: (
    fn: string,
    args: Record<string, unknown>,
  ) => PromiseLike<{ data: unknown; error: { message?: string } | null }>;
};

/**
 * 問後端這張單（或這一項）現在取消會不會照派原店；任何錯誤都回 failed，不丟例外。
 * timeoutMs（預設 8 秒）沒回 ⇒ 回 { kind: "failed", reason: "timeout" }（畫面跳「無法確認」，按確定照常取消）；
 *   晚到的回應直接丟掉。
 */
export async function fetchCancelPoNotice(
  sb: RpcClient,
  orderId: number,
  itemId?: number | null,
  timeoutMs: number = CANCEL_PO_NOTICE_TIMEOUT_MS,
): Promise<CancelPoNotice> {
  const query = (async (): Promise<CancelPoNotice> => {
    try {
      const { data, error } = await sb.rpc("rpc_order_cancel_po_notice", {
        p_order_id: orderId,
        p_item_id: itemId ?? null,
      });
      if (error) return { kind: "failed", reason: error.message ?? "查詢失敗" };
      return { kind: "rows", rows: Array.isArray(data) ? (data as CancelPoNoticeRow[]) : [] };
    } catch (e) {
      return { kind: "failed", reason: e instanceof Error ? e.message : String(e) };
    }
  })();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<CancelPoNotice>((resolve) => {
    timer = setTimeout(() => resolve({ kind: "failed", reason: "timeout" }), timeoutMs);
  });
  try {
    return await Promise.race([query, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 取消前先問一次。回 true ＝繼續原本的取消流程；false ＝使用者按了取消，停下來。
 * 不用提醒時直接回 true（不跳任何視窗）。timeoutMs 不給＝預設 8 秒（呼叫端不用傳）。
 */
export async function confirmCancelPoNotice(
  sb: RpcClient,
  orderId: number,
  itemId: number | null,
  question: string,
  ask: (text: string) => boolean,
  timeoutMs?: number,
): Promise<boolean> {
  const text = cancelPoNoticeText(await fetchCancelPoNotice(sb, orderId, itemId, timeoutMs), question);
  return text == null ? true : ask(text);
}

function toNum(value: number | string | null | undefined): number {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function formatQty(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/\.?0+$/, "");
}
