-- ============================================================
-- v_picking_demand_by_po：尾端新增 has_stock_left 布林欄
--
-- 動機（效能）：
--   派貨工作台 / 列印撿貨清單走 fetchAllRows 分頁撈整個 view。線上此 view
--   目前 12,240 列（376 張 PO），但真正「還有庫存可分配」（gr_qty > 已撿）的
--   只有 ~37 列。前端卻要連打 13 趟（offset 0→12000）把整張撈回、丟給 client
--   端 filter 掉 99.7%，導致派貨工作台「讀取不出來」（長時間載入）。
--
--   PostgREST 無法表達「欄位 > 欄位」的 server-side filter，故在 view 尾端
--   物化一個布林欄 has_stock_left，讓前端矩陣視角能 .eq("has_stock_left", true)
--   只撈可分配列（13 趟 → 1 趟、12,240 → ~37 列）。
--   依分店檢視分頁仍 lazy 撈完整 view（保留「缺貨待到」能見度）。
--
-- 語意：
--   has_stock_left = COALESCE(gr_qty,0) > COALESCE(po_sku_already_wave,0)
--   per (po, sku)：該 PO 該 SKU 已到貨量 > 跨 store 已撿量 = 尚有可分配庫存。
--   同 (po,sku) 各 store 列共享同值，故 filter 後仍保留該 (po,sku) 全部 store 列。
--
-- 基於：20260701000010_v_picking_demand_fix_already_wave.sql（最新 view 定義）
-- Rollback：CREATE OR REPLACE VIEW 回 20260701000010 版本（drop 新欄位）
-- ============================================================

-- CREATE OR REPLACE VIEW 限制：既有欄位順序 / 型別不可動、僅可在尾部加新欄位。
-- has_stock_left 放在最後一欄（po_sku_already_wave 之後）。
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
  SELECT DISTINCT po_item_id, campaign_id FROM (
    SELECT poi.id AS po_item_id, prc.campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
      JOIN purchase_requests pr ON pr.id = pri.pr_id
      JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
    UNION
    SELECT poi.id AS po_item_id, pri.source_campaign_id AS campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
     WHERE pri.source_campaign_id IS NOT NULL
  ) u
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
    SELECT pw.source_po_id, pwi.sku_id, pwi.store_id, pwi.qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
    WHERE pw.status <> 'cancelled'
      AND pw.source_po_id IS NOT NULL
    UNION ALL
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
-- 新增：per (po_id, sku_id) 跨 store 加總 picking_wave_items，與 RPC 守衛 SUM(pwi) 對齊。
-- 不依 store_demand JOIN，所以「撿給已 cancel 訂單對應 store」的孤兒 wave 也會被算進去。
po_sku_already_wave AS (
  SELECT pw.source_po_id AS po_id, pwi.sku_id, SUM(pwi.qty) AS already_wave
  FROM picking_wave_items pwi
  JOIN picking_waves pw ON pw.id = pwi.wave_id
  WHERE pw.status <> 'cancelled'
    AND pw.source_po_id IS NOT NULL
  GROUP BY pw.source_po_id, pwi.sku_id
),
shipped_qty AS (
  SELECT source_po_id, sku_id, store_id, SUM(qty_received) AS shipped_qty
  FROM (
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
  ps.is_restock_sourced,
  -- 新欄位：per (po, sku) 真實已撿，與 RPC 守衛對齊
  COALESCE(psaw.already_wave, 0)::NUMERIC AS po_sku_already_wave,
  -- 新欄位：per (po, sku) 是否尚有可分配庫存（gr > 已撿）。
  -- 前端矩陣視角用 .eq("has_stock_left", true) 只撈可分配列，避免整張 view 全撈。
  (COALESCE(g.gr_qty, 0) > COALESCE(psaw.already_wave, 0)) AS has_stock_left
FROM po_skus ps
JOIN skus s ON s.id = ps.sku_id
LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
LEFT JOIN stores st ON st.id = sd.store_id
LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
WHERE
  COALESCE(sq.shipped_qty, 0) < GREATEST(COALESCE(g.gr_qty, 0), 1)
  AND (COALESCE(g.gr_qty, 0) > 0 OR COALESCE(sd.demand_qty, 0) > 0);

GRANT SELECT ON public.v_picking_demand_by_po TO authenticated;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣。'
  'po_sku_already_wave (per po+sku) 為跨 store 已撿真值，與 RPC 守衛對齊；'
  'wave_qty (per po+sku+store) 仍依 store_demand JOIN，僅供 by_store 視角顯示；'
  'has_stock_left (per po+sku) = gr_qty > po_sku_already_wave，前端矩陣視角據此 server-side 過濾只撈可分配列。';
