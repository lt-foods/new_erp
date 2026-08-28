-- ============================================================
-- 2026-08-28: 日結報表訂單明細改「點了才載、分頁 20 筆」（Alex 8/26 補充指示）
--
-- 拆兩支：rpc_daily_pickup_settlement 只回彙總（拿掉 orders / orders_total /
-- orders_truncated 三個 key），明細改走新函式 rpc_daily_pickup_orders
-- （p_limit 預設 20、上限 100，p_offset 分頁，picked_at DESC）。
-- 口徑（picked_up 逐行、qty*unit_price、Asia/Taipei 日界、排除
-- cancelled/expired/transferred_out 訂單與 member_type='store_internal'
-- 容器單）與基底版本完全相同，只動回傳形狀，詳見基底檔頭。
--
-- ⚠ 兩支函式的 picked 母體（WHERE 那五個條件）必須逐字一致，
--   改其中一支記得同步另一支，否則彙總跟明細對不上。
--
-- 基底版本：20260826010000_rpc_daily_pickup_settlement.sql
--   （settlement 簽章不變，CREATE OR REPLACE 覆寫；orders 為新函式）。
-- 此版 SQL 已於 2026-08-26 套上正式庫（Management API），線上一直是本檔的行為；
--   基底檔進 main 的是初版（settlement 帶 orders），從零重跑時會被本檔蓋掉，一致。
-- rollback：settlement CREATE OR REPLACE 回 20260826010000 版本；
--           DROP FUNCTION rpc_daily_pickup_orders(bigint, date, date, integer, integer);
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_daily_pickup_settlement(
  p_store_id  bigint DEFAULT NULL,
  p_date_from date   DEFAULT NULL,
  p_date_to   date   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH params AS (
    SELECT
      COALESCE(p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date) AS d_from,
      LEAST(
        COALESCE(p_date_to, p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date),
        COALESCE(p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date) + 92
      ) AS d_to
  ),
  bounds AS (
    SELECT
      (p.d_from::timestamp AT TIME ZONE 'Asia/Taipei')       AS ts_from,
      ((p.d_to + 1)::timestamp AT TIME ZONE 'Asia/Taipei')   AS ts_to
    FROM params p
  ),
  picked AS (
    SELECT
      to_char((i.updated_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD') AS ymd,
      co.pickup_store_id                            AS store_id,
      COALESCE(s.name, '#' || co.pickup_store_id)   AS store_name,
      co.id                                         AS order_id,
      CASE
        WHEN co.status = 'completed'           THEN 'completed'
        WHEN co.status = 'partially_completed' THEN 'partial'
        ELSE 'other'
      END                                           AS grp,
      i.qty::numeric                                AS qty,
      (i.qty * i.unit_price)::numeric               AS amount
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
    JOIN bounds b ON TRUE
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN stores  s ON s.id = co.pickup_store_id
    WHERE i.status = 'picked_up'
      AND i.updated_at >= b.ts_from
      AND i.updated_at <  b.ts_to
      AND co.status NOT IN ('cancelled','expired','transferred_out')
      AND COALESCE(m.member_type, '') <> 'store_internal'
      AND (p_store_id IS NULL OR co.pickup_store_id = p_store_id)
  ),
  day_agg AS (
    SELECT
      p.ymd,
      p.store_id,
      p.store_name,
      count(DISTINCT p.order_id)                                          AS orders,
      SUM(p.qty)::numeric                                                 AS qty,
      SUM(p.amount)::numeric                                              AS amount,
      count(DISTINCT p.order_id) FILTER (WHERE p.grp = 'completed')       AS completed_orders,
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'completed'), 0)::numeric AS completed_amount,
      count(DISTINCT p.order_id) FILTER (WHERE p.grp = 'partial')         AS partial_orders,
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'partial'), 0)::numeric   AS partial_amount,
      COALESCE(SUM(p.amount) FILTER (WHERE p.grp = 'other'), 0)::numeric     AS other_amount
    FROM picked p
    GROUP BY p.ymd, p.store_id, p.store_name
  )
  SELECT jsonb_build_object(
    'date_from', (SELECT to_char(d_from, 'YYYY-MM-DD') FROM params),
    'date_to',   (SELECT to_char(d_to,   'YYYY-MM-DD') FROM params),
    'days', COALESCE(
      (SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.ymd DESC, d.store_name)
       FROM day_agg d),
      '[]'::jsonb
    )
  );
$$;

COMMENT ON FUNCTION rpc_daily_pickup_settlement(bigint, date, date) IS
  '日結報表彙總：依日期×分店聚合「已取走品項」金額（picked_up 逐行、qty*unit_price、'
  'Asia/Taipei 日界、updated_at 當取貨時間），拆已完成 / 部分取貨。排除 cancelled/'
  'expired/transferred_out 訂單與內部容器單（member_type=store_internal）。'
  '口徑同 rpc_order_overview 的 pickup 聚合，不扣折扣。訂單明細走 '
  'rpc_daily_pickup_orders（分頁），兩支的 picked 母體必須一致。';

GRANT EXECUTE ON FUNCTION rpc_daily_pickup_settlement(bigint, date, date) TO authenticated;

-- ------------------------------------------------------------
-- 訂單明細（點了才載、分頁）。picked 母體與上面那支逐字相同。
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION rpc_daily_pickup_orders(
  p_store_id  bigint  DEFAULT NULL,
  p_date_from date    DEFAULT NULL,
  p_date_to   date    DEFAULT NULL,
  p_limit     integer DEFAULT 20,
  p_offset    integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH params AS (
    SELECT
      COALESCE(p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date) AS d_from,
      LEAST(
        COALESCE(p_date_to, p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date),
        COALESCE(p_date_from, (now() AT TIME ZONE 'Asia/Taipei')::date) + 92
      ) AS d_to
  ),
  bounds AS (
    SELECT
      (p.d_from::timestamp AT TIME ZONE 'Asia/Taipei')       AS ts_from,
      ((p.d_to + 1)::timestamp AT TIME ZONE 'Asia/Taipei')   AS ts_to
    FROM params p
  ),
  picked AS (
    SELECT
      to_char((i.updated_at AT TIME ZONE 'Asia/Taipei')::date, 'YYYY-MM-DD') AS ymd,
      co.pickup_store_id                            AS store_id,
      COALESCE(s.name, '#' || co.pickup_store_id)   AS store_name,
      co.id                                         AS order_id,
      co.order_no,
      co.status,
      COALESCE(m.name, co.nickname_snapshot)        AS member_name,
      i.qty::numeric                                AS qty,
      (i.qty * i.unit_price)::numeric               AS amount,
      i.updated_at                                  AS picked_at
    FROM customer_order_items i
    JOIN customer_orders co ON co.id = i.order_id
    JOIN bounds b ON TRUE
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN stores  s ON s.id = co.pickup_store_id
    WHERE i.status = 'picked_up'
      AND i.updated_at >= b.ts_from
      AND i.updated_at <  b.ts_to
      AND co.status NOT IN ('cancelled','expired','transferred_out')
      AND COALESCE(m.member_type, '') <> 'store_internal'
      AND (p_store_id IS NULL OR co.pickup_store_id = p_store_id)
  ),
  order_day AS (
    SELECT
      p.ymd,
      p.store_id,
      p.store_name,
      p.order_id,
      p.order_no,
      p.status,
      p.member_name,
      count(*)               AS item_count,
      SUM(p.qty)::numeric    AS qty,
      SUM(p.amount)::numeric AS amount,
      max(p.picked_at)       AS picked_at
    FROM picked p
    GROUP BY p.ymd, p.store_id, p.store_name, p.order_id, p.order_no, p.status, p.member_name
  ),
  page AS (
    SELECT *
    FROM order_day
    ORDER BY picked_at DESC, order_id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM order_day),
    'rows', COALESCE(
      (SELECT jsonb_agg(to_jsonb(o.*) ORDER BY o.picked_at DESC, o.order_id DESC)
       FROM page o),
      '[]'::jsonb
    )
  );
$$;

COMMENT ON FUNCTION rpc_daily_pickup_orders(bigint, date, date, integer, integer) IS
  '日結報表訂單明細（分頁，預設 20 筆／上限 100）：依 訂單×日期 聚合已取走品項，'
  'picked_at DESC。母體與 rpc_daily_pickup_settlement 完全一致，改任一支要同步另一支。';

GRANT EXECUTE ON FUNCTION rpc_daily_pickup_orders(bigint, date, date, integer, integer) TO authenticated;
