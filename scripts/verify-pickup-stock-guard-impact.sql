-- 取貨閘門「門市實體庫存」守衛（20260818000010）的影響範圍 / 驗收查詢
--
-- 列出「閘門回 true、但該店該 SKU 的累計已承諾量已經超過 on_hand」的品項 ——
-- 也就是按下取貨會把 on_hand 扣成負的、客人撲空的那些。
--
-- 套用 migration **之前**跑：完整的超賣清單（＝這支修正要擋掉的量）。
--   2026-08-18 實測：78 筆 / 110 件 / 71 張單 / 10 家店。
-- 套用 migration **之後**跑：應該回 0 列。還有列代表守衛沒生效，回頭查。
--
-- 用法：
--   node .claude-scripts/apply_via_mgmt_api.cjs scripts/verify-pickup-stock-guard-impact.sql
--
-- ⚠ 三個一定要照抄的寫法，都是 2026-08-18 這次踩出來的：
--
--   1. **母體要涵蓋 confirmed / pending**。取貨頁的 ACTIVE_STATUSES 是
--      pending/confirmed/reserved/ready/partially_ready/partially_completed/shipping，
--      而閘門對 confirmed 單一樣會回 true（松山災情那兩張就是 confirmed）。
--      第一版只抓 ready/shipping，結論是「只有 22 筆而且全部豁免」＝看起來沒事，
--      涵蓋 confirmed 之後才看到真正的 78 筆。
--   2. **cum 用視窗函數算，不要用相關子查詢**。母體上萬筆，per-row 子查詢直接 timeout。
--      「已承諾」只算單頭 ready/partially_completed/shipping；本行不論單頭狀態
--      一律計入自己（＝ promised 前綴 + 自己的量），與 migration 內的守衛逐字對齊。
--   3. **閘門很貴（~5ms/次），一定要先預篩再跑**，而且要 MATERIALIZED ——
--      planner 不會照子句順序跑（20260813020000 的教訓）。這裡用「這家店收過這個
--      SKU 沒有 / 這張單有沒有自己的 transfer / 有沒有 DN / 有沒有 offset 單」
--      當預篩，那是閘門 Path A~D' 回 true 的必要條件。

WITH recv AS MATERIALIZED (
  -- Path B / C 的必要條件：該店該 SKU 有過 hq_to_store 實收
  SELECT DISTINCT st.id AS store_id, ti.sku_id
    FROM transfers t
    JOIN stores st ON st.location_id = t.dest_location AND st.tenant_id = t.tenant_id
    JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.qty_received > 0
   WHERE t.transfer_type = 'hq_to_store' AND t.status IN ('received','closed')
),
lines AS (
  SELECT co.tenant_id, co.pickup_store_id, coi.sku_id, coi.id AS item_id, coi.qty,
         co.created_at, co.order_no, co.status AS ord_status, co.id AS order_id,
         co.campaign_id,
         (co.status IN ('ready','partially_completed','shipping')) AS is_promised
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    LEFT JOIN members m ON m.id = co.member_id
   WHERE coi.status IN ('pending','reserved','ready')
     AND coi.qty > 0
     AND coi.backorder_at IS NULL
     AND co.status NOT IN ('completed','expired','cancelled','transferred_out')
     -- 容器單與 offset 單本身是守衛的豁免對象，不列入
     AND COALESCE(m.member_type, '')       <> 'store_internal'
     AND COALESCE(co.order_kind, 'normal') <> 'offset'
),
ranked AS (
  SELECT l.*,
         SUM(CASE WHEN l.is_promised THEN l.qty ELSE 0 END)
           OVER (PARTITION BY l.tenant_id, l.pickup_store_id, l.sku_id
                 ORDER BY l.created_at, l.order_no, l.item_id
                 ROWS UNBOUNDED PRECEDING) AS promised_prefix
    FROM lines l
),
over AS MATERIALIZED (
  SELECT r.*,
         r.promised_prefix + CASE WHEN r.is_promised THEN 0 ELSE r.qty END AS cum,
         COALESCE(sb.on_hand, 0) AS on_hand
    FROM ranked r
    -- 沒綁倉別的店算不出 on_hand，守衛也豁免它們
    JOIN stores st ON st.id = r.pickup_store_id AND st.location_id IS NOT NULL
    LEFT JOIN stock_balances sb
           ON sb.tenant_id   = st.tenant_id
          AND sb.location_id = st.location_id
          AND sb.sku_id      = r.sku_id
   WHERE r.promised_prefix + CASE WHEN r.is_promised THEN 0 ELSE r.qty END
         > COALESCE(sb.on_hand, 0)
),
reachable AS MATERIALIZED (
  -- 閘門有機會回 true 的（Path A~D' 的必要條件聯集）；先砍掉再跑閘門
  SELECT o.* FROM over o
   WHERE EXISTS (SELECT 1 FROM recv WHERE recv.store_id = o.pickup_store_id AND recv.sku_id = o.sku_id)
      OR EXISTS (SELECT 1 FROM transfers t
                  WHERE t.customer_order_id = o.order_id AND t.tenant_id = o.tenant_id
                    AND t.status IN ('received','closed'))
      OR EXISTS (SELECT 1 FROM inventory_deduction_notes n
                  WHERE n.tenant_id = o.tenant_id AND n.campaign_id = o.campaign_id
                    AND n.store_id = o.pickup_store_id AND n.sku_id = o.sku_id
                    AND n.cancelled_at IS NULL)
      OR EXISTS (SELECT 1 FROM customer_orders oo
                   JOIN customer_order_items oi ON oi.order_id = oo.id AND oi.sku_id = o.sku_id
                    AND oi.qty < 0 AND oi.status NOT IN ('cancelled','expired')
                  WHERE oo.tenant_id = o.tenant_id AND oo.campaign_id = o.campaign_id
                    AND oo.pickup_store_id = o.pickup_store_id AND oo.order_kind = 'offset'
                    AND oo.status NOT IN ('cancelled','expired','transferred_out'))
)
SELECT st.name                                   AS store,
       h.order_no,
       h.ord_status,
       COALESCE(sk.variant_name, sk.product_name) AS sku,
       h.qty,
       h.cum,
       h.cum - h.qty                             AS ahead_of_me,
       h.on_hand,
       h.cum - h.on_hand                         AS over,
       -- 這一組是靠哪條路徑通過「到貨」判斷的（只是資訊，不再是守衛的豁免）
       CASE
         WHEN EXISTS (SELECT 1 FROM transfers t
                       WHERE t.customer_order_id = h.order_id AND t.tenant_id = h.tenant_id
                         AND t.status IN ('received','closed'))                 THEN 'path_a'
         WHEN EXISTS (SELECT 1 FROM inventory_deduction_notes n
                       WHERE n.tenant_id = h.tenant_id AND n.campaign_id = h.campaign_id
                         AND n.store_id = h.pickup_store_id AND n.sku_id = h.sku_id
                         AND n.cancelled_at IS NULL)                            THEN 'path_d_deduction'
         WHEN EXISTS (SELECT 1 FROM customer_orders oo
                        JOIN customer_order_items oi ON oi.order_id = oo.id AND oi.sku_id = h.sku_id
                         AND oi.qty < 0 AND oi.status NOT IN ('cancelled','expired')
                       WHERE oo.tenant_id = h.tenant_id AND oo.campaign_id = h.campaign_id
                         AND oo.pickup_store_id = h.pickup_store_id AND oo.order_kind = 'offset'
                         AND oo.status NOT IN ('cancelled','expired','transferred_out'))
                                                                                THEN 'path_d2_offset'
         ELSE 'path_b_or_c'
       END                                       AS arrived_via
  FROM reachable h
  JOIN stores st ON st.id = h.pickup_store_id
  LEFT JOIN skus sk ON sk.id = h.sku_id
 WHERE public.is_order_item_pickup_ready(h.item_id)
 ORDER BY st.name, sku, h.created_at;
