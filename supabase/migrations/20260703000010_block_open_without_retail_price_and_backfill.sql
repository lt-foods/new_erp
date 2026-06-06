-- ============================================================================
-- 2026-07-03: 防止「開團加單金額 = 0」 + 回填既有 0 元加單金額
-- ----------------------------------------------------------------------------
-- 以哪個版本為基底：20260701040000_campaign_from_product_with_description.sql
--   （rpc_create_campaign_from_product 5 參數版的最新定義 — 含 p_description、
--     SKU 迴圈已使用 effective_to IS NULL 的現行 retail 價查詢）
-- rollback 指回　 ：20260701040000_campaign_from_product_with_description.sql
--   （還原時：DROP 本檔的 5 參數版，重跑 20260701040000 的定義與 GRANT；
--     Part 2 backfill 為一次性資料修正，無法自動回滾。）
--
-- 背景（問題現象）：
--   團媽回報「開團的加單金額是 0，但商品頁金額正確」，每天約 3-4 個商品。
--   根因：
--     1. 從商品開團走 rpc_create_campaign_from_product，活動直接以 status='open' 建立。
--        若該 SKU 開團當下尚未設定 retail 定價，campaign_items.unit_price 被
--        COALESCE(..., 0) 塞成 0。
--     2. 事後才補上零售價時，價格同步 trigger _sync_retail_price_to_campaigns
--        （20260514000008 之後）只同步 status='draft' 的團，open 的團被略過，
--        故加單金額永遠卡在 0；而商品頁是 live 讀 prices，所以顯示正確。
--
-- 變更（對應使用者選定方案 1 + 3）：
--   Part 1（防止再發生）：rpc_create_campaign_from_product 在建團前先檢查——
--     若該商品有任何 active SKU 尚無「現行 retail 價」(effective_to IS NULL)，
--     直接 RAISE EXCEPTION 並列出缺價的 SKU，整筆開團 rollback（不建任何資料），
--     強迫先到商品頁補價再開團。其餘邏輯（團號、文案、塞 SKU）逐字保留。
--   Part 2（回填壞資料）：把現存 draft/open 團裡 unit_price=0、但該 SKU 現在
--     已有現行 retail 價(>0) 的 campaign_items，回填成現行 retail 價。
--     （只動 draft/open；closed/ordered/... 等已凍結狀態不碰，避免改到歷史/訂單參照。）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Part 1: rpc_create_campaign_from_product — 開團前擋下缺價 SKU
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT);

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
  v_missing     TEXT;
  v_sort        INT  := 1;
  r             RECORD;
BEGIN
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
    start_at, end_at, pickup_deadline,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_name, v_desc, 'open', p_product_id,
    NOW(), p_end_at, p_pickup_deadline,
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

GRANT EXECUTE ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_campaign_from_product(TEXT, TIMESTAMPTZ, DATE, BIGINT, TEXT) IS
  '從單一商品建團（1:1 invariant）：自動產生團號、設 product_id、塞入所有 active SKU；'
  '文案 description = COALESCE(p_description, 商品 description)；'
  '建團前若有 active SKU 缺現行 retail 價則 RAISE EXCEPTION 擋下，避免 0 元加單金額。';

-- ----------------------------------------------------------------------------
-- Part 2: 一次性回填既有 0 元加單金額（只動 draft/open 團）
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  cnt INT;
BEGIN
  WITH current_retail AS (
    SELECT DISTINCT ON (p.tenant_id, p.sku_id)
           p.tenant_id, p.sku_id, p.price
      FROM prices p
     WHERE p.scope        = 'retail'
       AND p.effective_to IS NULL
     ORDER BY p.tenant_id, p.sku_id, p.effective_from DESC
  ),
  updated AS (
    UPDATE campaign_items ci
       SET unit_price = cr.price,
           updated_at = NOW()
      FROM current_retail cr,
           group_buy_campaigns gbc
     WHERE ci.sku_id      = cr.sku_id
       AND ci.tenant_id   = cr.tenant_id
       AND ci.campaign_id = gbc.id
       AND gbc.tenant_id  = ci.tenant_id
       AND gbc.status IN ('draft','open')
       AND COALESCE(ci.unit_price, 0) = 0
       AND cr.price > 0
    RETURNING 1
  )
  SELECT COUNT(*) INTO cnt FROM updated;
  RAISE NOTICE 'Backfill: corrected % campaign_items with 0 unit_price → current retail price', cnt;
END $$;
