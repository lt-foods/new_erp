-- 20260829000000 — rpc_orders_pivot：日期界線與日分組改用 Asia/Taipei
--
-- 起因：樞紐表的日期篩選從「月」改成「日」（<input type="date">，預設當月 1 日 ~
-- 當月最後一日）。改成日之後，原本被月粒度蓋住的時區偏移就會天天出現。
--
-- 問題：資料庫 session TimeZone 是 UTC（實測 current_setting('TimeZone') = 'UTC'），
-- 所以 `p_date_from::timestamptz` = 該日 00:00 UTC = 台北時間 08:00。使用者選
-- 「8/16 ~ 8/20」實際撈到的是台北 8/16 08:00 ~ 8/21 08:00：
--   - 8/16 凌晨 0~8 點下的單被漏掉
--   - 8/21 凌晨 0~8 點下的單被誤算進來
-- 線上 79,677 張訂單裡有 10,522 張（13.2%）落在台北 00:00~08:00 這一段，
-- 不是邊角案例。同樣的偏移也在 group_key：`f.created_at::date` 取的是 UTC 日，
-- 台北 8/16 03:00 的單會被標成 8/15 那一列。
--
-- 修法：所有 date 參數與 timestamptz 欄位的換算一律套 `AT TIME ZONE 'Asia/Taipei'`，
-- 與全 repo 既有慣例一致（close_date 那一系列 view / RPC 從 20260426 就這樣寫）。
--   p_date_from::timestamp AT TIME ZONE 'Asia/Taipei'  → 台北當日 00:00 的 timestamptz
--   (f.created_at AT TIME ZONE 'Asia/Taipei')::date     → 台北日
-- p_date_to 維持排他上界（`<`）—— 前端送「使用者選的結束日 + 1 天」，所以起訖
-- 兩天都完整含在範圍內。
--
-- pickup_deadline 是 date 欄位（非 timestamptz），本來就沒有時區問題，比較式不動；
-- 只有它的 group_key fallback 用到 created_at，一併改成台北日。
-- （'pickup_date' 分組 2026-05-21 已從前端下架，這裡只是保持內部一致。）
--
-- 基底版本：20260808000000_stats_exclude_transferred_out_items.sql
--           （已與線上 pg_get_functiondef 逐字對過，無 drift）
-- rollback：重跑 20260808000000 那一支即可回到 UTC 界線版本。

CREATE OR REPLACE FUNCTION public.rpc_orders_pivot(p_view_by text, p_date_from date, p_date_to date, p_campaign_ids bigint[], p_store_id bigint, p_statuses text[], p_closed_only boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
            AND c.status IN ('closed','locked','ordered','receiving','ready','completed'))
        OR (p_closed_only IS FALSE
            AND c.status NOT IN ('closed','locked','ordered','receiving','ready','completed'))
      )
      AND CASE p_view_by
        WHEN 'pickup_date' THEN
          -- pickup_deadline 是 date，直接比，沒有時區問題
          (p_date_from IS NULL OR o.pickup_deadline >= p_date_from)
          AND (p_date_to IS NULL OR o.pickup_deadline <  p_date_to)
        WHEN 'order_date' THEN
          (p_date_from IS NULL
             OR o.created_at >= (p_date_from::timestamp AT TIME ZONE 'Asia/Taipei'))
          AND (p_date_to IS NULL
             OR o.created_at <  (p_date_to::timestamp AT TIME ZONE 'Asia/Taipei'))
        WHEN 'campaign' THEN
          c.end_at IS NULL
          OR (
            (p_date_from IS NULL
               OR c.end_at >= (p_date_from::timestamp AT TIME ZONE 'Asia/Taipei'))
            AND (p_date_to IS NULL
               OR c.end_at <  (p_date_to::timestamp AT TIME ZONE 'Asia/Taipei'))
          )
        ELSE TRUE
      END
  ),
  base AS (
    SELECT
      CASE p_view_by
        WHEN 'campaign'    THEN 'c' || f.campaign_id::text
        WHEN 'pickup_date' THEN 'd' || to_char(COALESCE(f.pickup_deadline, (f.created_at AT TIME ZONE 'Asia/Taipei')::date), 'YYYY-MM-DD')
        WHEN 'order_date'  THEN 'd' || to_char((f.created_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD')
      END                                              AS group_key,
      CASE WHEN p_view_by = 'campaign' THEN f.campaign_id ELSE NULL::bigint END
                                                       AS group_id,
      i.sku_id,
      s.product_name                                   AS sku_product_name,
      s.variant_name                                   AS sku_variant_name,
      f.pickup_store_id,
      f.id                                             AS order_id,
      -- 排除旗標：訂單層級（取消/過期/轉出）或品項層級（部分轉出把來源品項
      -- 標 cancelled 但留在原單）任一成立，這一列就不算進正單數量
      (f.status IN ('cancelled','expired','transferred_out')
       OR i.status IN ('cancelled','expired'))         AS excluded,
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
      SUM(CASE WHEN b.excluded THEN 0 ELSE b.qty END)::numeric                AS qty_sum,
      SUM(CASE WHEN b.excluded THEN 0 ELSE b.qty * b.unit_price END)::numeric AS amount,
      SUM(CASE WHEN b.excluded THEN b.qty ELSE 0 END)::numeric                AS neg_qty_sum,
      SUM(CASE WHEN b.excluded THEN b.qty * b.unit_price ELSE 0 END)::numeric AS neg_amount,
      COALESCE(
        ARRAY_AGG(DISTINCT b.order_id) FILTER (WHERE NOT b.excluded),
        '{}'::bigint[]
      )                                                                       AS pos_order_ids,
      COALESCE(
        ARRAY_AGG(DISTINCT b.order_id) FILTER (WHERE b.excluded),
        '{}'::bigint[]
      )                                                                       AS neg_order_ids
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
$function$;

COMMENT ON FUNCTION public.rpc_orders_pivot(text, date, date, bigint[], bigint, text[], boolean) IS
  '訂單樞紐：qty_sum/amount 只算「訂單未取消/過期/轉出」且「品項未取消/過期」的量；'
  '被排除的量進 neg_qty_sum/neg_amount。p_date_from / p_date_to 以 Asia/Taipei 解讀'
  '（DB session 是 UTC，直接 ::timestamptz 會差 8 小時），p_date_to 為排他上界；'
  'order_date 的日分組同樣取台北日。基底：20260808000000。';
