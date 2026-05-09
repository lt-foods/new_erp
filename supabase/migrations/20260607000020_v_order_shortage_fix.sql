-- ============================================================
-- v_order_shortage 修正:supply 算法 bug
--
-- Bug:之前 supply CTE 用 SUM(gr_qty) 直接從 v_picking_demand_by_po
-- 跨 (sku, store) 加總,但同一 (po, sku) 的 gr_qty 在每個 store 列重複出現,
-- 導致每店看到的 supply 被人為放大 N 倍(N = 該 PO 服務的店數)。
--
-- 修法:supply 改成 SKU 維度(每個 PO×SKU 只算一次),然後按各店 demand 比例分配。
--
-- 新邏輯:
--   - supply_per_sku = SUM(DISTINCT (po, sku) 的 gr) + SUM(in_transit)
--   - demand_per_sku = SUM(顧客訂單 demand,跨店)
--   - sku 是否短缺:demand_per_sku > supply_per_sku
--   - 短缺量按 (sku, store) demand 比例分到各店
-- ============================================================

DROP VIEW IF EXISTS public.v_order_shortage CASCADE;

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 1. SKU 維度 supply(去重 PO×SKU)
supply_per_po_sku AS (
  SELECT DISTINCT po_id, sku_id, gr_qty, qty_in_transit
  FROM v_picking_demand_by_po
),
supply_per_sku AS (
  SELECT
    sku_id,
    SUM(gr_qty)         AS total_gr,
    SUM(qty_in_transit) AS total_in_transit
  FROM supply_per_po_sku
  GROUP BY sku_id
),
-- 已撿+已派(每 (sku, store) 算一次,不重複)
allocated_per_sku_store AS (
  SELECT
    sku_id, store_id,
    SUM(wave_qty)    AS total_wave,
    SUM(shipped_qty) AS total_shipped
  FROM v_picking_demand_by_po
  WHERE store_id IS NOT NULL
  GROUP BY sku_id, store_id
),
allocated_per_sku AS (
  SELECT sku_id,
    SUM(total_wave)    AS total_wave,
    SUM(total_shipped) AS total_shipped
  FROM allocated_per_sku_store
  GROUP BY sku_id
),
-- 2. SKU 維度 demand
demand_per_sku_store AS (
  SELECT
    coi.sku_id,
    co.pickup_store_id AS store_id,
    SUM(coi.qty) AS demand_qty
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
    AND coi.status NOT IN ('cancelled','expired')
    AND co.transferred_from_order_id IS NULL
    AND co.pickup_store_id IS NOT NULL
  GROUP BY coi.sku_id, co.pickup_store_id
),
demand_per_sku AS (
  SELECT sku_id, SUM(demand_qty) AS total_demand
  FROM demand_per_sku_store
  GROUP BY sku_id
),
-- 3. SKU 層級短缺判定
sku_shortage AS (
  SELECT
    d.sku_id,
    d.total_demand,
    COALESCE(s.total_gr, 0)         AS total_gr,
    COALESCE(s.total_in_transit, 0) AS total_in_transit,
    COALESCE(a.total_wave, 0)       AS total_wave,
    COALESCE(a.total_shipped, 0)    AS total_shipped,
    GREATEST(0,
      d.total_demand - COALESCE(s.total_gr, 0) - COALESCE(s.total_in_transit, 0)
    ) AS sku_shortage_qty
  FROM demand_per_sku d
  LEFT JOIN supply_per_sku s ON s.sku_id = d.sku_id
  LEFT JOIN allocated_per_sku a ON a.sku_id = d.sku_id
  WHERE
    -- 只列總供給 < 總需求 的 SKU
    d.total_demand > COALESCE(s.total_gr, 0) + COALESCE(s.total_in_transit, 0)
)
-- 4. 展開到 order_item:該訂單按 (sku, store) demand 比例承擔短缺
SELECT
  co.tenant_id,
  co.id              AS order_id,
  co.order_no,
  co.member_id,
  co.pickup_store_id AS store_id,
  st.name            AS store_name,
  co.status          AS order_status,
  co.shortage_notified_at,
  co.shortage_resolution,
  co.shortage_resolution_at,
  coi.id             AS order_item_id,
  coi.sku_id,
  s.sku_code,
  s.product_name,
  s.variant_name,
  coi.qty            AS order_qty,
  ss.total_demand,
  ss.total_gr,
  ss.total_in_transit,
  ss.total_wave,
  ss.total_shipped,
  ss.sku_shortage_qty AS total_supplier_shortage,
  -- 每張 order_item 的短缺量 = 比例分配
  ROUND(coi.qty::NUMERIC * ss.sku_shortage_qty / NULLIF(ss.total_demand, 0), 2) AS demand_unfulfillable,
  co.created_at      AS order_created_at,
  co.updated_at      AS order_updated_at
FROM customer_orders co
JOIN customer_order_items coi ON coi.order_id = co.id
JOIN sku_shortage ss ON ss.sku_id = coi.sku_id
LEFT JOIN skus s ON s.id = coi.sku_id
LEFT JOIN stores st ON st.id = co.pickup_store_id
WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
  AND coi.status NOT IN ('cancelled','expired')
  AND co.transferred_from_order_id IS NULL
  AND ss.sku_shortage_qty > 0;

GRANT SELECT ON public.v_order_shortage TO authenticated;

COMMENT ON VIEW public.v_order_shortage IS
  '短缺訂單看板 v2:SKU 層級判定短缺(supply per po-sku 去重),展開到 order_item 按比例分攤短缺量。';
