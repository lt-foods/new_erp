-- ============================================================
-- 修：三支新 RPC + prices RLS 把空 role ('') 視為 admin 等級
--
-- 背景：dev / 早期帳號 JWT app_metadata.role 沒設值（""），
-- codebase 既有 RLS / RPC 慣例（如 ccp_hq_all、purchase_rls_admin）都會把空字串
-- 也納入 admin 等級允許清單。本批新加的 rpc_set_cost_price / rpc_set_branch_price /
-- rpc_schedule_candidate / read_prices_role_scoped 漏了，導致實際登入後呼叫 RPC 被擋。
--
-- Scope: 只重建 RPC body 跟 RLS policy，不動 schema
-- Rollback: 重新 apply 20260514000001 + 20260514000002 + 20260514000000 對應段
-- ============================================================

-- ----------------------------------------------------------------
-- rpc_set_cost_price — 加空 role
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_cost_price(
  p_sku_id         BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_reason         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot set cost price', v_role;
  END IF;

  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  RETURN public.rpc_upsert_price(
    v_tenant, p_sku_id, 'cost', NULL, p_price, p_effective_from, p_reason, v_user
  );
END;
$$;

-- ----------------------------------------------------------------
-- rpc_set_branch_price — 加空 role
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_branch_price(
  p_sku_id         BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_reason         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot set branch price', v_role;
  END IF;

  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  RETURN public.rpc_upsert_price(
    v_tenant, p_sku_id, 'branch', NULL, p_price, p_effective_from, p_reason, v_user
  );
END;
$$;

-- ----------------------------------------------------------------
-- rpc_schedule_candidate — 加空 role
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
   WHERE id = p_candidate_id
     AND tenant_id = v_tenant
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
      LEFT JOIN skus s ON s.product_id = p.id AND s.tenant_id = v_tenant
      LEFT JOIN campaign_items ci ON ci.sku_id = s.id AND ci.tenant_id = v_tenant
      LEFT JOIN group_buy_campaigns c ON c.id = ci.campaign_id AND c.tenant_id = v_tenant
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
      p_id           := NULL,
      p_product_code := v_product_code,
      p_name         := TRIM(p_product_name),
      p_short_name   := NULL,
      p_brand_id     := NULL,
      p_category_id  := NULL,
      p_description  := v_cand.raw_text,
      p_status       := 'draft',
      p_reason       := 'schedule candidate #' || p_candidate_id::TEXT
    );

    v_sku_code := public.rpc_next_sku_code(v_product_id);

    v_sku_id := public.rpc_upsert_sku(
      p_id           := NULL,
      p_product_id   := v_product_id,
      p_sku_code     := v_sku_code,
      p_variant_name := NULL,
      p_spec         := '{}'::jsonb,
      p_base_unit    := NULL,
      p_weight_g     := NULL,
      p_tax_rate     := NULL,
      p_status       := 'draft',
      p_reason       := 'schedule candidate #' || p_candidate_id::TEXT
    );

    IF v_cand.adopted_sale_price IS NOT NULL THEN
      PERFORM public.rpc_set_retail_price(
        v_sku_id,
        v_cand.adopted_sale_price,
        NOW(),
        'schedule candidate #' || p_candidate_id::TEXT
      );
    END IF;
  END IF;

  v_campaign_no := 'GB' || to_char(p_scheduled_date, 'YYYYMMDD')
                 || '-C' || lpad(p_candidate_id::TEXT, 6, '0');

  v_campaign_id := public.rpc_upsert_campaign(
    p_id              := NULL,
    p_campaign_no     := v_campaign_no,
    p_name            := TRIM(p_product_name),
    p_description     := v_cand.raw_text,
    p_cover_image_url := NULL,
    p_status          := 'draft',
    p_close_type      := 'regular',
    p_start_at        := p_scheduled_date::TIMESTAMPTZ,
    p_end_at          := NULL,
    p_pickup_deadline := NULL,
    p_pickup_days     := NULL,
    p_total_cap_qty   := NULL,
    p_notes           := 'schedule candidate #' || p_candidate_id::TEXT
  );

  v_unit_price := COALESCE(v_cand.adopted_sale_price, 0);

  PERFORM public.rpc_upsert_campaign_item(
    p_id          := NULL,
    p_campaign_id := v_campaign_id,
    p_sku_id      := v_sku_id,
    p_unit_price  := v_unit_price,
    p_cap_qty     := NULL,
    p_sort_order  := 0,
    p_notes       := NULL
  );

  UPDATE community_product_candidates
     SET adopted_product_id = v_product_id,
         owner_action       = 'scheduled',
         scheduled_open_at  = p_scheduled_date,
         scheduled_by       = v_user,
         scheduled_at       = NOW(),
         updated_at         = NOW(),
         updated_by         = v_user
   WHERE id = p_candidate_id
     AND tenant_id = v_tenant;

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

-- ----------------------------------------------------------------
-- prices RLS — 加空 role 到 cost/branch 允許清單
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS read_prices_role_scoped ON prices;

CREATE POLICY read_prices_role_scoped ON prices
  FOR SELECT
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      scope IN ('retail','store','member_tier','promo')
      OR
      (scope = 'cost'
       AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','']))
      OR
      (scope = 'branch'
       AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','store_manager','']))
    )
  );

COMMENT ON POLICY read_prices_role_scoped ON prices IS
  '依 role × scope 分層：總部全看 / store_manager 不看 cost / store_staff 不看 cost+branch / 空 role 視為 admin 等級（dev/legacy 帳號）';
