-- ============================================================
-- v_picking_demand_by_po — 加上 PO 狀態 / 在途 / 短少 三欄,排除 restock-sourced POs
--
-- 改進:
-- 1. po_status:讓 UI 區分「還會再來貨」vs「PO 結了不會再到」
-- 2. qty_in_transit:訂購 − 已到貨,只在 PO 還沒 fully_received 時有值
-- 3. qty_shortage:PO 已 fully_received 且 gr_qty < qty_ordered 時的差額(永遠不會到)
-- 4. 排除 restock-sourced POs(那些走 HQ Inbox 的「📦 PO 到貨建轉貨單」流程,不該在撿貨工作站)
--
-- TEST:
--   - 一張 PO 訂 100 收 60 (status=partially_received) → in_transit=40, shortage=0
--   - 一張 PO 訂 100 收 100 (status=fully_received) → in_transit=0, shortage=0
--   - 一張 PO 訂 100 收 95 (status=fully_received) → in_transit=0, shortage=5
--   - restock-sourced PO 不出現
--
-- Rollback: CREATE OR REPLACE 回 20260513000000 版本
-- ============================================================

DROP VIEW IF EXISTS public.v_picking_demand_by_po CASCADE;

CREATE OR REPLACE VIEW public.v_picking_demand_by_po AS
WITH po_skus AS (
  SELECT
    po.id            AS po_id,
    po.tenant_id,
    po.po_no,
    po.status        AS po_status,
    po.supplier_id,
    poi.id           AS po_item_id,
    poi.sku_id,
    poi.qty_ordered
  FROM purchase_orders po
  JOIN purchase_order_items poi ON poi.po_id = po.id
  WHERE po.status IN ('sent', 'partially_received', 'fully_received')
    -- 排除 restock-sourced POs(那條走 HQ Inbox 流程,不經撿貨工作站)
    AND NOT EXISTS (
      SELECT 1
        FROM purchase_request_items pri2
        JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
       WHERE pri2.po_item_id = poi.id
    )
),
gr_qty AS (
  SELECT
    gri.po_item_id,
    SUM(gri.qty_received) AS gr_qty
  FROM goods_receipt_items gri
  JOIN goods_receipts gr ON gr.id = gri.gr_id
  WHERE gr.status = 'confirmed'
  GROUP BY gri.po_item_id
),
po_campaigns AS (
  SELECT DISTINCT
    poi.id AS po_item_id,
    prc.campaign_id
  FROM purchase_order_items poi
  JOIN purchase_request_items pri ON pri.po_item_id = poi.id
  JOIN purchase_requests pr ON pr.id = pri.pr_id
  JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
),
store_demand AS (
  SELECT
    pc.po_item_id,
    co.pickup_store_id AS store_id,
    SUM(coi.qty) AS demand_qty
  FROM po_campaigns pc
  JOIN customer_orders co ON co.campaign_id = pc.campaign_id
                         AND co.status NOT IN ('cancelled','expired','transferred_out')
                         AND co.transferred_from_order_id IS NULL
  JOIN customer_order_items coi ON coi.order_id = co.id
                               AND coi.status NOT IN ('cancelled','expired')
  JOIN purchase_order_items poi ON poi.id = pc.po_item_id
                               AND poi.sku_id = coi.sku_id
  GROUP BY pc.po_item_id, co.pickup_store_id
),
wave_qty AS (
  SELECT
    pw.source_po_id,
    pwi.sku_id,
    pwi.store_id,
    SUM(pwi.qty) AS wave_qty
  FROM picking_wave_items pwi
  JOIN picking_waves pw ON pw.id = pwi.wave_id
  WHERE pw.status <> 'cancelled'
    AND pw.source_po_id IS NOT NULL
  GROUP BY pw.source_po_id, pwi.sku_id, pwi.store_id
),
shipped_qty AS (
  SELECT
    pw.source_po_id,
    ti.sku_id,
    (substring(t.transfer_no FROM 'WAVE-\d+-S(\d+)'))::BIGINT AS store_id,
    SUM(ti.qty_received) AS shipped_qty
  FROM transfers t
  JOIN transfer_items ti ON ti.transfer_id = t.id
  JOIN picking_waves pw ON t.transfer_no LIKE 'WAVE-' || pw.id || '-S%'
  WHERE t.transfer_type = 'hq_to_store'
    AND t.status IN ('received', 'closed')
    AND pw.source_po_id IS NOT NULL
  GROUP BY pw.source_po_id, ti.sku_id, store_id
)
SELECT
  ps.tenant_id,
  ps.po_id,
  ps.po_no,
  ps.po_status,
  ps.supplier_id,
  ps.po_item_id,
  ps.sku_id,
  s.sku_code,
  COALESCE(s.product_name, '') || COALESCE(' ' || NULLIF(s.variant_name,''), '') AS sku_label,
  ps.qty_ordered,
  COALESCE(g.gr_qty, 0)::NUMERIC AS gr_qty,
  -- 在途:還沒 fully_received 時的差額(會再到)
  CASE
    WHEN ps.po_status <> 'fully_received'
      THEN GREATEST(0, ps.qty_ordered - COALESCE(g.gr_qty, 0))
    ELSE 0
  END::NUMERIC AS qty_in_transit,
  -- 短少:fully_received 但少給(永遠不會到)
  CASE
    WHEN ps.po_status = 'fully_received' AND COALESCE(g.gr_qty, 0) < ps.qty_ordered
      THEN ps.qty_ordered - COALESCE(g.gr_qty, 0)
    ELSE 0
  END::NUMERIC AS qty_shortage,
  sd.store_id,
  st.code AS store_code,
  st.name AS store_name,
  COALESCE(sd.demand_qty, 0)::NUMERIC AS demand_qty,
  COALESCE(wq.wave_qty, 0)::NUMERIC AS wave_qty,
  COALESCE(sq.shipped_qty, 0)::NUMERIC AS shipped_qty
FROM po_skus ps
JOIN skus s ON s.id = ps.sku_id
LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
LEFT JOIN stores st ON st.id = sd.store_id
LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
WHERE
  -- 只列「未派完」的 (po, sku, store):shipped_qty < gr_qty 且 gr_qty > 0
  -- (gr_qty=0 但仍有需求的列也保留,讓使用者看到「還沒到」的訂單)
  COALESCE(sq.shipped_qty, 0) < GREATEST(COALESCE(g.gr_qty, 0), 1)
  -- 排除完全已配送完且沒任何 demand 的列
  AND (COALESCE(g.gr_qty, 0) > 0 OR COALESCE(sd.demand_qty, 0) > 0);

GRANT SELECT ON public.v_picking_demand_by_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖:PO × SKU × store 矩陣,含 PO 狀態 / 在途 / 短少 三欄。已排除 restock-sourced POs(走 HQ Inbox 流程)。';
