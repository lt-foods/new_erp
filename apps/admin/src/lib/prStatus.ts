// ============================================================
// 請購單 (purchase_requests.status / review_status) 中央定義
//
// Single source of truth — 所有 admin 端 status 中文 label
// 都從這裡 import。新增 status 時：
//   1. 加到 PR_STATUSES tuple
//   2. 加到 PR_STATUS_LABEL
//   3. 同步 supabase migration 的 CHECK constraint
//
// 命名術語：
//   PR = Purchase Request = 請購單（內部需求單）
//   PO = Purchase Order   = 採購單（對供應商正式下訂，見 poStatus.ts）
// ============================================================

export const PR_STATUSES = [
  "draft",
  "submitted",
  "partially_ordered",
  "fully_ordered",
  "cancelled",
] as const;

export type PRStatus = (typeof PR_STATUSES)[number];

export const PR_STATUS_LABEL: Record<PRStatus, string> = {
  draft:             "草稿",
  submitted:         "已送審",
  partially_ordered: "部分轉單",
  fully_ordered:     "全部轉單",
  cancelled:         "已取消",
};

export const PR_REVIEW_STATUSES = [
  "pending_review",
  "approved",
  "rejected",
] as const;

export type PRReviewStatus = (typeof PR_REVIEW_STATUSES)[number];

export const PR_REVIEW_LABEL: Record<PRReviewStatus, string> = {
  pending_review: "待審核",
  approved:       "已通過",
  rejected:       "已退回",
};

/** 取中文 label；未知 status 直接 fallback 原字串。 */
export function prStatusLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return PR_STATUS_LABEL[s as PRStatus] ?? s;
}

export function prReviewLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return PR_REVIEW_LABEL[s as PRReviewStatus] ?? s;
}

/** 顯示用的單據名稱（中文）。 */
export const PR_TERM_ZH = "請購單";
