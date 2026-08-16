-- _sku_commitment（20260816000000）等價性驗證。
-- 用法：scripts/apply-migration.sh scripts/verify-sku-commitment-equivalence.sql
--
-- 預期結果：兩列都是 0。
--   a_mismatches：promised / promised_active / waiting / pool_arrived
--     必須與各呼叫端原本 inline 的算法逐筆相等（零行為變更）。
--   b_unexpected：pool_claimed 的差異只允許出現在「有負數 offset 品項」的
--     那些 (店,SKU)，且差額剛好等於被排除掉的負數量
--     （＝ _grow_internal_pool 虛增自由量的 bug，2026-08-16 實測 35 組 / 112 件）。

WITH c AS (
  SELECT st.id AS store_id, k.*
    FROM stores st, LATERAL public._sku_commitment(st.id) k
   -- ⚠ 不要加 st.is_active：已停用的 5 家分店身上還掛著 1,327 組 (店,SKU) 的
   -- 未取品項，只在一邊濾會產生 1,117 筆假 mismatch（第一次跑就被這個騙到）。
), legacy AS (
  SELECT co.pickup_store_id AS store_id, coi.sku_id,
    SUM(coi.qty) FILTER (WHERE co.status IN ('ready','partially_completed','shipping')
       AND COALESCE(co.order_kind,'normal') <> 'offset'
       AND COALESCE(m.member_type,'') <> 'store_internal')                    AS promised,
    SUM(coi.qty) FILTER (WHERE co.status IN ('ready','partially_completed','shipping')
       AND COALESCE(co.order_kind,'normal') <> 'offset'
       AND COALESCE(m.member_type,'') <> 'store_internal'
       AND coi.backorder_at IS NULL)                                          AS promised_active,
    SUM(coi.qty) FILTER (WHERE co.status = 'confirmed'
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND COALESCE(m.member_type,'') <> 'store_internal')                    AS waiting,
    SUM(coi.qty) FILTER (WHERE co.status IN ('ready','partially_completed')
       AND m.member_type = 'store_internal' AND coi.qty > 0)                  AS pool_arrived
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.order_id = co.id
  LEFT JOIN members m ON m.id = co.member_id
 WHERE coi.status IN ('pending','reserved','ready')
 GROUP BY 1,2
), pool_legacy AS (
  SELECT co.pickup_store_id AS store_id, coi.sku_id, SUM(coi.qty) AS pool_claimed
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
   WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed')
     AND coi.status IN ('pending','reserved','ready')
   GROUP BY 1,2
), neg AS (
  SELECT co.pickup_store_id AS store_id, coi.sku_id, SUM(coi.qty) AS neg
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN members m ON m.id = co.member_id AND m.member_type = 'store_internal'
   WHERE co.status NOT IN ('cancelled','expired','transferred_out','completed')
     AND coi.status IN ('pending','reserved','ready') AND coi.qty < 0
   GROUP BY 1,2
)
SELECT
  (SELECT count(*) FROM c FULL JOIN legacy l USING (store_id, sku_id)
    WHERE COALESCE(c.promised,0)        <> COALESCE(l.promised,0)
       OR COALESCE(c.promised_active,0) <> COALESCE(l.promised_active,0)
       OR COALESCE(c.waiting,0)         <> COALESCE(l.waiting,0)
       OR COALESCE(c.pool_arrived,0)    <> COALESCE(l.pool_arrived,0)
  ) AS a_mismatches,
  (SELECT count(*) FROM c FULL JOIN pool_legacy p USING (store_id, sku_id)
                          LEFT JOIN neg         n USING (store_id, sku_id)
    WHERE COALESCE(c.pool_claimed,0) - COALESCE(p.pool_claimed,0)
          IS DISTINCT FROM -COALESCE(n.neg,0)
  ) AS b_unexpected,
  (SELECT count(*) FROM neg) AS bugfix_pairs,
  (SELECT COALESCE(SUM(-neg),0) FROM neg) AS bugfix_units;
