-- ============================================================================
-- v_picking_demand_by_close_date: 加 picked_qty
--
-- 原本工作站的「已撿過」判斷在前端用 .eq("wave_date", closeDate) 查 picking_waves，
-- 但 wave_date 是配送日（closeDate+2）不等於結單日，所以永遠抓不到 → 已撿過從不顯示。
-- 已派貨完成的 SKU 還是會被顯示成「+ 加入」，操作者再選一次 → 重複建撿貨單。
--
-- 修正：view 加 picked_qty 欄位，聚合「該 (close_date, sku, store) 已建在非 cancelled
-- 的 picking_wave_items 的 qty」。前端用 picked_qty >= demand_qty 判斷是否已撿過。
--
-- 不變：
--   - 既有的 EXISTS PR+PO guard
--   - 既有的 received_qty / po_numbers / order_numbers 聚合
-- ============================================================================

DROP VIEW IF EXISTS public.v_picking_demand_by_close_date CASCADE;

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
  SUM(coi.qty) AS demand_qty,
  COUNT(DISTINCT co.id) AS order_count,
  array_agg(DISTINCT gbc.id) AS campaign_ids,
  COALESCE(SUM(gri.qty_received) FILTER (WHERE gr.status = 'confirmed'), 0)::NUMERIC AS received_qty,
  COALESCE(picked_agg.picked_qty, 0)::NUMERIC AS picked_qty,
  array_agg(DISTINCT po.po_no) FILTER (WHERE po.po_no IS NOT NULL) AS po_numbers,
  array_agg(DISTINCT co.order_no) FILTER (WHERE co.order_no IS NOT NULL) AS order_numbers
FROM group_buy_campaigns gbc
JOIN customer_orders co ON co.campaign_id = gbc.id
                       AND co.status NOT IN ('cancelled','expired','transferred_out')
JOIN customer_order_items coi ON coi.order_id = co.id
                             AND coi.status NOT IN ('cancelled','expired')
JOIN skus s ON s.id = coi.sku_id
JOIN stores st ON st.id = co.pickup_store_id
LEFT JOIN goods_receipt_items gri ON gri.sku_id = coi.sku_id
LEFT JOIN goods_receipts gr ON gr.id = gri.gr_id AND gr.tenant_id = gbc.tenant_id AND gr.status = 'confirmed'
LEFT JOIN purchase_orders po ON po.id = gr.po_id
-- picked_qty: 已建在非 cancelled wave 的 qty（同 close_date 之 campaigns 範圍）
LEFT JOIN LATERAL (
  SELECT SUM(pwi.qty) AS picked_qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
    JOIN group_buy_campaigns gbc2 ON gbc2.id = pwi.campaign_id
   WHERE pwi.tenant_id = gbc.tenant_id
     AND pwi.sku_id = coi.sku_id
     AND pwi.store_id = co.pickup_store_id
     AND pw.status <> 'cancelled'
     AND DATE(gbc2.end_at AT TIME ZONE 'Asia/Taipei') = DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei')
) picked_agg ON TRUE
WHERE gbc.status NOT IN ('cancelled')
  AND EXISTS (
    SELECT 1
      FROM purchase_request_items pri
      JOIN purchase_requests pr ON pr.id = pri.pr_id
     WHERE pr.tenant_id = gbc.tenant_id
       AND pr.source_close_date = DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei')
       AND pri.sku_id = coi.sku_id
       AND pri.po_item_id IS NOT NULL
       AND pr.status NOT IN ('cancelled')
  )
GROUP BY
  gbc.tenant_id,
  DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei'),
  coi.sku_id, s.product_name, s.variant_name, s.sku_code,
  co.pickup_store_id, st.code, st.name,
  picked_agg.picked_qty;

GRANT SELECT ON public.v_picking_demand_by_close_date TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_close_date IS
  '撿貨工作站需求矩陣：含 picked_qty (已建在非 cancelled wave 的 qty) 用於前端判斷已撿過';
