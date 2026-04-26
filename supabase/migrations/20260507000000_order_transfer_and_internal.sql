-- ============================================================
-- Phase 5a-1: 訂單轉手 + 分店內部訂單 (店長叫貨 / 棄單轉店 / 互助轉手)
-- TEST: docs/TEST-order-transfer.md
--
-- 把「貨從 A 店流到 B 店」收斂到 customer_orders：
--   1. 客戶棄單 → 互助轉訂單
--   2. 店長為自己店叫貨進門市庫存
--   3. 互助交流板認領（5b/5c UI 接這層 RPC）
--   4. 88 折出清 = 內部訂單 + unit_price 折價 (無新欄位)
-- ============================================================

-- ============================================================
-- 1. SCHEMA DELTA
-- ============================================================

-- 1.1 customer_orders 加轉手欄位 + 'transferred_out' status
ALTER TABLE customer_orders
  ADD COLUMN transferred_from_order_id BIGINT REFERENCES customer_orders(id),
  ADD COLUMN transferred_to_order_id   BIGINT REFERENCES customer_orders(id);

ALTER TABLE customer_orders DROP CONSTRAINT customer_orders_status_check;
ALTER TABLE customer_orders ADD CONSTRAINT customer_orders_status_check
  CHECK (status IN ('pending','confirmed','reserved','shipping','ready',
                    'partially_ready','partially_completed','completed',
                    'expired','cancelled','transferred_out'));

CREATE INDEX idx_corders_transferred_from ON customer_orders (transferred_from_order_id)
  WHERE transferred_from_order_id IS NOT NULL;
CREATE INDEX idx_corders_transferred_to ON customer_orders (transferred_to_order_id)
  WHERE transferred_to_order_id IS NOT NULL;

COMMENT ON COLUMN customer_orders.transferred_from_order_id IS 'Phase 5a-1: 此訂單由哪張原訂單轉手而來 (互助/棄單轉手場景)';
COMMENT ON COLUMN customer_orders.transferred_to_order_id   IS 'Phase 5a-1: 此訂單已轉手到哪張新訂單 (原單 status=transferred_out)';

-- 1.2 members.member_type 加 'store_internal'
ALTER TABLE members DROP CONSTRAINT members_member_type_check;
ALTER TABLE members ADD CONSTRAINT members_member_type_check
  CHECK (member_type IN ('full','guest','store_internal'));

COMMENT ON COLUMN members.member_type IS 'full=正式會員 / guest=訪客 / store_internal=分店內部 member (店長叫貨用，每店一筆)';

-- 1.3 customer_order_items.source 加 'store_internal' / 'aid_transfer'
ALTER TABLE customer_order_items DROP CONSTRAINT customer_order_items_source_check;
ALTER TABLE customer_order_items ADD CONSTRAINT customer_order_items_source_check
  CHECK (source IN ('manual','screenshot_parse','csv','rollover','liff',
                    'store_internal','aid_transfer'));

-- ============================================================
-- 2. rpc_get_or_create_store_member(p_store_id, p_operator)
-- ============================================================
-- 為分店建立 / 取得內部 member (member_type='store_internal')。
-- idempotent — 同 store 只會建一筆，advisory lock 防 concurrent。
-- phone_hash 用 'STORE-INTERNAL-{store_id}' placeholder（真 hash 為 hex、不會碰撞）。

CREATE OR REPLACE FUNCTION rpc_get_or_create_store_member(
  p_store_id   BIGINT,
  p_operator   UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id   UUID;
  v_store_name  TEXT;
  v_member_no   TEXT;
  v_phone_hash  TEXT;
  v_member_id   BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('store_member:' || p_store_id::text));

  SELECT tenant_id, name INTO v_tenant_id, v_store_name
    FROM stores WHERE id = p_store_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;

  v_member_no  := 'STORE-' || p_store_id;
  v_phone_hash := 'STORE-INTERNAL-' || p_store_id;

  SELECT id INTO v_member_id
    FROM members
   WHERE tenant_id = v_tenant_id AND member_no = v_member_no;

  IF v_member_id IS NOT NULL THEN
    RETURN v_member_id;
  END IF;

  INSERT INTO members (
    tenant_id, member_no, phone_hash, name, home_store_id,
    member_type, status, created_by, updated_by
  ) VALUES (
    v_tenant_id, v_member_no, v_phone_hash,
    '【內部】' || COALESCE(v_store_name, '店 ' || p_store_id),
    p_store_id, 'store_internal', 'active',
    p_operator, p_operator
  ) RETURNING id INTO v_member_id;

  RETURN v_member_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_get_or_create_store_member(BIGINT, UUID) TO authenticated;

-- ============================================================
-- 3. rpc_create_store_internal_order(...)
-- ============================================================
-- 店長為自己店叫貨。客戶 = store_internal member、pickup = 自己店。
-- 支援自帶 unit_price (88 折出清 / 內部任意定價)。
--
-- p_items: [{campaign_item_id BIGINT, qty NUMERIC, unit_price NUMERIC (optional)}]
--   unit_price NULL → fallback 到 campaign_items.unit_price (走 list price)

CREATE OR REPLACE FUNCTION rpc_create_store_internal_order(
  p_campaign_id  BIGINT,
  p_store_id     BIGINT,
  p_items        JSONB,
  p_operator     UUID,
  p_notes        TEXT DEFAULT NULL
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
  v_unit_price   NUMERIC;
BEGIN
  -- campaign 驗證
  SELECT tenant_id, campaign_no, status
    INTO v_tenant_id, v_campaign_no, v_campaign_st
    FROM group_buy_campaigns WHERE id = p_campaign_id;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_campaign_st NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is %; only open/closed accept internal order',
                    p_campaign_id, v_campaign_st;
  END IF;

  -- p_items 不可空
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items is empty';
  END IF;

  -- 取得 / 建立 store_internal member
  v_member_id := rpc_get_or_create_store_member(p_store_id, p_operator);

  -- 取該店任一 line_channel；無則 fallback 到第一個 channel
  SELECT id INTO v_channel_id
    FROM line_channels
   WHERE tenant_id = v_tenant_id AND home_store_id = p_store_id
   LIMIT 1;

  IF v_channel_id IS NULL THEN
    SELECT id INTO v_channel_id
      FROM line_channels
     WHERE tenant_id = v_tenant_id
     LIMIT 1;
  END IF;

  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no line_channel available for tenant';
  END IF;

  -- 找既有 (UNIQUE: tenant+campaign+channel+member)
  SELECT id INTO v_order_id FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = p_campaign_id
     AND channel_id  = v_channel_id
     AND member_id   = v_member_id;

  IF v_order_id IS NULL THEN
    SELECT COUNT(*) + 1 INTO v_seq
      FROM customer_orders
     WHERE tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    v_order_no := v_campaign_no || '-INT' || lpad(v_seq::text, 4, '0');

    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id,
      pickup_store_id, status, notes, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_no, p_campaign_id, v_channel_id, v_member_id,
      p_store_id, 'pending',
      COALESCE(p_notes, '【店長內部叫貨】'),
      p_operator, p_operator
    ) RETURNING id INTO v_order_id;
  END IF;

  -- 寫 items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_ci_id := (v_item ->> 'campaign_item_id')::BIGINT;
    v_qty   := (v_item ->> 'qty')::NUMERIC;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'qty must be > 0';
    END IF;

    SELECT unit_price, sku_id INTO v_ci_price, v_ci_sku
      FROM campaign_items
     WHERE id = v_ci_id AND tenant_id = v_tenant_id AND campaign_id = p_campaign_id;
    IF v_ci_price IS NULL THEN
      RAISE EXCEPTION 'campaign_item % not in campaign %', v_ci_id, p_campaign_id;
    END IF;

    -- 自帶 unit_price 覆寫 (88 折用)；NULL 則用 list price
    v_unit_price := COALESCE((v_item ->> 'unit_price')::NUMERIC, v_ci_price);
    IF v_unit_price < 0 THEN
      RAISE EXCEPTION 'unit_price cannot be negative';
    END IF;

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_order_id, v_ci_id, v_ci_sku, v_qty, v_unit_price,
      'pending', 'store_internal', p_operator, p_operator
    );
  END LOOP;

  RETURN v_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_create_store_internal_order(BIGINT, BIGINT, JSONB, UUID, TEXT) TO authenticated;

-- ============================================================
-- 4. rpc_transfer_order_to_store(...)
-- ============================================================
-- 訂單轉手核心 RPC：
--   - 客戶棄單 → 別店接收
--   - 互助板「我要接收這張轉出訂單」按鈕呼叫
--   - 同店換客人 / 換掛店長 (F4 同店允許)
--
-- 不在範疇：通知接收店店長 (LINE OA push) — 由 5b UI 層觸發

CREATE OR REPLACE FUNCTION rpc_transfer_order_to_store(
  p_order_id              BIGINT,
  p_to_pickup_store_id    BIGINT,
  p_to_member_id          BIGINT,    -- NULL → 自動用接收店的 store_internal
  p_to_channel_id         BIGINT,    -- NULL → 自動取接收店的 line_channel
  p_operator              UUID,
  p_reason                TEXT DEFAULT NULL
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
  v_item             RECORD;
  v_orig_mov         RECORD;
  v_rev_id           BIGINT;
  v_now              TIMESTAMPTZ := NOW();
  v_note_out         TEXT;
  v_note_in          TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_transfer:' || p_order_id::text));

  -- 鎖原訂單
  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  v_tenant_id := v_orig.tenant_id;

  -- 驗 status — 只允 pending / confirmed / reserved (F2)
  IF v_orig.status NOT IN ('pending','confirmed','reserved') THEN
    RAISE EXCEPTION 'order % status=%, only pending/confirmed/reserved can be transferred',
                    p_order_id, v_orig.status;
  END IF;

  -- 驗未轉手過 (F3)
  IF v_orig.transferred_to_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'order % already transferred to order %',
                    p_order_id, v_orig.transferred_to_order_id;
  END IF;

  -- 驗接收店存在
  PERFORM 1 FROM stores WHERE id = p_to_pickup_store_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pickup_store % not in tenant', p_to_pickup_store_id;
  END IF;

  -- F7: 接收 member NULL → 自動用接收店的 store_internal
  v_to_member_id := COALESCE(
    p_to_member_id,
    rpc_get_or_create_store_member(p_to_pickup_store_id, p_operator)
  );

  PERFORM 1 FROM members WHERE id = v_to_member_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'member % not in tenant', v_to_member_id;
  END IF;

  -- channel NULL → 取接收店的 line_channel；無則 fallback
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

  PERFORM 1 FROM line_channels
   WHERE id = v_to_channel_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'channel % not in tenant', v_to_channel_id;
  END IF;

  -- F6: UNIQUE (tenant, campaign, channel, member) — 接收方已有同 trio 訂單時擋下
  PERFORM 1 FROM customer_orders
   WHERE tenant_id = v_tenant_id
     AND campaign_id = v_orig.campaign_id
     AND channel_id  = v_to_channel_id
     AND member_id   = v_to_member_id;
  IF FOUND THEN
    RAISE EXCEPTION 'receiver already has order in (campaign=%, channel=%, member=%)',
                    v_orig.campaign_id, v_to_channel_id, v_to_member_id;
  END IF;

  -- E2: 若原 items 已 allocate (有 reserved_movement_id) → 反向 stock_movement 釋放
  FOR v_item IN
    SELECT id, reserved_movement_id FROM customer_order_items
     WHERE order_id = p_order_id AND reserved_movement_id IS NOT NULL
  LOOP
    SELECT * INTO v_orig_mov FROM stock_movements WHERE id = v_item.reserved_movement_id;
    IF FOUND THEN
      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, reverses, reason, operator_id
      ) VALUES (
        v_orig_mov.tenant_id, v_orig_mov.location_id, v_orig_mov.sku_id,
        -v_orig_mov.quantity, v_orig_mov.unit_cost, 'reversal',
        'order_transfer', p_order_id, v_orig_mov.id,
        'order #' || p_order_id || ' transferred out, release allocation', p_operator
      ) RETURNING id INTO v_rev_id;

      UPDATE stock_movements SET reversed_by = v_rev_id WHERE id = v_orig_mov.id;
      UPDATE customer_order_items SET reserved_movement_id = NULL WHERE id = v_item.id;
    END IF;
  END LOOP;

  -- 產生新 order_no
  SELECT campaign_no INTO v_campaign_no FROM group_buy_campaigns WHERE id = v_orig.campaign_id;
  SELECT COUNT(*) + 1 INTO v_seq
    FROM customer_orders
   WHERE tenant_id = v_tenant_id AND campaign_id = v_orig.campaign_id;
  v_new_order_no := v_campaign_no || '-TF' || lpad(v_seq::text, 4, '0');

  v_note_in := COALESCE(p_reason, '') ||
               E'\n[轉入 ← 訂單 #' || p_order_id || ' (' || v_orig.order_no || ')] ' ||
               to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

  -- 建新訂單
  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id,
    nickname_snapshot, pickup_store_id, status, notes,
    transferred_from_order_id,
    created_by, updated_by, created_at, updated_at
  ) VALUES (
    v_tenant_id, v_new_order_no, v_orig.campaign_id, v_to_channel_id, v_to_member_id,
    v_orig.nickname_snapshot, p_to_pickup_store_id, 'pending', v_note_in,
    p_order_id,
    p_operator, p_operator, v_now, v_now
  ) RETURNING id INTO v_new_order_id;

  -- 複製 items (source='aid_transfer'、reserved_movement_id 重設為 NULL)
  INSERT INTO customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by
  )
  SELECT tenant_id, v_new_order_id, campaign_item_id, sku_id, qty, unit_price,
         'pending', 'aid_transfer', notes, p_operator, p_operator
    FROM customer_order_items
   WHERE order_id = p_order_id;

  -- 原訂單 status='transferred_out'、寫 transferred_to + 兩邊 notes
  v_note_out := COALESCE(p_reason, '') ||
                E'\n[轉出 → 訂單 #' || v_new_order_id || ' (' || v_new_order_no || ')] ' ||
                to_char(v_now, 'YYYY-MM-DD HH24:MI:SS');

  UPDATE customer_orders
     SET status                   = 'transferred_out',
         transferred_to_order_id  = v_new_order_id,
         notes                    = COALESCE(notes, '') || v_note_out,
         updated_by               = p_operator,
         updated_at               = v_now
   WHERE id = p_order_id;

  RETURN v_new_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_transfer_order_to_store(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT) TO authenticated;

-- ============================================================
-- 5. 整合：picking_wave demand 抓需求時排除 transferred_out (G3)
-- ============================================================
-- picking_demand_view 的查詢應自然排除 'transferred_out' (status NOT IN ...)
-- 既有 view 已用 WHERE status IN (...)、不需修改即排除
-- 此處只是 sanity check note
COMMENT ON COLUMN customer_orders.status IS
  'transferred_out 視同已關閉、不被 expiry/shortage/picking 流程處理';
