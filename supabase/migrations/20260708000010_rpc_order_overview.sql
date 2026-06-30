-- ============================================================
-- rpc_order_overview — admin /orders 頁首聚合（tab 數量 + 月趨勢）
--
-- 動機：/orders 頁讀取很慢。根因是頁面 mount 時瀏覽器端做兩件重活：
--   (1) KPI 趨勢卡：chunked fetch 把「整月所有訂單(最多 5 萬筆) + 全部
--       order_items」搬回瀏覽器再 client 聚合 → 數 MB 傳輸 + 大量計算。
--   (2) Tab 數量：5 個 count:exact 全表掃描並發跑。
--
-- 修法：照 rpc_orders_pivot (20260621000030) 的 RETURNS jsonb 範本，把
--   tab 數量 + 每日趨勢 + 本月累計合併成單一伺服端聚合、一次 round-trip。
--   jsonb 單一 row 不受 PostgREST max_rows=1000 截斷。
--
-- 篩選與既有 client 邏輯對齊：
--   * campaign / 取貨店 篩選
--   * keyword：與 buildKeywordOr 同語意 — 每個 token 都要在
--     members.name/phone/member_no 命中(token-AND)，或整串命中
--     customer_orders.order_no/nickname_snapshot
--   * 趨勢只計有效成交（排除 cancelled/expired/transferred_out），
--     日界以 Asia/Taipei 切（與 client tpeFmt 一致）
--   * tab 分組沿用 PENDING/CANCELLED 狀態集合
--
-- 基底版本：無（全新 function）
-- rollback：DROP FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz);
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_order_overview(
  p_campaign_ids bigint[],
  p_store_id     bigint,
  p_keyword      text,
  p_month_start  timestamptz
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
  tab_counts AS (
    SELECT
      count(*) FILTER (WHERE status IN ('pending','confirmed','shipping','ready')) AS pending,
      count(*) FILTER (WHERE status = 'partially_completed')                       AS partially,
      count(*) FILTER (WHERE status = 'completed')                                 AS completed,
      count(*) FILTER (WHERE status IN ('cancelled','expired'))                    AS cancelled,
      count(*) FILTER (WHERE status = 'transferred_out')                           AS transferred
    FROM filtered
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
    'trend_total', (SELECT to_jsonb(total_agg.*) FROM total_agg)
  );
$$;

GRANT EXECUTE ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz) TO authenticated;
