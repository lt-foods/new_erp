-- 取貨閘門「門市實體庫存」守衛（20260818000010）的**反向**檢查 —— 有沒有誤擋
--
-- 問的是：店裡帳上明明有貨（on_hand > 0），卻有已到貨的單（ready /
-- partially_completed）被閘門擋下來。CLAUDE.md 記過「false negative（貨在店裡
-- 卻不給發）比 false positive 難收拾」—— 店員發不出貨只能改走轉單，那會開一張
-- 新單、原單永遠留在原狀態，就是重複單災情。所以這支要在套用後立刻跑。
--
-- 用法：
--   node .claude-scripts/apply_via_mgmt_api.cjs scripts/verify-pickup-stock-guard-regression.sql
--
-- 怎麼判讀 blocked_by：
--   backorder        少發配貨標的待補貨（本次守衛無關，本來就會擋，要人工點「⚖️ 配貨」）
--   stock_guard      本次新增的實體守衛擋的 —— 這才是要看的。合理的情況是
--                    「排在前面的人已經把 on_hand 佔滿了」，也就是同 (店,SKU) 還有
--                    更早的單在等；不合理的情況是前面根本沒人，那就要查 on_hand
--                    是不是低於實際（到貨沒入帳 / 重複扣帳），該補收貨或盤點。
--   other            兩道守衛以外的原因（Path A~D' 都沒中，＝這批貨真的沒到店）。
--
-- 套用前先跑一次存基準，套用後再跑一次比對：stock_guard 那一類是新增的，
-- 其餘兩類的數字應該完全不變。

WITH blocked AS (
  SELECT coi.id      AS item_id,
         coi.sku_id,
         coi.qty,
         coi.backorder_at,
         co.id       AS order_id,
         co.tenant_id,
         co.order_no,
         co.created_at,
         co.pickup_store_id
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    LEFT JOIN members m ON m.id = co.member_id
   WHERE coi.status IN ('pending','reserved','ready')
     AND co.status IN ('ready','partially_completed')
     AND COALESCE(m.member_type, '') <> 'store_internal'
     AND COALESCE(co.order_kind, 'normal') <> 'offset'
     AND NOT public.is_order_item_pickup_ready(coi.id)
),
scored AS (
  SELECT b.*,
         (SELECT COALESCE(SUM(y.qty), 0)
            FROM customer_order_items y
            JOIN customer_orders yo ON yo.id = y.order_id
            LEFT JOIN members ym ON ym.id = yo.member_id
           WHERE yo.tenant_id       = b.tenant_id
             AND yo.pickup_store_id = b.pickup_store_id
             AND y.sku_id           = b.sku_id
             AND y.status IN ('pending','reserved','ready')
             AND y.qty > 0
             AND y.backorder_at IS NULL
             AND (yo.status IN ('ready','partially_completed','shipping')
                  OR y.id = b.item_id)
             AND COALESCE(ym.member_type, '') <> 'store_internal'
             AND COALESCE(yo.order_kind, 'normal') <> 'offset'
             AND (yo.created_at, yo.order_no, y.id)
                 <= (b.created_at, b.order_no, b.item_id)
         ) AS cum,
         COALESCE((SELECT sb.on_hand
                     FROM stores st
                     JOIN stock_balances sb
                       ON sb.tenant_id   = st.tenant_id
                      AND sb.location_id = st.location_id
                      AND sb.sku_id      = b.sku_id
                    WHERE st.id = b.pickup_store_id), 0) AS on_hand
    FROM blocked b
)
SELECT CASE
         WHEN s.backorder_at IS NOT NULL   THEN 'backorder'
         WHEN s.cum > s.on_hand            THEN 'stock_guard'
         ELSE 'other'
       END                                     AS blocked_by,
       st.name                                 AS store,
       COUNT(*)                                AS blocked_lines,
       SUM(s.qty)                              AS blocked_qty,
       -- 這些被擋的行前面還有多少人在排（cum − 自己的量）。0 代表前面沒人排，
       -- 卻還是被擋 → on_hand 很可能低於實際，要查收貨/盤點。
       COUNT(*) FILTER (WHERE s.cum - s.qty <= 0 AND s.cum > s.on_hand)
                                               AS first_in_line_but_blocked
  FROM scored s
  JOIN stores st ON st.id = s.pickup_store_id
 WHERE s.on_hand > 0            -- 店裡帳上有貨才談得上「誤擋」
 GROUP BY 1, 2
 ORDER BY blocked_by, blocked_lines DESC;
