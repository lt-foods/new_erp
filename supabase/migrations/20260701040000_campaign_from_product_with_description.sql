-- ============================================================================
-- 2026-07-01: rpc_create_campaign_from_product — 開團帶入文案(description)
-- ----------------------------------------------------------------------------
-- 以哪個版本為基底：20260514000010_rpc_singular_product.sql（rpc_create_campaign_from_product 最新定義）
-- rollback 指回　 ：20260514000010_rpc_singular_product.sql
--   （還原時：DROP 本檔的 5 參數版，重跑 20260514000010 的 4 參數版定義與 GRANT。）
--
-- 問題：從商品詳情頁「建立新開團」走 rpc_create_campaign_from_product，INSERT 沒寫
--   description，導致開團的「文案」為 NULL，會員 App 不顯示文案。
--   （對照：從候選池 rpc_schedule_candidate 進的團會把 raw_text 寫進 description，故有文案。）
--
-- 變更：
--   1. rpc_create_campaign_from_product 新增 p_description 參數（DEFAULT NULL）。
--      description = COALESCE(p_description, 該商品 products.description)
--      → 呼叫端（建立新開團視窗）會帶入「商品文案」當預設、可編輯；未帶時退回商品文案。
--   2. 既有「沒文案」的開團，一次性用其商品 products.description 回填。
--   其餘（產團號、塞 active SKU 進 campaign_items）逐字保留。
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT);

CREATE OR REPLACE FUNCTION public.rpc_create_campaign_from_product(
  p_name            TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE,
  p_product_id      BIGINT,
  p_description     TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_no          TEXT;
  v_campaign_id BIGINT;
  v_desc        TEXT;
  v_sort        INT  := 1;
  r             RECORD;
BEGIN
  -- 確認 product 在同 tenant
  PERFORM 1 FROM products WHERE id = p_product_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  -- 文案：優先用呼叫端傳入的 p_description；未提供(NULL)時退回商品本身的 description
  v_desc := COALESCE(
    p_description,
    (SELECT description FROM products WHERE id = p_product_id AND tenant_id = v_tenant)
  );

  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, status, product_id,
    start_at, end_at, pickup_deadline,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc, 'open', p_product_id,
    NOW(), p_end_at, p_pickup_deadline,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_campaign_id;

  -- 對該 product 的所有 active SKU 補進 campaign_items
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

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT) IS
  '從單一商品建團（1:1 invariant）：自動產生團號、設 product_id、塞入所有 active SKU；'
  '文案 description = COALESCE(p_description, 商品 description)。';

-- ----------------------------------------------------------------------------
-- 一次性回填：既有「沒文案」的開團，用其商品的 description 補上（冪等：只補空白者）
-- ----------------------------------------------------------------------------
UPDATE group_buy_campaigns c
   SET description = p.description,
       updated_at  = NOW()
  FROM products p
 WHERE c.product_id = p.id
   AND c.tenant_id  = p.tenant_id
   AND (c.description IS NULL OR btrim(c.description) = '')
   AND p.description IS NOT NULL
   AND btrim(p.description) <> '';
