-- ============================================================
-- v_picking_demand_by_po — 把 restock-sourced POs 也納入派貨工作台
--
-- 背景:原本 view 故意排除 restock POs,改走 HQ Inbox 的「📦 PO 到貨建轉貨單」
-- 但實務上使用者想在派貨工作台一次處理客戶訂單 + 補貨,所以放行。
--
-- 改動:
-- 1. 移除 po_skus CTE 的 NOT EXISTS(restock)排除條件
-- 2. 新增欄位 is_restock_sourced(BOOL),UI 可加 badge 區分
-- 3. demand 加新分支 restock_demand,從 restock_request_lines + requesting_store_id 取需求
-- 4. wave_qty 加新分支:把 HQ Inbox 直接派出去的 restock transfer 也算 "已撿"
-- 5. shipped_qty 同上 — 兩條派貨流都算進去,避免雙重派貨
--
-- 不更動 rpc_create_wave_from_po:它本來就吃任意 PO,campaign_id 是 nullable
-- (picking_wave_items.campaign_id 允許 NULL,restock 來源的 wave items 就掛 NULL)
--
-- Rollback: CREATE OR REPLACE 回 20260606000060 版本(排除 restock)
-- ============================================================

-- 用 CREATE OR REPLACE 避免 cascade 砸到 v_order_shortage / v_hq_inbox。
-- 新欄位 is_restock_sourced 一定要放在 SELECT 最後一欄(PG 規定:replace 時既有欄位的位置 / 型別不可動)。
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
    poi.qty_ordered,
    EXISTS (
      SELECT 1
        FROM purchase_request_items pri2
        JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
       WHERE pri2.po_item_id = poi.id
    ) AS is_restock_sourced
  FROM purchase_orders po
  JOIN purchase_order_items poi ON poi.po_id = po.id
  WHERE po.status IN ('sent', 'partially_received', 'fully_received')
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
campaign_demand AS (
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
restock_demand AS (
  SELECT
    poi.id AS po_item_id,
    rr.requesting_store_id AS store_id,
    SUM(rrl.qty) AS demand_qty
  FROM purchase_order_items poi
  JOIN purchase_request_items pri ON pri.po_item_id = poi.id
  JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id
                          AND rr.status NOT IN ('cancelled','rejected')
  JOIN restock_request_lines rrl ON rrl.request_id = rr.id
                                AND rrl.sku_id = poi.sku_id
  GROUP BY poi.id, rr.requesting_store_id
),
store_demand AS (
  SELECT po_item_id, store_id, SUM(demand_qty) AS demand_qty
  FROM (
    SELECT po_item_id, store_id, demand_qty FROM campaign_demand
    UNION ALL
    SELECT po_item_id, store_id, demand_qty FROM restock_demand
  ) u
  GROUP BY po_item_id, store_id
),
wave_qty AS (
  SELECT source_po_id, sku_id, store_id, SUM(qty) AS wave_qty
  FROM (
    -- (1) picking_wave_items(customer-order 撿貨 + restock 從派貨工作台撿貨)
    SELECT pw.source_po_id, pwi.sku_id, pwi.store_id, pwi.qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
    WHERE pw.status <> 'cancelled'
      AND pw.source_po_id IS NOT NULL
    UNION ALL
    -- (2) HQ Inbox 直接派出去的 restock transfer(沒有 wave),用 qty_requested 對應 wave allocation 語意
    SELECT
      poi.po_id AS source_po_id,
      ti.sku_id,
      rr.requesting_store_id AS store_id,
      ti.qty_requested
    FROM restock_requests rr
    JOIN transfers t ON t.id = rr.linked_transfer_id
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status <> 'cancelled'
  ) u
  GROUP BY source_po_id, sku_id, store_id
),
shipped_qty AS (
  SELECT source_po_id, sku_id, store_id, SUM(qty_received) AS shipped_qty
  FROM (
    -- (1) Wave 派出去 → transfers(transfer_no = 'WAVE-{wave_id}-S{store_id}')
    SELECT
      pw.source_po_id,
      ti.sku_id,
      (substring(t.transfer_no FROM 'WAVE-\d+-S(\d+)'))::BIGINT AS store_id,
      ti.qty_received
    FROM transfers t
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN picking_waves pw ON t.transfer_no LIKE 'WAVE-' || pw.id || '-S%'
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status IN ('received', 'closed')
      AND pw.source_po_id IS NOT NULL
    UNION ALL
    -- (2) HQ Inbox 直接派出去的 restock transfer
    SELECT
      poi.po_id AS source_po_id,
      ti.sku_id,
      rr.requesting_store_id AS store_id,
      ti.qty_received
    FROM restock_requests rr
    JOIN transfers t ON t.id = rr.linked_transfer_id
    JOIN transfer_items ti ON ti.transfer_id = t.id
    JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
    JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
    WHERE t.transfer_type = 'hq_to_store'
      AND t.status IN ('received', 'closed')
  ) u
  GROUP BY source_po_id, sku_id, store_id
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
  CASE
    WHEN ps.po_status <> 'fully_received'
      THEN GREATEST(0, ps.qty_ordered - COALESCE(g.gr_qty, 0))
    ELSE 0
  END::NUMERIC AS qty_in_transit,
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
  COALESCE(sq.shipped_qty, 0)::NUMERIC AS shipped_qty,
  ps.is_restock_sourced
FROM po_skus ps
JOIN skus s ON s.id = ps.sku_id
LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
LEFT JOIN stores st ON st.id = sd.store_id
LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
WHERE
  COALESCE(sq.shipped_qty, 0) < GREATEST(COALESCE(g.gr_qty, 0), 1)
  AND (COALESCE(g.gr_qty, 0) > 0 OR COALESCE(sd.demand_qty, 0) > 0);

GRANT SELECT ON public.v_picking_demand_by_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖:PO × SKU × store 矩陣;支援 customer-order PO 與 restock-sourced PO 兩條來源,'
  '同時計入 picking_wave_items + 直接 restock transfer,避免雙重派貨。';
