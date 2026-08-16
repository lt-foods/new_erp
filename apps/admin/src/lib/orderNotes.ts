// 轉單 RPC（rpc_transfer_order_to_store / rpc_transfer_order_partial）會把內部
// 流程標記 append 到 customer_orders.notes，每個標記獨立一行、以 [ 開頭，例：
//   [轉入 (部分, 經總倉) ← 訂單 #36612 (GB20260522-C000325-TF0054)] 2026-07-21 08:10:39
//   [追加轉入 (空中轉) ← 訂單 #123 (GB...)] 2026-07-21 08:10:39 / 原因
//   [轉出 → 訂單 #456 (GB...)] / [全部轉出 → ...] / [部分轉出 → ...] / [部分追加 → ...]
// 這些是內部轉單流程訊息，客人拿到的取貨單不該出現 —— 列印前整行剔除。
const TRANSFER_MARKER_LINE = /^\s*\[(?:追加轉入|轉入|全部轉出|部分轉出|部分追加|轉出)[^\]]*\]/;

// 現貨直配（20260816000010 起）同樣往 notes 寫內部標記，而且**單頭與品項都會寫**：
//   單頭：【現貨直配】店內現貨直接配給客人（待取，取貨時才扣庫存收款）
//         [拆單] 自 SP-2-0001 拆出（…）
//   品項：[現貨直配] 2026-08-16 08:49
// 2026-08-16 回報：這些整段被印在客人的取貨清單上。與轉單標記同一類 ——
// 是給後台看的流程訊息，不是客人交代的事情，列印前一律剔除。
// 用全形【】與半形[] 兩種括號都要認：單頭那行是全形、品項那行是半形。
const SPOT_MARKER_LINE = /^\s*(?:【現貨直配】|\[(?:現貨直配|拆單)[^\]]*\])/;

function isInternalMarker(line: string): boolean {
  return TRANSFER_MARKER_LINE.test(line) || SPOT_MARKER_LINE.test(line);
}

/**
 * 列印用：剔除內部流程標記，只留真正由店員手打、客人該看到的備註。
 * 整段都是內部標記時回 null（呼叫端就不會畫出空的「📝」）。
 */
export function stripTransferNotes(notes: string | null | undefined): string | null {
  if (!notes) return null;
  const kept = notes
    .split("\n")
    .filter((line) => !isInternalMarker(line))
    .join("\n")
    .trim();
  return kept || null;
}

/** 品項備註同一套規則（`customer_order_items.notes`）。 */
export const stripItemNotes = stripTransferNotes;
