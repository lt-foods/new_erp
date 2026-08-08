-- ============================================================
-- 2026-08-08: 統計不再重複計算「已轉走」的數量／金額
--
-- 回報：同店互轉（換客人）後，開團的「本店小計 / 品項數量」變多 ——
--   一進一出總量卻不守恆。
--
-- 成因：轉單是「複製 + 標記」不是「搬移」，而統計只濾了訂單層級的
--   status，沒濾品項層級：
--     rpc_transfer_order_partial 把整項轉走的來源品項標成
--       customer_order_items.status='cancelled'，但**留在來源單上**，
--       來源單 status 也不變（還是 confirmed/ready）。
--     ⇒ 來源單照算原數量 + 轉入單再算一次。
--   實例 GRP-20260804-007 湖口店：-0058 轉 1 顆到 -TF0157，
--   小計 21 顆 / $1,325（實際 20 顆 / $1,250）。
--   （另一條路：rpc_transfer_order_to_store 整單轉出把來源單標
--    transferred_out 但品項原封不動 —— 這兩支 RPC 本來就有濾
--    transferred_out，故不受影響。）
--
-- 修法：
--   1. rpc_orders_pivot — 正單 qty_sum/amount 改用「訂單被排除 OR
--      品項被排除」單一旗標；被排除的量照舊進 neg_qty_sum/neg_amount
--      （UI 顯示「(取消 N 個)」），drill-down 的 pos/neg_order_ids
--      跟著同一旗標，行為與原本一致。
--   2. rpc_order_overview — trend 的 order_amt 排除 cancelled/expired
--      品項（pickup_items 本來就只取 i.status='picked_up'，不受影響）。
--
-- 前端同步（同一個 commit）：CampaignOrdersPanel / MemberDetail /
--   campaigns 列表與月曆的加總，一律改走 lib/orderStatus.ts 的
--   orderCountsInTotals + orderItemCountsInTotals。
--
-- 基底版本：兩支都以 2026-08-08 線上 pg_get_functiondef 逐字取回為基底。
--   注意 repo drift：線上 rpc_orders_pivot 的 p_closed_only 白名單比
--   20260622000010 多一個 'locked'（線上 hotfix），本檔一併以線上為準收錄。
-- Rollback：CREATE OR REPLACE 回本檔內文並移除新增條件即為前一版
--   （pivot 還原成只看 b.status；overview 移除 order_amt 的 WHERE）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. rpc_orders_pivot：品項層級的取消也要排除在正單數量之外
-- ----------------------------------------------------------------
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
  '被排除的量進 neg_qty_sum/neg_amount。品項層級的排除是為了部分轉出 —— '
  '來源品項被標 cancelled 但留在原單，不濾會與轉入單重複計。基底：2026-08-08 線上版。';

-- ----------------------------------------------------------------
-- 2. rpc_order_overview：本月金額趨勢排除已取消品項
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_order_overview(p_campaign_ids bigint[], p_store_id bigint, p_keyword text, p_month_start timestamp with time zone, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_sku_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  WITH kw AS (
    -- 與 buildKeywordOr 一致：先把 %,() 換成空白避免當成 ILIKE 萬用字元
    SELECT NULLIF(btrim(regexp_replace(COALESCE(p_keyword, ''), '[%,()]', ' ', 'g')), '') AS q
  ),
  toks AS (
    SELECT ARRAY(
      SELECT t FROM unnest(regexp_split_to_array((SELECT q FROM kw), '[\s+]+')) AS t
      WHERE t <> ''
    ) AS arr
  ),
  qualified_members AS (
    -- token-AND：每個 token 都要在 name/phone/member_no 至少一欄命中
    SELECT m.id
    FROM members m
    WHERE (SELECT q FROM kw) IS NOT NULL
      AND m.status <> 'deleted'
      AND NOT EXISTS (
        SELECT 1
        FROM unnest((SELECT arr FROM toks)) AS tok
        WHERE NOT (
          m.name      ILIKE '%' || tok || '%'
          OR m.phone     ILIKE '%' || tok || '%'
          OR m.member_no ILIKE '%' || tok || '%'
        )
      )
  ),
  filtered AS (
    -- v_admin_orders = customer_orders + event_at（事件日，定義見 20260805000120）
    SELECT o.id, o.member_id, o.created_at, o.event_at, o.status
    FROM v_admin_orders o
    WHERE (p_store_id IS NULL OR o.pickup_store_id = p_store_id)
      AND (
        p_campaign_ids IS NULL
        OR cardinality(p_campaign_ids) = 0
        OR o.campaign_id = ANY(p_campaign_ids)
      )
      -- 品項篩選：訂單層級（至少含一列指定 SKU 的訂單），與列表的
      -- customer_order_items!inner 內嵌過濾同義
      AND (
        p_sku_ids IS NULL
        OR cardinality(p_sku_ids) = 0
        OR EXISTS (
          SELECT 1 FROM customer_order_items i
          WHERE i.order_id = o.id AND i.sku_id = ANY(p_sku_ids)
        )
      )
      AND (
        (SELECT q FROM kw) IS NULL
        OR o.order_no          ILIKE '%' || (SELECT q FROM kw) || '%'
        OR o.nickname_snapshot ILIKE '%' || (SELECT q FROM kw) || '%'
        OR o.member_id IN (SELECT id FROM qualified_members)
      )
  ),
  -- 「未取貨」tab 專用：訂單日 created_at 區間
  ranged_order AS (
    SELECT f.*
    FROM filtered f
    WHERE (p_date_from IS NULL OR f.created_at >= p_date_from)
      AND (p_date_to   IS NULL OR f.created_at <  p_date_to)
  ),
  -- 其餘 tab 專用：事件日 event_at 區間
  ranged_event AS (
    SELECT f.*
    FROM filtered f
    WHERE (p_date_from IS NULL OR f.event_at >= p_date_from)
      AND (p_date_to   IS NULL OR f.event_at <  p_date_to)
  ),
  tab_counts AS (
    SELECT
      (SELECT count(*) FROM ranged_order WHERE status IN ('pending','confirmed','shipping','ready')) AS pending,
      -- ready 是 pending 的子集（刻意重疊）：未取貨=全部未取，可取貨=其中已到店的。
      -- 兩者的日期語意不同（訂單日 vs 到貨可取日），故取自不同的 ranged。
      (SELECT count(*) FROM ranged_event WHERE status = 'ready')                                     AS ready,
      (SELECT count(*) FROM ranged_event WHERE status = 'partially_completed')                       AS partially,
      (SELECT count(*) FROM ranged_event WHERE status = 'completed')                                 AS completed,
      (SELECT count(*) FROM ranged_event WHERE status IN ('cancelled','expired'))                    AS cancelled,
      (SELECT count(*) FROM ranged_event WHERE status = 'transferred_out')                           AS transferred
  ),
  trend_orders AS (
    SELECT
      f.id,
      f.member_id,
      to_char((f.created_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD') AS ymd
    FROM filtered f
    WHERE f.status NOT IN ('cancelled','expired','transferred_out')
      AND f.created_at >= p_month_start
  ),
  order_amt AS (
    SELECT i.order_id, SUM(i.qty * i.unit_price)::numeric AS amount
    FROM customer_order_items i
    JOIN trend_orders t ON t.id = i.order_id
    -- 部分轉出會把「整項轉走」的來源品項標 cancelled 留在原單上；
    -- 不濾掉的話同一批貨會在來源單與轉入單各算一次金額
    WHERE i.status NOT IN ('cancelled','expired')
    GROUP BY i.order_id
  ),
  day_agg AS (
    SELECT
      t.ymd,
      count(DISTINCT t.id)                 AS orders,
      count(DISTINCT t.member_id)          AS members,
      COALESCE(SUM(a.amount), 0)::numeric  AS amount
    FROM trend_orders t
    LEFT JOIN order_amt a ON a.order_id = t.id
    GROUP BY t.ymd
  ),
  total_agg AS (
    SELECT
      count(DISTINCT t.id)                 AS orders,
      count(DISTINCT t.member_id)          AS members,
      COALESCE(SUM(a.amount), 0)::numeric  AS amount
    FROM trend_orders t
    LEFT JOIN order_amt a ON a.order_id = t.id
  ),
  -- 取貨明細（本月）：一行 picked_up = 一次交貨，逐行加總
  pickup_items AS (
    SELECT
      to_char((i.updated_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD') AS ymd,
      f.id                            AS order_id,
      (i.qty * i.unit_price)::numeric AS amount,
      i.qty::numeric                  AS qty
    FROM filtered f
    JOIN customer_order_items i ON i.order_id = f.id
    WHERE i.status = 'picked_up'
      AND i.updated_at >= p_month_start
      AND f.status NOT IN ('cancelled','expired','transferred_out')
  ),
  pickup_day_agg AS (
    SELECT
      p.ymd,
      count(DISTINCT p.order_id) AS orders,
      SUM(p.amount)::numeric     AS amount,
      SUM(p.qty)::numeric        AS qty
    FROM pickup_items p
    GROUP BY p.ymd
  ),
  pickup_total_agg AS (
    SELECT
      count(DISTINCT p.order_id)         AS orders,
      COALESCE(SUM(p.amount), 0)::numeric AS amount,
      COALESCE(SUM(p.qty), 0)::numeric    AS qty
    FROM pickup_items p
  )
  SELECT jsonb_build_object(
    'tab_counts', (SELECT to_jsonb(tab_counts.*) FROM tab_counts),
    'trend_days', COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'ymd', ymd, 'orders', orders, 'members', members, 'amount', amount
                ) ORDER BY ymd)
       FROM day_agg),
      '[]'::jsonb
    ),
    'trend_total', (SELECT to_jsonb(total_agg.*) FROM total_agg),
    'pickup_days', COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'ymd', ymd, 'orders', orders, 'amount', amount, 'qty', qty
                ) ORDER BY ymd)
       FROM pickup_day_agg),
      '[]'::jsonb
    ),
    'pickup_total', (SELECT to_jsonb(pickup_total_agg.*) FROM pickup_total_agg)
  );
$function$;
