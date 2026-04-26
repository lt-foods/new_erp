-- ============================================================
-- PR 手動建立：A. 針對單一 campaign 建 PR / B. 全空白手動 PR
-- TEST: docs/TEST-pr-manual-creation.md
--
-- 設計決策（2026-04-26 確認）：
--   1. campaign PR 與 close_date PR 完全允許共存（不互斥）
--      → 同 campaign 不可重複（源 source_campaign_id 守）
--   2. 全空白 PR 無守衛（隨時可建）
--   3. campaign PR 只允許 closed campaign（不允許 open）
-- ============================================================

-- ============================================================
-- 1. SCHEMA: purchase_requests source_type 加 'campaign' + source_campaign_id
-- ============================================================

ALTER TABLE purchase_requests
  DROP CONSTRAINT IF EXISTS purchase_requests_source_type_check;

ALTER TABLE purchase_requests
  ADD CONSTRAINT purchase_requests_source_type_check
  CHECK (source_type IN ('manual','close_date','campaign'));

ALTER TABLE purchase_requests
  ADD COLUMN IF NOT EXISTS source_campaign_id BIGINT
  REFERENCES group_buy_campaigns(id);

-- 重寫一致性 CHECK
ALTER TABLE purchase_requests
  DROP CONSTRAINT IF EXISTS chk_pr_source_close_date;

ALTER TABLE purchase_requests
  DROP CONSTRAINT IF EXISTS chk_pr_source_consistency;

ALTER TABLE purchase_requests
  ADD CONSTRAINT chk_pr_source_consistency CHECK (
    (source_type = 'close_date' AND source_close_date IS NOT NULL) OR
    (source_type = 'campaign'   AND source_campaign_id IS NOT NULL) OR
    (source_type = 'manual')
  );

CREATE INDEX IF NOT EXISTS idx_pr_campaign ON purchase_requests
  (tenant_id, source_campaign_id) WHERE source_type = 'campaign';

-- ============================================================
-- 2. RPC: rpc_create_pr_from_campaign
--    針對單一 closed campaign 建 PR；不影響同日 close_date PR
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_campaign(
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_camp_tenant    UUID;
  v_camp_status    TEXT;
  v_close_date     DATE;
  v_existing_pr_id BIGINT;
  v_demand_count   INTEGER;
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
BEGIN
  -- 1. 載入 campaign + 守衛
  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_camp_tenant, v_camp_status, v_close_date
    FROM group_buy_campaigns
   WHERE id = p_campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;

  IF v_camp_tenant <> v_tenant THEN
    RAISE EXCEPTION 'tenant mismatch';
  END IF;

  IF v_camp_status <> 'closed' THEN
    RAISE EXCEPTION 'campaign % not in closed status (current: %)',
      p_campaign_id, v_camp_status;
  END IF;

  -- 2. 守衛：同 campaign 已有未取消 PR
  SELECT id INTO v_existing_pr_id
    FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND source_type = 'campaign'
     AND source_campaign_id = p_campaign_id
     AND status <> 'cancelled'
   LIMIT 1;

  IF v_existing_pr_id IS NOT NULL THEN
    RAISE EXCEPTION 'campaign % already has PR (id=%)',
      p_campaign_id, v_existing_pr_id
      USING HINT = '請至既有採購單繼續編輯，或先取消後重開';
  END IF;

  -- 3. 守衛：是否有可彙總的訂單
  SELECT COUNT(*) INTO v_demand_count
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE co.tenant_id = v_tenant
     AND co.campaign_id = p_campaign_id
     AND co.status NOT IN ('cancelled','expired')
     AND coi.status NOT IN ('cancelled','expired');

  IF v_demand_count = 0 THEN
    RAISE EXCEPTION 'no orders to aggregate for campaign %', p_campaign_id;
  END IF;

  -- 4. dest location
  SELECT id INTO v_dest_loc FROM locations
   WHERE tenant_id = v_tenant
   ORDER BY id LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  -- 5. PR header
  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_campaign_id, source_close_date,
    source_location_id, status, total_amount,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'campaign', p_campaign_id, v_close_date,
    v_dest_loc, 'draft', 0,
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  -- 6. items：彙總該 campaign 的 SKU 需求 + price/cost snapshot
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested,
    suggested_supplier_id, unit_cost,
    retail_price, franchise_price,
    source_campaign_id,
    created_by, updated_by
  )
  SELECT
    v_pr_id, agg.sku_id, agg.qty_total,
    ss.supplier_id, COALESCE(ss.default_unit_cost, 0),
    pr_retail.price, pr_franchise.price,
    p_campaign_id, p_operator, p_operator
  FROM (
    SELECT coi.sku_id, SUM(coi.qty) AS qty_total
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.tenant_id = v_tenant
       AND co.campaign_id = p_campaign_id
       AND co.status NOT IN ('cancelled','expired')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  ) agg
  LEFT JOIN LATERAL (
    SELECT supplier_id, default_unit_cost
      FROM supplier_skus
     WHERE tenant_id = v_tenant AND sku_id = agg.sku_id AND is_preferred = TRUE
     LIMIT 1
  ) ss ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM prices
     WHERE sku_id = agg.sku_id AND scope = 'retail'
     ORDER BY effective_from DESC NULLS LAST
     LIMIT 1
  ) pr_retail ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM prices
     WHERE sku_id = agg.sku_id AND scope = 'franchise'
     ORDER BY effective_from DESC NULLS LAST
     LIMIT 1
  ) pr_franchise ON TRUE;

  -- 7. total snapshot
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_pr_from_campaign TO authenticated;

COMMENT ON FUNCTION public.rpc_create_pr_from_campaign IS
  '針對單一 closed campaign 建 PR（與同日 close_date PR 共存；同 campaign 不可重複）';

-- ============================================================
-- 3. RPC: rpc_create_pr_blank
--    全空白手動 PR；無守衛
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_create_pr_blank(
  p_operator UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_pr_id    BIGINT;
  v_pr_no    TEXT;
  v_dest_loc BIGINT;
BEGIN
  SELECT id INTO v_dest_loc FROM locations
   WHERE tenant_id = v_tenant
   ORDER BY id LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type,
    source_location_id, status, total_amount,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'manual',
    v_dest_loc, 'draft', 0,
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  RETURN v_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_pr_blank TO authenticated;

COMMENT ON FUNCTION public.rpc_create_pr_blank IS
  '全空白手動 PR：無守衛、items 空、跳轉編輯頁手動加 SKU';
