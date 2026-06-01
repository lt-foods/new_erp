-- ============================================================================
-- 2026-07-01: 商品文案寫入時正規化金額逐位括號 $(2)(0)(0) → $200
-- ----------------------------------------------------------------------------
-- 以哪個版本為基底：20260424140000_products_ext.sql（rpc_upsert_product 最新定義）
-- rollback 指回　 ：20260424140000_products_ext.sql
--   （還原時重跑該檔的 rpc_upsert_product 定義即可；normalize_campaign_text 可保留或 DROP。）
--
-- 需求（使用者 2026-07-01）：LINE 文案常把金額逐位數包小括號（鍵盤數字 emoji 殘留），
--   例如「$(2)(0)(0)」。希望「從選品→商品」以及「後台編輯商品文案存檔」時就把它正規化成
--   「$200」，讓 products.description、之後開團、會員顯示都乾淨（不靠顯示層硬清）。
--
-- 做法：
--   1. 新增 normalize_campaign_text(text)：把緊接 $/＄ 的一串 (數字) 去括號合併。
--      只動「$ 後面的逐位括號」，其餘括號（(8小包)、（日本監製）、列點(1)、正常 $159）不碰；
--      不剝 HTML 標籤（TipTap 富文本格式保留），但會清掉 HTML 內文字的 $(2)(0)(0)。
--   2. rpc_upsert_product 寫入 description 前先過 normalize_campaign_text。
--      （rpc_schedule_candidate 採用候選 → 也走 rpc_upsert_product，故一併涵蓋。）
--   舊資料不回填（依使用者決定；既有顯示仍由 member 端 cleanCampaignText 處理）。
-- ============================================================================

-- 1) 正規化函式：$(2)(0)(0) → $200
CREATE OR REPLACE FUNCTION public.normalize_campaign_text(p_text TEXT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v     TEXT;
  v_new TEXT;
BEGIN
  IF p_text IS NULL THEN RETURN NULL; END IF;
  v := p_text;
  -- 反覆把「$/＄ ＋ 已併好的數字」後面的下一個 (數字) 拉進來，直到不再變動，
  -- 即可把任意長度的 $(2)(0)(0)… 合併成 $200…
  LOOP
    v_new := regexp_replace(
      v,
      '([$＄][0-9]*)[（(][[:space:]]*([0-9])[[:space:]]*[)）]',
      '\1\2',
      'g'
    );
    EXIT WHEN v_new = v;
    v := v_new;
  END LOOP;
  RETURN v;
END;
$$;

COMMENT ON FUNCTION public.normalize_campaign_text(TEXT) IS
  '文案正規化：把緊接 $/＄ 的逐位數小括號合併，例如 $(2)(0)(0) → $200；其餘括號與 HTML 標籤不動。';

-- 2) rpc_upsert_product：寫入 description 前先正規化（以 20260424140000 版本為基底，逐字保留，
--    僅新增 v_desc 並在 INSERT / UPDATE 改用 v_desc）
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
  v_desc   TEXT := public.normalize_campaign_text(p_description);  -- 寫入前正規化文案
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
      v_desc, COALESCE(p_status, 'draft'), COALESCE(p_images, '[]'::jsonb),
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
           description          = v_desc,
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
