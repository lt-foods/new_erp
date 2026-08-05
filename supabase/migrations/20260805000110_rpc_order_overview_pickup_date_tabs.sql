-- ============================================================
-- rpc_order_overview v4 — 「已完成 / 部分取貨」兩個 tab 的日期區間改看取貨日
--
-- 動機：/orders 的日期區間一律套 customer_orders.created_at（訂單日）。團購是
--   「下單 → 等到貨 → 到店取」，中間隔好幾天到好幾週，所以在「已完成」分頁把
--   日期設成今天/近三天，永遠是 0 筆 —— 使用者想問的是「這幾天交出去哪些貨」，
--   不是「這幾天下的單裡有哪些已經取完了」。實測（松山店 2026-08-03~08-05）：
--     訂單日區間 → completed 0 筆
--     同一天實際取貨 → 213 張單，但那些單的訂單日散在 5~7 月
--
-- 修法：日期語意跟著 tab 走，不另外做切換 UI（與 orders/page.tsx 同步）：
--     未取貨 / 可取貨 / 轉出 / 取消  → 訂單日 created_at   （原行為，未動）
--     已完成 / 部分取貨              → 取貨日              （本次新增）
--   取貨日定義沿用同檔 pickup_items：customer_order_items.status='picked_up'
--   的 updated_at（rpc_record_pickup 在標記 picked_up 的同一句 UPDATE 寫入；
--   rpc_undo_pickup 改回 pending 故自動不計）。判定用 EXISTS =「該區間內有取過
--   貨」，部分取貨分批取的單只要其中一批落在區間內就算，與列表頁的
--   customer_order_items!inner 內嵌過濾（PostgREST 走 lateral，父列不重複）同語意。
--   線上實測兩者同為 213 筆。
--
-- 邊界：p_date_from / p_date_to 都是 NULL（未設日期）時，取貨日 tab 不得退化成
--   「必須有 picked_up 明細」—— 否則沒設日期時 completed 的數量會少掉。
--
-- 基底版本：20260803000020_rpc_order_overview_today_pickup.sql（v3）
--   本檔只改 tab_counts 的日期來源，trend_* / pickup_* 聚合一字未動（仍固定為
--   p_month_start 起算的當月、不吃日期區間）。簽章不變，不需 DROP。
-- rollback：CREATE OR REPLACE 回 20260803000020 的版本。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_order_overview(
  p_campaign_ids bigint[],
  p_store_id     bigint,
  p_keyword      text,
  p_month_start  timestamptz,
  p_date_from    timestamptz DEFAULT NULL,
  p_date_to      timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
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
    SELECT o.id, o.member_id, o.created_at, o.status
    FROM customer_orders o
    WHERE (p_store_id IS NULL OR o.pickup_store_id = p_store_id)
      AND (
        p_campaign_ids IS NULL
        OR cardinality(p_campaign_ids) = 0
        OR o.campaign_id = ANY(p_campaign_ids)
      )
      AND (
        (SELECT q FROM kw) IS NULL
        OR o.order_no          ILIKE '%' || (SELECT q FROM kw) || '%'
        OR o.nickname_snapshot ILIKE '%' || (SELECT q FROM kw) || '%'
        OR o.member_id IN (SELECT id FROM qualified_members)
      )
  ),
  -- tab 數量專用：訂單日 created_at 區間（未取貨 / 可取貨 / 轉出 / 取消 用）
  ranged_order AS (
    SELECT f.*
    FROM filtered f
    WHERE (p_date_from IS NULL OR f.created_at >= p_date_from)
      AND (p_date_to   IS NULL OR f.created_at <  p_date_to)
  ),
  -- tab 數量專用：取貨日區間（已完成 / 部分取貨 用）
  -- 未設日期時不套任何條件，否則會退化成「必須有 picked_up 明細」而少算。
  ranged_pickup AS (
    SELECT f.*
    FROM filtered f
    WHERE (p_date_from IS NULL AND p_date_to IS NULL)
       OR EXISTS (
            SELECT 1
            FROM customer_order_items i
            WHERE i.order_id = f.id
              AND i.status = 'picked_up'
              AND (p_date_from IS NULL OR i.updated_at >= p_date_from)
              AND (p_date_to   IS NULL OR i.updated_at <  p_date_to)
          )
  ),
  tab_counts AS (
    SELECT
      (SELECT count(*) FROM ranged_order  WHERE status IN ('pending','confirmed','shipping','ready')) AS pending,
      -- ready 是 pending 的子集（刻意重疊）：未取貨=全部未取，可取貨=其中已到店的
      (SELECT count(*) FROM ranged_order  WHERE status = 'ready')                                     AS ready,
      (SELECT count(*) FROM ranged_pickup WHERE status = 'partially_completed')                       AS partially,
      (SELECT count(*) FROM ranged_pickup WHERE status = 'completed')                                 AS completed,
      (SELECT count(*) FROM ranged_order  WHERE status IN ('cancelled','expired'))                    AS cancelled,
      (SELECT count(*) FROM ranged_order  WHERE status = 'transferred_out')                           AS transferred
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
$$;

COMMENT ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) IS
  'admin /orders 頁首聚合：tab 數量（含 ready「可取貨」）+ 本月每日下單趨勢 + 本月每日取貨金額。'
  'p_date_from/p_date_to 為半開區間 [from, to)，只套用於 tab 數量，且日期語意跟著 tab 走：'
  '未取貨/可取貨/轉出/取消 = 訂單日 created_at；已完成/部分取貨 = 取貨日（picked_up 明細的 updated_at）。'
  '趨勢與取貨聚合固定為 p_month_start 起算的當月。';

GRANT EXECUTE ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) TO authenticated;
