-- ============================================================
-- 2026-08-08: rpc_order_overview v8 — 新增「下單來源」每日趨勢
--
-- 需求：訂單頁要一張折線圖 KPI，比較「App 下單 / 商城下單 / 小幫手代客」
--   三條線的每日走勢（並列同一張圖，看得出通路消長）。
--
-- 做法：沿用既有 trend_orders（本月、排除 cancelled/expired/transferred_out
--   的訂單），往下 join 品項取 customer_order_items.source，依 (日期, source)
--   聚合。新增兩個回傳欄位，其餘輸出一字不動：
--     source_days  : [{ymd, source, orders, amount, qty}, ...]
--     source_total : [{source, orders, amount, qty}, ...]
--
-- ⚠ orders 是 count(DISTINCT order_id)：一張單同時有小幫手代 key 與會員自助
--   的品項（closed 緩衝期補加，見 orderSource.ts 的 summarizeOrderSource）時，
--   兩個 source 各算一次 —— Σ source_days.orders ≥ trend_days.orders。
--   這張圖問的是「這天每個通路各有幾張單在動」，不是把訂單切派給單一通路，
--   混合單本來就該在兩條線上都出現。amount/qty 則是逐品項加總，不會重複。
--
-- 金額口徑與既有 trend 一致：排除 status IN ('cancelled','expired') 的品項
--   （斷貨／部分轉出的來源品項留在原單上，不濾會重複計，見 20260808000000）。
--
-- 基底版本：20260808000000_stats_exclude_transferred_out_items.sql 第 2 節（v7，
--   線上現行版本；grep rpc_order_overview 的最新定義）。簽章不變（7 參數），
--   故用 CREATE OR REPLACE，不需 DROP、GRANT 也沿用。
-- Rollback：把 20260808000000 第 2 節的函式本體再跑一次即可回到 v7。
-- ============================================================

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
  -- 來源趨勢（本月）：同一批 trend_orders 往下拆到品項，取 source。
  -- 口徑與 order_amt 一致（排除 cancelled/expired 品項），差別只在多 GROUP BY source。
  source_items AS (
    SELECT
      t.ymd,
      i.source,
      t.id                            AS order_id,
      (i.qty * i.unit_price)::numeric AS amount,
      i.qty::numeric                  AS qty
    FROM trend_orders t
    JOIN customer_order_items i ON i.order_id = t.id
    WHERE i.status NOT IN ('cancelled','expired')
  ),
  source_day_agg AS (
    SELECT
      s.ymd,
      s.source,
      count(DISTINCT s.order_id) AS orders,
      SUM(s.amount)::numeric     AS amount,
      SUM(s.qty)::numeric        AS qty
    FROM source_items s
    GROUP BY s.ymd, s.source
  ),
  source_total_agg AS (
    SELECT
      s.source,
      count(DISTINCT s.order_id) AS orders,
      SUM(s.amount)::numeric     AS amount,
      SUM(s.qty)::numeric        AS qty
    FROM source_items s
    GROUP BY s.source
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
    'source_days', COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'ymd', ymd, 'source', source, 'orders', orders, 'amount', amount, 'qty', qty
                ) ORDER BY ymd, source)
       FROM source_day_agg),
      '[]'::jsonb
    ),
    'source_total', COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'source', source, 'orders', orders, 'amount', amount, 'qty', qty
                ) ORDER BY source)
       FROM source_total_agg),
      '[]'::jsonb
    ),
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

COMMENT ON FUNCTION public.rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz, bigint[]) IS
  'admin /orders 頁首聚合：tab 數量（日期區間依 tab 語意走 created_at / event_at）、'
  '本月下單趨勢 trend_days/trend_total、本月來源趨勢 source_days/source_total'
  '（依 customer_order_items.source 分組，混合來源的單在各來源都計一張）、'
  '本月取貨趨勢 pickup_days/pickup_total。v8，基底 20260808000000。';
