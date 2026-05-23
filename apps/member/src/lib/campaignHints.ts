import type { CampaignSummary } from "@/components/CampaignCard";

/**
 * 列表頁 → 詳情頁的「預填快取」。
 *
 * 當 /shop、/shop/flash、/shop/food-train 抓到 campaign 清單時把
 * 摘要塞進來；詳情頁 mount 時先用這份 hint 立刻畫出標題 / 封面 /
 * 倒數 / 起跳價，避免空白等 API。完整資料抓回來再蓋掉。
 *
 * 純記憶體 Map：SPA 導航期間都活著；hard reload 後失效是 OK 的
 * (那時用戶不是從列表進來，本來就沒上下文可預填)。
 */
const hints = new Map<number, CampaignSummary>();

export function setCampaignHints(campaigns: CampaignSummary[]): void {
  for (const c of campaigns) hints.set(c.id, c);
}

export function getCampaignHint(id: number): CampaignSummary | undefined {
  return hints.get(id);
}
