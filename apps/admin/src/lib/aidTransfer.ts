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

// 「貨還沒交到收貨店手上」的轉入單狀態 —— 轉出店還需要為它做事（印單、交貨）。
// pending 一定要在裡面，見上面。
export const AID_IN_FLIGHT_STATUSES = ["pending", "confirmed", "shipping"] as const;

export function isAidInFlight(status: string): boolean {
  return (AID_IN_FLIGHT_STATUSES as readonly string[]).includes(status);
}

// 路徑（貨怎麼走）
export function aidRouteLabel(isAir: boolean): string {
  return isAir ? "✈ 空中轉直送" : "🏬 經總倉";
}

// 轉出店視角的階段文字。收貨店收掉（ready）之後轉出店就沒事了，但記錄還是要看得懂。
export function aidStageLabel(status: string, isAir: boolean): string {
  switch (status) {
    case "pending":
      return isAir ? "等出貨" : "等總倉收貨";
    case "confirmed":
      return isAir ? "等出貨" : "總倉已收・等派貨";
    case "reserved":
      return "已保留";
    case "shipping":
      return isAir ? "已出貨・等收貨店收" : "總倉已派貨・等收貨店收";
    case "ready":
      return "收貨店已收貨";
    case "partially_completed":
      return "收貨店部分取貨";
    case "completed":
      return "收貨店已取貨";
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
