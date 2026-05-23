-- ============================================================
-- Stage 3 — 店家可改待確認訂單數量
--
-- 1. 放寬 rpc_create_customer_orders:從 status='open' 放寬為 IN ('open','closed')
--    讓 HQ/店家在 closed 緩衝期可補加單(顧客 App 已隱藏不會撞到)
-- 2. 新增 rpc_update_order_item_qty:店家可改自家 pending 訂單 qty
--    沿用 _check_order_edit_perm + customer_order_audit_log pattern
--    (對齊 20260605000002_rpc_edit_order_price_and_notes.sql)
--
-- 設計:
--   - 訂單狀態必須是 pending(被 PR 鎖定變 confirmed 後就擋下,Stage 4 自動觸發)
--   - qty > 0(配合 schema CHECK,刪品項另走 RPC,不在本 scope)
--   - no-op(新值=舊值)不寫 audit log
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 放寬加單閘:rpc_create_customer_orders status='open' → IN ('open','closed')
-- ----------------------------------------------------------------
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
BEGIN
  SELECT status, campaign_no INTO v_status, v_campaign_no
    FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  -- 放寬:open(顧客可下單)+ closed(已隱藏但 HQ/店家補單緩衝期)
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

    PERFORM 1 FROM members WHERE id = v_member_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', v_member_id; END IF;
    PERFORM 1 FROM stores WHERE id = v_pickup_store AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', v_pickup_store; END IF;

    SELECT id INTO v_order_id FROM customer_orders
     WHERE tenant_id = v_tenant
       AND campaign_id = p_campaign_id
       AND channel_id  = p_channel_id
       AND member_id   = v_member_id;

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

COMMENT ON FUNCTION public.rpc_create_customer_orders IS
  '小幫手代客 key 訂單。campaign 必須 status IN (open, closed);'
  'closed 是 HQ/店家補加單緩衝期(顧客 App 已隱藏不會撞到)。'
  '合併規則:同 (campaign, channel, member) → UPSERT,items 累加同 campaign_item_id';

-- ----------------------------------------------------------------
-- 2. rpc_update_order_item_qty:店家可改自家 pending 訂單 qty
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_update_order_item_qty(
  p_order_id BIGINT,
  p_item_id  BIGINT,
  p_new_qty  NUMERIC,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_order_items;
BEGIN
  -- 1. 權限檢查(沿用 helper:HQ 全部 / 店家限自家 pickup_store_id)
  v_order := _check_order_edit_perm(p_order_id);

  -- 2. 訂單狀態閘:僅 pending(被 PR 鎖定變 confirmed 後就擋下)
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION '訂單狀態為 %,僅 待確認 訂單可改數量', v_order.status;
  END IF;

  -- 3. 輸入驗證(配合 schema CHECK qty > 0,刪品項另走 RPC)
  IF p_new_qty IS NULL OR p_new_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be > 0';
  END IF;

  SELECT qty INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  -- 4. no-op 短路
  IF v_old = p_new_qty THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET qty        = p_new_qty,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  -- 5. 稽核
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'qty',
     to_jsonb(v_old), to_jsonb(p_new_qty), p_reason, p_operator);

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_order_item_qty(BIGINT, BIGINT, NUMERIC, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_order_item_qty IS
  '店家可改自家 pending 訂單品項 qty。'
  'HQ 全部 / 店家限自家 pickup_store_id;訂單狀態必須是 pending;qty 必須 > 0;'
  '寫 customer_order_audit_log,no-op 不寫';
