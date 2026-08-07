-- ============================================================
-- v_order_shortage：短缺分攤改「整數貪婪分配」，收件匣不再出現小數
--
-- 問題：總倉收件匣「異常 → 訂單短少」的 預期/實際/差額 出現 0.14、
--   -0.86 這種小數。來源是本 view 的末端展開：SKU 層級短缺（整數）
--   用 ROUND(qty × shortage / total_demand, 2) 按需求比例攤給「所有」
--   還沒拿到貨的訂單品項 — 每張單分到一個小數（= 拿不到貨的機率
--   權重），對操作人員無法解讀（「實際 0.14 件」沒有物理意義），
--   而且全網每張 pending 單都被列成異常（線上 585 張，其中多數
--   分攤到的短缺 < 0.1 件，幾乎確定拿得到貨，純噪音）。
--
-- 修法：只改末端展開，SKU 短缺判定模型完全不動 ——
--   展開列依「下單時間新→舊」排序做貪婪整數分配（FIFO：先下單者
--   先取得貨，短缺由最晚下單的訂單承擔）：
--     每列分到 = LEAST(order_qty, CEIL(sku_shortage_qty) − 比自己晚的量)
--   分不到短缺（較早下單、供給蓋得住）的列直接從 view 消失。
--   效果：demand_unfulfillable 恆為整數；view 只列真正承擔短缺的
--   訂單。CEIL 為保守取整（缺 0.4 件 → 顯示缺 1 件）。
--   另：展開排除 qty <= 0 的抵減品項（offset 負量是會計抵減、不是
--   待交付的貨；它仍照舊計入 demand_per_sku 淨需求，只是不再作為
--   「短缺訂單」列出 — 負數列會破壞貪婪分配的累計窗口）。
--
-- 下游相容（欄位同名同序同型別，值域從小數收斂為整數）：
--   - v_hq_exceptions / rpc_hq_exceptions（異常頁）：預期/實際/差額
--     變整數；customer_shortage 列數 = 真正短缺的訂單數。
--   - rpc_hq_shortage_orders、v_hq_inbox shortage 計數、前端
--     fetchShortageRowsByIds：均為 pass-through，免改。
--
-- 2026-08-07 線上 dry-run（部署前以 SELECT 比對）：
--   舊：653 item 列 / 585 訂單 / 32 SKU，646 列含小數，Σ短缺 288.88
--   新：111 item 列 /  94 訂單 / 32 SKU，  0 列含小數，Σ短缺 288
--   每顆 SKU 的分配總和 = CEIL(sku_shortage_qty)，0 筆不一致。
--
-- 基於：20260807000000_same_store_transfer_before_arrival.sql 第 5 節
--   （= 線上現行定義：po_item_stockout 分支 + stockout_at 閘 +
--   同店衍生單需求；v4 前瞻版 20260801000000_v_order_shortage_v4_
--   forward_looking 線上未部署，該檔已記載此 drift，本檔沿用線上版）。
-- Rollback：CREATE OR REPLACE VIEW 回 20260807000000 第 5 節版本。
-- TEST: docs/TEST-order-shortage-integer-allocation.md
-- ============================================================

CREATE OR REPLACE VIEW public.v_order_shortage AS
WITH
-- 1.「採購已定案」閘門 + 供給（沿用線上版：含 stockout_at 閘）
settled_po_supply AS (
  SELECT
    poi.sku_id,
    SUM(COALESCE(g.gr_qty, 0)) AS total_gr,
    SUM(
      CASE WHEN po.status IN ('sent', 'partially_received')
             AND poi.stockout_at IS NULL
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
-- 已撿+已派（純資訊欄位，不影響短缺判定）
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
-- 2. SKU 維度 demand（沿用線上版：同店衍生單計入、跨店衍生單排除）
demand_per_sku_store AS (
  SELECT
    coi.sku_id,
    co.pickup_store_id AS store_id,
    SUM(coi.qty) AS demand_qty
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
    AND coi.status NOT IN ('cancelled','expired')
    AND (co.transferred_from_order_id IS NULL OR EXISTS (
          SELECT 1 FROM customer_orders src
          WHERE src.id = co.transferred_from_order_id
            AND src.pickup_store_id = co.pickup_store_id))
    AND co.pickup_store_id IS NOT NULL
  GROUP BY coi.sku_id, co.pickup_store_id
),
demand_per_sku AS (
  SELECT sku_id, SUM(demand_qty) AS total_demand
  FROM demand_per_sku_store
  GROUP BY sku_id
),
-- 3. SKU 層級短缺判定（完全沿用線上版）
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
  WHERE d.total_demand > COALESCE(s.total_gr, 0) + COALESCE(s.total_in_transit, 0)
),
-- 4. 展開到 order_item + 貪婪整數分配的累計窗口：
--    同 SKU 依下單時間新→舊排，newer_qty = 排在自己前面（更晚下單）
--    的品項數量累計 — 短缺先由更晚的單吸收，輪不到自己就不列。
expanded AS (
  SELECT
    co.tenant_id,
    co.id              AS order_id,
    co.order_no,
    co.member_id,
    co.pickup_store_id AS store_id,
    co.status          AS order_status,
    co.shortage_notified_at,
    co.shortage_resolution,
    co.shortage_resolution_at,
    coi.id             AS order_item_id,
    coi.sku_id,
    coi.qty            AS order_qty,
    ss.total_demand,
    ss.total_gr,
    ss.total_in_transit,
    ss.total_wave,
    ss.total_shipped,
    ss.sku_shortage_qty,
    co.created_at      AS order_created_at,
    co.updated_at      AS order_updated_at,
    SUM(coi.qty) OVER (
      PARTITION BY coi.sku_id
      ORDER BY co.created_at DESC, coi.id DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) - coi.qty AS newer_qty
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  JOIN sku_shortage ss ON ss.sku_id = coi.sku_id
  WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed','partially_completed')
    AND coi.status NOT IN ('cancelled','expired')
    AND (co.transferred_from_order_id IS NULL OR EXISTS (
          SELECT 1 FROM customer_orders src
          WHERE src.id = co.transferred_from_order_id
            AND src.pickup_store_id = co.pickup_store_id))
    AND coi.qty > 0
    AND ss.sku_shortage_qty > 0
)
SELECT
  e.tenant_id,
  e.order_id,
  e.order_no,
  e.member_id,
  e.store_id,
  st.name            AS store_name,
  e.order_status,
  e.shortage_notified_at,
  e.shortage_resolution,
  e.shortage_resolution_at,
  e.order_item_id,
  e.sku_id,
  s.sku_code,
  s.product_name,
  s.variant_name,
  e.order_qty,
  e.total_demand,
  e.total_gr,
  e.total_in_transit,
  e.total_wave,
  e.total_shipped,
  e.sku_shortage_qty AS total_supplier_shortage,
  LEAST(e.order_qty::NUMERIC, CEIL(e.sku_shortage_qty) - e.newer_qty) AS demand_unfulfillable,
  e.order_created_at,
  e.order_updated_at
FROM expanded e
LEFT JOIN skus s ON s.id = e.sku_id
LEFT JOIN stores st ON st.id = e.store_id
WHERE CEIL(e.sku_shortage_qty) - e.newer_qty > 0;

GRANT SELECT ON public.v_order_shortage TO authenticated;

COMMENT ON VIEW public.v_order_shortage IS
  '短缺訂單看板：SKU 層級判定沿用線上版（採購定案閘門 + stockout_at 閘 + 同店衍生單需求），'
  '末端展開改貪婪整數分配 — 依下單時間新→舊承擔短缺（FIFO），demand_unfulfillable 恆為整數，'
  '只列真正承擔短缺的訂單（較早下單、供給蓋得住的單不再列出）。';
