-- ============================================================
-- RPC 配合 1:1 invariant：
--   1. 新 rpc_create_campaign_from_product（單 product）取代 _from_products（多）
--   2. rpc_schedule_candidate 內部建 campaign 時補設 product_id
--
-- 變更後：
--   - 「從商品開團」UI 改 call 新 RPC、單 product 入參
--   - rpc_schedule_candidate 建出來的 campaign 自動帶 product_id
--   - 既有 rpc_create_campaign_from_products 維持運作（dev 過渡），但內部會 RAISE WARNING 提醒；
--     UI 切換完成後可再寫 migration 砍掉
--
-- Scope: 加 RPC + 修 RPC，不動表
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT);
-- ============================================================

-- ----------------------------------------------------------------
-- rpc_create_campaign_from_product — 單 product 建團
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_no          TEXT;
  v_campaign_id BIGINT;
  v_sort        INT  := 1;
  r             RECORD;
BEGIN
  -- 確認 product 在同 tenant
  PERFORM 1 FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, status, product_id,
    start_at, end_at, pickup_deadline,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, 'open', p_product_id,
    NOW(), p_end_at, p_pickup_deadline,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_campaign_id;

  -- 對該 product 的所有 active SKU 補進 campaign_items
  FOR r IN
    SELECT
      s.id AS sku_id,
      COALESCE(
        (SELECT p.price
           FROM prices p
          WHERE p.sku_id    = s.id
            AND p.scope     = 'retail'
            AND p.tenant_id = v_tenant
            AND p.effective_to IS NULL
          ORDER BY p.effective_from DESC
          LIMIT 1),
        0
      ) AS unit_price
    FROM skus s
   WHERE s.product_id = p_product_id
     AND s.tenant_id  = v_tenant
     AND s.status     = 'active'
   ORDER BY s.id
  LOOP
    INSERT INTO campaign_items (
      tenant_id, campaign_id, sku_id, unit_price, sort_order,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_campaign_id, r.sku_id, r.unit_price, v_sort,
      auth.uid(), auth.uid()
    )
    ON CONFLICT (campaign_id, sku_id) DO NOTHING;
    v_sort := v_sort + 1;
  END LOOP;

  RETURN v_campaign_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT) IS
  '從單一商品建團（1:1 invariant）：自動產生團號、設 product_id、塞入所有 active SKU。';

-- ----------------------------------------------------------------
-- rpc_schedule_candidate：補設 product_id
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_schedule_candidate(
  p_candidate_id    BIGINT,
  p_scheduled_date  DATE,
  p_product_name    TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_user           UUID := auth.uid();
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_cand           RECORD;
  v_product_code   TEXT;
  v_product_id     BIGINT;
  v_sku_code       TEXT;
  v_sku_id         BIGINT;
  v_campaign_no    TEXT;
  v_campaign_id    BIGINT;
  v_unit_price     NUMERIC;
  v_existing_camp  RECORD;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot schedule candidate', v_role;
  END IF;

  IF TRIM(COALESCE(p_product_name, '')) = '' THEN
    RAISE EXCEPTION 'product_name must not be blank';
  END IF;
  IF p_scheduled_date IS NULL THEN
    RAISE EXCEPTION 'scheduled_date must not be null';
  END IF;

  SELECT id, owner_action, adopted_product_id, adopted_sale_price, raw_text
    INTO v_cand
    FROM community_product_candidates
   WHERE id = p_candidate_id AND tenant_id = v_tenant
     FOR UPDATE;

  IF v_cand.id IS NULL THEN
    RAISE EXCEPTION 'candidate % not found or cross-tenant', p_candidate_id;
  END IF;

  IF v_cand.adopted_product_id IS NOT NULL THEN
    SELECT c.id AS campaign_id, c.campaign_no, p.product_code,
           (SELECT id FROM skus WHERE product_id = v_cand.adopted_product_id
              AND tenant_id = v_tenant ORDER BY id LIMIT 1) AS sku_id
      INTO v_existing_camp
      FROM products p
      LEFT JOIN group_buy_campaigns c
             ON c.product_id = p.id AND c.tenant_id = v_tenant
     WHERE p.id = v_cand.adopted_product_id
       AND p.tenant_id = v_tenant
     ORDER BY c.created_at ASC NULLS LAST
     LIMIT 1;

    IF v_existing_camp.campaign_id IS NULL THEN
      v_product_id  := v_cand.adopted_product_id;
      v_sku_id      := v_existing_camp.sku_id;
      v_product_code:= v_existing_camp.product_code;
    ELSE
      RETURN jsonb_build_object(
        'product_id',         v_cand.adopted_product_id,
        'product_code',       v_existing_camp.product_code,
        'sku_id',             v_existing_camp.sku_id,
        'campaign_id',        v_existing_camp.campaign_id,
        'campaign_no',        v_existing_camp.campaign_no,
        'already_scheduled',  TRUE
      );
    END IF;
  ELSE
    v_product_code := public.rpc_next_product_code();
    v_product_id := public.rpc_upsert_product(
      p_id := NULL, p_product_code := v_product_code,
      p_name := TRIM(p_product_name), p_short_name := NULL,
      p_brand_id := NULL, p_category_id := NULL,
      p_description := v_cand.raw_text, p_status := 'draft',
      p_reason := 'schedule candidate #' || p_candidate_id::TEXT
    );

    v_sku_code := public.rpc_next_sku_code(v_product_id);
    v_sku_id := public.rpc_upsert_sku(
      p_id := NULL, p_product_id := v_product_id, p_sku_code := v_sku_code,
      p_variant_name := NULL, p_spec := '{}'::jsonb,
      p_base_unit := NULL, p_weight_g := NULL, p_tax_rate := NULL,
      p_status := 'draft',
      p_reason := 'schedule candidate #' || p_candidate_id::TEXT
    );

    IF v_cand.adopted_sale_price IS NOT NULL THEN
      PERFORM public.rpc_set_retail_price(
        v_sku_id, v_cand.adopted_sale_price, NOW(),
        'schedule candidate #' || p_candidate_id::TEXT
      );
    END IF;
  END IF;

  v_campaign_no := 'GB' || to_char(p_scheduled_date, 'YYYYMMDD')
                 || '-C' || lpad(p_candidate_id::TEXT, 6, '0');

  v_campaign_id := public.rpc_upsert_campaign(
    p_id := NULL, p_campaign_no := v_campaign_no,
    p_name := TRIM(p_product_name), p_description := v_cand.raw_text,
    p_cover_image_url := NULL, p_status := 'draft', p_close_type := 'regular',
    p_start_at := p_scheduled_date::TIMESTAMPTZ, p_end_at := NULL,
    p_pickup_deadline := NULL, p_pickup_days := NULL,
    p_total_cap_qty := NULL,
    p_notes := 'schedule candidate #' || p_candidate_id::TEXT
  );

  -- 補設 product_id（rpc_upsert_campaign 沒有此參數）
  UPDATE group_buy_campaigns
     SET product_id = v_product_id
   WHERE id = v_campaign_id AND tenant_id = v_tenant;

  v_unit_price := COALESCE(v_cand.adopted_sale_price, 0);
  PERFORM public.rpc_upsert_campaign_item(
    p_id := NULL, p_campaign_id := v_campaign_id, p_sku_id := v_sku_id,
    p_unit_price := v_unit_price, p_cap_qty := NULL,
    p_sort_order := 0, p_notes := NULL
  );

  UPDATE community_product_candidates
     SET adopted_product_id = v_product_id, owner_action = 'scheduled',
         scheduled_open_at  = p_scheduled_date,
         scheduled_by = v_user, scheduled_at = NOW(),
         updated_at = NOW(), updated_by = v_user
   WHERE id = p_candidate_id AND tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'product_id',         v_product_id,
    'product_code',       v_product_code,
    'sku_id',             v_sku_id,
    'campaign_id',        v_campaign_id,
    'campaign_no',        v_campaign_no,
    'already_scheduled',  FALSE
  );
END;
$$;
