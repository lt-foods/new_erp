-- ============================================================
-- Price write wrappers（JWT-based）
--
-- 既有 rpc_upsert_price 取 p_tenant_id + p_operator 作 param（service-role 用）。
-- 本 migration 加 authenticated role 的 wrapper：
--   - rpc_ensure_default_sku(p_product_id) → 確保每 product 至少有一個 SKU
--   - rpc_set_retail_price(p_sku_id, p_price, ...) → 包裝 rpc_upsert_price
--
-- 都從 JWT 讀 tenant_id、auth.uid() 讀 operator。
-- ============================================================

-- ============================================================
-- 確保 product 有 default SKU（沒有就建一個 sku_code = product_code）
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_ensure_default_sku(
  p_product_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant  UUID := public._current_tenant_id();
  v_user    UUID := auth.uid();
  v_sku_id  BIGINT;
  v_prod    RECORD;
BEGIN
  -- 先取已有的最小 id（default = 最早建立）
  SELECT id INTO v_sku_id
    FROM skus
   WHERE product_id = p_product_id AND tenant_id = v_tenant
   ORDER BY id
   LIMIT 1;

  IF v_sku_id IS NOT NULL THEN
    RETURN v_sku_id;
  END IF;

  -- 否則建一個（sku_code = product_code、denorm name/brand/category）
  SELECT product_code, name, brand_id, category_id INTO v_prod
    FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF v_prod.product_code IS NULL THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  INSERT INTO skus (
    tenant_id, product_id, sku_code, variant_name, spec,
    base_unit, tax_rate, status,
    product_name, brand_id, category_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, p_product_id, v_prod.product_code, NULL, '{}'::jsonb,
    '個', 0.0500, 'active',
    v_prod.name, v_prod.brand_id, v_prod.category_id,
    v_user, v_user
  ) RETURNING id INTO v_sku_id;

  -- base sku_pack
  INSERT INTO sku_packs (sku_id, unit, qty_in_base, is_default_sale, created_by, updated_by)
  VALUES (v_sku_id, '個', 1, TRUE, v_user, v_user);

  PERFORM public._log_product_audit(v_tenant, 'sku', v_sku_id, 'create', NULL,
    jsonb_build_object('auto_default', TRUE, 'product_id', p_product_id), NULL);
  RETURN v_sku_id;
END;
$$;

-- ============================================================
-- Wrapper：設定零售價
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_set_retail_price(
  p_sku_id         BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_reason         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
BEGIN
  -- 確認 SKU 在同 tenant
  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  -- 呼叫既有 rpc_upsert_price（scope='retail', scope_id=NULL）
  RETURN public.rpc_upsert_price(
    v_tenant, p_sku_id, 'retail', NULL, p_price, p_effective_from, p_reason, v_user
  );
END;
$$;

-- ============================================================
-- Wrapper：設定門市覆寫價（加盟店模式）
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_set_store_price(
  p_sku_id         BIGINT,
  p_store_id       BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_reason         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
BEGIN
  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  -- TODO：驗 store 在同 tenant（stores schema 待 v0.1.1 完整部署後補）
  RETURN public.rpc_upsert_price(
    v_tenant, p_sku_id, 'store', p_store_id, p_price, p_effective_from, p_reason, v_user
  );
END;
$$;

-- Grants
GRANT EXECUTE ON FUNCTION public.rpc_ensure_default_sku TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_retail_price   TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_set_store_price    TO authenticated;
