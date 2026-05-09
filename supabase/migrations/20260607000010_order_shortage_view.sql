-- ============================================================
-- P4: 短少訂單看板 schema
--
-- 短少 = 顧客訂單需求量 > 實際可滿足量(到貨 + 在途 - 已派)
--
-- 1. 在 customer_orders 加 shortage 處理欄位
-- 2. 建 v_order_shortage view 列出受影響的訂單(SKU × store 維度,展開到 order)
--
-- 業務語意:
--   - 一張顧客訂單一個 (sku, store) → 該店該 SKU 的「需求」
--   - 該店該 SKU 的「供給」= GR 量 + 在途量 - 已派貨給其他訂單
--   - shortage > 0 表示這張訂單目前不一定能滿足
--   - 區分「在途」(in_transit, 還會到) vs「短缺」(supplier 已關單,永遠不會到)
--
-- TEST:
--   1. PO 訂 100 收 95 (fully_received, 短少 5),需求 100 → 該店該 SKU 短缺 5
--   2. PO 訂 100 收 60 (partially_received),需求 100 → 在途 40,沒短缺(會到)
--   3. PO 訂 100 收 100,需求 80 → 沒短缺
--
-- Rollback: DROP VIEW + ALTER TABLE DROP COLUMN
-- ============================================================

-- ----------------------------------------------------------------
-- 1. customer_orders 加 shortage 處理欄位
-- ----------------------------------------------------------------
ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS shortage_notified_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS shortage_notified_by  UUID,
  ADD COLUMN IF NOT EXISTS shortage_resolution   TEXT
    CHECK (shortage_resolution IN ('notified','cancelled','reallocated','waiting_next_po') OR shortage_resolution IS NULL),
  ADD COLUMN IF NOT EXISTS shortage_resolution_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS shortage_resolution_by UUID;

COMMENT ON COLUMN customer_orders.shortage_notified_at IS '上次通知客戶短缺的時間';
COMMENT ON COLUMN customer_orders.shortage_resolution IS '短缺處理方式:notified/cancelled/reallocated/waiting_next_po';

CREATE INDEX IF NOT EXISTS idx_customer_orders_shortage
  ON customer_orders (tenant_id, shortage_resolution)
  WHERE shortage_resolution IS NOT NULL;

-- ----------------------------------------------------------------
-- 2. v_order_shortage — 短缺訂單看板 view
-- ----------------------------------------------------------------
DROP VIEW IF EXISTS public.v_order_shortage CASCADE;

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 每個 (sku, store) 的供給情況(把 v_picking_demand_by_po 各 PO 列加總)
supply AS (
  SELECT
    sku_id,
    store_id,
    SUM(gr_qty)        AS total_gr,
    SUM(qty_in_transit) AS total_in_transit,
    SUM(qty_shortage)  AS total_shortage,
    SUM(wave_qty)      AS total_wave,
    SUM(shipped_qty)   AS total_shipped
  FROM v_picking_demand_by_po
  WHERE store_id IS NOT NULL
  GROUP BY sku_id, store_id
),
-- 每個 (sku, store) 的需求(累計各 pending/reserved 訂單)
demand AS (
  SELECT
    coi.sku_id,
    co.pickup_store_id AS store_id,
    SUM(coi.qty) AS total_demand
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
    AND coi.status NOT IN ('cancelled','expired')
    AND co.transferred_from_order_id IS NULL
    AND co.pickup_store_id IS NOT NULL
  GROUP BY coi.sku_id, co.pickup_store_id
),
-- (sku, store) shortage 計算
sku_store_shortage AS (
  SELECT
    d.sku_id,
    d.store_id,
    d.total_demand,
    COALESCE(s.total_gr, 0)         AS total_gr,
    COALESCE(s.total_in_transit, 0) AS total_in_transit,
    COALESCE(s.total_shortage, 0)   AS total_supplier_shortage,
    COALESCE(s.total_wave, 0)       AS total_wave,
    COALESCE(s.total_shipped, 0)    AS total_shipped,
    -- 「會供給的量」= GR + 在途
    GREATEST(0, d.total_demand - COALESCE(s.total_gr, 0) - COALESCE(s.total_in_transit, 0)) AS demand_unfulfillable
  FROM demand d
  LEFT JOIN supply s ON s.sku_id = d.sku_id AND s.store_id = d.store_id
)
-- 展開到 order_item 層級,只列「會永遠拿不到貨」的訂單
SELECT
  co.tenant_id,
  co.id           AS order_id,
  co.order_no,
  co.member_id,
  co.pickup_store_id AS store_id,
  st.name         AS store_name,
  co.status       AS order_status,
  co.shortage_notified_at,
  co.shortage_resolution,
  co.shortage_resolution_at,
  coi.id          AS order_item_id,
  coi.sku_id,
  s.sku_code,
  s.product_name,
  s.variant_name,
  coi.qty         AS order_qty,
  sss.total_demand,
  sss.total_gr,
  sss.total_in_transit,
  sss.total_supplier_shortage,
  sss.total_wave,
  sss.total_shipped,
  sss.demand_unfulfillable,
  co.created_at   AS order_created_at,
  co.updated_at   AS order_updated_at
FROM customer_orders co
JOIN customer_order_items coi ON coi.order_id = co.id
JOIN sku_store_shortage sss
  ON sss.sku_id = coi.sku_id AND sss.store_id = co.pickup_store_id
LEFT JOIN skus s ON s.id = coi.sku_id
LEFT JOIN stores st ON st.id = co.pickup_store_id
WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
  AND coi.status NOT IN ('cancelled','expired')
  AND co.transferred_from_order_id IS NULL
  -- 只列有實質短缺的(供給 < 需求)
  AND sss.demand_unfulfillable > 0;

GRANT SELECT ON public.v_order_shortage TO authenticated;

COMMENT ON VIEW public.v_order_shortage IS
  '短缺訂單看板:列出顧客訂單中,目前 (sku, store) 供給(GR + 在途) < 需求 的 order_items。HQ 客服據此通知/取消/改派。';

-- ----------------------------------------------------------------
-- 3. RPC:HQ 標記 shortage order 處理狀態
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_handle_shortage_order(
  p_order_id BIGINT,
  p_action   TEXT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot handle shortage', v_role;
  END IF;
  IF p_action NOT IN ('notified','cancelled','waiting_next_po','reallocated') THEN
    RAISE EXCEPTION 'invalid action: %', p_action;
  END IF;

  IF p_action = 'notified' THEN
    UPDATE customer_orders
       SET shortage_notified_at  = NOW(),
           shortage_notified_by  = p_operator,
           shortage_resolution   = 'notified',
           shortage_resolution_at = NOW(),
           shortage_resolution_by = p_operator,
           updated_by = p_operator
     WHERE id = p_order_id AND tenant_id = v_tenant;
  ELSE
    UPDATE customer_orders
       SET shortage_resolution    = p_action,
           shortage_resolution_at = NOW(),
           shortage_resolution_by = p_operator,
           updated_by = p_operator
     WHERE id = p_order_id AND tenant_id = v_tenant;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_handle_shortage_order(BIGINT, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_handle_shortage_order(BIGINT, TEXT, UUID) IS
  'HQ 標記短缺訂單處理狀態(notified/cancelled/waiting_next_po/reallocated)。實際取消退款由其他流程做。';
