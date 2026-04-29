-- ============================================================
-- 撿貨工作站需求矩陣：要求 PR + PO 已建立才出現
--
-- 之前 v_picking_demand_by_close_date 只看 customer_orders 存在就會列出
-- (close_date, sku_id, store_id)，導致：
--   - 結單後尚未跑採購流程的商品也出現在「批次撿貨工作站」清單
--   - 操作者誤以為可以先撿，但其實供應商還沒收到 PO
--
-- 新規則：
--   每筆 (close_date, sku_id) 必須在 purchase_request_items 找得到
--   對應 row、且 po_item_id IS NOT NULL（= 已被拆進 PO），且 PR.status
--   ≠ 'cancelled'，否則該 SKU 不出現在 view（連同 close_date dropdown 也不列）。
--
-- 不變：
--   - status 排除規則（gbc / co / coi 的 cancelled/expired/transferred_out）
--   - 進庫量 / PO 號 / 訂單號 的 LEFT JOIN 聚合方式
--   - GROUP BY 維度
-- ============================================================

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
  co.pickup_store_id, st.code, st.name;

GRANT SELECT ON public.v_picking_demand_by_close_date TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_close_date IS
  '撿貨工作站需求矩陣：限定已 PR + PO 拆單的 SKU 才出現（避免未進入採購流程的商品誤現於撿貨清單）';
