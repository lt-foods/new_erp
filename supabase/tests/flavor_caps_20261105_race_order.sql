-- ============================================================================
-- flavor_caps_20261105_race_order.sql —— 一條連線買一個花生（本機臨時庫）
--   psql -v round=1 -v member=21 -v path=mall -v hold=2 -f flavor_caps_20261105_race_order.sql
--   path=mall 走 rpc_place_member_order_guarded；path=admin 走 rpc_create_customer_orders_capped
--   hold：下單後交易再開幾秒才存檔，另一條連線這段時間要排隊
--   印出 RACE ok 或 RACE <錯誤訊息>
-- ============================================================================
\set QUIET 1
\pset tuples_only on
\pset format unaligned
SELECT set_config('request.jwt.claims',
  '{"tenant_id":"00000000-0000-0000-0000-000000000001","app_metadata":{"tenant_id":"00000000-0000-0000-0000-000000000001","role":"admin"}}', false) AS _cfg \gset
SELECT g.id AS cid, ci.id AS iid FROM group_buy_campaigns g JOIN campaign_items ci ON ci.campaign_id = g.id AND ci.sku_id = 13
 WHERE g.name = 'race-' || :'round' \gset
BEGIN;
CREATE FUNCTION pg_temp.go(p_path text, p_cid bigint, p_iid bigint, p_member bigint) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF p_path = 'mall' THEN
    PERFORM * FROM rpc_place_member_order_guarded('00000000-0000-0000-0000-000000000001', p_cid, 1, p_member, 1,
      jsonb_build_array(jsonb_build_object('campaign_item_id', p_iid, 'qty', 1)));
  ELSE
    PERFORM * FROM rpc_create_customer_orders_capped(p_cid, 1,
      jsonb_build_array(jsonb_build_object('member_id', p_member, 'pickup_store_id', 1, 'nickname', 'n',
        'items', jsonb_build_array(jsonb_build_object('campaign_item_id', p_iid, 'qty', 1)))));
  END IF;
  RETURN 'ok';
EXCEPTION WHEN raise_exception THEN RETURN SQLERRM; END $$;
SELECT 'RACE ' || pg_temp.go(:'path', :cid, :iid, :member);
SELECT pg_sleep(:hold)::text AS _s \gset
COMMIT;
