-- §2.4-2.8 rejection cases — collect results into a temp table so we can SELECT them
BEGIN;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000099","tenant_id":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

CREATE TEMP TABLE _r (scn TEXT, verdict TEXT, msg TEXT);

INSERT INTO line_channels (tenant_id, code, name, home_store_id, created_by, updated_by)
VALUES ('00000000-0000-0000-0000-000000000001', 'TEST_CH2', 'rej_ch', 1,
        '00000000-0000-0000-0000-000000000099', '00000000-0000-0000-0000-000000000099');
INSERT INTO line_channels (tenant_id, code, name, home_store_id, created_by, updated_by)
VALUES ('00000000-0000-0000-0000-000000000001', 'TEST_CH3', 'ch3', 1,
        '00000000-0000-0000-0000-000000000099', '00000000-0000-0000-0000-000000000099');

-- 2.5 qty<=0
DO $$
DECLARE v_msg TEXT;
BEGIN
  BEGIN
    PERFORM rpc_create_customer_orders(
      3,(SELECT id FROM line_channels WHERE code='TEST_CH2'),
      jsonb_build_array(jsonb_build_object('member_id',1,'pickup_store_id',1,
        'items',jsonb_build_array(jsonb_build_object('campaign_item_id',2,'qty',0)))));
    INSERT INTO _r VALUES ('2.5 qty=0','FAIL','no error raised');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _r VALUES ('2.5 qty=0', CASE WHEN v_msg LIKE '%qty must be > 0%' THEN 'PASS' ELSE 'FAIL' END, v_msg);
  END;
END $$;

-- 2.6 closed campaign (toggle status, test, revert)
UPDATE group_buy_campaigns SET status='closed' WHERE id=3;
DO $$
DECLARE v_msg TEXT;
BEGIN
  BEGIN
    PERFORM rpc_create_customer_orders(
      3,(SELECT id FROM line_channels WHERE code='TEST_CH2'),
      jsonb_build_array(jsonb_build_object('member_id',1,'pickup_store_id',1,
        'items',jsonb_build_array(jsonb_build_object('campaign_item_id',2,'qty',1)))));
    INSERT INTO _r VALUES ('2.6 closed','FAIL','no error raised');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _r VALUES ('2.6 closed', CASE WHEN v_msg LIKE '%only open campaigns%' THEN 'PASS' ELSE 'FAIL' END, v_msg);
  END;
END $$;
UPDATE group_buy_campaigns SET status='open' WHERE id=3;

-- 2.4 cross-tenant member
INSERT INTO members (tenant_id, member_no, phone_hash, name, status, created_by, updated_by)
VALUES ('00000000-0000-0000-0000-000000000099','OTHER1','h','other','active',
        '00000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000099');
DO $$
DECLARE v_msg TEXT; v_other BIGINT;
BEGIN
  SELECT id INTO v_other FROM members WHERE member_no='OTHER1';
  BEGIN
    PERFORM rpc_create_customer_orders(
      3,(SELECT id FROM line_channels WHERE code='TEST_CH2'),
      jsonb_build_array(jsonb_build_object('member_id',v_other,'pickup_store_id',1,
        'items',jsonb_build_array(jsonb_build_object('campaign_item_id',2,'qty',1)))));
    INSERT INTO _r VALUES ('2.4 cross-tenant','FAIL','no error');
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    INSERT INTO _r VALUES ('2.4 cross-tenant', CASE WHEN v_msg LIKE '%not in tenant%' THEN 'PASS' ELSE 'FAIL' END, v_msg);
  END;
END $$;

-- 2.8 cross-channel same nickname (different members, both succeed)
DO $$
DECLARE v_a BIGINT; v_b BIGINT; v_count BIGINT;
BEGIN
  v_a := rpc_bind_line_alias((SELECT id FROM line_channels WHERE code='TEST_CH2'), '小美', 1);
  v_b := rpc_bind_line_alias((SELECT id FROM line_channels WHERE code='TEST_CH3'), '小美', 4);
  SELECT count(*) INTO v_count FROM customer_line_aliases
   WHERE nickname='小美' AND channel_id IN (SELECT id FROM line_channels WHERE code IN ('TEST_CH2','TEST_CH3'));
  INSERT INTO _r VALUES ('2.8 cross-channel', CASE WHEN v_count=2 THEN 'PASS' ELSE 'FAIL' END,
    format('count=%s alias_a=%s alias_b=%s', v_count, v_a, v_b));
END $$;

-- 2.7 re-bind same channel+nickname → same row, member_id updated
DO $$
DECLARE v_a BIGINT; v_b BIGINT; v_member BIGINT;
BEGIN
  v_a := rpc_bind_line_alias((SELECT id FROM line_channels WHERE code='TEST_CH2'), '阿明', 1);
  v_b := rpc_bind_line_alias((SELECT id FROM line_channels WHERE code='TEST_CH2'), '阿明', 4);
  SELECT member_id INTO v_member FROM customer_line_aliases WHERE id=v_a;
  INSERT INTO _r VALUES ('2.7 re-bind', CASE WHEN v_a=v_b AND v_member=4 THEN 'PASS' ELSE 'FAIL' END,
    format('a=%s b=%s member=%s', v_a, v_b, v_member));
END $$;

SELECT * FROM _r ORDER BY scn;
ROLLBACK;
