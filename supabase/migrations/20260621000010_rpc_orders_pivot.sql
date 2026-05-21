-- ============================================================
-- rpc_orders_pivot
--   訂單樞紐表 server-side aggregate
--   取代 admin /orders/pivot 之前 client side 撈 raw customer_orders
--   + customer_order_items 再 group by 的做法 — 那種做法 items 一次性
--   `.in('order_id', ...)` 沒分頁，會被 PostgREST max_rows=1000 截斷，
--   導致跨多店時 items 數字偏低（甚至出現「單選某店 > 全部店」的反直覺結果）。
--
--   回傳只有 group × sku × store 的 cardinality（通常 < 幾百），不會撞 1000。
--   呼叫者：admin /orders/pivot
--   權限：靠 customer_orders / customer_order_items 既有 RLS 守門
--         （函式為 LANGUAGE sql STABLE，沒有 SECURITY DEFINER）
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_orders_pivot(
  p_view_by      text,        -- 'campaign' | 'pickup_date' | 'order_date'
  p_date_from    date,        -- 月起始（含），NULL = 不過濾下界
  p_date_to      date,        -- 下月起始（不含），NULL = 不過濾上界
  p_campaign_ids bigint[],    -- NULL 或空陣列 = 全部
  p_store_id     bigint,      -- NULL = 全部店
  p_statuses     text[]       -- 必填，要納入的訂單狀態
)
RETURNS TABLE (
  group_key        text,
  group_id         bigint,        -- campaign mode = campaign_id；date mode = NULL
  sku_id           bigint,
  sku_product_name text,
  sku_variant_name text,
  pickup_store_id  bigint,
  qty_sum          numeric,
  amount           numeric,
  pos_order_ids    bigint[],
  neg_order_ids    bigint[]
)
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
      AND CASE p_view_by
        WHEN 'pickup_date' THEN
          (p_date_from IS NULL OR o.pickup_deadline >= p_date_from)
          AND (p_date_to IS NULL OR o.pickup_deadline <  p_date_to)
        WHEN 'order_date' THEN
          (p_date_from IS NULL OR o.created_at >= p_date_from::timestamptz)
          AND (p_date_to IS NULL OR o.created_at <  p_date_to::timestamptz)
        WHEN 'campaign' THEN
          -- 沒設 end_at 的 campaign 一律納入；有 end_at 才以月份過濾
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
  )
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
    b.pickup_store_id;
$$;

GRANT EXECUTE ON FUNCTION rpc_orders_pivot(text, date, date, bigint[], bigint, text[]) TO authenticated;
