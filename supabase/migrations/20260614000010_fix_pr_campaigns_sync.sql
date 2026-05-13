-- ============================================================
-- Fix: purchase_request_campaigns 寫入 / 讀取面不一致
--
-- 背景：
--   發現 PO2605130062 不在撿貨工作站 — 因為 v_picking_demand_by_po
--   只 JOIN purchase_request_campaigns 找 campaign linkage，但兩支 PR-建立 RPC
--   (rpc_create_pr_from_close_date / rpc_append_campaign_to_pr) 都只寫
--   purchase_request_items.source_campaign_id、沒寫 join 表。
--
-- 修法 (4 段)：
--   1. View v_picking_demand_by_po：po_campaigns CTE 加 UNION 從
--      pri.source_campaign_id 取 (防呆 fallback)
--   2. rpc_create_pr_from_close_date：補 INSERT purchase_request_campaigns
--   3. rpc_append_campaign_to_pr：補 INSERT purchase_request_campaigns
--   4. Backfill：從 pri.source_campaign_id 把既有未補的 join row 補上
--
-- Rollback：
--   - view: 回 20260611000020 版本
--   - rpc: 回 20260512000001 (close_date) / 20260428190000 (append) 版本
-- ============================================================

-- ============================================================
-- 1. View v_picking_demand_by_po：po_campaigns 加 fallback
-- ============================================================
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
-- 改動：UNION 兩條路徑取 campaign linkage
po_campaigns AS (
  SELECT DISTINCT po_item_id, campaign_id FROM (
    -- Path A: purchase_request_campaigns join 表 (rpc_create_pr_from_campaigns 寫的)
    SELECT poi.id AS po_item_id, prc.campaign_id
      FROM purchase_order_items poi
      JOIN purchase_request_items pri ON pri.po_item_id = poi.id
      JOIN purchase_requests pr ON pr.id = pri.pr_id
      JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
    UNION
    -- Path B: fallback 從 pri.source_campaign_id (rpc_create_pr_from_close_date /
    -- rpc_append_campaign_to_pr 寫的、但歷史漏 sync join 表)
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

-- ============================================================
-- 2. rpc_create_pr_from_close_date：補寫 purchase_request_campaigns
--    (從該 close_date 的所有 closed campaigns 衍生)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_close_date(p_close_date date, p_operator uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_pr_id       BIGINT;
  v_pr_no       TEXT;
  v_dest_loc    BIGINT;
  v_campaign_count INTEGER;
  v_demand_count   INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_campaign_count
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant
     AND status = 'closed'
     AND DATE(end_at AT TIME ZONE 'Asia/Taipei') = p_close_date;

  IF v_campaign_count = 0 THEN
    RAISE EXCEPTION 'no closed campaigns on date %', p_close_date;
  END IF;

  SELECT COUNT(*) INTO v_demand_count
    FROM group_buy_campaigns gbc
    JOIN customer_orders co ON co.campaign_id = gbc.id
    JOIN customer_order_items coi ON coi.order_id = co.id
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'closed'
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
     AND co.status NOT IN ('cancelled','expired','transferred_out')
     AND coi.status NOT IN ('cancelled','expired');

  IF v_demand_count = 0 THEN
    RAISE EXCEPTION 'no orders to aggregate for close_date %', p_close_date;
  END IF;

  SELECT id INTO v_dest_loc FROM locations
   WHERE tenant_id = v_tenant
   ORDER BY id LIMIT 1;

  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined for tenant %', v_tenant;
  END IF;

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

  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested,
    suggested_supplier_id, unit_cost, source_campaign_id,
    created_by, updated_by
  )
  SELECT
    v_pr_id,
    agg.sku_id,
    agg.qty_total,
    ss.supplier_id,
    COALESCE(ss.default_unit_cost, 0),
    agg.first_campaign_id,
    p_operator,
    p_operator
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
       AND co.status NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  ) agg
  LEFT JOIN LATERAL (
    SELECT supplier_id, default_unit_cost
      FROM supplier_skus
     WHERE tenant_id = v_tenant
       AND sku_id = agg.sku_id
       AND is_preferred = TRUE
     LIMIT 1
  ) ss ON TRUE;

  -- *** 新增：sync purchase_request_campaigns join 表 ***
  -- 把該 close_date 的所有 closed campaigns 都 link 到此 PR
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, gbc.id, v_tenant
    FROM group_buy_campaigns gbc
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'closed'
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = p_close_date
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$function$;

-- ============================================================
-- 3. rpc_append_campaign_to_pr：補寫 purchase_request_campaigns
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_append_campaign_to_pr(p_pr_id bigint, p_campaign_id bigint, p_operator uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tenant      UUID;
  v_pr_status   TEXT;
  v_pr_close_date DATE;
  v_camp_status TEXT;
  v_camp_close_date DATE;
  v_camp_tenant UUID;
  v_inserted    INTEGER := 0;
  v_updated     INTEGER := 0;
  v_demand RECORD;
BEGIN
  SELECT tenant_id, status, source_close_date
    INTO v_tenant, v_pr_status, v_pr_close_date
    FROM purchase_requests
   WHERE id = p_pr_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found', p_pr_id;
  END IF;

  IF v_pr_status <> 'draft' THEN
    RAISE EXCEPTION 'PR % is not in draft status (current: %); cannot append',
      p_pr_id, v_pr_status;
  END IF;

  SELECT tenant_id, status, DATE(end_at AT TIME ZONE 'Asia/Taipei')
    INTO v_camp_tenant, v_camp_status, v_camp_close_date
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

  IF v_pr_close_date IS NOT NULL AND v_camp_close_date <> v_pr_close_date THEN
    RAISE EXCEPTION 'close_date mismatch: PR=%, campaign=%',
      v_pr_close_date, v_camp_close_date;
  END IF;

  FOR v_demand IN
    SELECT
      coi.sku_id,
      SUM(coi.qty) AS qty_total
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id
     WHERE co.campaign_id = p_campaign_id
       AND co.tenant_id = v_tenant
       AND co.status NOT IN ('cancelled','expired')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id
  LOOP
    UPDATE purchase_request_items
       SET qty_requested = qty_requested + v_demand.qty_total,
           updated_by = p_operator
     WHERE pr_id = p_pr_id AND sku_id = v_demand.sku_id;

    IF FOUND THEN
      v_updated := v_updated + 1;
    ELSE
      INSERT INTO purchase_request_items (
        pr_id, sku_id, qty_requested,
        suggested_supplier_id, unit_cost,
        retail_price, franchise_price,
        source_campaign_id,
        created_by, updated_by
      )
      SELECT
        p_pr_id, v_demand.sku_id, v_demand.qty_total,
        ss.supplier_id, COALESCE(ss.default_unit_cost, 0),
        pr_retail.price, pr_franchise.price,
        p_campaign_id, p_operator, p_operator
      FROM (SELECT 1) dummy
      LEFT JOIN LATERAL (
        SELECT supplier_id, default_unit_cost
          FROM supplier_skus
         WHERE tenant_id = v_tenant
           AND sku_id = v_demand.sku_id
           AND is_preferred = TRUE
         LIMIT 1
      ) ss ON TRUE
      LEFT JOIN LATERAL (
        SELECT price FROM prices
         WHERE sku_id = v_demand.sku_id AND scope = 'retail'
         ORDER BY effective_from DESC NULLS LAST
         LIMIT 1
      ) pr_retail ON TRUE
      LEFT JOIN LATERAL (
        SELECT price FROM prices
         WHERE sku_id = v_demand.sku_id AND scope = 'franchise'
         ORDER BY effective_from DESC NULLS LAST
         LIMIT 1
      ) pr_franchise ON TRUE;

      v_inserted := v_inserted + 1;
    END IF;
  END LOOP;

  -- *** 新增：sync purchase_request_campaigns join 表 ***
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  VALUES (p_pr_id, p_campaign_id, v_tenant)
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = p_pr_id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id = p_pr_id;

  RETURN jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
END;
$function$;

-- ============================================================
-- 4. Backfill: 從 pri.source_campaign_id 補既有 PR 漏掉的 purchase_request_campaigns
-- ============================================================
INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
SELECT DISTINCT pri.pr_id, pri.source_campaign_id, pr.tenant_id
  FROM purchase_request_items pri
  JOIN purchase_requests pr ON pr.id = pri.pr_id
 WHERE pri.source_campaign_id IS NOT NULL
   AND pr.status NOT IN ('cancelled')
ON CONFLICT (pr_id, campaign_id) DO NOTHING;

COMMENT ON VIEW public.v_picking_demand_by_po IS
  '撿貨工作站主視圖：PO × SKU × store 矩陣；po_campaigns CTE 同時讀 '
  'purchase_request_campaigns join 表 + pri.source_campaign_id fallback、避免 '
  'rpc_create_pr_from_close_date / rpc_append_campaign_to_pr 漏寫 join 表時看不到 demand。';
