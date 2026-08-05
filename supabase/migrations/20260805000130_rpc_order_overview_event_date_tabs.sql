-- ============================================================
-- rpc_order_overview v5 — tab 數量的日期區間改用「事件日」event_at
--
-- 承 v4（20260805000110，只有已完成/部分取貨改看取貨日）再擴大：除了「未取貨」
-- 之外的每個 tab，日期區間都套該狀態自己的事件時間，定義集中在 v_admin_orders
-- .event_at（見 20260805000120，含各來源的線上覆蓋率與「為何不能用 updated_at」）：
--
--   未取貨 (pending/confirmed/shipping/ready) → created_at 訂單日（唯一看下單時間的 tab）
--   可取貨 (ready)                            → ready_at      到貨可取日
--   部分取貨 (partially_completed)            → 最後一次取貨
--   已完成 (completed)                        → completed_at  取貨完成日
--   取消 (cancelled/expired)                  → cancelled_at  取消日
--   轉出 (transferred_out)                    → 接手單 created_at 轉出日
--
-- 「未取貨」刻意維持訂單日：它混了 pending/confirmed/shipping/ready 四個狀態，
-- 還沒有終態事件可言，使用者在這個 tab 問的就是「這幾天下的單還沒取」。
--
-- 列表頁 (orders/page.tsx) 查同一張 v_admin_orders 並對 event_at 下同樣的區間，
-- 兩邊語意一致；線上對照（松山店、事件日 2026-08-05）：
--   completed 212 = v4 的 EXISTS 取貨日版本 212 = KPI 卡當日 213 單扣掉 1 張
--   partially_completed 後的餘數，數字對得起來。
--
-- 基底版本：20260805000110_rpc_order_overview_pickup_date_tabs.sql（v4）
--   本檔只改 tab_counts 的日期來源（filtered 改查 v_admin_orders 以取得 event_at），
--   trend_* / pickup_* 聚合一字未動（仍固定為 p_month_start 起算的當月）。
--   簽章不變，不需 DROP。
-- rollback：CREATE OR REPLACE 回 20260805000110 的版本。
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
    -- v_admin_orders = customer_orders + event_at（事件日，定義見 20260805000120）
    SELECT o.id, o.member_id, o.created_at, o.event_at, o.status
    FROM v_admin_orders o
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
  'p_date_from/p_date_to 為半開區間 [from, to)，只套用於 tab 數量：未取貨看訂單日 created_at，'
  '其餘 tab 看事件日 v_admin_orders.event_at（可取/取貨/取消/轉出各自的發生時間）。'
  '趨勢與取貨聚合固定為 p_month_start 起算的當月。';

GRANT EXECUTE ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) TO authenticated;
