-- ============================================================================
-- flavor_caps_20261105_race_setup.sql —— 兩條連線搶最後一個花生（本機臨時庫）
-- 用法：
--   psql -v round=1 -f flavor_caps_20261105_race_setup.sql
--   同時開兩條連線各跑 flavor_caps_20261105_race_order.sql，參數見該檔檔頭
--   psql -v round=1 -f flavor_caps_20261105_race_check.sql
-- ============================================================================
\set ON_ERROR_STOP 1
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false);
SELECT rpc_create_campaign_from_product(
  p_name => 'race-' || :'round', p_end_at => now() + interval '3 day', p_pickup_deadline => NULL, p_product_id => 1,
  p_close_type => 'limited', p_sales_channel => 'main', p_total_cap_qty => NULL,
  p_item_caps => '[{"sku_id":11,"cap_qty":3},{"sku_id":12,"cap_qty":5},{"sku_id":13,"cap_qty":1}]');
