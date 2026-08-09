-- ============================================================================
-- 2026-08-09: rpc_store_product_heat — 首頁「門市 × 商品熱賣」地圖的聚合來源
--
-- 需求：首頁要一眼看出「哪一家店賣得旺」以及「那家店主力賣什麼」，並且反過來
--   問「這個商品在哪幾家店賣得好」。地圖用 stores.latitude/longitude 定位
--   （見 20260809000000）。
--
-- 口徑（刻意與 rpc_order_overview v8 的 trend 對齊，兩頁數字才不會打架）：
--   - 訂單層：排除 status IN ('cancelled','expired','transferred_out')
--     （transferred_out 的貨已在接手單上，不排會一批貨算兩次）
--   - 品項層：排除 status IN ('cancelled','expired')
--     斷貨走 status='cancelled' + stockout_at（見 20260702020000），不濾就是
--     把「拿不到的貨」算進熱賣度；部分轉出也把來源品項留在原單上標 cancelled
--     （見 20260808000000_stats_exclude_transferred_out_items）。
--   - 時間軸走「下單日 created_at」不是取貨日：問的是「這段期間客人想要什麼」，
--     取貨日會被到貨批次牽著走（同一天到貨的單全擠成一根）。
--   - 起點對齊台北時區的日界：p_days=30 → 含今天在內往回 30 個自然日。
--
-- 商品層級用 products.id（不是 sku）：同一商品的不同規格在「熱賣程度」這個問題
--   上是同一件事；要看規格差異請進商品頁。名稱優先取 products.name，
--   回退 skus.product_name（熱路徑 denorm 欄位）。
--
-- 回傳一律含**所有未刪除門市**（含本期零銷售、含沒座標的），前端才畫得出
--   「尚未設定座標」清單；沒座標的店不會被畫到地圖上但仍出現在排行榜。
--
-- SECURITY INVOKER（預設）：RLS 套用 caller，與 rpc_order_overview 同慣例 ——
--   店長只看得到自己店的訂單，聚合結果自然收斂，不需要在函式裡再判角色。
--
-- 效能：線上 30 天約 22k 張單 / 3.7k SKU，實測 seq scan 約 120ms，
--   遠低於首頁其他查詢的成本，不另建索引。
--
-- Rollback: DROP FUNCTION IF EXISTS public.rpc_store_product_heat(integer, integer, integer);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_store_product_heat(
  p_days     INTEGER DEFAULT 30,
  p_top      INTEGER DEFAULT 8,
  p_products INTEGER DEFAULT 12
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    -- 夾住上下界：p_days 直接被前端 querystring 帶進來，不夾會被一個 3650 拖垮首頁
    SELECT
      LEAST(GREATEST(COALESCE(p_days, 30), 1), 365)   AS days,
      LEAST(GREATEST(COALESCE(p_top, 8), 1), 20)      AS top_n,
      LEAST(GREATEST(COALESCE(p_products, 12), 1), 40) AS prod_n
  ),
  bounds AS (
    SELECT
      p.days, p.top_n, p.prod_n,
      ((date_trunc('day', (NOW() AT TIME ZONE 'Asia/Taipei'))
        - ((p.days - 1) * INTERVAL '1 day')) AT TIME ZONE 'Asia/Taipei') AS since
    FROM params p
  ),
  ord AS (
    SELECT o.id, o.pickup_store_id AS store_id, o.member_id
    FROM customer_orders o, bounds b
    WHERE o.created_at >= b.since
      AND o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.pickup_store_id IS NOT NULL
  ),
  li AS (
    SELECT
      o.store_id,
      o.id                            AS order_id,
      o.member_id,
      sk.product_id,
      i.qty::numeric                  AS qty,
      (i.qty * i.unit_price)::numeric AS amount
    FROM ord o
    JOIN customer_order_items i ON i.order_id = o.id
    JOIN skus sk               ON sk.id = i.sku_id
    WHERE i.status NOT IN ('cancelled', 'expired')
  ),
  store_agg AS (
    SELECT
      store_id,
      count(DISTINCT order_id)  AS orders,
      count(DISTINCT member_id) AS members,
      SUM(qty)::numeric         AS qty,
      SUM(amount)::numeric      AS amount
    FROM li
    GROUP BY store_id
  ),
  sp AS (
    SELECT
      store_id,
      product_id,
      count(DISTINCT order_id) AS orders,
      SUM(qty)::numeric        AS qty,
      SUM(amount)::numeric     AS amount
    FROM li
    GROUP BY store_id, product_id
  ),
  prod_agg AS (
    SELECT
      product_id,
      count(DISTINCT order_id) AS orders,
      count(DISTINCT store_id) AS store_count,
      SUM(qty)::numeric        AS qty,
      SUM(amount)::numeric     AS amount
    FROM li
    GROUP BY product_id
  ),
  prod_named AS (
    SELECT
      a.*,
      COALESCE(pr.name, (SELECT sk.product_name FROM skus sk
                          WHERE sk.product_id = a.product_id AND sk.product_name IS NOT NULL
                          LIMIT 1),
               '#' || a.product_id) AS name
    FROM prod_agg a
    LEFT JOIN products pr ON pr.id = a.product_id
  ),
  -- 全店排行榜取前 prod_n 名（依金額）；「這個商品在哪些店賣得好」只需要這幾檔的
  -- 逐店分佈，不必把 sp 全表送到前端
  top_products AS (
    SELECT pn.*
    FROM prod_named pn
    ORDER BY pn.amount DESC, pn.qty DESC, pn.product_id
    LIMIT (SELECT prod_n FROM bounds)
  ),
  -- 每家店自己的前 top_n 名商品
  store_top AS (
    SELECT sp.*, ROW_NUMBER() OVER (
             PARTITION BY sp.store_id ORDER BY sp.amount DESC, sp.qty DESC, sp.product_id
           ) AS rn
    FROM sp
  ),
  store_rows AS (
    SELECT
      s.id, s.code, s.name, s.is_active,
      s.latitude, s.longitude, s.address,
      COALESCE(a.orders, 0)             AS orders,
      COALESCE(a.members, 0)            AS members,
      COALESCE(a.qty, 0)::numeric       AS qty,
      COALESCE(a.amount, 0)::numeric    AS amount,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'id',     t.product_id,
                 'name',   COALESCE(pn.name, '#' || t.product_id),
                 'orders', t.orders,
                 'qty',    t.qty,
                 'amount', t.amount
               ) ORDER BY t.rn)
        FROM store_top t
        LEFT JOIN prod_named pn ON pn.product_id = t.product_id
        WHERE t.store_id = s.id AND t.rn <= (SELECT top_n FROM bounds)
      ), '[]'::jsonb)                   AS top
    FROM stores s
    LEFT JOIN store_agg a ON a.store_id = s.id
    WHERE s.deleted_at IS NULL
  ),
  product_rows AS (
    SELECT
      tp.product_id, tp.name, tp.orders, tp.store_count, tp.qty, tp.amount,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'store_id', x.store_id,
                 'orders',   x.orders,
                 'qty',      x.qty,
                 'amount',   x.amount
               ) ORDER BY x.amount DESC)
        FROM sp x
        WHERE x.product_id = tp.product_id
      ), '[]'::jsonb) AS by_store
    FROM top_products tp
  ),
  totals AS (
    SELECT
      count(DISTINCT order_id)               AS orders,
      count(DISTINCT member_id)              AS members,
      COALESCE(SUM(qty), 0)::numeric         AS qty,
      COALESCE(SUM(amount), 0)::numeric      AS amount
    FROM li
  )
  SELECT jsonb_build_object(
    'days',  (SELECT days FROM bounds),
    'since', (SELECT since FROM bounds),
    'totals', (SELECT to_jsonb(totals.*) FROM totals),
    'stores', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id',        r.id,
               'code',      r.code,
               'name',      r.name,
               'is_active', r.is_active,
               'address',   r.address,
               'lat',       r.latitude,
               'lng',       r.longitude,
               'orders',    r.orders,
               'members',   r.members,
               'qty',       r.qty,
               'amount',    r.amount,
               'top',       r.top
             ) ORDER BY r.amount DESC, r.name)
      FROM store_rows r), '[]'::jsonb),
    'products', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id',          p.product_id,
               'name',        p.name,
               'orders',      p.orders,
               'store_count', p.store_count,
               'qty',         p.qty,
               'amount',      p.amount,
               'by_store',    p.by_store
             ) ORDER BY p.amount DESC, p.qty DESC, p.product_id)
      FROM product_rows p), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_store_product_heat(integer, integer, integer) IS
  '首頁「門市 × 商品熱賣地圖」聚合：近 p_days 天（台北日界、以下單日計）'
  '各門市的單數/人數/件數/金額 + 該店 Top p_top 商品，以及全店 Top p_products '
  '商品與其逐店分佈。排除 cancelled/expired/transferred_out 訂單與 '
  'cancelled/expired 品項，口徑對齊 rpc_order_overview。'
  '回傳含所有未刪除門市（含零銷售、含未設座標者）。';

GRANT EXECUTE ON FUNCTION public.rpc_store_product_heat(integer, integer, integer) TO authenticated;
