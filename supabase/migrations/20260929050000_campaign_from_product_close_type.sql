-- ============================================================================
-- 20260929050000_campaign_from_product_close_type.sql
--
-- 商品頁「建立開團」彈窗要能選開團類別（老闆 9/30 手機建團時提的）。
-- 原本 rpc_create_campaign_from_product 不收 close_type / sales_channel，一律用欄位預設
-- （常規 / 主商城），要快團、限量、美食列車、漂漂館只能建完再到開團編輯改。
--
-- rpc_create_campaign_from_product 多收 p_close_type（預設 'regular'）、p_sales_channel
-- （預設 'main'），INSERT 時就寫進去 —— 開團當下的 LINE 記事本自動發文 trigger 看
-- sales_channel，建完再改就來不及了。舊呼叫（匯入頁只帶 5 個參數）不用改。
--
-- 基底：rpc_create_campaign_from_product @ 20260927010000（只加兩個參數、兩個欄位、驗證）。
--   已對過線上 pg_get_functiondef，與 20260927010000 相同。
-- rollback：DROP 11 參數版，重跑 20260927010000 那段 CREATE。
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT,
  p_description     TEXT DEFAULT NULL,
  p_customer_end_at TIMESTAMPTZ DEFAULT NULL,
  p_start_at        TIMESTAMPTZ DEFAULT NULL,
  p_auto_open       BOOLEAN DEFAULT FALSE,
  p_line_note       BOOLEAN DEFAULT TRUE,
  p_close_type      TEXT    DEFAULT 'regular',
  p_sales_channel   TEXT    DEFAULT 'main'
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
  IF COALESCE(p_close_type, 'regular') NOT IN ('regular', 'fast', 'limited', 'food_train') THEN
    RAISE EXCEPTION '開團類別不正確：%', p_close_type;
  END IF;
  IF COALESCE(p_sales_channel, 'main') NOT IN ('main', 'piaopiao') THEN
    RAISE EXCEPTION '銷售通路不正確：%', p_sales_channel;
  END IF;

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
    start_at, end_at, customer_end_at, pickup_deadline, auto_open, line_note_enabled,
    close_type, sales_channel,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc,
    CASE WHEN v_is_future THEN 'draft' ELSE 'open' END,
    p_product_id, v_start_at, p_end_at, p_customer_end_at, p_pickup_deadline,
    COALESCE(p_auto_open, FALSE) AND v_is_future,
    COALESCE(p_line_note, TRUE),
    -- 漂漂館 = 常規 + sales_channel='piaopiao'（同 CampaignForm 的收單類型下拉）
    CASE WHEN COALESCE(p_sales_channel, 'main') = 'piaopiao' THEN 'regular' ELSE COALESCE(p_close_type, 'regular') END,
    COALESCE(p_sales_channel, 'main'),
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

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TEXT, TEXT)
  TO authenticated;
COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, BOOLEAN, TEXT, TEXT) IS
    '從單一商品建團：未來 p_start_at 建為草稿，並可用 p_auto_open 沿用既有排程自動開團；'
  '未傳 p_start_at 的舊呼叫維持立即開團，自動開團固定關閉；p_line_note=FALSE 開團時不發 LINE 記事本；'
  'p_close_type / p_sales_channel 指定開團類別（漂漂館 = regular + piaopiao）。';
