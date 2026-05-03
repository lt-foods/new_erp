-- ============================================================
-- group_buy_campaigns 加 display_order 欄
--
-- 原因：候選週曆 (community-candidates calendar) 拖拉卡片時，
-- 應該同步調整對應 campaign 在同日的顯示順序。candidate 已有
-- scheduled_sort_order，但 campaign 端沒對應欄位，導致 /campaigns
-- 週曆/月曆排序與候選週曆不一致。
--
-- 約定：display_order 由 candidate calendar 的 persistDay 同步寫入；
-- campaigns 列表/月曆/週曆 ORDER BY display_order ASC, start_at ASC。
-- ============================================================

ALTER TABLE group_buy_campaigns
  ADD COLUMN IF NOT EXISTS display_order INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN group_buy_campaigns.display_order IS
  '同日內顯示順序（由 community_product_candidates 拖拉週曆同步寫入）';

CREATE INDEX IF NOT EXISTS idx_gbc_date_order
  ON group_buy_campaigns(tenant_id, (DATE(start_at AT TIME ZONE 'Asia/Taipei')), display_order);
