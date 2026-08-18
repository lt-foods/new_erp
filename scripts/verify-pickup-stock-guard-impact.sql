-- 取貨閘門「門市實體庫存」守衛（20260818000010）的影響範圍 / 驗收查詢
--
-- 列出「閘門目前回 true、但該店該 SKU 的累計已承諾量已經超過 on_hand」的品項 ——
-- 也就是現在按下取貨一定會把 on_hand 扣成負的、客人撲空的那些。
--
-- 套用 migration **之前**跑：回的是完整的超賣清單（＝這支修正要擋掉的量）。
-- 套用 migration **之後**跑：真正被守衛擋掉的行會從 is_order_item_pickup_ready
--   消失，所以剩下來的只會是 exempt_reason 非 NULL 的那些（Path A / D / D' /
--   容器單 / offset / 沒綁倉別的店 —— 那些是刻意豁免的，不是漏網）。
--   exempt_reason IS NULL 的列如果還有，就是守衛沒生效，要回頭查。
--
-- 用法：
--   node .claude-scripts/apply_via_mgmt_api.cjs scripts/verify-pickup-stock-guard-impact.sql
--
-- cum 的算式與 migration 內的守衛逐字對齊（母體＝已承諾未取：單頭
-- ready/partially_completed/shipping、排除容器單/offset/待補貨/qty<=0，
-- 排序 (created_at, order_no, item_id)）。改守衛時這裡要一起改，否則對不上。

WITH cand AS (
  SELECT coi.id      AS item_id,
         coi.sku_id  AS sku_id,
         coi.qty     AS qty,
         co.id       AS order_id,
         co.tenant_id,
         co.order_no,
         co.created_at,
         co.campaign_id,
         co.pickup_store_id,
         co.member_id,
         co.order_kind
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
   WHERE coi.status IN ('pending','reserved','ready')
     AND coi.backorder_at IS NULL
     AND co.status IN ('ready','partially_completed','shipping')
     AND public.is_order_item_pickup_ready(coi.id)
),
scored AS (
  SELECT c.*,
         (SELECT COALESCE(SUM(y.qty), 0)
            FROM customer_order_items y
            JOIN customer_orders yo ON yo.id = y.order_id
            LEFT JOIN members ym ON ym.id = yo.member_id
           WHERE yo.tenant_id       = c.tenant_id
             AND yo.pickup_store_id = c.pickup_store_id
             AND y.sku_id           = c.sku_id
             AND y.status IN ('pending','reserved','ready')
             AND y.qty > 0
             AND y.backorder_at IS NULL
             AND (yo.status IN ('ready','partially_completed','shipping')
                  OR y.id = c.item_id)
             AND COALESCE(ym.member_type, '') <> 'store_internal'
             AND COALESCE(yo.order_kind, 'normal') <> 'offset'
             AND (yo.created_at, yo.order_no, y.id)
                 <= (c.created_at, c.order_no, c.item_id)
         ) AS cum,
         COALESCE((SELECT sb.on_hand
                     FROM stores st
                     JOIN stock_balances sb
                       ON sb.tenant_id   = st.tenant_id
                      AND sb.location_id = st.location_id
                      AND sb.sku_id      = c.sku_id
                    WHERE st.id = c.pickup_store_id), 0) AS on_hand
    FROM cand c
)
SELECT st.name                                        AS store,
       s.order_no,
       COALESCE(sk.variant_name, sk.product_name)      AS sku,
       s.qty,
       s.cum,
       s.on_hand,
       s.cum - s.on_hand                               AS over,
       -- 刻意豁免的路徑（守衛不作用在這些上面）
       CASE
         WHEN NOT EXISTS (SELECT 1 FROM stores x
                           WHERE x.id = s.pickup_store_id
                             AND x.location_id IS NOT NULL)          THEN 'no_location'
         WHEN COALESCE(s.order_kind, 'normal') = 'offset'            THEN 'offset_order'
         WHEN EXISTS (SELECT 1 FROM members m
                       WHERE m.id = s.member_id
                         AND COALESCE(m.member_type,'') = 'store_internal')
                                                                     THEN 'internal_pool'
         WHEN EXISTS (SELECT 1 FROM transfers t
                       WHERE t.customer_order_id = s.order_id
                         AND t.tenant_id = s.tenant_id
                         AND t.status IN ('received','closed'))      THEN 'path_a'
         WHEN EXISTS (SELECT 1 FROM inventory_deduction_notes n
                       WHERE n.tenant_id   = s.tenant_id
                         AND n.campaign_id = s.campaign_id
                         AND n.store_id    = s.pickup_store_id
                         AND n.sku_id      = s.sku_id
                         AND n.cancelled_at IS NULL)                 THEN 'path_d_deduction'
         WHEN EXISTS (SELECT 1
                        FROM customer_orders oo
                        JOIN customer_order_items oi
                          ON oi.order_id = oo.id
                         AND oi.sku_id   = s.sku_id
                         AND oi.qty < 0
                         AND oi.status NOT IN ('cancelled','expired')
                       WHERE oo.tenant_id       = s.tenant_id
                         AND oo.campaign_id     = s.campaign_id
                         AND oo.pickup_store_id = s.pickup_store_id
                         AND oo.order_kind      = 'offset'
                         AND oo.status NOT IN ('cancelled','expired','transferred_out'))
                                                                     THEN 'path_d2_offset'
         ELSE NULL
       END                                             AS exempt_reason
  FROM scored s
  JOIN stores st ON st.id = s.pickup_store_id
  LEFT JOIN skus sk ON sk.id = s.sku_id
 WHERE s.cum > s.on_hand
 ORDER BY exempt_reason NULLS FIRST, st.name, sku, s.created_at;
