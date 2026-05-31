-- ============================================================
-- 修：v_picking_demand_by_po 漏算「沒需求 store 已撿的 wave」
--
-- 背景：
--   原 view 的 wave_qty 用 LEFT JOIN store_demand sd → LEFT JOIN wave_qty wq
--   ON wq.store_id = sd.store_id，依賴 store_demand 才能對到 wave。
--   若 picking_wave_items 撿給某 store，但該 store 對應的 customer_orders 後來
--   cancel / transferred_out → store_demand 不含該 store → wave_qty 在 view 中
--   不會出現 → FE 從 row 加總 wave_qty 算 totalAlreadyWave 偏低 →
--   「可分配」誤報 → FIFO 切到滿張 PO → RPC 守衛 SUM(pwi) 算真值報錯
--   「進貨 X、已撿 X、可分配 0」。
--
--   截圖回報 PO2605250317 SKU G00123-02：UI 已撿 3 / 可分配 7，
--   實際 RPC 已撿 10 / 可分配 0，差異 7 = 撿給已 cancel/transferred_out 訂單對應 store 的 wave。
--
-- 修法：
--   1) view 在 SELECT 尾部新增一欄 po_sku_already_wave (per po_id+sku_id 跨 store
--      加總 picking_wave_items 的 qty)，不依 sd.store_id JOIN — 與 RPC 守衛對齊。
--   2) wave_qty (per po+sku+store) 保留不動，by_store 視角 + 「店欄位 small 字」
--      仍用它顯示原樣。
--
--   FE 改用 po_sku_already_wave 算 totalAvailable / FIFO （見 PR 同批 commit）。
--
-- 基於：20260614000010_fix_pr_campaigns_sync.sql 版本（最新 view 定義）
-- Rollback：CREATE OR REPLACE VIEW 回 20260614000010 版本（drop 新欄位）
-- ============================================================

-- CREATE OR REPLACE VIEW 限制：既有欄位順序 / 型別不可動、僅可在尾部加新欄位。
-- 這裡新增的 po_sku_already_wave 放在最後一欄（is_restock_sourced 之後）。
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
  COALESCE(psaw.already_wave, 0)::NUMERIC AS po_sku_already_wave
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
  'wave_qty (per po+sku+store) 仍依 store_demand JOIN，僅供 by_store 視角顯示。';
