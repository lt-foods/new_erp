// 轉單 RPC（rpc_transfer_order_to_store / rpc_transfer_order_partial）會把內部
// 流程標記 append 到 customer_orders.notes，每個標記獨立一行、以 [ 開頭，例：
//   [轉入 (部分, 經總倉) ← 訂單 #36612 (GB20260522-C000325-TF0054)] 2026-07-21 08:10:39
//   [追加轉入 (空中轉) ← 訂單 #123 (GB...)] 2026-07-21 08:10:39 / 原因
//   [轉出 → 訂單 #456 (GB...)] / [全部轉出 → ...] / [部分轉出 → ...] / [部分追加 → ...]
// 這些是內部轉單流程訊息，客人拿到的取貨單不該出現 —— 列印前整行剔除。
const TRANSFER_MARKER_LINE = /^\s*\[(?:追加轉入|轉入|全部轉出|部分轉出|部分追加|轉出)[^\]]*\]/;

export function stripTransferNotes(notes: string | null | undefined): string | null {
  if (!notes) return null;
  const kept = notes
    .split("\n")
    .filter((line) => !TRANSFER_MARKER_LINE.test(line))
    .join("\n")
    .trim();
  return kept || null;
}
