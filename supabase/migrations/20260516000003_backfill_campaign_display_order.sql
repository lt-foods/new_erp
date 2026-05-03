-- ============================================================
-- 回填 group_buy_campaigns.display_order
--
-- 既有 campaign 的 display_order 都是預設 0，導致同日 campaign 排序
-- 沒有跟 community_product_candidates 的 scheduled_sort_order 同步。
-- 從 campaign_no 'GB{YYYYMMDD}-C{padded candidate_id}' 推回 candidate，
-- 把 candidate.scheduled_sort_order 寫進 campaign.display_order。
-- ============================================================

UPDATE group_buy_campaigns gbc
   SET display_order = c.scheduled_sort_order
  FROM community_product_candidates c
 WHERE gbc.campaign_no ~ '^GB[0-9]{8}-C[0-9]{6}$'
   AND substring(gbc.campaign_no FROM 13 FOR 6)::bigint = c.id
   AND c.scheduled_sort_order IS NOT NULL
   AND c.tenant_id = gbc.tenant_id;
