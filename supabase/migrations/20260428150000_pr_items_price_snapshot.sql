-- ============================================================
-- PR items 加售價/分店價 snapshot：採購人員可手動覆寫
-- 建單時從 prices 表抓 retail / franchise，後續編輯不影響商品主檔
-- ============================================================

ALTER TABLE purchase_request_items
  ADD COLUMN retail_price    NUMERIC(18,4),
  ADD COLUMN franchise_price NUMERIC(18,4);

-- 重建 rpc_create_pr_from_close_date：填入價格 snapshot
CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_close_date(
  p_close_date DATE,
  p_operator   UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_pr_id       BIGINT;
  v_pr_no       TEXT;
  v_dest_loc    BIGINT;
  v_campaign_count INTEGER;
  v_demand_count   INTEGER;
  v_existing_pr_id BIGINT;
BEGIN
  -- 0. 守衛：同結單日已開過 PR
  SELECT id INTO v_existing_pr_id
    FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND source_type = 'close_date'
     AND source_close_date = p_close_date
     AND status <> 'cancelled'
   LIMIT 1;

  IF v_existing_pr_id IS NOT NULL THEN
    RAISE EXCEPTION 'close_date % already has PR (id=%)', p_close_date, v_existing_pr_id
      USING HINT = '請至既有採購單繼續編輯，或先取消後重開';
  END IF;

  -- 1. 守衛：該日是否有 closed campaign
  SELECT COUNT(*) INTO v_campaign_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'closed'
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date;

  IF v_campaign_count = 0 THEN
    RAISE EXCEPTION 'no closed campaigns on date %', p_close_date;
  END IF;

  -- 2. 守衛：是否有可彙總的訂單
  SELECT COUNT(*) INTO v_demand_count
    FROM group_buy_campaigns gbc
    JOIN customer_orders co ON co.campaign_id = gbc.id
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'closed'
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
     AND co.status NOT IN ('cancelled','expired')
     AND coi.status NOT IN ('cancelled','expired');

  IF v_demand_count = 0 THEN
    RAISE EXCEPTION 'no orders to aggregate for close_date %', p_close_date;
  END IF;

  -- 3. dest location
  SELECT id INTO v_dest_loc FROM locations
   WHERE tenant_id = v_tenant
   ORDER BY id LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

  -- 4. PR header
  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', p_close_date,
    v_dest_loc, 'draft', 0,
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  -- 5. items（含售價/分店價 snapshot）
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
    agg.first_campaign_id, p_operator, p_operator
  FROM (
    SELECT
      coi.sku_id,
      SUM(coi.qty) AS qty_total,
      MIN(gbc.id)  AS first_campaign_id
      FROM group_buy_campaigns gbc
      JOIN customer_orders co ON co.campaign_id = gbc.id
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE gbc.tenant_id = v_tenant
       AND gbc.status = 'closed'
       AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
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

  -- 6. total snapshot
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$$;
