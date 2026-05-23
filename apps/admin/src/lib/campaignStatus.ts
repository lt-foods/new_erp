// ============================================================
// 開團 (group_buy_campaigns.status) 中央定義
//
// Single source of truth — 所有 admin 端 status 中文 label / badge
// 都從這裡 import。新增 status 時：
//   1. 加到 CAMPAIGN_STATUSES tuple
//   2. 加到 CAMPAIGN_STATUS_LABEL
//   3. 加到 CAMPAIGN_STATUS_BADGE
//   4. 同步 supabase migration 的 CHECK constraint
//
// 狀態語意（簡述，完整流程見 docs）：
//   draft     - 草稿，App 不顯示
//   open      - 開團中，App 顯示，顧客可下單
//   closed    - 已收單，App 隱藏，HQ/店家仍可補加單/改 qty
//   locked    - 已鎖定，請購單已建，所有訂單自動 confirmed，不可加單/改 qty
//   ordered   - 已下訂，採購單已發給供應商（目前無 RPC 自動推進）
//   receiving - 到貨中（目前無 RPC 自動推進）
//   ready     - 可取貨（目前無 RPC 自動推進）
//   completed - 已完成（rpc_finalize_campaign）
//   cancelled - 已取消，任何階段都可手動取消
// ============================================================

export const CAMPAIGN_STATUSES = [
  "draft",
  "open",
  "closed",
  "locked",
  "ordered",
  "receiving",
  "ready",
  "completed",
  "cancelled",
] as const;

export type CampaignStatus = (typeof CAMPAIGN_STATUSES)[number];

export const CAMPAIGN_STATUS_LABEL: Record<CampaignStatus, string> = {
  draft:     "草稿",
  open:      "開團中",
  closed:    "已收單",
  locked:    "已鎖定",
  ordered:   "已下訂",
  receiving: "到貨中",
  ready:     "可取貨",
  completed: "已完成",
  cancelled: "已取消",
};

export const CAMPAIGN_STATUS_BADGE: Record<CampaignStatus, string> = {
  draft:     "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  open:      "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300",
  closed:    "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  locked:    "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300",
  ordered:   "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  receiving: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  ready:     "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

/** 取中文 label；未知 status 直接 fallback 原字串。 */
export function campaignStatusLabel(s: string | null | undefined): string {
  if (!s) return "—";
  return CAMPAIGN_STATUS_LABEL[s as CampaignStatus] ?? s;
}

/** 取 badge className；未知 status 用 zinc fallback。 */
export function campaignStatusBadge(s: string | null | undefined): string {
  if (!s) return CAMPAIGN_STATUS_BADGE.draft;
  return CAMPAIGN_STATUS_BADGE[s as CampaignStatus] ?? CAMPAIGN_STATUS_BADGE.draft;
}
