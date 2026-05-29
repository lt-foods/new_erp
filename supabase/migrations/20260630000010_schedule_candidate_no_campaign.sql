-- ============================================================
-- rpc_schedule_candidate：排程候選商品時「不再自動建開團」
--
-- 變更動機：
--   從選品池排程候選商品時，原本會一次建好
--     draft product + sku + (retail price) + 開團 campaign + campaign_items。
--   現調整為：排程只建 draft product + sku（+ retail price），
--   標記候選為 scheduled、寫入 scheduled_open_at。
--   「開團」改由商品編輯頁的「建立新開團」按鈕手動觸發
--   （走 rpc_create_campaign_from_product）。
--
-- 以哪個版本為基底：
--   20260514000010_rpc_singular_product.sql 內的 rpc_schedule_candidate
--   （時間最新的版本）。本檔僅移除其中 campaign / campaign_items 建立段落，
--   其餘（權限檢查、product/sku 建立、retail price、候選標記）原樣保留。
--
-- Rollback：
--   重新套用 20260514000010_rpc_singular_product.sql 的 rpc_schedule_candidate 定義
--   即可恢復「排程同時建開團」行為。
--
-- Scope：只改 rpc_schedule_candidate，不動表、不動其他 RPC。
-- ============================================================

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
    -- 已有對應商品：沿用既有 product / 第一個 sku，不重建（開團另由商品編輯頁手動建立）
    v_product_id := v_cand.adopted_product_id;

    SELECT product_code INTO v_product_code
      FROM products
     WHERE id = v_product_id AND tenant_id = v_tenant;

    SELECT id INTO v_sku_id
      FROM skus
     WHERE product_id = v_product_id AND tenant_id = v_tenant
     ORDER BY id
     LIMIT 1;
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

  -- NOTE: 不再建立 group_buy_campaigns / campaign_items。
  --       開團改由商品編輯頁「建立新開團」按鈕 (rpc_create_campaign_from_product) 觸發。

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
    'campaign_id',        NULL,
    'campaign_no',        NULL,
    'already_scheduled',  FALSE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_schedule_candidate(BIGINT, DATE, TEXT) TO authenticated;
