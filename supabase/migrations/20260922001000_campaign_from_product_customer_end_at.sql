-- ============================================================================
-- 商品頁建立開團：一次寫入客人收單(customer_end_at)與店家收單(end_at)
--
-- 目的：
--   商品編輯頁「建立開團」原本只能送 p_end_at，也就是店家最後收單時間。
--   2026-09-22 老闆確認：客人收單通常比店家收單早一天，建團時就要一次設定。
--
-- 相容：
--   p_customer_end_at 放最後且有 DEFAULT NULL；舊呼叫端不傳仍可用。
--   重新建立 5 參數版為 6 參數版，避免 PostgREST overload ambiguous。
--
-- rollback：
--   重套 supabase/migrations/20260703000010_block_open_without_retail_price_and_backfill.sql
--   內的 rpc_create_campaign_from_product 5 參數版。
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT);
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT,
  p_description     TEXT DEFAULT NULL,
  p_customer_end_at TIMESTAMPTZ DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_no          TEXT;
  v_campaign_id BIGINT;
  v_desc        TEXT;
  v_missing     TEXT;
  v_sort        INT  := 1;
  r             RECORD;
BEGIN
  IF p_customer_end_at IS NOT NULL AND p_end_at IS NOT NULL AND p_customer_end_at > p_end_at THEN
    RAISE EXCEPTION '客人收單時間不能晚於店家收單時間';
  END IF;

  -- 確認 product 在同 tenant
  PERFORM 1 FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  -- 防止「0 元加單金額」：開團前檢查所有 active SKU 是否都有現行 retail 價。
  -- 任何一個沒有 → 列出來、擋下開團（不建任何資料），強迫先補價。
  SELECT string_agg(
           s.sku_code || COALESCE(' (' || NULLIF(btrim(s.variant_name), '') || ')', ''),
           '、' ORDER BY s.id)
    INTO v_missing
    FROM skus s
   WHERE s.product_id = p_product_id
     AND s.tenant_id  = v_tenant
     AND s.status     = 'active'
     AND NOT EXISTS (
       SELECT 1
         FROM prices p
        WHERE p.sku_id       = s.id
          AND p.tenant_id    = v_tenant
          AND p.scope        = 'retail'
          AND p.effective_to IS NULL
     );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '無法開團：以下規格尚未設定零售價，請先到商品頁設定價格後再開團 → %', v_missing;
  END IF;

  -- 文案：優先用呼叫端傳入的 p_description；未提供(NULL)時退回商品本身的 description
  v_desc := COALESCE(
    p_description,
    (SELECT description FROM products WHERE id = p_product_id AND tenant_id = v_tenant)
  );

  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, status, product_id,
    start_at, end_at, customer_end_at, pickup_deadline,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc, 'open', p_product_id,
    NOW(), p_end_at, p_customer_end_at, p_pickup_deadline,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_campaign_id;

  -- 對該 product 的所有 active SKU 補進 campaign_items
  -- （經過上面的檢查，這裡每個 SKU 都保證有現行 retail 價，不會再產生 0）
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

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ) IS
  '從單一商品建團（1:1 invariant）：自動產生團號、設 product_id、塞入所有 active SKU；'
  'p_customer_end_at=客人收單，p_end_at=店家最後收單；'
  '文案 description = COALESCE(p_description, 商品 description)；'
  '建團前若有 active SKU 缺現行 retail 價則 RAISE EXCEPTION 擋下，避免 0 元加單金額。';
