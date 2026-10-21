// 採購單「已到貨也能斷貨」（20261022100000_po_force_stockout_after_received.sql）：
// 按鈕顯示條件、確認視窗的判斷與措辭、回收貨待辦。
//
// 這顆鈕在做什麼（後端 rpc_force_stockout_po_item）：
//   這一項對應那張請購單涵蓋的團 × 這個商品 × 還沒取貨的客人品項，一次取消＋蓋斷貨時間
//   （照 #1087 已審過的規則：配貨還回、編輯歷史、整單收尾、付過錢不動錢）。
//   ⛔ 不動採購單那一項、開團商品、派車單、庫存、月結、退回單 —— 實體貨照現在的退貨流程，
//      所以按完要給一份「回收貨待辦」（returnTodoLines）。
//
// ⓘ 為什麼獨立成一支、而且一個 import 都沒有：
//   純計算＋措辭，`node --test` 直接吃 .ts 就驗得到（同 pickingMultiPo.ts 的作法）。
//
// ⛔ 畫面上每一句都必須是程式真的會做的事（機制索引「畫面上的斷言要當事實查核」）。
//    待辦路徑的出處：機制索引「四之八之二」（2026-10-22 契爾氏那次實際走完一遍）。

/** 後端 rpc_preview_force_stockout 回傳（只列畫面用到的欄位；數字可能是字串，用的時候 Number()） */
export type ForceStockoutPreview = {
  found: boolean;
  po_item_id: number;
  po_no?: string;
  po_status?: string;
  sku_code?: string | null;
  sku_label?: string | null;
  qty_ordered?: number | string;
  qty_received?: number | string;
  campaigns?: { id: number; campaign_no: string | null; name: string | null }[];
  other_po_items?: { po_no: string; po_status: string; campaign_no: string | null }[];
  restock_requests?: number | string;
  block_reasons: string[];
  untouched?: {
    picked_items: number | string;
    picked_qty: number | string;
    picked_orders: number | string;
    dead_items: number | string;
    dead_qty: number | string;
    dead_orders: number | string;
  };
  prior?: { items: number | string; qty: number | string; last_at: string | null };
  summary?: ForceStockoutSummary;
  return_todo?: ReturnTodoRow[];
  can_execute: boolean;
  already_done: boolean;
  nothing_to_do: boolean;
};

export type ForceStockoutSummary = {
  items: number | string;
  qty: number | string;
  offset_items: number | string;
  members: number | string;
  orders: number | string;
  orders_cancel: number | string;
  orders_complete: number | string;
  orders_keep: number | string;
  orders_paid: number | string;
  by_store: { store_id: number; store_name: string; items: number | string; qty: number | string; members: number | string; orders: number | string }[];
  by_campaign: { campaign_id: number; campaign_no: string | null; items: number | string; qty: number | string }[];
  paid_orders: PaidOrder[];
};

/** 付過錢或用過儲值金的單（單號＋店，不含客人資料）；outcome：paid＝單子不動、keep＝單子留著、complete＝收尾完成 */
export type PaidOrder = { store_name: string; order_no: string; outcome: string };

/** 這一項（同一張採購單、同一個商品）撿貨派出去到哪幾家店、收了沒 */
export type ReturnTodoRow = {
  store_id: number;
  store_name: string;
  wave_code: string;
  wave_status: string;
  qty: number | string;
  transfer_no: string | null;
  transfer_status: string | null;
  qty_shipped: number | string | null;
  qty_received: number | string | null;
  received_at: string | null;
  stage: "received" | "in_transit" | "not_shipped" | "transfer_cancelled" | string;
};

/** 後端 rpc_force_stockout_po_item 回傳 */
export type ForceStockoutResult = {
  ok: boolean;
  already_done: boolean;
  nothing_to_do: boolean;
  at?: string;
  items_cancelled: number | string;
  qty_cancelled?: number | string;
  offset_items_cancelled?: number | string;
  orders_cancelled?: number | string;
  orders_completed?: number | string;
  orders_kept?: number | string;
  paid_orders?: PaidOrder[];
  members_notified?: number | string;
  released_rows?: number | string;
  released_qty?: number | string;
  dn_voided?: number | string;
};

/** 原因的長度上限（後端同一個數字：rpc_force_stockout_po_item 第 2 步） */
export const FORCE_STOCKOUT_REASON_MAX = 200;

/** 數字顯示：整數不帶小數、小數去尾 0（同 POStoreAddModal 的 formatQty） */
export function fmtQty(value: number | string | null | undefined): string {
  const n = Number(value ?? 0);
  if (!Number.isFinite(n)) return "0";
  return Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/\.?0+$/, "");
}

/**
 * 採購單明細那一列要不要顯示「已到貨也能斷貨」。
 *
 * ⛔ 跟原本的「⛔ 斷貨」鈕不會同時出現在同一列（老闆 10/22）：
 *   原本那顆的顯示條件由頁面自己算（`canStockout && 已收 < 訂購`），整個傳進來當 originalStockoutShown；
 *   它出現的列，這顆一律不出現 —— 原本的鈕照舊、不被取代。
 *   ⇒ 「部分到貨、還在等剩下的量」那種列只會看到原本的鈕。
 * 其他條件：名單內（canForce）、這一項沒標斷貨、已收量 > 0、採購單不是草稿／已取消。
 * （後端還有更多擋法，例如一團兩張採購單、斷貨拆出來的單 —— 那些在確認視窗裡講原因。）
 */
export function showForceStockoutButton(row: {
  canForce: boolean;
  poStatus: string | null | undefined;
  stockoutAt: string | null | undefined;
  qtyReceived: number;
  originalStockoutShown: boolean;
}): boolean {
  if (!row.canForce) return false;
  if (row.originalStockoutShown) return false;
  if (row.stockoutAt) return false;
  if (!(Number(row.qtyReceived) > 0)) return false;
  if (!row.poStatus || row.poStatus === "draft" || row.poStatus === "cancelled") return false;
  return true;
}

/** 輸入的商品代碼要送給後端的樣子：只去掉前後空白（大小寫、中間的字一個都不改） */
export function normalizeSkuInput(input: string): string {
  return (input ?? "").trim();
}

/**
 * 輸入的商品代碼對不對（2026-10-22 CEO 裁定的規則）：前後空白不算（方便複製貼上），
 * 其他一字不差、大小寫要一樣。送給後端的也是去掉前後空白之後的值，後端逐字比 ⇒ 前後端一致。
 */
export function skuCodeMatches(input: string, skuCode: string | null | undefined): boolean {
  if (!skuCode) return false;
  return normalizeSkuInput(input) === skuCode;
}

/** 原因有沒有問題：null＝可以；否則回給人看的提示 */
export function reasonProblem(reason: string): string | null {
  const r = (reason ?? "").trim();
  if (r === "") return "請填原因（會寫進每一筆的編輯歷史）";
  if (Array.from(r).length > FORCE_STOCKOUT_REASON_MAX) {
    return `原因太長（${Array.from(r).length} 字），請精簡到 ${FORCE_STOCKOUT_REASON_MAX} 字以內`;
  }
  return null;
}

/** 「確定取消」按不按得下去：預覽說可以、代碼對、原因有填 */
export function canSubmitForceStockout(
  preview: Pick<ForceStockoutPreview, "can_execute" | "sku_code"> | null,
  skuInput: string,
  reason: string,
): boolean {
  if (!preview || !preview.can_execute) return false;
  if (!skuCodeMatches(skuInput, preview.sku_code)) return false;
  return reasonProblem(reason) === null;
}

/** 預覽上方的紅字：擋下原因；沒有可取消的也要講清楚是「已經做過」還是「本來就沒有」 */
export function previewStopLines(p: ForceStockoutPreview): string[] {
  const out = [...(p.block_reasons ?? [])];
  if (out.length === 0 && p.already_done) {
    const prior = p.prior;
    out.push(
      `已經做過了：這一項之前按過，取消的 ${fmtQty(prior?.items)} 筆（${fmtQty(prior?.qty)} 件）現在都還是取消狀態，` +
        `目前沒有還在等貨的客人品項。`,
    );
  } else if (out.length === 0 && p.nothing_to_do) {
    out.push("這些團裡已經沒有還在等這個商品、也還沒取貨的客人品項，不用按。");
  }
  return out;
}

/** 預覽的「會發生什麼」：人數、件數、每張單怎麼收尾 */
export function summaryLines(s: ForceStockoutSummary): string[] {
  const lines = [
    `會取消 ${fmtQty(s.members)} 位客人的 ${fmtQty(s.items)} 筆、共 ${fmtQty(s.qty)} 件` +
      `（${fmtQty(s.orders)} 張單；店家內部單也算在內，沒綁會員的單各算一位）`,
  ];
  if (Number(s.offset_items) > 0) {
    lines.push(`其中 ${fmtQty(s.offset_items)} 筆是抵減單（負數量），一併取消、不算在件數裡`);
  }
  lines.push(`・整張取消 ${fmtQty(s.orders_cancel)} 張（單上只剩這個商品、沒取過貨、沒付錢）`);
  if (Number(s.orders_complete) > 0) {
    lines.push(`・收尾成「已完成」${fmtQty(s.orders_complete)} 張（單上其他商品都取過了）`);
  }
  if (Number(s.orders_keep) > 0) {
    lines.push(`・單子留著 ${fmtQty(s.orders_keep)} 張（單上還有別的商品要取，只少這一項）`);
  }
  if (Number(s.orders_paid) > 0) {
    lines.push(`・付過錢或用過儲值金、單子不動 ${fmtQty(s.orders_paid)} 張（這一項照樣取消）`);
  }
  return lines;
}

/** 預覽的「不動的」 */
export function untouchedLines(p: ForceStockoutPreview): string[] {
  const u = p.untouched;
  const out: string[] = [];
  if (u && Number(u.picked_items) > 0) {
    out.push(`已經取貨的 ${fmtQty(u.picked_items)} 筆（${fmtQty(u.picked_qty)} 件、${fmtQty(u.picked_orders)} 張單）：不動`);
  }
  if (u && Number(u.dead_items) > 0) {
    out.push(
      `店家已經取消／過期／轉出的單上還掛著的 ${fmtQty(u.dead_items)} 筆（${fmtQty(u.dead_qty)} 件、${fmtQty(u.dead_orders)} 張單）：不動`,
    );
  }
  if (Number(p.restock_requests ?? 0) > 0) {
    out.push(`這一項還有 ${fmtQty(p.restock_requests)} 筆補貨申請（店家叫的 RR- 內部單）：這顆鈕不處理`);
  }
  return out;
}

/** 付過錢的單：錢不動、要人工確認退款（單號＋店） */
export function paidOrderLines(list: PaidOrder[] | null | undefined): string[] {
  return (list ?? []).map((o) => {
    const what =
      o.outcome === "keep"
        ? "單子留著"
        : o.outcome === "complete"
          ? "收尾成已完成"
          : "單子不動";
    return `${o.store_name} ${o.order_no}（${what}；這一項照樣取消，錢不會自動退）`;
  });
}

/**
 * 回收貨退回總倉之後的那一步（#924「退回貨處理」10/22 已上正式庫）：
 *   總倉按「同意收回」或「同意退」→「不補貨」之後，那批貨自動凍結、派不出去，
 *   要到退回貨處理頁處理才解凍。選單位置＝layout.tsx 的「倉儲 (WMS)」→「退回貨處理」。
 */
export const RETURN_DISPOSITION_STEP =
  "之後那批貨會凍結、派不出去，要到左選單「倉儲 (WMS) → 退回貨處理」處理才解凍";

/** 回收貨待辦：一家店一行，照「收了沒」給要做的事（出處：機制索引「四之八之二」） */
export function returnTodoLine(r: ReturnTodoRow): string {
  switch (r.stage) {
    case "received":
      return (
        `${r.store_name}：已收貨 ${fmtQty(r.qty_received)} 件（派車單 ${r.transfer_no ?? "?"}）` +
        ` → 店家到「退貨」頁開退回單退回總倉；總倉到「總倉收件匣 → 🚚 轉貨單 → ↩ 退貨回總倉」按「同意收回」；` +
        RETURN_DISPOSITION_STEP
      );
    case "in_transit":
      // 分頁名「店家少收」＝components/ExceptionsContent.tsx 的 transfer_short（老闆 10/22 截圖對過）
      return (
        `${r.store_name}：派出 ${fmtQty(r.qty_shipped)} 件、店家還沒收（派車單 ${r.transfer_no ?? "?"}）` +
        ` → 店家收貨時這一項實收改 0；總倉到「總倉收件匣 → ⚠️ 異常 → 店家少收」按「同意退」→「不補貨」；` +
        RETURN_DISPOSITION_STEP
      );
    case "not_shipped":
      return `${r.store_name}：撿貨單 ${r.wave_code} 還沒派車（${fmtQty(r.qty)} 件）→ 這一項先不要派出去，請總倉在撿貨單上處理`;
    case "transfer_cancelled":
      return `${r.store_name}：派車單 ${r.transfer_no ?? "?"} 已取消 → 不用處理`;
    default:
      return `${r.store_name}：撿貨單 ${r.wave_code}（狀態 ${r.stage}）→ 請總倉確認`;
  }
}

/** 回收貨待辦整段（沒有派出去過的也要講：貨還在總倉） */
export function returnTodoLines(rows: ReturnTodoRow[] | null | undefined): string[] {
  const list = rows ?? [];
  if (list.length === 0) {
    return ["這一項還沒有撿貨派出去：貨都還在總倉，要退廠商請走採購單退貨。"];
  }
  return [...list.map(returnTodoLine), ...RETURN_DISPOSITION_NOTES];
}

/**
 * 「退回貨處理」頁怎麼按（照 wms/return-disposition/page.tsx 的畫面字樣：
 *   「完好數量」＋「實物已到總倉（必勾）」、「破損數量」＋「破損原因（必填）」、
 *   「遺失數量」＋「遺失原因（必填）」、按鈕「送出處理」；說明句「完好的貨會恢復成可重新派出的庫存；
 *   破損與遺失會記入總倉損失」）。那一頁沒有「退廠商」選項 ⇒ 只講事實，不替人選哪一種。
 */
export const RETURN_DISPOSITION_NOTES = [
  "「退回貨處理」頁：填「完好數量」（要勾「實物已到總倉」）＝恢復成可再派出的庫存；" +
    "填「破損數量」或「遺失數量」（要填原因）＝記入總倉損失；填完按「送出處理」。",
  "錯貨要退廠商的：退回貨處理頁沒有「退廠商」選項，先在那一頁處理完，再走採購單退貨；" +
    "選「完好」的話那批貨會回到可派出的庫存，小心不要又派出去。",
];

/** 按完之後的結果 */
export function resultLines(r: ForceStockoutResult): string[] {
  if (r.nothing_to_do) {
    return [
      r.already_done
        ? "已經做過了：這一項之前按過，沒有新的可以取消，這次什麼都沒改。"
        : "沒有可以取消的客人品項，這次什麼都沒改。",
    ];
  }
  const lines = [
    `已取消 ${fmtQty(r.items_cancelled)} 筆、共 ${fmtQty(r.qty_cancelled)} 件` +
      (Number(r.offset_items_cancelled ?? 0) > 0 ? `（另有 ${fmtQty(r.offset_items_cancelled)} 筆抵減單一併取消）` : ""),
    `整張取消 ${fmtQty(r.orders_cancelled)} 張；收尾成已完成 ${fmtQty(r.orders_completed)} 張；單子留著 ${fmtQty(r.orders_kept)} 張`,
    Number(r.members_notified ?? 0) > 0
      ? `已在會員通知中心發斷貨通知給 ${fmtQty(r.members_notified)} 位（不推 LINE）`
      : "沒有發通知（要通知客人，請店家自己講）",
  ];
  if (Number(r.released_rows ?? 0) > 0) {
    lines.push(`有 ${fmtQty(r.released_rows)} 筆從店內庫存配過貨，已還回 ${fmtQty(r.released_qty)} 件`);
  }
  return lines;
}
