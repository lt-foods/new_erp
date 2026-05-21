-- ============================================================
-- rpc_orders_pivot v3 — RETURNS jsonb
--
-- 修 bug：admin /orders/pivot 在「取貨店 = 全部」時、某些開團整筆 row 消失
-- （單選某店反而看得到，因為 row 數較少未撞上限）。
--
-- 根因：PostgREST `max_rows = 1000`（supabase/config.toml）對所有
--   GET / RPC setof 結果套上 row 上限。v2 的 RPC 雖然 server-side
--   aggregate，但回的是 setof，每一 row = (group × sku × store) 一個
--   cell，全部店模式輕鬆破 1000、被靜默截斷。RPC 內部沒 ORDER BY，
--   截斷後留哪幾筆是 DB 隨機決定 → 任何開團都可能消失。
--
-- 修法：改 `RETURNS jsonb`、外層 `jsonb_agg(to_jsonb(t))` 包成單一 row。
--   PostgREST max_rows 算 row 數、不算 jsonb array 內元素 → 不再被截斷。
--
-- 邏輯主體與 v2 (20260621000020) 完全一致。
-- PG 不能 CREATE OR REPLACE 改 return type → DROP + CREATE。
-- ============================================================

DROP FUNCTION IF EXISTS rpc_orders_pivot(text, date, date, bigint[], bigint, text[], boolean);

CREATE OR REPLACE FUNCTION rpc_orders_pivot(
  p_view_by      text,
  p_date_from    date,
  p_date_to      date,
  p_campaign_ids bigint[],
  p_store_id     bigint,
  p_statuses     text[],
  p_closed_only  boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH filtered AS (
    SELECT o.*
    FROM customer_orders o
    LEFT JOIN group_buy_campaigns c ON c.id = o.campaign_id
    WHERE o.status = ANY(p_statuses)
      AND (p_store_id IS NULL OR o.pickup_store_id = p_store_id)
      AND (
        p_campaign_ids IS NULL
        OR cardinality(p_campaign_ids) = 0
        OR o.campaign_id = ANY(p_campaign_ids)
      )
      AND (
        p_closed_only IS NULL
        OR (p_closed_only IS TRUE
            AND c.status IN ('closed','ordered','receiving','ready','completed'))
        OR (p_closed_only IS FALSE
            AND c.status NOT IN ('closed','ordered','receiving','ready','completed'))
      )
      AND CASE p_view_by
        WHEN 'pickup_date' THEN
          (p_date_from IS NULL OR o.pickup_deadline >= p_date_from)
          AND (p_date_to IS NULL OR o.pickup_deadline <  p_date_to)
        WHEN 'order_date' THEN
          (p_date_from IS NULL OR o.created_at >= p_date_from::timestamptz)
          AND (p_date_to IS NULL OR o.created_at <  p_date_to::timestamptz)
        WHEN 'campaign' THEN
          c.end_at IS NULL
          OR (
            (p_date_from IS NULL OR c.end_at >= p_date_from::timestamptz)
            AND (p_date_to IS NULL OR c.end_at <  p_date_to::timestamptz)
          )
        ELSE TRUE
      END
  ),
  base AS (
    SELECT
      CASE p_view_by
        WHEN 'campaign'    THEN 'c' || f.campaign_id::text
        WHEN 'pickup_date' THEN 'd' || to_char(COALESCE(f.pickup_deadline, f.created_at::date), 'YYYY-MM-DD')
        WHEN 'order_date'  THEN 'd' || to_char(f.created_at::date, 'YYYY-MM-DD')
      END                                              AS group_key,
      CASE WHEN p_view_by = 'campaign' THEN f.campaign_id ELSE NULL::bigint END
                                                       AS group_id,
      i.sku_id,
      s.product_name                                   AS sku_product_name,
      s.variant_name                                   AS sku_variant_name,
      f.pickup_store_id,
      f.id                                             AS order_id,
      f.status,
      i.qty,
      i.unit_price
    FROM filtered f
    JOIN customer_order_items i ON i.order_id = f.id
    LEFT JOIN skus s ON s.id = i.sku_id
  ),
  agg AS (
    SELECT
      b.group_key,
      b.group_id,
      b.sku_id,
      b.sku_product_name,
      b.sku_variant_name,
      b.pickup_store_id,
      SUM(CASE WHEN b.status IN ('cancelled','expired','transferred_out')
               THEN (-b.qty) ELSE b.qty END)::numeric                          AS qty_sum,
      SUM(CASE WHEN b.status IN ('cancelled','expired','transferred_out')
               THEN (-b.qty) * b.unit_price ELSE b.qty * b.unit_price END)::numeric
                                                                                AS amount,
      COALESCE(
        ARRAY_AGG(DISTINCT b.order_id)
          FILTER (WHERE b.status NOT IN ('cancelled','expired','transferred_out')),
        '{}'::bigint[]
      )                                                                         AS pos_order_ids,
      COALESCE(
        ARRAY_AGG(DISTINCT b.order_id)
          FILTER (WHERE b.status IN ('cancelled','expired','transferred_out')),
        '{}'::bigint[]
      )                                                                         AS neg_order_ids
    FROM base b
    GROUP BY
      b.group_key,
      b.group_id,
      b.sku_id,
      b.sku_product_name,
      b.sku_variant_name,
      b.pickup_store_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(agg.*)), '[]'::jsonb)
  FROM agg;
$$;

GRANT EXECUTE ON FUNCTION rpc_orders_pivot(text, date, date, bigint[], bigint, text[], boolean) TO authenticated;
