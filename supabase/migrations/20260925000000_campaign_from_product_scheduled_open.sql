-- ============================================================================
-- 商品頁建立開團：支援未來開團時間與自動開團
--
-- 未來開團強制先建草稿；勾選自動開團時，沿用
-- 20260924040000_line_note_scheduled_posting.sql 的 cron 與開團 trigger。
-- p_start_at / p_auto_open 都放最後且有預設值，舊匯入呼叫不需修改。
--
-- rollback：DROP 8 參數版，再重套
-- 20260922001000_campaign_from_product_customer_end_at.sql 的 6 參數定義。
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT);
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN);

CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT,
  p_description     TEXT DEFAULT NULL,
  p_customer_end_at TIMESTAMPTZ DEFAULT NULL,
  p_start_at        TIMESTAMPTZ DEFAULT NULL,
  p_auto_open       BOOLEAN DEFAULT FALSE
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
  v_start_at    TIMESTAMPTZ;
  v_is_future   BOOLEAN;
  v_sort        INT := 1;
  r             RECORD;
BEGIN
  v_start_at := COALESCE(p_start_at, NOW());
  v_is_future := v_start_at > NOW();

  IF p_end_at IS NULL THEN
    RAISE EXCEPTION '請設定店家收單時間';
  END IF;
  IF p_customer_end_at IS NOT NULL AND p_customer_end_at > p_end_at THEN
    RAISE EXCEPTION '客人收單時間不能晚於店家收單時間';
  END IF;
  IF p_customer_end_at IS NOT NULL AND v_start_at >= p_customer_end_at THEN
    RAISE EXCEPTION '開團時間必須早於客人收單時間';
  END IF;
  IF p_customer_end_at IS NULL AND v_start_at >= p_end_at THEN
    RAISE EXCEPTION '開團時間必須早於店家收單時間';
  END IF;

  -- 確認 product 在同 tenant
  PERFORM 1 FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  -- 開團前檢查所有 active SKU 都有現行 retail 價，防止 0 元加單。
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

  v_desc := COALESCE(
    p_description,
    (SELECT description FROM products WHERE id = p_product_id AND tenant_id = v_tenant)
  );
  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, status, product_id,
    start_at, end_at, customer_end_at, pickup_deadline, auto_open,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc,
    CASE WHEN v_is_future THEN 'draft' ELSE 'open' END,
    p_product_id, v_start_at, p_end_at, p_customer_end_at, p_pickup_deadline,
    COALESCE(p_auto_open, FALSE) AND v_is_future,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_campaign_id;

  -- 將該商品的所有 active SKU 補進 campaign_items。
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

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) IS
  '從單一商品建團：未來 p_start_at 建為草稿，並可用 p_auto_open 沿用既有排程自動開團；'
  '未傳 p_start_at 的舊呼叫維持立即開團，自動開團固定關閉；'
  '保留商品文案、active SKU 與現行 retail 價檢查。';
