-- ============================================================
-- rpc_create_offset_order：建立庫存抵減單（負數訂單）
-- rpc_cancel_offset_order：取消庫存抵減單
--
-- 業務情境：店裡已有庫存不想多訂，又不想取消顧客的訂單，
-- 但要讓採購聚合扣掉這部分。做法是門市建一張 order_kind='offset'
-- 的訂單、qty 為負，由 store_internal member 持有。
--
-- 與 rpc_create_store_internal_order 的差異：
--   - order_kind='offset'（vs 'normal'）
--   - qty 必須全為負（vs 必須為正）
--   - status 直接 'confirmed'（vs 'pending'，不需經過確認）
--   - notes 必填，會被加上「[庫存抵減單]」前綴
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_create_offset_order(
  p_campaign_id BIGINT,
  p_store_id    BIGINT,
  p_items       JSONB,         -- [{campaign_item_id, qty}], qty 必須 < 0
  p_reason      TEXT,
  p_operator    UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id    UUID;
  v_campaign_no  TEXT;
  v_campaign_st  TEXT;
  v_member_id    BIGINT;
  v_channel_id   BIGINT;
  v_seq          INT;
  v_order_no     TEXT;
  v_order_id     BIGINT;
  v_item         JSONB;
  v_ci_id        BIGINT;
  v_ci_sku       BIGINT;
  v_ci_price     NUMERIC;
  v_qty          NUMERIC;
BEGIN
  -- 必填驗證
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION '抵減原因 (p_reason) 必填';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  -- qty 全為負驗證
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) e
    WHERE (e->>'qty')::numeric >= 0
  ) THEN
    RAISE EXCEPTION '抵減單所有品項 qty 必須 < 0';
  END IF;

  -- campaign 驗證
  SELECT tenant_id, campaign_no, status
    INTO v_tenant_id, v_campaign_no, v_campaign_st
    FROM group_buy_campaigns WHERE id = p_campaign_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_campaign_st NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed accept offset order',
                    p_campaign_id, v_campaign_st;
  END IF;

  -- 取得 / 建立 store_internal member
  v_member_id := rpc_get_or_create_store_member(p_store_id, p_operator);

  -- 取該店任一 line_channel；無則 fallback 到 tenant 第一個
  SELECT id INTO v_channel_id
    FROM line_channels
   WHERE tenant_id = v_tenant_id AND home_store_id = p_store_id
   LIMIT 1;
  IF v_channel_id IS NULL THEN
    SELECT id INTO v_channel_id FROM line_channels
     WHERE tenant_id = v_tenant_id LIMIT 1;
  END IF;
  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for tenant';
  END IF;

  -- 抵減單獨立 (UNIQUE: tenant+campaign+channel+member 用了 store_internal
  -- 會跟 rpc_create_store_internal_order 撞)，所以 offset 單帶 -OFF 後綴
  -- 跳過 UNIQUE 衝突 → 改用獨立 member（用 -INT 後綴的另一個 member？）
  --
  -- 簡化：暫不允許同 store + 同 campaign 多張 offset 單，沿用既有 member
  -- 並將 order_no 後綴設 -OFF{seq}。若 UNIQUE 衝突，回傳既有 order_id
  -- 並將新 items 累加到既有單。
  SELECT id INTO v_order_id FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = p_campaign_id
     AND channel_id  = v_channel_id
     AND member_id   = v_member_id
     AND order_kind  = 'offset';

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = p_campaign_id
       AND order_kind = 'offset';
    v_order_no := v_campaign_no || '-OFF' || lpad(v_seq::text, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      pickup_store_id, order_kind, status, notes, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_no, p_campaign_id, v_channel_id, v_member_id,
      p_store_id, 'offset', 'confirmed',
      '[庫存抵減單] ' || p_reason,
      p_operator, p_operator
    ) RETURNING id INTO v_order_id;
  ELSE
    -- 既有 offset 單，累加 notes（保留歷次原因）
    UPDATE customer_orders SET
      notes      = COALESCE(notes, '') || E'\n[追加] ' || p_reason,
      updated_by = p_operator
    WHERE id = v_order_id;
  END IF;

  -- 寫 items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
    v_qty   := (v_item ->> 'qty')::NUMERIC;

    SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
      FROM campaign_items
     WHERE id = v_ci_id AND tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    IF v_ci_price IS NULL THEN
      RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_id, v_ci_id, v_ci_sku, v_qty, v_ci_price,
      'pending', 'store_internal', p_operator, p_operator
    );
  END LOOP;

  RETURN v_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_create_offset_order(BIGINT, BIGINT, JSONB, TEXT, UUID) TO authenticated;


-- ============================================================
-- rpc_cancel_offset_order：取消抵減單
--
-- 抵減單沒有 transfer / picking_wave 關聯，直接 status='cancelled' 即可，
-- 不走 rpc_cancel_aid_order 的全鏈路逆轉。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_cancel_offset_order(
  p_order_id BIGINT,
  p_reason   TEXT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_kind   TEXT;
  v_status TEXT;
BEGIN
  SELECT order_kind, status INTO v_kind, v_status
    FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  IF v_kind <> 'offset' THEN
    RAISE EXCEPTION 'order % is order_kind=%, use rpc_cancel_aid_order instead', p_order_id, v_kind;
  END IF;
  IF v_status = 'cancelled' THEN
    RETURN; -- idempotent
  END IF;

  UPDATE customer_orders SET
    status     = 'cancelled',
    notes      = COALESCE(notes, '') || E'\n[cancelled] ' || COALESCE(p_reason, ''),
    updated_by = p_operator,
    updated_at = NOW()
  WHERE id = p_order_id;

  -- 同時把 items 標 cancelled
  UPDATE customer_order_items SET
    status     = 'cancelled',
    updated_by = p_operator,
    updated_at = NOW()
  WHERE order_id = p_order_id AND status NOT IN ('cancelled');
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_cancel_offset_order(BIGINT, TEXT, UUID) TO authenticated;
