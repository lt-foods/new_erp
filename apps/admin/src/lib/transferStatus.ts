// ============================================================
// 轉貨單 (transfers.status) 中文 label 中央定義
//
// Single source of truth — 對齊 wms/transfers 與 hq/inbox 既有用字。
// 新增 status 時同步 supabase migration 的 CHECK constraint。
// ============================================================

export const TRANSFER_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  confirmed: "已確認",
  shipped: "已出貨",
  received: "已收貨",
  cancelled: "已取消",
  closed: "已結案",
};

/** 取中文 label；未知 status 直接 fallback 原字串。 */
export function transferStatusLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return TRANSFER_STATUS_LABEL[s] ?? s;
}
