-- ============================================================
-- rpc_order_overview v3 — 加「取貨金額」聚合（KPI 卡「今日取貨金額」用）
--
-- 動機：/orders 頁 KPI 列的四張卡都是「下單」視角（本月營業額 / 訂單數 /
--   客單價 / 會員數，全部以 customer_orders.created_at 切）。門市每天真正
--   關心的「今天交出去多少貨、收了多少錢」看不到。新增 pickup_days /
--   pickup_total，讓 UI 多一張「今日取貨金額」卡（大字＝今天、副字＝本月
--   累計、sparkline＝本月每日），與既有四張卡同一組 filter、同一次 round-trip。
--
-- 定義：
--   * 取貨明細 = customer_order_items.status='picked_up'。
--     rpc_record_pickup 整行取直接標 picked_up、部分取則拆出一行 picked_up
--     （qty=本次取貨量），因此逐行加總不會重複也不會漏。
--     rpc_undo_pickup 會把 picked_up 改回 pending，撤銷的取貨自動不計。
--   * 金額 = qty * unit_price，與 trend 的營業額同一公式（不扣折扣），
--     兩張卡才能直接對比。要看實收金額是另一個題目（折扣分攤在
--     PickupDialog.lineSubQty，與此處刻意不混用）。
--   * 取貨時間 = customer_order_items.updated_at。
--     rpc_record_pickup 在標 picked_up 的同一句 UPDATE 寫 updated_at，
--     語意上「更精準」的來源是 pickup_movement_id → stock_movements.created_at
--     （append-only、不可改），但線上實測兩者對 17311 筆 picked_up 全部
--     完全相等（max drift 0.000000 秒、無 pickup_movement_id 為 NULL 者），
--     而多這個 join 會讓本段從 46ms 變 224ms。故取 updated_at。
--     ⚠ 若日後有 RPC 會在標記 picked_up 之後再 UPDATE 該行（目前沒有；撤銷
--     取貨是改回 pending 而不是留在 picked_up），就要改回 join stock_movements。
--   * 排除 cancelled/expired/transferred_out 訂單，與 trend 一致。
--   * 日界以 Asia/Taipei 切，與 trend_days 一致。
--   * campaign / 店家 / keyword filter 沿用 filtered CTE；日期區間 (p_date_from
--     /p_date_to) 不套 — 與 trend 同理，這張卡講的是「今天」與「本月」。
--
-- 基底版本：20260803000000_rpc_order_overview_ready_tab_and_date_range.sql
--   （tab_counts 含 ready + p_date_from/p_date_to 版；本檔在其上只加
--   pickup_days / pickup_total 兩個 key，既有 key 一字未動）。
-- rollback：CREATE OR REPLACE 回 20260803000000 的版本（簽章相同，不需 DROP）。
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
  -- tab 數量專用：再套訂單日期區間（趨勢卡 / 取貨卡不套，見檔頭說明）
  ranged AS (
    SELECT f.*
    FROM filtered f
    WHERE (p_date_from IS NULL OR f.created_at >= p_date_from)
      AND (p_date_to   IS NULL OR f.created_at <  p_date_to)
  ),
  tab_counts AS (
    SELECT
      count(*) FILTER (WHERE status IN ('pending','confirmed','shipping','ready')) AS pending,
      -- ready 是 pending 的子集（刻意重疊）：未取貨=全部未取，可取貨=其中已到店的
      count(*) FILTER (WHERE status = 'ready')                                     AS ready,
      count(*) FILTER (WHERE status = 'partially_completed')                       AS partially,
      count(*) FILTER (WHERE status = 'completed')                                 AS completed,
      count(*) FILTER (WHERE status IN ('cancelled','expired'))                    AS cancelled,
      count(*) FILTER (WHERE status = 'transferred_out')                           AS transferred
    FROM ranged
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
  'p_date_from/p_date_to 為訂單日 created_at 半開區間 [from, to)，只套用於 tab 數量；'
  '趨勢與取貨聚合固定為 p_month_start 起算的當月。';

GRANT EXECUTE ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) TO authenticated;
