-- ============================================================
-- rpc_order_overview v2 — 新增「可取貨」tab 數量 + 訂單日期區間篩選
--
-- 動機：admin /orders 頁
--   (1) 多一個「可取貨」tab（status='ready'，與 ORDER_STATUS_LABEL.ready
--       同語意 — 貨已到店、會員還沒來取）。原「未取貨」tab 是
--       pending/confirmed/shipping/ready 的聯集，ready 混在裡面看不出來。
--       兩個 tab 刻意重疊：未取貨仍是全部未取的總覽，可取貨是其子集。
--   (2) 多一個訂單日期 (created_at) 區間篩選，tab 數量要跟著列表一起收斂，
--       否則 tab 顯示 120 筆、列表只有 3 筆會對不起來。
--
-- 日期區間只套在 tab_counts，趨勢卡 (trend_days / trend_total) 維持「本月」：
--   趨勢卡的 label 就寫死是「本月營業額 / 本月訂單數 / ...」，是與列表篩選
--   無關的當月 KPI 總覽（本來也不受 tab 影響）。把日期區間套進去會讓
--   「本月」變成「本月 ∩ 使用者選的區間」，label 與數字對不上。
--
-- p_date_from / p_date_to 由 client 換算成 timestamptz 後傳入（半開區間
-- [from, to)，to 是「迄日的隔天 00:00」，因此迄日當天整天算進來）。
-- 兩者皆 DEFAULT NULL — 舊版前端只帶 4 個具名參數也仍能解析到本函式。
--
-- 基底版本：20260708000010_rpc_order_overview.sql（線上現行唯一版本；
--   grep rpc_order_overview 僅該檔定義過，20260708000020 只是提及）。
-- rollback：
--   DROP FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz);
--   再把 20260708000010 的 4-arg 版本整段重跑。
-- ============================================================

-- 舊 4-arg 版本移除：新版把它的參數列往後加上兩個 DEFAULT NULL 參數，
-- 留著會變成兩支同名 function（PostgREST 靠具名參數解析、不會歧義，但屬死碼）。
DROP FUNCTION IF EXISTS rpc_order_overview(bigint[], bigint, text, timestamptz);

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
  -- tab 數量專用：再套訂單日期區間（趨勢卡不套，見檔頭說明）
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

COMMENT ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) IS
  'admin /orders 頁首聚合：tab 數量（含 ready「可取貨」）+ 本月每日趨勢。'
  'p_date_from/p_date_to 為訂單日 created_at 半開區間 [from, to)，只套用於 tab 數量，趨勢維持本月。';

GRANT EXECUTE ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) TO authenticated;
