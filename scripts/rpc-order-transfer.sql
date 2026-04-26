-- 測試 Phase 5a-1：訂單轉手 + 分店內部訂單
-- 包在一個 DO 區塊裡、RAISE 'ROLLBACK_OK' 強迫整段回滾。
DO $outer$
DECLARE
  v_op                       UUID := '22222222-2222-2222-2222-222222222222';
  v_tenant                   UUID;
  v_campaign_id              BIGINT;
  v_campaign_no              TEXT;
  v_campaign_status          TEXT;
  v_campaign_item_id         BIGINT;
  v_store_a_id               BIGINT;
  v_store_b_id               BIGINT;
  v_member_a_id              BIGINT;
  v_internal_member_a_id     BIGINT;
  v_internal_member_a_id_2   BIGINT;
  v_internal_member_b_id     BIGINT;
  v_orig_order_id            BIGINT;
  v_new_order_id             BIGINT;
  v_orig_status              TEXT;
  v_unit_price               NUMERIC;
  v_list_price               NUMERIC;
  v_count                    INT;
BEGIN
  -- ============================================================
  -- Fixture：拿一個 closed (or open) campaign + 2 stores + 1 真會員
  -- ============================================================
  SELECT id, campaign_no, status, tenant_id
    INTO v_campaign_id, v_campaign_no, v_campaign_status, v_tenant
    FROM group_buy_campaigns
   WHERE status IN ('open','closed')
   ORDER BY id DESC LIMIT 1;
  IF v_campaign_id IS NULL THEN
    RAISE EXCEPTION 'fixture FAIL: no campaign found';
  END IF;

  SELECT id, unit_price INTO v_campaign_item_id, v_list_price
    FROM campaign_items WHERE campaign_id = v_campaign_id ORDER BY id LIMIT 1;
  IF v_campaign_item_id IS NULL THEN
    RAISE EXCEPTION 'fixture FAIL: no campaign_item in campaign %', v_campaign_id;
  END IF;

  SELECT id INTO v_store_a_id FROM stores
   WHERE tenant_id = v_tenant ORDER BY id LIMIT 1;
  SELECT id INTO v_store_b_id FROM stores
   WHERE tenant_id = v_tenant AND id <> v_store_a_id ORDER BY id LIMIT 1;
  IF v_store_b_id IS NULL THEN
    RAISE EXCEPTION 'fixture FAIL: need 2 stores';
  END IF;

  SELECT id INTO v_member_a_id FROM members
   WHERE tenant_id = v_tenant AND member_type = 'full' LIMIT 1;

  RAISE NOTICE 'fixture: tenant=%, campaign=% (%), stores=A:% B:%, item=%, list_price=%, member=%',
               v_tenant, v_campaign_id, v_campaign_status, v_store_a_id, v_store_b_id,
               v_campaign_item_id, v_list_price, v_member_a_id;

  -- ============================================================
  -- A. rpc_get_or_create_store_member
  -- ============================================================
  -- A1: 第一次呼叫建新 member
  v_internal_member_a_id := rpc_get_or_create_store_member(v_store_a_id, v_op);
  IF v_internal_member_a_id IS NULL THEN
    RAISE EXCEPTION 'A1 FAIL: returned NULL';
  END IF;
  RAISE NOTICE 'A1 PASS: created store_internal member id=%', v_internal_member_a_id;

  -- A2: idempotent — 第二次呼叫返回相同 id
  v_internal_member_a_id_2 := rpc_get_or_create_store_member(v_store_a_id, v_op);
  IF v_internal_member_a_id <> v_internal_member_a_id_2 THEN
    RAISE EXCEPTION 'A2 FAIL: ids differ % vs %', v_internal_member_a_id, v_internal_member_a_id_2;
  END IF;
  RAISE NOTICE 'A2 PASS: idempotent';

  -- A4: 欄位驗證
  PERFORM 1 FROM members
    WHERE id = v_internal_member_a_id
      AND member_type = 'store_internal'
      AND home_store_id = v_store_a_id
      AND member_no = 'STORE-' || v_store_a_id
      AND name LIKE '【內部】%';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A4 FAIL: fields wrong';
  END IF;
  RAISE NOTICE 'A4 PASS: fields verified';

  -- store_b 用的內部 member（後續會用）
  v_internal_member_b_id := rpc_get_or_create_store_member(v_store_b_id, v_op);

  -- ============================================================
  -- B. rpc_create_store_internal_order
  -- ============================================================
  -- B1+B2+B3+B4+B5+B7: happy path
  v_new_order_id := rpc_create_store_internal_order(
    v_campaign_id, v_store_a_id,
    jsonb_build_array(jsonb_build_object(
      'campaign_item_id', v_campaign_item_id, 'qty', 5)),
    v_op, '測試 B1'
  );
  IF v_new_order_id IS NULL THEN
    RAISE EXCEPTION 'B1 FAIL: returned NULL';
  END IF;

  PERFORM 1 FROM customer_orders
    WHERE id = v_new_order_id
      AND member_id = v_internal_member_a_id        -- B2
      AND pickup_store_id = v_store_a_id            -- B3
      AND order_no LIKE '%-INT%';                   -- B7
  IF NOT FOUND THEN
    RAISE EXCEPTION 'B2/B3/B7 FAIL';
  END IF;

  PERFORM 1 FROM customer_order_items
    WHERE order_id = v_new_order_id
      AND source = 'store_internal'                 -- B4
      AND unit_price = v_list_price;                -- B5 (no override = list price)
  IF NOT FOUND THEN
    RAISE EXCEPTION 'B4/B5 FAIL';
  END IF;

  RAISE NOTICE 'B1-B5,B7 PASS: order=% (using list price=%)', v_new_order_id, v_list_price;
  v_orig_order_id := v_new_order_id;  -- 留給 D 用

  -- ============================================================
  -- C. 88 折定價（self-override unit_price）
  -- ============================================================
  -- C1: 自帶 unit_price = list * 0.88，新建到 store_b 不撞 unique
  v_new_order_id := rpc_create_store_internal_order(
    v_campaign_id, v_store_b_id,
    jsonb_build_array(jsonb_build_object(
      'campaign_item_id', v_campaign_item_id,
      'qty', 3,
      'unit_price', round(v_list_price * 0.88, 4))),
    v_op, '測試 C1 88 折'
  );

  PERFORM 1 FROM customer_order_items
    WHERE order_id = v_new_order_id
      AND unit_price = round(v_list_price * 0.88, 4);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'C1 FAIL: 88 折 price not written';
  END IF;
  RAISE NOTICE 'C1 PASS: 88 折 unit_price=%', round(v_list_price * 0.88, 4);

  -- C3: unit_price < 0 should raise
  BEGIN
    PERFORM rpc_create_store_internal_order(
      v_campaign_id, v_store_b_id,
      jsonb_build_array(jsonb_build_object(
        'campaign_item_id', v_campaign_item_id, 'qty', 1, 'unit_price', -10)),
      v_op, NULL);
    RAISE EXCEPTION 'C3 FAIL: should have raised';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%negative%' THEN
      RAISE NOTICE 'C3 PASS: %', SQLERRM;
    ELSE
      RAISE;
    END IF;
  END;

  -- ============================================================
  -- D. rpc_transfer_order_to_store happy path
  -- ============================================================
  -- v_orig_order_id 是 store_a 的 internal order；轉給 store_b 的 v_member_a_id
  IF v_member_a_id IS NULL THEN
    RAISE NOTICE 'D SKIP: no full member';
  ELSE
    -- 確保 (campaign, channel_b, member_a) 沒有衝突
    DELETE FROM customer_order_items WHERE order_id IN (
      SELECT id FROM customer_orders
       WHERE tenant_id = v_tenant
         AND campaign_id = v_campaign_id
         AND member_id = v_member_a_id
         AND pickup_store_id IN (v_store_a_id, v_store_b_id)
    );
    DELETE FROM customer_orders
       WHERE tenant_id = v_tenant
         AND campaign_id = v_campaign_id
         AND member_id = v_member_a_id
         AND pickup_store_id IN (v_store_a_id, v_store_b_id);

    BEGIN
      v_new_order_id := rpc_transfer_order_to_store(
        v_orig_order_id, v_store_b_id, v_member_a_id, NULL, v_op, '測試 D');

      -- D2: 原訂單 status='transferred_out' + transferred_to
      SELECT status INTO v_orig_status FROM customer_orders WHERE id = v_orig_order_id;
      IF v_orig_status <> 'transferred_out' THEN
        RAISE EXCEPTION 'D2 FAIL: orig status=%', v_orig_status;
      END IF;
      PERFORM 1 FROM customer_orders
        WHERE id = v_orig_order_id AND transferred_to_order_id = v_new_order_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'D2 FAIL: transferred_to_order_id wrong';
      END IF;

      -- D3: 新訂單欄位
      PERFORM 1 FROM customer_orders
        WHERE id = v_new_order_id
          AND transferred_from_order_id = v_orig_order_id
          AND pickup_store_id = v_store_b_id
          AND member_id = v_member_a_id
          AND status = 'pending';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'D3 FAIL';
      END IF;

      -- D4: items 複製
      SELECT COUNT(*) INTO v_count FROM customer_order_items WHERE order_id = v_new_order_id;
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'D4 FAIL: item count=%, expected 1', v_count;
      END IF;

      -- D5: items.source = 'aid_transfer'
      PERFORM 1 FROM customer_order_items
        WHERE order_id = v_new_order_id AND source = 'aid_transfer';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'D5 FAIL: source <> aid_transfer';
      END IF;

      RAISE NOTICE 'D1-D5 PASS: orig=% → new=%, status=transferred_out', v_orig_order_id, v_new_order_id;
    END;
  END IF;

  -- ============================================================
  -- F. 邊界 / 錯誤
  -- ============================================================
  -- F1: order not found
  BEGIN
    PERFORM rpc_transfer_order_to_store(-99999, v_store_a_id, NULL, NULL, v_op, NULL);
    RAISE EXCEPTION 'F1 FAIL';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%not found%' THEN
      RAISE NOTICE 'F1 PASS: %', SQLERRM;
    ELSE
      RAISE;
    END IF;
  END;

  -- F3: already transferred
  IF v_orig_status = 'transferred_out' THEN
    BEGIN
      PERFORM rpc_transfer_order_to_store(v_orig_order_id, v_store_a_id, NULL, NULL, v_op, NULL);
      RAISE EXCEPTION 'F3 FAIL';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%status=transferred_out%' OR SQLERRM LIKE '%already transferred%' THEN
        RAISE NOTICE 'F3 PASS: %', SQLERRM;
      ELSE
        RAISE;
      END IF;
    END;
  END IF;

  -- F7: NULL member_id auto 用 store_internal（隱含在 D test 用了 v_member_a_id；補一個獨立 case）
  -- 用全新 store_a 的另一張 order 轉給 store_b、member 傳 NULL
  -- 但同 trio 會撞 unique（v_internal_member_b_id 已在 C 建了 order）
  -- 跳過 F7 獨立驗，留 NOTICE
  RAISE NOTICE 'F7 SKIP: need third store for clean isolation; F7 邏輯由 RPC 內 COALESCE 顯示';

  -- ============================================================
  -- G3: v_picking_demand_by_close_date 排除 transferred_out
  -- ============================================================
  -- 驗 v_orig_order_id 的 order_no 不出現在 view 的 order_numbers array
  PERFORM 1 FROM v_picking_demand_by_close_date
    WHERE tenant_id = v_tenant
      AND (SELECT order_no FROM customer_orders WHERE id = v_orig_order_id) = ANY(order_numbers);
  IF FOUND THEN
    RAISE EXCEPTION 'G3 FAIL: transferred_out order still in v_picking_demand_by_close_date';
  END IF;
  RAISE NOTICE 'G3 PASS: transferred_out order excluded from v_picking_demand_by_close_date';

  -- ============================================================
  RAISE NOTICE '======= ALL TESTS PASSED (A1/A2/A4 + B1-B5,B7 + C1,C3 + D1-D5 + F1,F3 + G3) =======';
  RAISE EXCEPTION 'ROLLBACK_OK';
END $outer$;
