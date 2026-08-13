-- Mobile quick campaign creator for quick-control.
-- Creates one open shop campaign from one active product in a single transaction.

CREATE OR REPLACE FUNCTION public.rpc_quick_create_campaign_from_product(
  p_product_id BIGINT,
  p_name TEXT,
  p_close_type TEXT,
  p_end_at TIMESTAMPTZ,
  p_description TEXT DEFAULT NULL,
  p_pickup_deadline DATE DEFAULT NULL,
  p_total_cap_qty NUMERIC DEFAULT NULL,
  p_item_caps JSONB DEFAULT '[]'::jsonb
) RETURNS TABLE (
  campaign_id BIGINT,
  campaign_no TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user UUID := auth.uid();
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_product products%ROWTYPE;
  v_campaign_id BIGINT;
  v_campaign_no TEXT;
  v_close_type TEXT := lower(btrim(COALESCE(p_close_type, '')));
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_sku_count INT := 0;
  v_item_cap_total NUMERIC := 0;
  v_missing TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;

  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'campaign name required';
  END IF;

  IF v_close_type NOT IN ('fast', 'limited', 'food_train') THEN
    RAISE EXCEPTION 'invalid close_type: %', p_close_type;
  END IF;

  IF p_end_at IS NULL OR p_end_at <= NOW() THEN
    RAISE EXCEPTION 'future end_at is required';
  END IF;

  IF p_total_cap_qty IS NOT NULL AND p_total_cap_qty <= 0 THEN
    RAISE EXCEPTION 'total_cap_qty must be > 0';
  END IF;

  IF p_item_caps IS NOT NULL AND jsonb_typeof(p_item_caps) <> 'array' THEN
    RAISE EXCEPTION 'item_caps must be an array';
  END IF;

  SELECT *
    INTO v_product
    FROM products
   WHERE id = p_product_id
     AND tenant_id = v_tenant
     AND status = 'active'
     AND COALESCE(is_for_shop, TRUE) IS TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'active shop product % not in tenant', p_product_id;
  END IF;

  SELECT COUNT(*)
    INTO v_sku_count
    FROM skus
   WHERE tenant_id = v_tenant
     AND product_id = p_product_id
     AND status = 'active';

  IF v_sku_count = 0 THEN
    RAISE EXCEPTION 'product has no active SKU';
  END IF;

  WITH caps AS (
    SELECT
      (x ->> 'sku_id')::BIGINT AS sku_id,
      NULLIF(btrim(x ->> 'cap_qty'), '')::NUMERIC AS cap_qty
    FROM jsonb_array_elements(COALESCE(p_item_caps, '[]'::jsonb)) AS x
  )
  SELECT COALESCE(SUM(cap_qty), 0)
    INTO v_item_cap_total
    FROM caps;

  IF EXISTS (
    WITH caps AS (
      SELECT
        (x ->> 'sku_id')::BIGINT AS sku_id,
        NULLIF(btrim(x ->> 'cap_qty'), '')::NUMERIC AS cap_qty
      FROM jsonb_array_elements(COALESCE(p_item_caps, '[]'::jsonb)) AS x
    )
    SELECT 1
      FROM caps
     WHERE sku_id IS NULL OR cap_qty IS NULL OR cap_qty <= 0
  ) THEN
    RAISE EXCEPTION 'item cap_qty must be > 0';
  END IF;

  IF EXISTS (
    WITH caps AS (
      SELECT (x ->> 'sku_id')::BIGINT AS sku_id
      FROM jsonb_array_elements(COALESCE(p_item_caps, '[]'::jsonb)) AS x
    )
    SELECT 1
      FROM caps c
      LEFT JOIN skus s
        ON s.id = c.sku_id
       AND s.tenant_id = v_tenant
       AND s.product_id = p_product_id
       AND s.status = 'active'
     WHERE s.id IS NULL
  ) THEN
    RAISE EXCEPTION 'item cap SKU not in active product';
  END IF;

  IF v_close_type = 'limited'
     AND COALESCE(p_total_cap_qty, 0) <= 0
     AND COALESCE(v_item_cap_total, 0) <= 0 THEN
    RAISE EXCEPTION 'limited campaign requires total cap or item cap';
  END IF;

  WITH active_skus AS (
    SELECT id, sku_code, variant_name
      FROM skus
     WHERE tenant_id = v_tenant
       AND product_id = p_product_id
       AND status = 'active'
  ),
  current_retail AS (
    SELECT DISTINCT ON (p.sku_id)
           p.sku_id,
           p.price
      FROM prices p
      JOIN active_skus s ON s.id = p.sku_id
     WHERE p.tenant_id = v_tenant
       AND p.scope = 'retail'
       AND p.effective_from <= NOW()
       AND (p.effective_to IS NULL OR p.effective_to > NOW())
       AND p.price > 0
     ORDER BY p.sku_id, p.effective_from DESC, p.id DESC
  )
  SELECT string_agg(
           s.sku_code || COALESCE(' (' || NULLIF(btrim(s.variant_name), '') || ')', ''),
           ', ' ORDER BY s.id
         )
    INTO v_missing
    FROM active_skus s
    LEFT JOIN current_retail cr ON cr.sku_id = s.id
   WHERE cr.sku_id IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'active SKU missing current retail price: %', v_missing;
  END IF;

  v_campaign_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, status, close_type, product_id,
    start_at, end_at, pickup_deadline, total_cap_qty, is_for_shop,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_campaign_no, v_name, COALESCE(p_description, v_product.description),
    'draft', v_close_type, p_product_id,
    NOW(), p_end_at, p_pickup_deadline, p_total_cap_qty, FALSE,
    v_user, v_user
  )
  RETURNING id INTO v_campaign_id;

  WITH caps AS (
    SELECT
      (x ->> 'sku_id')::BIGINT AS sku_id,
      MAX(NULLIF(btrim(x ->> 'cap_qty'), '')::NUMERIC) AS cap_qty
    FROM jsonb_array_elements(COALESCE(p_item_caps, '[]'::jsonb)) AS x
    GROUP BY (x ->> 'sku_id')::BIGINT
  ),
  current_retail AS (
    SELECT DISTINCT ON (p.sku_id)
           p.sku_id,
           p.price
      FROM prices p
     WHERE p.tenant_id = v_tenant
       AND p.scope = 'retail'
       AND p.effective_from <= NOW()
       AND (p.effective_to IS NULL OR p.effective_to > NOW())
       AND p.price > 0
     ORDER BY p.sku_id, p.effective_from DESC, p.id DESC
  ),
  src AS (
    SELECT
      s.id AS sku_id,
      cr.price AS unit_price,
      caps.cap_qty,
      ROW_NUMBER() OVER (ORDER BY s.id)::INT AS sort_order
    FROM skus s
    JOIN current_retail cr ON cr.sku_id = s.id
    LEFT JOIN caps ON caps.sku_id = s.id
   WHERE s.tenant_id = v_tenant
     AND s.product_id = p_product_id
     AND s.status = 'active'
  )
  INSERT INTO campaign_items (
    tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order,
    created_by, updated_by
  )
  SELECT
    v_tenant, v_campaign_id, sku_id, unit_price, cap_qty, sort_order,
    v_user, v_user
  FROM src;

  UPDATE group_buy_campaigns
     SET status = 'open',
         is_for_shop = TRUE,
         updated_by = v_user,
         updated_at = NOW()
   WHERE tenant_id = v_tenant
     AND id = v_campaign_id;

  RETURN QUERY SELECT v_campaign_id, v_campaign_no;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_quick_create_campaign_from_product(
  BIGINT, TEXT, TEXT, TIMESTAMPTZ, TEXT, DATE, NUMERIC, JSONB
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_quick_create_campaign_from_product(
  BIGINT, TEXT, TEXT, TIMESTAMPTZ, TEXT, DATE, NUMERIC, JSONB
) TO authenticated;

COMMENT ON FUNCTION public.rpc_quick_create_campaign_from_product(
  BIGINT, TEXT, TEXT, TIMESTAMPTZ, TEXT, DATE, NUMERIC, JSONB
) IS
  'Mobile quick-control creator: role-gated single-transaction campaign creation from one active shop product with current retail prices and optional caps.';
