-- ============================================================
-- rpc_create_restock_request + restock_requests RLS：修店端(store role)自店檢查
--
-- 問題：店端角色的「只能建自家店申請」檢查比對 auth.jwt() ->> 'store_id'，
--   但本系統 store_manager / store_staff 帳號 JWT **沒有 store_id claim**
--   （只有 app_metadata.stores 店名陣列），導致該檢查恆為 DISTINCT →
--   店長建補貨申請一律被擋「store role can only create request for own store」。
--   restock_requests 的 restock_select RLS 也比對同一個不存在的 claim，
--   店端連自家申請都讀不到。
--
-- 修法：與 20260707000080（rpc_create_order_return 同型 bug）一致，改用
--   20260707000070 的 _jwt_store_ids()（app_metadata.stores 店名 → store_id），
--   檢查「p_store_id / requesting_store_id 是否在店端管理的店清單內」。
--
-- 其餘行為（sentinel campaign/channel/campaign_item、customer_orders +
-- items 同步建立、虛擬 SKU 拒絕、qty 守衛等）與基底版本逐字保留。
--
-- 基底版本：rpc_create_restock_request → 20260612000020_restock_creates_customer_order.sql（線上現行）；
--          restock_select policy    → 20260515000001_restock_requests_schema.sql（線上現行）。
-- Rollback：CREATE OR REPLACE 回 20260612000020 版本（店端檢查改回比對 jwt.store_id）；
--          DROP POLICY restock_select 後建回 20260515000001 版本。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_create_restock_request — 店端自店檢查改走 _jwt_store_ids()
-- ----------------------------------------------------------------
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

  -- 店端 role 只能建自家店申請。「自己店」由 app_metadata.stores 店名經
  -- _jwt_store_ids() 推導（本系統 JWT 無 store_id claim，見 20260707000080 同型修法）。
  IF v_role IN ('store_manager','store_staff') THEN
    IF NOT (p_store_id = ANY (public._jwt_store_ids())) THEN
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

COMMENT ON FUNCTION public.rpc_create_restock_request IS
  'Case 2：分店建補貨申請（pending 狀態、限真實 SKU，同步建 restock customer_order）。'
  '店端角色只能建自家店申請，自己店由 app_metadata.stores 經 _jwt_store_ids() 判定。';

-- ----------------------------------------------------------------
-- 2. restock_select RLS — 店端讀自家店申請改走 _jwt_store_ids()
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS restock_select ON restock_requests;
CREATE POLICY restock_select ON restock_requests
  FOR SELECT
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      -- HQ role 全看
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
        = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','assistant',''])
      OR
      -- 分店 role 只看自家店（app_metadata.stores 店名 → store_id）
      (
        COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
          = ANY (ARRAY['store_manager','store_staff'])
        AND requesting_store_id = ANY (public._jwt_store_ids())
      )
    )
  );

COMMENT ON POLICY restock_select ON restock_requests IS
  'HQ role 全看；門市角色只看自家店申請，自己店由 app_metadata.stores 店名經 _jwt_store_ids() 推導。';
