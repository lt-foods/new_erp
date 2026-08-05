-- ============================================================
-- rpc_order_overview v6 — 加 tab_amounts：「目前篩選結果」的金額 / 單數 / 件數
--
-- 動機：頁首三張 KPI 卡都是固定視角（本月營業額 / 本月訂單數 / 今日取貨金額），
--   不吃下方的日期區間與分頁。使用者篩完（例：文山店、已完成、8/4）想直接看到
--   「這批單是多少錢」，只能自己把 50 筆一頁的清單加總。tab_amounts 就是把列表
--   當下那組條件的金額算在伺服端回來。
--
-- 定義：
--   * 範圍 = 與 tab_counts 完全同一組條件（開團 / 店家 / 關鍵字 / 分頁狀態 /
--     日期區間，且日期語意同樣跟著 tab 走：未取貨看 created_at，其餘看
--     v_admin_orders.event_at）。所以卡片數字與 tab 上的筆數一定對得起來。
--   * 金額 = 該訂單所有明細的 qty * unit_price 加總（不扣折扣），與「本月營業額」
--     同一公式，兩張卡才能直接對比。注意這是「訂單金額」不是「已取貨金額」：
--     部分取貨的單算的是整張單的值，要看實際交出去多少錢請用「今日取貨金額」卡
--     / pickup_days。
--   * 六個 tab 一次算完（單次掃描 group by status），維持前端「切 tab 不重抓
--     RPC」的行為，不需要多傳 p_tab 參數、簽章不變。
--
-- 成本：scoped 只收 tab 真的會用到的狀態，日期區間有設時很小；最壞情況（全租戶、
--   完全不篩）實測 311ms，一般（單一店家 + 日期區間）在個位數毫秒。
--
-- 基底版本：20260805000130_rpc_order_overview_event_date_tabs.sql（v5）
--   本檔只加 tab_amounts 一個 key，並把 ranged_order / ranged_event 收斂到各自
--   tab 會用到的狀態（tab_counts 本來就只取那些狀態，數字不變）。
-- rollback：CREATE OR REPLACE 回 20260805000130 的版本。
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
    SELECT f.id, f.status
    FROM filtered f
    WHERE f.status IN ('pending','confirmed','shipping','ready')
      AND (p_date_from IS NULL OR f.created_at >= p_date_from)
      AND (p_date_to   IS NULL OR f.created_at <  p_date_to)
  ),
  -- 其餘 tab 專用：事件日 event_at 區間
  ranged_event AS (
    SELECT f.id, f.status
    FROM filtered f
    WHERE f.status IN ('ready','partially_completed','completed','cancelled','expired','transferred_out')
      AND (p_date_from IS NULL OR f.event_at >= p_date_from)
      AND (p_date_to   IS NULL OR f.event_at <  p_date_to)
  ),
  tab_counts AS (
    SELECT
      (SELECT count(*) FROM ranged_order)                                                             AS pending,
      -- ready 是 pending 的子集（刻意重疊）：未取貨=全部未取，可取貨=其中已到店的。
      -- 兩者的日期語意不同（訂單日 vs 到貨可取日），故取自不同的 ranged。
      (SELECT count(*) FROM ranged_event WHERE status = 'ready')                                      AS ready,
      (SELECT count(*) FROM ranged_event WHERE status = 'partially_completed')                        AS partially,
      (SELECT count(*) FROM ranged_event WHERE status = 'completed')                                  AS completed,
      (SELECT count(*) FROM ranged_event WHERE status IN ('cancelled','expired'))                     AS cancelled,
      (SELECT count(*) FROM ranged_event WHERE status = 'transferred_out')                            AS transferred
  ),
  -- 篩選結果金額：先把兩組 ranged 用到的訂單去重，只對這些訂單算一次明細加總
  scoped AS (
    SELECT id FROM ranged_order
    UNION
    SELECT id FROM ranged_event
  ),
  scoped_totals AS (
    SELECT i.order_id, SUM(i.qty)::numeric AS qty, SUM(i.qty * i.unit_price)::numeric AS amount
    FROM customer_order_items i
    JOIN scoped s ON s.id = i.order_id
    GROUP BY i.order_id
  ),
  amt_pending AS (
    SELECT
      count(*)::bigint                    AS orders,
      COALESCE(SUM(t.qty), 0)::numeric    AS qty,
      COALESCE(SUM(t.amount), 0)::numeric AS amount
    FROM ranged_order r
    LEFT JOIN scoped_totals t ON t.order_id = r.id
  ),
  amt_event_tab AS (
    SELECT
      CASE r.status
        WHEN 'ready'               THEN 'ready'
        WHEN 'partially_completed' THEN 'partially'
        WHEN 'completed'           THEN 'completed'
        WHEN 'transferred_out'     THEN 'transferred'
        ELSE 'cancelled'  -- cancelled / expired 同一個 tab
      END                                 AS tab,
      count(*)::bigint                    AS orders,
      COALESCE(SUM(t.qty), 0)::numeric    AS qty,
      COALESCE(SUM(t.amount), 0)::numeric AS amount
    FROM ranged_event r
    LEFT JOIN scoped_totals t ON t.order_id = r.id
    GROUP BY 1
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
    -- 目前篩選條件下，各 tab 的金額 / 單數 / 件數（沒有資料的 tab 不會有 key，前端補 0）
    'tab_amounts', (
      SELECT jsonb_build_object('pending', (SELECT to_jsonb(a.*) FROM amt_pending a))
             || COALESCE(
                  jsonb_object_agg(
                    e.tab,
                    jsonb_build_object('orders', e.orders, 'qty', e.qty, 'amount', e.amount)
                  ),
                  '{}'::jsonb
                )
      FROM amt_event_tab e
    ),
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
  'admin /orders 頁首聚合：tab 數量 + tab 金額（目前篩選結果）+ 本月每日下單趨勢 + 本月每日取貨金額。'
  'p_date_from/p_date_to 為半開區間 [from, to)，套用於 tab_counts / tab_amounts：未取貨看訂單日 created_at，'
  '其餘 tab 看事件日 v_admin_orders.event_at。tab_amounts 的金額為訂單全部明細 qty*unit_price（不扣折扣），'
  '與「本月營業額」同公式；趨勢與取貨聚合固定為 p_month_start 起算的當月。';

GRANT EXECUTE ON FUNCTION rpc_order_overview(bigint[], bigint, text, timestamptz, timestamptz, timestamptz) TO authenticated;
