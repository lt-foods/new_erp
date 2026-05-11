-- ============================================================
-- v_picking_demand_no_po — 派貨工作台「無 PO 來源」section data
--
-- 來源:pending / approved_transfer 狀態的 restock_requests + restock_request_lines
-- 供給:HQ central_warehouse 的 stock_balances.on_hand
-- 已撿:source_restock_request_id 對應的 picking_waves
-- 已派:對應 transfer 已 received 的 qty(暫不算,沿用 wave_qty 即可)
--
-- columns 對齊 v_picking_demand_by_po 以便前端共用 type:
--   po_id, po_no, po_status (NULL / 'restock'), supplier_id (NULL),
--   po_item_id (NULL), sku_id, sku_code, sku_label,
--   qty_ordered, gr_qty (= HQ on_hand for that sku),
--   qty_in_transit, qty_shortage,
--   store_id (= requesting_store), store_code, store_name,
--   demand_qty, wave_qty, shipped_qty, is_restock_sourced
--
-- 額外欄位:
--   restock_request_id, restock_status (pending / approved_transfer)
-- ============================================================

CREATE OR REPLACE VIEW public.v_picking_demand_no_po AS
WITH hq_loc AS (
  SELECT DISTINCT ON (tenant_id) tenant_id, id AS location_id
    FROM locations
   WHERE type = 'central_warehouse'
   ORDER BY tenant_id, id
),
rr_lines AS (
  SELECT
    rr.id              AS restock_request_id,
    rr.tenant_id,
    rr.status          AS restock_status,
    rr.requesting_store_id AS store_id,
    rrl.sku_id,
    rrl.qty            AS demand_qty
  FROM restock_requests rr
  JOIN restock_request_lines rrl ON rrl.request_id = rr.id
  WHERE rr.status IN ('pending','approved_transfer')
),
hq_supply AS (
  SELECT
    sb.tenant_id, sb.sku_id, sb.on_hand
  FROM stock_balances sb
  JOIN hq_loc h ON h.tenant_id = sb.tenant_id AND h.location_id = sb.location_id
),
wave_qty AS (
  SELECT pw.source_restock_request_id AS restock_request_id,
         pwi.sku_id, pwi.store_id,
         SUM(pwi.qty) AS wave_qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
   WHERE pw.status <> 'cancelled'
     AND pw.source_restock_request_id IS NOT NULL
   GROUP BY pw.source_restock_request_id, pwi.sku_id, pwi.store_id
)
SELECT
  l.tenant_id,
  NULL::BIGINT                AS po_id,
  'RR-' || l.restock_request_id::TEXT AS po_no,
  'restock'::TEXT             AS po_status,
  NULL::BIGINT                AS supplier_id,
  NULL::BIGINT                AS po_item_id,
  l.sku_id,
  s.sku_code,
  COALESCE(s.product_name,'') || COALESCE(' ' || NULLIF(s.variant_name,''),'') AS sku_label,
  l.demand_qty                AS qty_ordered,
  COALESCE(hs.on_hand, 0)::NUMERIC AS gr_qty,
  0::NUMERIC                  AS qty_in_transit,
  0::NUMERIC                  AS qty_shortage,
  l.store_id,
  st.code                     AS store_code,
  st.name                     AS store_name,
  l.demand_qty,
  COALESCE(wq.wave_qty, 0)::NUMERIC AS wave_qty,
  0::NUMERIC                  AS shipped_qty,
  TRUE                        AS is_restock_sourced,
  l.restock_request_id,
  l.restock_status
FROM rr_lines l
JOIN skus s ON s.id = l.sku_id
LEFT JOIN hq_supply hs ON hs.tenant_id = l.tenant_id AND hs.sku_id = l.sku_id
LEFT JOIN stores st ON st.id = l.store_id
LEFT JOIN wave_qty wq ON wq.restock_request_id = l.restock_request_id
                     AND wq.sku_id = l.sku_id
                     AND wq.store_id = l.store_id
WHERE
  -- 還沒派完(wave_qty < demand_qty)才出現
  COALESCE(wq.wave_qty, 0) < l.demand_qty;

GRANT SELECT ON public.v_picking_demand_no_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_no_po IS
  '派貨工作台「無 PO 來源」section:從 pending/approved_transfer 的 restock_requests + HQ stock_balances 算需求/供給。';
