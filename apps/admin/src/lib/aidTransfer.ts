// 互助 / 轉單（訂單轉給別店）在「轉出店」視角的階段文字與狀態集合。
//
// 為什麼要收在同一支：轉出店的貨走到哪裡，這個判斷散在三個地方（儀表板提醒、
// 來源訂單的轉出記錄、來源訂單的列印鈕）。分開寫的後果 2026-08-18 已經發生過一次
// —— 儀表板只認 confirmed/shipping，而**經總倉的轉入單一開始是 `pending`**
// （rpc_transfer_order_to_store / _partial：跨店非空中轉一律建成 pending，
// 要等總倉在 /hq/inbox 收到貨才推 confirmed）。結果轉出店在「貨還在自己手上、
// 最需要印隨貨單」的那一段完全收不到提醒。
//
// 空中轉不同：轉單當下就自動出貨（20260814030000），轉入單直接進 shipping，
// confirmed 只會是自動出貨上線前卡住的舊單。
//
// ⚠ 這三個地方一律走 customer_order_transfer_links（20260824000100），
// **不要**回頭反查 customer_orders.transferred_from_order_id —— 那一欄只有
// 「建新轉入單」那條分支會寫，「追加轉入（併入同活動＋同頻道＋同會員的既有
// active 單）」什麼都不寫，於是三個畫面同時查無此事：2026-08-24 松山認領互助板
// 的喜願蛋轉給古華，貨併進古華既有的 TF0486（那張單身上有 3 家店的 5 次認領），
// 該欄指著最早的中和店 —— 松山端完全查不到，儀表板還把整張單算成「中和 → 古華」。
// 一張轉入單可以有多個來源，是 1:N，補寫一欄救不了。

// 「貨還沒交到收貨店手上」的轉入單狀態 —— 轉出店還需要為它做事（印單、交貨）。
// pending 一定要在裡面，見上面。
export const AID_IN_FLIGHT_STATUSES = ["pending", "confirmed", "shipping"] as const;

export function isAidInFlight(status: string): boolean {
  return (AID_IN_FLIGHT_STATUSES as readonly string[]).includes(status);
}

// 這一趟沒走成（取消提供 / 取消轉入 / 退回原店 / 逾期）。
// 互助板的分頁用它把「已取消」從「已簽收」裡拆出來 —— 兩者混在一起時，
// 看起來像一堆已送達的紀錄，實際上大半是取消掉的（2026-08-25 回報：
// 「對方已簽收 (8)」裡有 5 筆是已取消）。
export const AID_DEAD_STATUSES = ["cancelled", "expired"] as const;

export function isAidDead(status: string): boolean {
  return (AID_DEAD_STATUSES as readonly string[]).includes(status);
}

// ---- 訂單轉移連結（customer_order_transfer_links） ----

export const TRANSFER_LINK_SELECT =
  "id, source_order_id, dest_order_id, dest_item_ids, is_air_transfer, appended, transferred_at";

export type TransferLink = {
  id: number;
  source_order_id: number;
  dest_order_id: number;
  dest_item_ids: number[] | null;
  is_air_transfer: boolean | null;
  appended: boolean | null;
  transferred_at: string;
};

/** 這一趟轉移真正搬過去的品項。
 *
 *  為什麼不能直接用整張轉入單的品項：追加分支會把好幾家店的貨併進同一張單
 *  （線上 TF0486 有 5 個品項來自 3 家店）。轉出店的提醒數量與隨貨單只該算
 *  自己那一批，否則松山會看到「5 件」、印出來把中和店的 3 件也一起寄走。
 *
 *  dest_item_ids 是空的只會發生在回填抓不到對應品項的極舊資料 —— 退回
 *  「整張單的互助品項」，寧可多印也不要印出一張空白單。 */
export function linkItems<T extends { id: number; source?: string | null }>(
  link: Pick<TransferLink, "dest_item_ids">,
  items: T[],
): T[] {
  const ids = link.dest_item_ids;
  if (ids && ids.length > 0) {
    const set = new Set(ids.map(Number));
    return items.filter((it) => set.has(Number(it.id)));
  }
  return items.filter((it) => it.source === "aid_transfer");
}

/** 未取消品項的數量加總（提醒與轉出記錄都用這個口徑：
 *  品項全被取消的單沒有實體貨在走，不該叫人去印一張空白單）。 */
export function activeQty(items: { qty: number | string; status: string }[]): number {
  return items
    .filter((it) => !["cancelled", "expired"].includes(it.status))
    .reduce((s, it) => s + Number(it.qty), 0);
}

// 路徑（貨怎麼走）
export function aidRouteLabel(isAir: boolean): string {
  return isAir ? "✈ 空中轉直送" : "🏬 經總倉";
}

// 轉出店視角的階段文字。收貨店收掉（ready）之後轉出店就沒事了，但記錄還是要看得懂。
export function aidStageLabel(status: string, isAir: boolean): string {
  switch (status) {
    case "pending":
      return isAir ? "待出貨" : "待總倉簽收";
    case "confirmed":
      return isAir ? "待出貨" : "總倉已簽收・待派送";
    case "reserved":
      return "已保留";
    case "shipping":
      return isAir ? "已出貨・待收貨店簽收" : "總倉已派送・待收貨店簽收";
    case "ready":
      return "收貨店已簽收";
    case "partially_completed":
      return "收貨店已部分取貨";
    case "completed":
      return "收貨店已取貨完成";
    case "cancelled":
      return "已取消";
    case "expired":
      return "已逾期";
    case "transferred_out":
      return "已再轉出";
    default:
      return status;
  }
}
