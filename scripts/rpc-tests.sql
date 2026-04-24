-- §2 RPC tests; wrap in BEGIN/ROLLBACK so dev DB stays clean
BEGIN;

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000099","tenant_id":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

-- Use the dummy uid as auth.uid() proxy: insert with explicit user
INSERT INTO line_channels (tenant_id, code, name, home_store_id, created_by, updated_by)
VALUES ('00000000-0000-0000-0000-000000000001', 'TEST_CH', '測試頻道', 1,
        '00000000-0000-0000-0000-000000000099', '00000000-0000-0000-0000-000000000099');

-- 2.1 search_members
SELECT '2.1' AS scn, count(*) AS rows_returned FROM rpc_search_members('', 5);
SELECT '2.1b name=Alex' AS scn, * FROM rpc_search_members('Alex', 5);
SELECT '2.1c phone=1' AS scn, * FROM rpc_search_members('1', 5);

-- 2.2 search_skus_for_campaign
SELECT '2.2 campaign=3' AS scn, * FROM rpc_search_skus_for_campaign(3, '', 10);
SELECT '2.2b empty for campaign=1 (no items? or 1 item)' AS scn, count(*) FROM rpc_search_skus_for_campaign(1, '', 10);

-- 2.7 bind_alias new
SELECT '2.7 bind new' AS scn, rpc_bind_line_alias((SELECT id FROM line_channels WHERE code='TEST_CH'), '小美', 1) AS alias_id;
-- 2.7b re-bind to different member (member_id=4)
SELECT '2.7b re-bind' AS scn, rpc_bind_line_alias((SELECT id FROM line_channels WHERE code='TEST_CH'), '小美', 4) AS alias_id;
SELECT '2.7c after re-bind' AS scn, id, nickname, member_id FROM customer_line_aliases WHERE nickname='小美';

-- 2.3 create_customer_orders new
SELECT '2.3 create' AS scn, * FROM rpc_create_customer_orders(
  3,
  (SELECT id FROM line_channels WHERE code='TEST_CH'),
  jsonb_build_array(jsonb_build_object(
    'member_id', 1, 'nickname', '測試一號', 'pickup_store_id', 1,
    'items', jsonb_build_array(
      jsonb_build_object('campaign_item_id', 2, 'qty', 2),
      jsonb_build_object('campaign_item_id', 3, 'qty', 1)
    )
  ))
);
-- 2.3b merge same member
SELECT '2.3b merge' AS scn, * FROM rpc_create_customer_orders(
  3,
  (SELECT id FROM line_channels WHERE code='TEST_CH'),
  jsonb_build_array(jsonb_build_object(
    'member_id', 1, 'pickup_store_id', 1,
    'items', jsonb_build_array(
      jsonb_build_object('campaign_item_id', 2, 'qty', 5)
    )
  ))
);
SELECT '2.3c items after merge' AS scn, coi.order_id, coi.campaign_item_id, coi.qty, coi.unit_price FROM customer_order_items coi
 WHERE coi.order_id IN (SELECT id FROM customer_orders WHERE channel_id=(SELECT id FROM line_channels WHERE code='TEST_CH'))
 ORDER BY coi.campaign_item_id;

ROLLBACK;
