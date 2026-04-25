-- ============================================================================
-- v_picking_demand_by_close_date
-- 給「撿貨工作站」用：以結單日（close_date）為單位，列出 SKU × 分店的需求矩陣
-- ============================================================================
CREATE OR REPLACE VIEW public.v_picking_demand_by_close_date AS
SELECT
  gbc.tenant_id,
  DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') AS close_date,
  coi.sku_id,
  COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
  s.sku_code,
  co.pickup_store_id AS store_id,
  st.code AS store_code,
  st.name AS store_name,
  SUM(coi.qty)   AS demand_qty,
  COUNT(DISTINCT co.id) AS order_count,
  array_agg(DISTINCT gbc.id) AS campaign_ids
FROM group_buy_campaigns gbc
JOIN customer_orders co ON co.campaign_id = gbc.id AND co.status NOT IN ('cancelled','expired')
JOIN customer_order_items coi ON coi.order_id = co.id AND coi.status NOT IN ('cancelled','expired')
JOIN skus s ON s.id = coi.sku_id
JOIN stores st ON st.id = co.pickup_store_id
WHERE gbc.status NOT IN ('cancelled')
GROUP BY gbc.tenant_id, DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei'),
         coi.sku_id, s.product_name, s.variant_name, s.sku_code,
         co.pickup_store_id, st.code, st.name;

GRANT SELECT ON public.v_picking_demand_by_close_date TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_close_date IS
  '撿貨工作站需求矩陣：close_date × sku × store 各分店的需求量';
