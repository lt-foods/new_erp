-- ============================================================
-- 補貨申請 → 自動掛一張 customer_order 給分店
-- 並提供 rpc_create_wave_from_restock 用於派貨工作台「無 PO 來源」section
--
-- 設計:
-- - 為「補貨」需求虛擬一條 channel 走向(避免動 customer_orders.campaign_id/channel_id NOT NULL)
-- - 每 tenant 一筆 sentinel campaign(campaign_no='__INTERNAL_RESTOCK__')
-- - 每 store 一筆 sentinel channel(code='__INTERNAL_RESTOCK_{store_id}__',home_store_id=store)
-- - 每 (sentinel campaign, sku) 一筆 sentinel campaign_item(lazy)
-- - customer_orders.order_kind 加 'restock' 值
-- - external_source='manual' + external_order_no='RR-{id}' 標記來源
--
-- 不影響既有報表(只要 reports 過濾掉 order_kind='restock' 或 sentinel campaign 就好)
-- ============================================================

-- 1. 放寬 order_kind 容許 'restock'
ALTER TABLE public.customer_orders DROP CONSTRAINT IF EXISTS customer_orders_order_kind_check;
ALTER TABLE public.customer_orders ADD CONSTRAINT customer_orders_order_kind_check
  CHECK (order_kind = ANY (ARRAY['normal'::text, 'offset'::text, 'restock'::text]));

-- 2. sentinel campaign helper(per tenant)
CREATE OR REPLACE FUNCTION public._restock_sentinel_campaign(p_tenant UUID)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  SELECT id INTO v_id FROM group_buy_campaigns
    WHERE tenant_id = p_tenant AND campaign_no = '__INTERNAL_RESTOCK__';
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, status, close_type, notes
  ) VALUES (
    p_tenant, '__INTERNAL_RESTOCK__', '【內部】補貨申請', 'open', 'regular',
    'sentinel for store restock requests — do not delete'
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- 3. sentinel channel helper(per store)
CREATE OR REPLACE FUNCTION public._restock_sentinel_channel(p_tenant UUID, p_store_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT := '__INTERNAL_RESTOCK_' || p_store_id::TEXT || '__';
  v_id BIGINT;
BEGIN
  SELECT id INTO v_id FROM line_channels
    WHERE tenant_id = p_tenant AND code = v_code;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  INSERT INTO line_channels (
    tenant_id, code, name, channel_type, home_store_id, is_active, notes
  ) VALUES (
    p_tenant, v_code,
    '【內部】補貨申請-' || p_store_id::TEXT,
    'oa_channel', p_store_id, true,
    'sentinel for store restock requests — do not delete'
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- 4. sentinel campaign_item helper(per (campaign, sku))
CREATE OR REPLACE FUNCTION public._restock_sentinel_campaign_item(
  p_tenant UUID, p_campaign_id BIGINT, p_sku_id BIGINT, p_unit_price NUMERIC
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  SELECT id INTO v_id FROM campaign_items
    WHERE campaign_id = p_campaign_id AND sku_id = p_sku_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  INSERT INTO campaign_items (
    tenant_id, campaign_id, sku_id, unit_price, sort_order
  ) VALUES (
    p_tenant, p_campaign_id, p_sku_id, COALESCE(p_unit_price, 0), 0
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- 5. 改寫 rpc_create_restock_request — 多寫一張 customer_orders + items
CREATE OR REPLACE FUNCTION public.rpc_create_restock_request(
  p_store_id BIGINT,
  p_lines    JSONB,
  p_notes    TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_request_id   BIGINT;
  v_line         JSONB;
  v_sku_id       BIGINT;
  v_count        INT := 0;
  v_is_virtual   BOOLEAN;
  v_campaign_id  BIGINT;
  v_channel_id   BIGINT;
  v_order_id     BIGINT;
  v_order_no     TEXT;
  v_campaign_item_id BIGINT;
  v_unit_price   NUMERIC;
  v_qty          NUMERIC;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create restock request', v_role;
  END IF;

  IF v_role IN ('store_manager','store_staff') THEN
    IF p_store_id::TEXT IS DISTINCT FROM (auth.jwt() ->> 'store_id') THEN
      RAISE EXCEPTION 'store role can only create request for own store';
    END IF;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;

  -- 1. 建 restock_request
  INSERT INTO restock_requests (
    tenant_id, requesting_store_id, status, notes,
    requested_by, requested_at, created_by, updated_by
  ) VALUES (
    v_tenant, p_store_id, 'pending', p_notes,
    v_user, NOW(), v_user, v_user
  ) RETURNING id INTO v_request_id;

  -- 2. 建 sentinel campaign + channel + customer_order
  v_campaign_id := public._restock_sentinel_campaign(v_tenant);
  v_channel_id  := public._restock_sentinel_channel(v_tenant, p_store_id);
  v_order_no := 'RR-' || v_request_id::TEXT;

  INSERT INTO customer_orders (
    tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id,
    status, order_kind, order_type, external_source, external_order_no,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_order_no, v_campaign_id, v_channel_id, NULL, p_store_id,
    'pending', 'restock', 'regular', 'manual', v_order_no,
    '【內部】補貨申請 #' || v_request_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_order_id;

  -- 3. 跑每一個 line:寫 restock_request_lines + customer_order_items
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty    := (v_line ->> 'qty')::NUMERIC;
    v_unit_price := COALESCE((v_line ->> 'unit_price')::NUMERIC, 0);

    SELECT p.is_virtual INTO v_is_virtual
      FROM skus s
      JOIN products p ON p.id = s.product_id
     WHERE s.id = v_sku_id AND s.tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sku % not in tenant', v_sku_id;
    END IF;
    IF v_is_virtual THEN
      RAISE EXCEPTION 'restock request cannot use virtual sku %', v_sku_id;
    END IF;

    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'line qty must be > 0';
    END IF;

    INSERT INTO restock_request_lines (
      tenant_id, request_id, sku_id, qty, unit_price, notes,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_request_id, v_sku_id, v_qty, v_unit_price,
      v_line ->> 'notes', v_user, v_user
    );

    -- sentinel campaign_item per sku
    v_campaign_item_id := public._restock_sentinel_campaign_item(
      v_tenant, v_campaign_id, v_sku_id, v_unit_price
    );

    INSERT INTO customer_order_items (
      tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
      status, source, created_by, updated_by
    ) VALUES (
      v_tenant, v_order_id, v_campaign_item_id, v_sku_id, v_qty, v_unit_price,
      'pending', 'manual', v_user, v_user
    );

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  RETURN v_request_id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_create_restock_request(BIGINT, JSONB, TEXT)
  TO authenticated;

-- 6. rpc_create_wave_from_restock — 派貨工作台「無 PO 來源」section 提交時呼叫
CREATE OR REPLACE FUNCTION public.rpc_create_wave_from_restock(
  p_restock_request_id BIGINT,
  p_wave_date          DATE,
  p_allocations        JSONB,   -- [{ sku_id, store_id, qty }]
  p_operator           UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request      restock_requests%ROWTYPE;
  v_tenant       UUID;
  v_wave_id      BIGINT;
  v_wave_code    TEXT;
  v_alloc        JSONB;
  v_sku_id       BIGINT;
  v_store_id     BIGINT;
  v_qty          NUMERIC(18,3);
  v_total_qty    NUMERIC(18,3) := 0;
  v_item_count   INTEGER := 0;
  v_store_count  INTEGER := 0;
  v_hq_location  BIGINT;
  v_short        RECORD;
BEGIN
  -- 1. restock 守衛
  SELECT * INTO v_request FROM restock_requests
    WHERE id = p_restock_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到補貨申請 #%', p_restock_request_id;
  END IF;
  IF v_request.status NOT IN ('pending','approved_transfer') THEN
    RAISE EXCEPTION '補貨申請狀態為「%」、不可建撿貨單(需為 pending 或 approved_transfer)',
      v_request.status;
  END IF;
  v_tenant := v_request.tenant_id;

  -- 2. allocations 守衛
  IF p_allocations IS NULL OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION '請先填寫各分店分配量、不可全為空';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('wave:restock:' || p_restock_request_id::TEXT));

  -- 3. 守衛:每個分配 qty > 0、store 等於 requesting_store
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_qty := (v_alloc->>'qty')::NUMERIC;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION '分配數量必須 > 0';
    END IF;
    IF v_store_id <> v_request.requesting_store_id THEN
      RAISE EXCEPTION '補貨申請只能派給申請分店 #%、不可派往其他店',
        v_request.requesting_store_id;
    END IF;
  END LOOP;

  -- 4. 守衛:總分配量 ≤ HQ 即時庫存(stock_balances on_hand at HQ central_warehouse)
  -- 找 HQ central_warehouse location_id
  SELECT id INTO v_hq_location FROM locations
    WHERE tenant_id = v_tenant AND type = 'central_warehouse'
    ORDER BY id LIMIT 1;
  IF v_hq_location IS NULL THEN
    RAISE EXCEPTION '找不到總倉 location(type=central_warehouse)';
  END IF;

  -- 守衛:已分配量(同 sku 在 sentinel restock 申請間競爭由 advisory_lock 保護)
  WITH alloc_agg AS (
    SELECT (a->>'sku_id')::BIGINT AS sku_id,
           SUM((a->>'qty')::NUMERIC) AS total_alloc
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY (a->>'sku_id')::BIGINT
  ),
  -- 同申請的 line 拘束:分配量 ≤ 申請量
  line_agg AS (
    SELECT sku_id, SUM(qty) AS line_qty
    FROM restock_request_lines
    WHERE request_id = p_restock_request_id
    GROUP BY sku_id
  )
  SELECT
    s.sku_code,
    COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
    aa.total_alloc,
    COALESCE(la.line_qty, 0) AS line_qty,
    COALESCE(sb.on_hand, 0) AS on_hand
  INTO v_short
  FROM alloc_agg aa
  JOIN skus s ON s.id = aa.sku_id
  LEFT JOIN line_agg la ON la.sku_id = aa.sku_id
  LEFT JOIN stock_balances sb
    ON sb.tenant_id = v_tenant
   AND sb.location_id = v_hq_location
   AND sb.sku_id = aa.sku_id
  WHERE
    aa.total_alloc > COALESCE(la.line_qty, 0)
    OR aa.total_alloc > COALESCE(sb.on_hand, 0)
  LIMIT 1;

  IF v_short.sku_code IS NOT NULL THEN
    IF v_short.total_alloc > v_short.line_qty THEN
      RAISE EXCEPTION 'SKU「% %」分配 % 超過申請量 %',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc, v_short.line_qty;
    ELSE
      RAISE EXCEPTION 'SKU「% %」分配 % 超過總倉庫存 %',
        v_short.sku_code, v_short.sku_label, v_short.total_alloc, v_short.on_hand;
    END IF;
  END IF;

  -- 5. wave header
  v_wave_code := 'WV'
              || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYMMDD')
              || LPAD(nextval('public.picking_wave_code_seq')::TEXT, 6, '0');

  INSERT INTO picking_waves (
    tenant_id, wave_code, wave_date, status, source_restock_request_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_wave_code, p_wave_date, 'draft', p_restock_request_id,
    p_operator, p_operator
  ) RETURNING id INTO v_wave_id;

  -- 6. 寫 wave items
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
    v_sku_id   := (v_alloc->>'sku_id')::BIGINT;
    v_store_id := (v_alloc->>'store_id')::BIGINT;
    v_qty      := (v_alloc->>'qty')::NUMERIC;

    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, campaign_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_wave_id, v_sku_id, v_store_id, v_qty, NULL,
      p_operator, p_operator
    )
    ON CONFLICT (wave_id, sku_id, store_id) DO UPDATE
      SET qty = picking_wave_items.qty + EXCLUDED.qty,
          updated_by = p_operator,
          updated_at = NOW();
  END LOOP;

  -- 7. 統計 wave header
  SELECT COUNT(*), COUNT(DISTINCT store_id), COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items WHERE wave_id = v_wave_id;

  UPDATE picking_waves
    SET item_count = v_item_count,
        store_count = v_store_count,
        total_qty = v_total_qty,
        updated_at = NOW()
   WHERE id = v_wave_id;

  -- 8. restock 狀態 → approved_transfer(代表已建 wave、進入派貨)
  IF v_request.status = 'pending' THEN
    UPDATE restock_requests
      SET status = 'approved_transfer',
          approved_by = p_operator,
          approved_at = NOW(),
          updated_by = p_operator,
          updated_at = NOW()
     WHERE id = p_restock_request_id;
  END IF;

  RETURN jsonb_build_object(
    'wave_id', v_wave_id,
    'wave_code', v_wave_code,
    'item_count', v_item_count,
    'store_count', v_store_count,
    'total_qty', v_total_qty
  );
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_create_wave_from_restock(BIGINT, DATE, JSONB, UUID)
  TO authenticated;
