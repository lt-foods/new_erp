-- ============================================================
-- rpc_create_customer_orders 補回兩個被覆蓋掉的修法:
--   1. 排除 cancelled / expired / transferred_out 既有訂單
--      (原 20260605000013_rpc_create_customer_orders_skip_cancelled.sql)
--   2. 黑名單會員 (members.no_new_order = TRUE) 禁止建單 / 加單
--      (原 20260605000008_blacklist_block_new_order.sql)
--
-- 回歸原因:20260624000000_order_item_qty_edit.sql 為了放寬
--   campaign status 從 'open' → IN ('open','closed') 把 function 整個重寫,
--   不慎把上面兩個改動一起拿掉。
--
-- 使用者實例:GB20260522-C000330-0005 已取消後,同會員同活動同 channel
--   重新加單時,因為 SELECT 沒過濾 status,撈到舊的 cancelled 訂單
--   走 UPDATE branch,把新 items 加進取消的訂單裡。應該開新訂單。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_create_customer_orders(
  p_campaign_id BIGINT,
  p_channel_id  BIGINT,
  p_rows        JSONB
) RETURNS TABLE (out_order_id BIGINT, out_order_no TEXT, out_item_count INT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_status       TEXT;
  v_campaign_no  TEXT;
  v_row          JSONB;
  v_item         JSONB;
  v_member_id    BIGINT;
  v_pickup_store BIGINT;
  v_nickname     TEXT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_seq          INT;
  v_ci_id        BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
  v_ci_sku       BIGINT;
  v_existing_qty NUMERIC;
  v_count        INT;
  v_blacklisted  BOOLEAN;
  v_member_name  TEXT;
BEGIN
  SELECT status, campaign_no INTO v_status, v_campaign_no
    FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_status NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed campaigns accept manual entry',
                    p_campaign_id, v_status;
  END IF;

  PERFORM 1 FROM line_channels WHERE id = p_channel_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'channel % not in tenant', p_channel_id; END IF;

  IF p_rows IS NULL OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'p_rows is empty';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_member_id    := (v_row ->> 'member_id')::BIGINT;
    v_pickup_store := (v_row ->> 'pickup_store_id')::BIGINT;
    v_nickname     := v_row ->> 'nickname';

    IF v_member_id IS NULL THEN RAISE EXCEPTION 'member_id required'; END IF;
    IF v_pickup_store IS NULL THEN RAISE EXCEPTION 'pickup_store_id required'; END IF;

    SELECT no_new_order, COALESCE(name, member_no)
      INTO v_blacklisted, v_member_name
      FROM members
     WHERE id = v_member_id AND tenant_id = v_tenant;
    IF v_blacklisted IS NULL THEN
      RAISE EXCEPTION 'member % not in tenant', v_member_id;
    END IF;
    IF v_blacklisted THEN
      RAISE EXCEPTION '會員「%」已被列入黑名單，禁止建立 / 加單', v_member_name;
    END IF;

    PERFORM 1 FROM stores WHERE id = v_pickup_store AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', v_pickup_store; END IF;

    -- 找既有訂單時排除已 cancelled / expired / transferred_out
    -- (對齊 customer_orders_trio_kind_active_uniq partial UNIQUE 索引)
    SELECT id INTO v_order_id FROM customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id  = p_channel_id
       AND member_id   = v_member_id
       AND status NOT IN ('cancelled','expired','transferred_out');

    IF v_order_id IS NULL THEN
      SELECT COUNT(*) + 1 INTO v_seq FROM customer_orders
       WHERE tenant_id = v_tenant AND campaign_id = p_campaign_id;
      v_order_no := v_campaign_no || '-' || lpad(v_seq::text, 4, '0');

      INSERT INTO customer_orders (
        tenant_id, order_no, campaign_id, channel_id, member_id,
        nickname_snapshot, pickup_store_id, status, created_by, updated_by
      ) VALUES (
        v_tenant, v_order_no, p_campaign_id, p_channel_id, v_member_id,
        v_nickname, v_pickup_store, 'pending', v_user, v_user
      ) RETURNING id INTO v_order_id;
    ELSE
      UPDATE customer_orders SET
        nickname_snapshot = COALESCE(v_nickname, nickname_snapshot),
        pickup_store_id   = v_pickup_store,
        updated_by        = v_user
      WHERE id = v_order_id
      RETURNING order_no INTO v_order_no;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_row -> 'items')
    LOOP
      v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
      v_qty   := (v_item ->> 'qty')::NUMERIC;
      IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'qty must be > 0'; END IF;

      SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
        FROM campaign_items
       WHERE id = v_ci_id AND tenant_id = v_tenant AND campaign_id = p_campaign_id;
      IF v_ci_price IS NULL THEN
        RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
      END IF;

      SELECT coi.qty INTO v_existing_qty FROM customer_order_items coi
       WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;

      IF v_existing_qty IS NULL THEN
        INSERT INTO customer_order_items (
          tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
          status, source, created_by, updated_by
        ) VALUES (
          v_tenant, v_order_id, v_ci_id, v_ci_sku, v_qty, v_ci_price,
          'pending', 'manual', v_user, v_user
        );
      ELSE
        UPDATE customer_order_items coi SET
          qty        = v_existing_qty + v_qty,
          updated_by = v_user
        WHERE coi.order_id = v_order_id AND coi.campaign_item_id = v_ci_id;
      END IF;
    END LOOP;

    SELECT COUNT(*) INTO v_count FROM customer_order_items coi WHERE coi.order_id = v_order_id;
    out_order_id   := v_order_id;
    out_order_no   := v_order_no;
    out_item_count := v_count;
    RETURN NEXT;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_customer_orders TO authenticated;

COMMENT ON FUNCTION public.rpc_create_customer_orders IS
  '小幫手代客 key 訂單。campaign 必須 status IN (open, closed);'
  'closed 是 HQ/店家補加單緩衝期(顧客 App 已隱藏不會撞到)。'
  '黑名單會員 (members.no_new_order = TRUE) 禁止建單 / 加單。'
  '合併規則:同 (campaign, channel, member) 且 status 非 cancelled/expired/transferred_out '
  '→ UPSERT 累加 items;否則開新訂單。';
