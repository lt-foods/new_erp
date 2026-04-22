-- ============================================================
-- Product module write RPCs + Supabase Auth JWT tenant_id hook
--
-- Context:
--   product_schema.sql v0.1 規定「寫入一律走 RPC（SECURITY DEFINER），不開放直接 INSERT/UPDATE」
--   但只寫了 4 個讀取 / 定價 RPC；本 migration 補齊商品主檔寫入 RPC。
--
-- Security model (new convention for write RPCs):
--   - tenant_id 從 JWT 讀取（auth.jwt() ->> 'tenant_id'）、不接受 client 傳入
--   - operator 從 auth.uid() 讀取
--   - 若 JWT 無 tenant_id claim → raise exception
--   - RLS read policy 已用相同 JWT claim（product_schema.sql:366）
--
-- JWT tenant_id hook 需在 Supabase dashboard 啟用（見檔案末）
-- ============================================================

-- ============================================================
-- PART 1: JWT custom access token hook（注入 tenant_id claim）
-- ============================================================

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_claims   jsonb;
  v_user_id  uuid;
  v_tenant   text;
BEGIN
  v_claims  := event->'claims';
  v_user_id := (event->>'user_id')::uuid;

  -- 從 auth.users.raw_app_meta_data.tenant_id 取
  -- 使用 app_metadata（admin-controlled）而非 user_metadata（user-editable）
  SELECT raw_app_meta_data->>'tenant_id'
    INTO v_tenant
    FROM auth.users
   WHERE id = v_user_id;

  IF v_tenant IS NOT NULL THEN
    v_claims := jsonb_set(v_claims, '{tenant_id}', to_jsonb(v_tenant));
  END IF;

  event := jsonb_set(event, '{claims}', v_claims);
  RETURN event;
END;
$$;

COMMENT ON FUNCTION public.custom_access_token_hook IS
  'Supabase Auth hook：注入 raw_app_meta_data.tenant_id 到 JWT。需在 Dashboard → Authentication → Hooks 啟用。';

-- Supabase Auth 需要 supabase_auth_admin 才能呼叫 hook
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM authenticated, anon, public;

-- ============================================================
-- PART 2: Helpers
-- ============================================================

-- 從 JWT 讀當前 tenant_id；缺漏 → raise
CREATE OR REPLACE FUNCTION public._current_tenant_id()
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant_text TEXT;
BEGIN
  v_tenant_text := auth.jwt() ->> 'tenant_id';
  IF v_tenant_text IS NULL OR v_tenant_text = '' THEN
    RAISE EXCEPTION 'JWT missing tenant_id claim; ensure custom_access_token_hook is enabled and user has app_metadata.tenant_id set';
  END IF;
  RETURN v_tenant_text::UUID;
END;
$$;

-- 寫 audit log（append-only）
CREATE OR REPLACE FUNCTION public._log_product_audit(
  p_tenant_id   UUID,
  p_entity_type TEXT,
  p_entity_id   BIGINT,
  p_action      TEXT,
  p_before      JSONB,
  p_after       JSONB,
  p_reason      TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO product_audit_log (
    tenant_id, entity_type, entity_id, action,
    before_value, after_value, reason, operator_id
  ) VALUES (
    p_tenant_id, p_entity_type, p_entity_id, p_action,
    p_before, p_after, p_reason, auth.uid()
  );
END;
$$;

-- ============================================================
-- PART 3: Brand / Category upsert
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_upsert_brand(
  p_id        BIGINT,         -- null = INSERT
  p_code      TEXT,
  p_name      TEXT,
  p_is_active BOOLEAN DEFAULT TRUE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_before JSONB;
  v_id     BIGINT;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO brands (tenant_id, code, name, is_active, created_by, updated_by)
    VALUES (v_tenant, p_code, p_name, p_is_active, v_user, v_user)
    RETURNING id INTO v_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id, 'create', NULL,
      jsonb_build_object('kind','brand','code',p_code,'name',p_name), NULL);
  ELSE
    SELECT to_jsonb(b) INTO v_before FROM brands b
      WHERE b.id = p_id AND b.tenant_id = v_tenant;
    IF v_before IS NULL THEN
      RAISE EXCEPTION 'brand % not found or cross-tenant', p_id;
    END IF;
    UPDATE brands
       SET code = p_code, name = p_name, is_active = p_is_active,
           updated_by = v_user, updated_at = NOW()
     WHERE id = p_id;
    v_id := p_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id, 'update', v_before,
      jsonb_build_object('code',p_code,'name',p_name,'is_active',p_is_active), NULL);
  END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_category(
  p_id         BIGINT,
  p_parent_id  BIGINT,
  p_code       TEXT,
  p_name       TEXT,
  p_level      SMALLINT,
  p_sort_order INTEGER DEFAULT 0,
  p_is_active  BOOLEAN DEFAULT TRUE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_before JSONB;
  v_id     BIGINT;
BEGIN
  -- parent 必須在同 tenant
  IF p_parent_id IS NOT NULL THEN
    PERFORM 1 FROM categories WHERE id = p_parent_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'parent category % not in tenant', p_parent_id; END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO categories (tenant_id, parent_id, code, name, level, sort_order, is_active, created_by, updated_by)
    VALUES (v_tenant, p_parent_id, p_code, p_name, p_level, p_sort_order, p_is_active, v_user, v_user)
    RETURNING id INTO v_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id, 'create', NULL,
      jsonb_build_object('kind','category','code',p_code,'name',p_name,'level',p_level), NULL);
  ELSE
    SELECT to_jsonb(c) INTO v_before FROM categories c
      WHERE c.id = p_id AND c.tenant_id = v_tenant;
    IF v_before IS NULL THEN
      RAISE EXCEPTION 'category % not found or cross-tenant', p_id;
    END IF;
    UPDATE categories
       SET parent_id = p_parent_id, code = p_code, name = p_name,
           level = p_level, sort_order = p_sort_order, is_active = p_is_active,
           updated_by = v_user, updated_at = NOW()
     WHERE id = p_id;
    v_id := p_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id, 'update', v_before,
      jsonb_build_object('code',p_code,'name',p_name,'level',p_level), NULL);
  END IF;
  RETURN v_id;
END;
$$;

-- ============================================================
-- PART 4: Product upsert
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_upsert_product(
  p_id           BIGINT,
  p_product_code TEXT,
  p_name         TEXT,
  p_short_name   TEXT,
  p_brand_id     BIGINT,
  p_category_id  BIGINT,
  p_description  TEXT,
  p_status       TEXT,
  p_images       JSONB DEFAULT '[]'::jsonb,
  p_reason       TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_before JSONB;
  v_id     BIGINT;
BEGIN
  -- brand / category 必須在同 tenant
  IF p_brand_id IS NOT NULL THEN
    PERFORM 1 FROM brands WHERE id = p_brand_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'brand % not in tenant', p_brand_id; END IF;
  END IF;
  IF p_category_id IS NOT NULL THEN
    PERFORM 1 FROM categories WHERE id = p_category_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'category % not in tenant', p_category_id; END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO products (
      tenant_id, product_code, name, short_name, brand_id, category_id,
      description, status, images, created_by, updated_by
    ) VALUES (
      v_tenant, p_product_code, p_name, p_short_name, p_brand_id, p_category_id,
      p_description, COALESCE(p_status, 'draft'), COALESCE(p_images, '[]'::jsonb),
      v_user, v_user
    ) RETURNING id INTO v_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id, 'create', NULL,
      to_jsonb((SELECT p FROM products p WHERE p.id = v_id)), p_reason);
  ELSE
    SELECT to_jsonb(p) INTO v_before FROM products p
      WHERE p.id = p_id AND p.tenant_id = v_tenant;
    IF v_before IS NULL THEN
      RAISE EXCEPTION 'product % not found or cross-tenant', p_id;
    END IF;
    UPDATE products
       SET product_code = p_product_code, name = p_name, short_name = p_short_name,
           brand_id = p_brand_id, category_id = p_category_id,
           description = p_description, status = COALESCE(p_status, status),
           images = COALESCE(p_images, images),
           updated_by = v_user, updated_at = NOW()
     WHERE id = p_id;
    v_id := p_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id,
      CASE WHEN v_before->>'status' IS DISTINCT FROM p_status THEN 'status_change' ELSE 'update' END,
      v_before, to_jsonb((SELECT p FROM products p WHERE p.id = v_id)), p_reason);
  END IF;
  RETURN v_id;
END;
$$;

-- ============================================================
-- PART 5: SKU upsert（INSERT 時自動補 base sku_pack）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_upsert_sku(
  p_id           BIGINT,
  p_product_id   BIGINT,
  p_sku_code     TEXT,
  p_variant_name TEXT,
  p_spec         JSONB,
  p_base_unit    TEXT,
  p_weight_g     NUMERIC,
  p_tax_rate     NUMERIC,
  p_status       TEXT,
  p_reason       TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant  UUID := public._current_tenant_id();
  v_user    UUID := auth.uid();
  v_before  JSONB;
  v_id      BIGINT;
  v_prod    RECORD;
BEGIN
  -- product 必須在同 tenant，取 denorm 欄位
  SELECT id, name, brand_id, category_id INTO v_prod
    FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF v_prod.id IS NULL THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO skus (
      tenant_id, product_id, sku_code, variant_name, spec,
      base_unit, weight_g, tax_rate, status,
      product_name, category_id, brand_id,
      created_by, updated_by
    ) VALUES (
      v_tenant, p_product_id, p_sku_code, p_variant_name, COALESCE(p_spec, '{}'::jsonb),
      COALESCE(p_base_unit, '個'), p_weight_g, COALESCE(p_tax_rate, 0.0500), COALESCE(p_status, 'draft'),
      v_prod.name, v_prod.category_id, v_prod.brand_id,
      v_user, v_user
    ) RETURNING id INTO v_id;

    -- 自動建 base sku_pack（schema 規定每 SKU 至少一筆 unit=base_unit, qty_in_base=1）
    INSERT INTO sku_packs (sku_id, unit, qty_in_base, is_default_sale, created_by, updated_by)
    VALUES (v_id, COALESCE(p_base_unit, '個'), 1, TRUE, v_user, v_user);

    PERFORM public._log_product_audit(v_tenant, 'sku', v_id, 'create', NULL,
      to_jsonb((SELECT s FROM skus s WHERE s.id = v_id)), p_reason);
  ELSE
    SELECT to_jsonb(s) INTO v_before FROM skus s
      WHERE s.id = p_id AND s.tenant_id = v_tenant;
    IF v_before IS NULL THEN
      RAISE EXCEPTION 'sku % not found or cross-tenant', p_id;
    END IF;
    UPDATE skus
       SET sku_code = p_sku_code, variant_name = p_variant_name,
           spec = COALESCE(p_spec, spec), base_unit = COALESCE(p_base_unit, base_unit),
           weight_g = p_weight_g, tax_rate = COALESCE(p_tax_rate, tax_rate),
           status = COALESCE(p_status, status),
           product_name = v_prod.name, brand_id = v_prod.brand_id, category_id = v_prod.category_id,
           updated_by = v_user, updated_at = NOW()
     WHERE id = p_id;
    v_id := p_id;
    PERFORM public._log_product_audit(v_tenant, 'sku', v_id,
      CASE WHEN v_before->>'status' IS DISTINCT FROM p_status THEN 'status_change' ELSE 'update' END,
      v_before, to_jsonb((SELECT s FROM skus s WHERE s.id = v_id)), p_reason);
  END IF;
  RETURN v_id;
END;
$$;

-- ============================================================
-- PART 6: Barcode add / retire
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_add_external_barcode(
  p_sku_id        BIGINT,
  p_barcode_value TEXT,
  p_type          TEXT,              -- ean13/ean8/upca/upce/code128（禁用 internal）
  p_unit          TEXT,
  p_pack_qty      NUMERIC DEFAULT 1,
  p_is_primary    BOOLEAN DEFAULT FALSE
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_id     BIGINT;
BEGIN
  IF p_type = 'internal' THEN
    RAISE EXCEPTION 'use rpc_generate_internal_barcode for internal type';
  END IF;
  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'sku % not in tenant', p_sku_id; END IF;

  -- 設為 primary 前先清舊 primary
  IF p_is_primary THEN
    UPDATE barcodes SET is_primary = FALSE
     WHERE sku_id = p_sku_id AND is_primary = TRUE;
  END IF;

  INSERT INTO barcodes (tenant_id, barcode_value, sku_id, unit, pack_qty, type, is_primary, created_by)
  VALUES (v_tenant, p_barcode_value, p_sku_id, p_unit, p_pack_qty, p_type, p_is_primary, auth.uid())
  RETURNING id INTO v_id;

  PERFORM public._log_product_audit(v_tenant, 'barcode', v_id, 'create', NULL,
    jsonb_build_object('barcode_value',p_barcode_value,'sku_id',p_sku_id,'type',p_type), NULL);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_retire_barcode(
  p_barcode_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_before JSONB;
BEGIN
  SELECT to_jsonb(b) INTO v_before FROM barcodes b
    WHERE b.id = p_barcode_id AND b.tenant_id = v_tenant;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'barcode % not found or cross-tenant', p_barcode_id;
  END IF;
  UPDATE barcodes
     SET status = 'retired', retired_at = NOW(), is_primary = FALSE
   WHERE id = p_barcode_id;
  PERFORM public._log_product_audit(v_tenant, 'barcode', p_barcode_id, 'retire',
    v_before, jsonb_build_object('status','retired'), NULL);
END;
$$;

-- ============================================================
-- PART 7: Grants（authenticated role 可呼叫 write RPC）
-- ============================================================

GRANT EXECUTE ON FUNCTION public.rpc_upsert_brand         TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_category      TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_product       TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_sku           TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_add_external_barcode TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_retire_barcode       TO authenticated;

-- ============================================================
-- Dashboard setup 提醒（遷移後手動一次）
-- ============================================================
--
-- 1. Supabase Dashboard → Authentication → Hooks
--    - Enable "Custom Access Token" hook
--    - Function: public.custom_access_token_hook
--
-- 2. 建立首位 admin user（任選其一）
--    Option A. Dashboard → Authentication → Users → Add user (email/password)
--    Option B. 用 service_role SQL：
--
--       -- 先 sign-up，然後把 tenant_id 寫進 app_metadata
--       UPDATE auth.users
--          SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) ||
--              jsonb_build_object('tenant_id', '00000000-0000-0000-0000-000000000001')
--        WHERE email = '<your-admin-email>';
--
-- 3. 建 seed 資料（選做、方便測試）
--    INSERT INTO brands (tenant_id, code, name) VALUES
--      ('00000000-0000-0000-0000-000000000001', 'DEFAULT', '預設品牌');
--    INSERT INTO categories (tenant_id, code, name, level) VALUES
--      ('00000000-0000-0000-0000-000000000001', 'DEFAULT', '預設分類', 1);
