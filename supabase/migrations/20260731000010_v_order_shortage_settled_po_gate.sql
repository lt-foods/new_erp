-- ============================================================
-- v_order_shortage v3:只判「採購已定案」的 SKU + closed PO 供給不歸零
--
-- 問題(總倉收件匣「異常」爆量 8,823 筆、其中訂單短少 8,733):
--   v2 的供給來自 v_picking_demand_by_po,該 view 只含
--   status IN ('sent','partially_received','fully_received') 的 PO。
--   線上實測 8,733 筆的組成:
--     1. ~7,300 筆:新檔期(7/20-7/28 團購)收單了但 PO 還沒開
--        → 517 個 SKU 完全沒有 PO → 供給 = 0 → 檔期每一張訂單都被
--        標成「訂單短少」。這不是短少,是採購流程還沒跑到。
--     2. ~1,087 筆:斷貨後遺症。rpc_stockout_purchase_order 會把
--        部分到貨的 PO 轉 'closed'(20260702020000),而「部分到貨的
--        SKU 不視為斷貨」→ 其訂單品項不會被連動取消;但 PO 一轉
--        closed,已收的量就從 v2 供給裡消失 → 需求還在、供給歸零
--        → 82 個 SKU 的殘留訂單全變假異常。
--     3. ~340 筆:有活躍 PO 但供給真的不足 — 唯一的真異常。
--
-- 修法(兩刀):
--   A. 供給改為直接從 purchase_orders / goods_receipts 計算,
--      納入 'closed' PO 的已收量(關單 ≠ 貨消失;closed 的在途 = 0,
--      差額不會再到)。不再依賴 v_picking_demand_by_po 的供給欄位,
--      避免動到撿貨工作站 view。
--   B. 只對「採購已定案」的 SKU 判定短缺:SKU 必須存在至少一張
--      status IN ('sent','partially_received','fully_received','closed')
--      的 PO(以 INNER JOIN settled 供給實現)。完全沒 PO 的 SKU
--      = 還在等採購開單,不判短缺;只剩 cancelled PO 的 SKU
--      = 斷貨且零到貨,由斷貨連動(取消品項+通知)處理,不重複列。
--
-- 已知邊界:SKU 跨檔期重用時,舊 PO 會讓新檔期提早進入判定
--   (供給算舊 PO 的量)。此 view 本來就是 SKU 維度全域 pooling,
--   維持一致;誤差遠小於修掉的 8,400 筆假警報。
--
-- 欄位:與 v2 完全同名同序同型別(僅來源改寫),下游
--   v_hq_exceptions / v_hq_inbox / hq/inbox 頁免改。
-- total_wave / total_shipped 仍取自 v_picking_demand_by_po(僅活躍 PO
--   的已撿/已派,資訊欄位,不影響短缺判定),與 v2 行為一致。
--
-- 基於:20260607000020_v_order_shortage_fix.sql(v2,最新版)。
-- Rollback:CREATE OR REPLACE VIEW 回 20260607000020 版本。
-- ============================================================

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 1. SKU 維度供給:sent/partial/fully 算「已收 + 在途(未收餘量)」,
--    closed 只算已收(差額不會再到)。cancelled / draft 不入列。
--    這個 CTE 同時是「採購已定案」閘門:沒有列 = 該 SKU 不判短缺。
settled_po_supply AS (
  SELECT
    poi.sku_id,
    SUM(COALESCE(g.gr_qty, 0)) AS total_gr,
    SUM(
      CASE WHEN po.status IN ('sent', 'partially_received')
           THEN GREATEST(0, poi.qty_ordered - COALESCE(g.gr_qty, 0))
           ELSE 0
      END
    ) AS total_in_transit
  FROM purchase_orders po
  JOIN purchase_order_items poi ON poi.po_id = po.id
  LEFT JOIN (
    SELECT gri.po_item_id, SUM(gri.qty_received) AS gr_qty
    FROM goods_receipt_items gri
    JOIN goods_receipts gr ON gr.id = gri.gr_id
    WHERE gr.status = 'confirmed'
    GROUP BY gri.po_item_id
  ) g ON g.po_item_id = poi.id
  WHERE po.status IN ('sent', 'partially_received', 'fully_received', 'closed')
  GROUP BY poi.sku_id
),
-- 已撿+已派(沿用 v2:每 (sku, store) 算一次,不重複)
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
-- 2. SKU 維度 demand(沿用 v2)
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
-- 3. SKU 層級短缺判定:INNER JOIN settled_po_supply = 採購定案閘門
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
  JOIN settled_po_supply s ON s.sku_id = d.sku_id
  LEFT JOIN allocated_per_sku a ON a.sku_id = d.sku_id
  WHERE
    -- 只列總供給 < 總需求 的 SKU
    d.total_demand > COALESCE(s.total_gr, 0) + COALESCE(s.total_in_transit, 0)
)
-- 4. 展開到 order_item:該訂單按 (sku, store) demand 比例承擔短缺(沿用 v2)
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
  '短缺訂單看板 v3:只對「採購已定案」(存在 sent/partial/fully/closed PO)的 SKU 判定短缺;'
  '供給直接從 PO/GR 計算,closed PO 的已收量不歸零(關單≠貨消失)。'
  '完全沒 PO 的 SKU = 等採購開單,不列;只剩 cancelled PO 的 SKU 由斷貨連動處理,不列。'
  '展開到 order_item 按比例分攤短缺量,欄位與 v2 相容。';
