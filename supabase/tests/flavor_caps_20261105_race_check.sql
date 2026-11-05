-- ============================================================================
-- flavor_caps_20261105_race_check.sql —— 兩條連線搶完後，花生已售必須剛好 1（本機臨時庫）
--   psql -v round=1 -f flavor_caps_20261105_race_check.sql
-- ============================================================================
\set QUIET 1
\pset tuples_only on
\pset format unaligned
SELECT 'SOLD ' || COALESCE(SUM(coi.qty)::int, 0)
  FROM group_buy_campaigns g
  JOIN campaign_items ci ON ci.campaign_id = g.id AND ci.sku_id = 13
  LEFT JOIN customer_order_items coi ON coi.campaign_item_id = ci.id AND coi.status NOT IN ('cancelled','expired')
 WHERE g.name = 'race-' || :'round';
