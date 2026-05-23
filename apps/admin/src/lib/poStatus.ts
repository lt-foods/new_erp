// ============================================================
// 採購單 (purchase_orders.status) 中央定義
//
// Single source of truth — 所有 admin 端 status 中文 label
// 都從這裡 import。新增 status 時：
//   1. 加到 PO_STATUSES tuple
//   2. 加到 PO_STATUS_LABEL
//   3. 同步 supabase migration 的 CHECK constraint
//
// 命名術語：
//   PO = Purchase Order   = 採購單（對供應商正式下訂）
//   PR = Purchase Request = 請購單（內部需求單，見 prStatus.ts）
// ============================================================

export const PO_STATUSES = [
  "draft",
  "sent",
  "partially_received",
  "fully_received",
  "closed",
  "cancelled",
] as const;

export type POStatus = (typeof PO_STATUSES)[number];

export const PO_STATUS_LABEL: Record<POStatus, string> = {
  draft:              "草稿",
  sent:               "已發送",
  partially_received: "部分到貨",
  fully_received:     "全部到貨",
  closed:             "已結案",
  cancelled:          "已取消",
};

/** 取中文 label；未知 status 直接 fallback 原字串。 */
export function poStatusLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return PO_STATUS_LABEL[s as POStatus] ?? s;
}

/** 顯示用的單據名稱（中文）。 */
export const PO_TERM_ZH = "採購單";
