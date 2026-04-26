-- ============================================================
-- Phase 5c step 3 — partial 訂單轉出
--
-- 給互助板 offer / request 用：依 qty 拆單，原單剩多少留下、轉出 qty 開新單
--
-- 既有 rpc_transfer_order_to_store 是「整單轉出」(5b-1 棄單按鈕)、本 PR 不動
-- 新 rpc_transfer_order_partial 是「指定 sku + qty 部分轉出」
--
-- 規則：
--   - p_items: [{sku_id BIGINT, qty NUMERIC}]
--   - 對每個 item：在 source 找對應 sku、qty <= source 的 active item.qty
--       - 等於：source item status='cancelled' (qty 保留稽核、CHECK qty > 0 不能設 0)
--       - 小於：source item qty -= 轉出 qty
--   - 新單 INSERT items at p_items.qty (source='aid_transfer')
--   - 若 source 所有 active items qty 都歸 0 / 全 cancelled → status='transferred_out' + transferred_to
--   - 否則 source 保持 pending、notes 加註轉出
--   - 不接受 source items 已 reserved (reserved_movement_id NOT NULL) — RAISE，呼叫端應先解 allocation
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_transfer_order_partial(
  p_order_id              BIGINT,
  p_to_pickup_store_id    BIGINT,
  p_to_member_id          BIGINT,
  p_to_channel_id         BIGINT,
  p_operator              UUID,
  p_reason                TEXT,
  p_items                 JSONB
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_orig             customer_orders%ROWTYPE;
  v_tenant_id        UUID;
  v_to_member_id     BIGINT;
  v_to_channel_id    BIGINT;
  v_new_order_id     BIGINT;
  v_new_order_no     TEXT;
  v_seq              INT;
  v_campaign_no      TEXT;
  v_p_item           JSONB;
  v_p_sku_id         BIGINT;
  v_p_qty            NUMERIC;
  v_src_item_id      BIGINT;
  v_src_item_qty     NUMERIC;
  v_src_item_ci      BIGINT;
  v_src_item_price   NUMERIC;
  v_src_item_reserved BIGINT;
  v_remaining_count  INT;
  v_now              TIMESTAMPTZ := NOW();
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  IF v_orig.status NOT IN ('pending','confirmed','reserved') THEN
    RAISE EXCEPTION 'order % status=%, only pending/confirmed/reserved can be transferred',
                    p_order_id, v_orig.status;
  END IF;
  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'order % already transferred to order %',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_store % not in tenant', p_to_pickup_store_id;
  END IF;

  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not in tenant', v_to_member_id;
  END IF;

  v_to_channel_id := p_to_channel_id;
  IF v_to_channel_id IS NULL THEN
    SELECT id INTO v_to_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id AND home_store_id = p_to_pickup_store_id
     LIMIT 1;
    IF v_to_channel_id IS NULL THEN
      SELECT id INTO v_to_channel_id
        FROM line_channels
       WHERE tenant_id = v_tenant_id
       LIMIT 1;
    END IF;
  END IF;
  IF v_to_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for receiving store';
  END IF;

  -- UNIQUE (tenant, campaign, channel, member) — 接收方已有同 trio 訂單時擋下
  PERFORM 1 FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id;
  IF FOUND THEN
    RAISE EXCEPTION 'receiver already has order in (campaign=%, channel=%, member=%)',
                    v_orig.campaign_id, v_to_channel_id, v_to_member_id;
  END IF;

  -- 產生新 order_no
  SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
  SELECT COUNT(*) + 1 INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_tenant_id AND campaign_id = v_orig.campaign_id;
  v_new_order_no := v_campaign_no || '-TF' || lpad(v_seq::text, 4, '0');

  -- 建空殼新單
  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id,
    nickname_snapshot, pickup_store_id, status, notes,
    transferred_from_order_id,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
    v_orig.nickname_snapshot, p_to_pickup_store_id, 'pending',
    COALESCE(p_reason, '') ||
      E'\n[轉入 (部分) ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
      to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
    p_order_id,
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_new_order_id;

  -- 處理每個轉出 item
  FOR v_p_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_p_sku_id := (v_p_item ->> 'sku_id')::BIGINT;
    v_p_qty    := (v_p_item ->> 'qty')::NUMERIC;
    IF v_p_qty IS NULL OR v_p_qty <= 0 THEN
      RAISE EXCEPTION 'p_items: qty must be > 0';
    END IF;

    -- 找 source item (active、未取消、qty > 0)
    SELECT id, qty, campaign_item_id, unit_price, reserved_movement_id
      INTO v_src_item_id, v_src_item_qty, v_src_item_ci, v_src_item_price, v_src_item_reserved
      FROM customer_order_items
     WHERE order_id = p_order_id
       AND sku_id   = v_p_sku_id
       AND status   != 'cancelled'
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
    IF v_src_item_id IS NULL THEN
      RAISE EXCEPTION 'sku % not in order % (or already cancelled)', v_p_sku_id, p_order_id;
    END IF;
    IF v_src_item_reserved IS NOT NULL THEN
      RAISE EXCEPTION 'sku % already allocated (reserved_movement_id=%); release first',
                      v_p_sku_id, v_src_item_reserved;
    END IF;
    IF v_src_item_qty < v_p_qty THEN
      RAISE EXCEPTION 'sku % insufficient qty: source=%, requested=%',
                      v_p_sku_id, v_src_item_qty, v_p_qty;
    END IF;

    -- 若等於 → cancel source item；小於 → 減量
    IF v_src_item_qty = v_p_qty THEN
      UPDATE customer_order_items
         SET status = 'cancelled', updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    ELSE
      UPDATE customer_order_items
         SET qty = qty - v_p_qty, updated_by = p_operator, updated_at = v_now
       WHERE id = v_src_item_id;
    END IF;

    -- 寫新單 item
    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_new_order_id, v_src_item_ci, v_p_sku_id, v_p_qty, v_src_item_price,
      'pending', 'aid_transfer', p_operator, p_operator
    );
  END LOOP;

  -- source 是否還有 active items？
  SELECT COUNT(*) INTO v_remaining_count
    FROM customer_order_items
   WHERE order_id = p_order_id AND status != 'cancelled';

  IF v_remaining_count = 0 THEN
    -- 全部 cancelled → 視同整單轉出
    UPDATE customer_orders
       SET status = 'transferred_out',
           transferred_to_order_id = v_new_order_id,
           notes = COALESCE(notes, '') ||
                   E'\n[全部轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  ELSE
    -- 部分轉出、source 保留
    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[部分轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                   to_char(v_now, 'YYYY-MM-DD HH24:MI:SS'),
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  RETURN v_new_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB) TO authenticated;

COMMENT ON FUNCTION rpc_transfer_order_partial IS
  'Phase 5c step 3：依 sku + qty 部分轉出訂單；source qty 全 0 → transferred_out、否則保留 pending';
