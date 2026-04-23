-- ============================================================
-- Product schema extension — 樂樂對齊（B3）
--
-- Adds 11 columns to products + drops/recreates rpc_upsert_product
-- with the new signature. Reference: 樂樂舊系統 mng_product2 modal.
-- ============================================================

-- ============================================================
-- PART 1: Enum types
-- ============================================================

CREATE TYPE product_storage_type AS ENUM (
  'room_temp',      -- 常溫
  'refrigerated',   -- 冷藏
  'frozen',         -- 冷凍
  'meal_train'      -- 餐車（即時配送）
);
COMMENT ON TYPE product_storage_type IS '商品儲存溫層（樂樂 mng_product2.storage_type）';

CREATE TYPE product_sale_mode AS ENUM (
  'preorder',        -- 預購
  'in_stock_only',   -- 僅現貨
  'limited'          -- 限量
);
COMMENT ON TYPE product_sale_mode IS '銷售模式（團購預購 / 現貨 / 限量）';

-- ============================================================
-- PART 2: ALTER products
-- ============================================================

ALTER TABLE products
  ADD COLUMN storage_type         product_storage_type,
  ADD COLUMN customized_id        TEXT,
  ADD COLUMN customized_text      TEXT,
  ADD COLUMN storage_location     TEXT,
  ADD COLUMN default_supplier_id  BIGINT REFERENCES suppliers(id),
  ADD COLUMN count_for_start_sale INTEGER,
  ADD COLUMN limit_time           TIMESTAMPTZ,
  ADD COLUMN user_note            TEXT,
  ADD COLUMN user_note_public     TEXT,
  ADD COLUMN stop_shipping        BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN is_for_shop          BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN sale_mode            product_sale_mode NOT NULL DEFAULT 'preorder',
  ADD COLUMN vip_level_min        SMALLINT NOT NULL DEFAULT 0
    CHECK (vip_level_min BETWEEN 0 AND 10),
  ADD CONSTRAINT chk_products_customized_text_len
    CHECK (customized_text IS NULL OR char_length(customized_text) <= 7),
  ADD CONSTRAINT chk_products_count_for_start_sale_non_negative
    CHECK (count_for_start_sale IS NULL OR count_for_start_sale >= 0);

COMMENT ON COLUMN products.storage_type         IS '儲存溫層；NULL = 未設定';
COMMENT ON COLUMN products.customized_id        IS '客製編號（列印 / 標籤用）';
COMMENT ON COLUMN products.customized_text      IS '客製文字（≤ 7 字，列印標籤）';
COMMENT ON COLUMN products.storage_location     IS '倉儲存放位置 / 儲位';
COMMENT ON COLUMN products.default_supplier_id  IS '預設供應商（進貨預帶）';
COMMENT ON COLUMN products.count_for_start_sale IS '團購成團最低數量（NULL = 無門檻）';
COMMENT ON COLUMN products.limit_time           IS '收單時間（團購截止）';
COMMENT ON COLUMN products.user_note            IS '內部備註';
COMMENT ON COLUMN products.user_note_public     IS '公開備註（顯示給客人）';
COMMENT ON COLUMN products.stop_shipping        IS 'TRUE = 暫停出貨（臨時停售）';
COMMENT ON COLUMN products.is_for_shop          IS 'TRUE = 上架個人賣場';
COMMENT ON COLUMN products.sale_mode            IS '銷售模式：preorder/in_stock_only/limited';
COMMENT ON COLUMN products.vip_level_min        IS 'VIP 最低購買等級（0 = 無限制、10 = 最高 VIP）';

-- default_supplier_id lookup index（進貨單建立時撈供應商 → 商品清單）
CREATE INDEX idx_products_default_supplier
  ON products (tenant_id, default_supplier_id)
  WHERE default_supplier_id IS NOT NULL;

-- limit_time lookup index（收單排程：找出即將到期 / 已到期的團購品）
CREATE INDEX idx_products_limit_time
  ON products (tenant_id, limit_time)
  WHERE limit_time IS NOT NULL;

-- ============================================================
-- PART 3: rpc_upsert_product — drop + recreate with new signature
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_upsert_product(
  BIGINT, TEXT, TEXT, TEXT, BIGINT, BIGINT, TEXT, TEXT, JSONB, TEXT
);

CREATE OR REPLACE FUNCTION public.rpc_upsert_product(
  p_id                   BIGINT,
  p_product_code         TEXT,
  p_name                 TEXT,
  p_short_name           TEXT,
  p_brand_id             BIGINT,
  p_category_id          BIGINT,
  p_description          TEXT,
  p_status               TEXT,
  p_images               JSONB                DEFAULT '[]'::jsonb,
  p_storage_type         product_storage_type DEFAULT NULL,
  p_customized_id        TEXT                 DEFAULT NULL,
  p_customized_text      TEXT                 DEFAULT NULL,
  p_storage_location     TEXT                 DEFAULT NULL,
  p_default_supplier_id  BIGINT               DEFAULT NULL,
  p_count_for_start_sale INTEGER              DEFAULT NULL,
  p_limit_time           TIMESTAMPTZ          DEFAULT NULL,
  p_user_note            TEXT                 DEFAULT NULL,
  p_user_note_public     TEXT                 DEFAULT NULL,
  p_stop_shipping        BOOLEAN              DEFAULT FALSE,
  p_is_for_shop          BOOLEAN              DEFAULT TRUE,
  p_sale_mode            product_sale_mode    DEFAULT 'preorder',
  p_vip_level_min        SMALLINT             DEFAULT 0,
  p_reason               TEXT                 DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_before JSONB;
  v_id     BIGINT;
BEGIN
  -- brand / category / supplier 必須在同 tenant
  IF p_brand_id IS NOT NULL THEN
    PERFORM 1 FROM brands WHERE id = p_brand_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'brand % not in tenant', p_brand_id; END IF;
  END IF;
  IF p_category_id IS NOT NULL THEN
    PERFORM 1 FROM categories WHERE id = p_category_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'category % not in tenant', p_category_id; END IF;
  END IF;
  IF p_default_supplier_id IS NOT NULL THEN
    PERFORM 1 FROM suppliers WHERE id = p_default_supplier_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'supplier % not in tenant', p_default_supplier_id; END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO products (
      tenant_id, product_code, name, short_name, brand_id, category_id,
      description, status, images,
      storage_type, customized_id, customized_text, storage_location,
      default_supplier_id, count_for_start_sale, limit_time,
      user_note, user_note_public, stop_shipping, is_for_shop,
      sale_mode, vip_level_min,
      created_by, updated_by
    ) VALUES (
      v_tenant, p_product_code, p_name, p_short_name, p_brand_id, p_category_id,
      p_description, COALESCE(p_status, 'draft'), COALESCE(p_images, '[]'::jsonb),
      p_storage_type, p_customized_id, p_customized_text, p_storage_location,
      p_default_supplier_id, p_count_for_start_sale, p_limit_time,
      p_user_note, p_user_note_public,
      COALESCE(p_stop_shipping, FALSE), COALESCE(p_is_for_shop, TRUE),
      COALESCE(p_sale_mode, 'preorder'), COALESCE(p_vip_level_min, 0),
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
       SET product_code         = p_product_code,
           name                 = p_name,
           short_name           = p_short_name,
           brand_id             = p_brand_id,
           category_id          = p_category_id,
           description          = p_description,
           status               = COALESCE(p_status, status),
           images               = COALESCE(p_images, images),
           storage_type         = p_storage_type,
           customized_id        = p_customized_id,
           customized_text      = p_customized_text,
           storage_location     = p_storage_location,
           default_supplier_id  = p_default_supplier_id,
           count_for_start_sale = p_count_for_start_sale,
           limit_time           = p_limit_time,
           user_note            = p_user_note,
           user_note_public     = p_user_note_public,
           stop_shipping        = COALESCE(p_stop_shipping, stop_shipping),
           is_for_shop          = COALESCE(p_is_for_shop, is_for_shop),
           sale_mode            = COALESCE(p_sale_mode, sale_mode),
           vip_level_min        = COALESCE(p_vip_level_min, vip_level_min),
           updated_by           = v_user,
           updated_at           = NOW()
     WHERE id = p_id;
    v_id := p_id;
    PERFORM public._log_product_audit(v_tenant, 'product', v_id,
      CASE WHEN v_before->>'status' IS DISTINCT FROM p_status THEN 'status_change' ELSE 'update' END,
      v_before, to_jsonb((SELECT p FROM products p WHERE p.id = v_id)), p_reason);
  END IF;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_product(
  BIGINT, TEXT, TEXT, TEXT, BIGINT, BIGINT, TEXT, TEXT, JSONB,
  product_storage_type, TEXT, TEXT, TEXT, BIGINT, INTEGER, TIMESTAMPTZ,
  TEXT, TEXT, BOOLEAN, BOOLEAN, product_sale_mode, SMALLINT, TEXT
) TO authenticated;
