-- ============================================================================
-- 2026-08-09: 四張「分析型」圖表的資料來源
--   1. rpc_member_cohorts          新客留存三角
--   2. rpc_member_rfm / _list      會員 RFM 分群（+ 分眾名單）
--   3. rpc_tag_penetration_trend   商品標籤滲透率趨勢
--   4. rpc_stockout_analysis       斷貨率分析
--
-- 共同口徑（與 rpc_region_tag_matrix / rpc_order_overview 一致）：
--   訂單排除 cancelled / expired / transferred_out
--   品項排除 cancelled / expired
--   會員排除 member_type='store_internal'（分店叫貨用的內部帳號）與 status='deleted'
-- 全部 SECURITY INVOKER（預設），RLS 套 caller。
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_member_cohorts(integer);
--   DROP FUNCTION IF EXISTS public.rpc_member_rfm(integer);
--   DROP FUNCTION IF EXISTS public.rpc_member_rfm_list(text, integer, integer);
--   DROP FUNCTION IF EXISTS public.rpc_tag_penetration_trend(integer);
--   DROP FUNCTION IF EXISTS public.rpc_stockout_analysis(integer);
--   DROP FUNCTION IF EXISTS public._rfm_segment(integer, integer);
-- ============================================================================

-- ============================================================================
-- 1. 新客留存三角
--    cohort = 該會員「第一次下單」的那一週（全歷史，不受 p_weeks 影響，
--    否則舊客會被誤判成新客）。格子 = 第 N 週有沒有再下單。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_member_cohorts(
  p_weeks INTEGER DEFAULT 12
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_weeks, 12), 4), 52) AS weeks
  ),
  vo AS (
    SELECT o.member_id,
           date_trunc('week', (o.created_at AT TIME ZONE 'Asia/Taipei'))::date AS wk
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')
  ),
  first_wk AS (
    SELECT member_id, min(wk) AS c0 FROM vo GROUP BY 1
  ),
  active AS (
    SELECT DISTINCT member_id, wk FROM vo
  ),
  -- 只顯示最近 p_weeks 個 cohort
  cohorts AS (
    SELECT f.c0, count(*) AS size
    FROM first_wk f, params p
    WHERE f.c0 >= (SELECT max(wk) FROM vo) - ((p.weeks - 1) * INTERVAL '1 week')
    GROUP BY 1
  ),
  cell AS (
    SELECT f.c0,
           ((a.wk - f.c0) / 7)::int AS offset_w,
           count(DISTINCT a.member_id) AS members
    FROM first_wk f
    JOIN cohorts ch ON ch.c0 = f.c0
    JOIN active a ON a.member_id = f.member_id AND a.wk >= f.c0
    GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'weeks',    (SELECT weeks FROM params),
    'max_week', (SELECT max(wk) FROM vo),
    'cohorts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'cohort', ch.c0,
               'size',   ch.size,
               'cells',  COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'offset', c.offset_w,
                          'members', c.members,
                          'pct', c.members::numeric / ch.size) ORDER BY c.offset_w)
                 FROM cell c WHERE c.c0 = ch.c0), '[]'::jsonb)
             ) ORDER BY ch.c0)
      FROM cohorts ch), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_member_cohorts(integer) IS
  '新客留存三角：cohort = 首次下單的那一週（全歷史認定），格子 = 第 N 週是否再下單。';

GRANT EXECUTE ON FUNCTION public.rpc_member_cohorts(integer) TO authenticated;

-- ============================================================================
-- 2. RFM 分群
--    分群規則只寫在這一支函式裡，rpc_member_rfm 與 rpc_member_rfm_list 共用，
--    免得兩邊各改一次就對不起來。
--    R/F/M 各自用五分位（ntile）；R 反轉（最近下單 = 5 分）。
-- ============================================================================
CREATE OR REPLACE FUNCTION public._rfm_segment(p_r INTEGER, p_f INTEGER)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_r >= 4 AND p_f >= 4 THEN '冠軍'        -- 最近買、買很多
    WHEN p_r >= 3 AND p_f >= 4 THEN '忠實'        -- 買很多，最近稍微淡一點
    WHEN p_r >= 4 AND p_f <= 2 THEN '新客潛力'    -- 剛來，次數還少
    WHEN p_r <= 2 AND p_f >= 4 THEN '需喚回'      -- 以前是大戶，最近不見了
    WHEN p_r <= 2 AND p_f <= 2 THEN '沉睡'
    ELSE '一般'
  END;
$$;
COMMENT ON FUNCTION public._rfm_segment(integer, integer) IS
  'RFM 分群規則的唯一來源（rpc_member_rfm 與 rpc_member_rfm_list 共用）';

CREATE OR REPLACE FUNCTION public.rpc_member_rfm(
  p_days INTEGER DEFAULT 90
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 90), 14), 365) AS days
  ),
  vo AS (
    SELECT o.id, o.member_id, o.created_at
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN params p
    WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.created_at >= NOW() - (p.days * INTERVAL '1 day')
  ),
  amt AS (
    SELECT v.member_id, SUM(i.qty * i.unit_price)::numeric AS amount
    FROM vo v
    JOIN customer_order_items i ON i.order_id = v.id AND i.status NOT IN ('cancelled', 'expired')
    GROUP BY 1
  ),
  base AS (
    SELECT v.member_id,
           (NOW()::date - max(v.created_at)::date) AS r_days,
           count(*)                                AS f_orders,
           COALESCE(max(a.amount), 0)              AS m_amount
    FROM vo v LEFT JOIN amt a ON a.member_id = v.member_id
    GROUP BY v.member_id
  ),
  scored AS (
    SELECT b.*,
           -- R 反轉：r_days 越小越近 → 分數越高
           6 - ntile(5) OVER (ORDER BY b.r_days)   AS r,
           ntile(5) OVER (ORDER BY b.f_orders)     AS f,
           ntile(5) OVER (ORDER BY b.m_amount)     AS m
    FROM base b
  ),
  seg AS (
    SELECT s.*, public._rfm_segment(s.r, s.f) AS segment FROM scored s
  )
  SELECT jsonb_build_object(
    'days',    (SELECT days FROM params),
    'members', (SELECT count(*) FROM seg),
    'amount',  (SELECT COALESCE(SUM(m_amount), 0) FROM seg),
    'segments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'segment',  segment,
               'members',  n,
               'avg_r',    avg_r,
               'avg_f',    avg_f,
               'avg_m',    avg_m,
               'amount',   amount
             ) ORDER BY amount DESC)
      FROM (
        SELECT segment, count(*) AS n,
               round(avg(r_days), 1)   AS avg_r,
               round(avg(f_orders), 1) AS avg_f,
               round(avg(m_amount))    AS avg_m,
               SUM(m_amount)           AS amount
        FROM seg GROUP BY segment) z), '[]'::jsonb),
    -- R×F 的 5×5 網格，前端畫九宮格／散點用
    'grid', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('r', r, 'f', f, 'members', n, 'amount', amount))
      FROM (SELECT r, f, count(*) AS n, SUM(m_amount) AS amount FROM seg GROUP BY 1,2) z
    ), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_member_rfm(integer) IS
  '會員 RFM 分群：R=距今天數、F=訂單數、M=金額，各取五分位（R 反轉）。'
  '分群規則見 _rfm_segment。回傳各群人數/金額與 R×F 5×5 網格。';

GRANT EXECUTE ON FUNCTION public.rpc_member_rfm(integer) TO authenticated;

-- 分眾名單（給 LINE 推播用）。與 rpc_member_rfm 同一套計分，只是最後篩一個群。
CREATE OR REPLACE FUNCTION public.rpc_member_rfm_list(
  p_segment TEXT,
  p_days    INTEGER DEFAULT 90,
  p_limit   INTEGER DEFAULT 500
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 90), 14), 365) AS days,
           LEAST(GREATEST(COALESCE(p_limit, 500), 1), 5000) AS lim
  ),
  vo AS (
    SELECT o.id, o.member_id, o.created_at, o.pickup_store_id
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN params p
    WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.created_at >= NOW() - (p.days * INTERVAL '1 day')
  ),
  amt AS (
    SELECT v.member_id, SUM(i.qty * i.unit_price)::numeric AS amount
    FROM vo v
    JOIN customer_order_items i ON i.order_id = v.id AND i.status NOT IN ('cancelled', 'expired')
    GROUP BY 1
  ),
  base AS (
    SELECT v.member_id,
           (NOW()::date - max(v.created_at)::date) AS r_days,
           count(*)                                AS f_orders,
           COALESCE(max(a.amount), 0)              AS m_amount,
           mode() WITHIN GROUP (ORDER BY v.pickup_store_id) AS store_id
    FROM vo v LEFT JOIN amt a ON a.member_id = v.member_id
    GROUP BY v.member_id
  ),
  seg AS (
    SELECT b.*,
           public._rfm_segment(
             6 - ntile(5) OVER (ORDER BY b.r_days),
             ntile(5) OVER (ORDER BY b.f_orders)
           ) AS segment
    FROM base b
  )
  SELECT jsonb_build_object(
    'segment', p_segment,
    'total',   (SELECT count(*) FROM seg WHERE segment = p_segment),
    'members', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', s.member_id, 'member_no', m.member_no, 'name', m.name,
               'phone', m.phone, 'store', st.name,
               'r_days', s.r_days, 'orders', s.f_orders, 'amount', s.m_amount,
               'has_line', (m.line_user_id IS NOT NULL))
             ORDER BY s.m_amount DESC)
      FROM (SELECT * FROM seg WHERE segment = p_segment
             ORDER BY m_amount DESC LIMIT (SELECT lim FROM params)) s
      JOIN members m ON m.id = s.member_id
      LEFT JOIN stores st ON st.id = s.store_id), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_member_rfm_list(text, integer, integer) IS
  '取某個 RFM 分群的會員名單（依金額排序），給 LINE 分眾推播用。計分與 rpc_member_rfm 完全一致。';

GRANT EXECUTE ON FUNCTION public.rpc_member_rfm_list(text, integer, integer) TO authenticated;

-- ============================================================================
-- 3. 標籤滲透率趨勢
--    每一週：買過該標籤的會員數 ÷ 該週下單會員數。
--    ⚠ 一個商品可以有多個標籤，各標籤的滲透率不會加總成 100%，別畫成堆疊面積圖。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_tag_penetration_trend(
  p_weeks INTEGER DEFAULT 12
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_weeks, 12), 4), 52) AS weeks
  ),
  vo AS (
    SELECT o.id, o.member_id,
           date_trunc('week', (o.created_at AT TIME ZONE 'Asia/Taipei'))::date AS wk
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN params p
    WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.created_at >= NOW() - (p.weeks * INTERVAL '1 week')
  ),
  wk_base AS (
    SELECT wk, count(DISTINCT member_id) AS buyers FROM vo GROUP BY 1
  ),
  hits AS (
    SELECT DISTINCT v.wk, v.member_id, tm.tag_id
    FROM vo v
    JOIN customer_order_items i ON i.order_id = v.id AND i.status NOT IN ('cancelled', 'expired')
    JOIN skus sk ON sk.id = i.sku_id
    JOIN product_tag_map tm ON tm.product_id = sk.product_id
  ),
  cell AS (
    SELECT wk, tag_id, count(*) AS buyers FROM hits GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'weeks', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('wk', wk, 'buyers', buyers) ORDER BY wk)
      FROM wk_base), '[]'::jsonb),
    'tags', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'group', t.tag_group,
                                          'buyers', x.buyers) ORDER BY x.buyers DESC)
      FROM (SELECT tag_id, count(DISTINCT member_id) AS buyers FROM hits GROUP BY 1) x
      JOIN product_tags t ON t.id = x.tag_id), '[]'::jsonb),
    'cells', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'wk', c.wk, 'tag_id', c.tag_id, 'buyers', c.buyers,
               'pen', c.buyers::numeric / b.buyers))
      FROM cell c JOIN wk_base b ON b.wk = c.wk AND b.buyers > 0), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_tag_penetration_trend(integer) IS
  '商品標籤滲透率的逐週走勢（買過該標籤的會員數 ÷ 該週下單會員數）。'
  '多標籤 → 各標籤滲透率不會加總成 100%，不要畫堆疊圖。';

GRANT EXECUTE ON FUNCTION public.rpc_tag_penetration_trend(integer) TO authenticated;

-- ============================================================================
-- 4. 斷貨率分析
--    斷貨的定義：customer_order_items.stockout_at IS NOT NULL
--    （斷貨走 status='cancelled' + stockout_at，不另開 status 值，見 20260702020000）
--    分母是「該期間所有品項」，含已斷貨的那些。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_stockout_analysis(
  p_days INTEGER DEFAULT 90
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 90), 7), 365) AS days
  ),
  it AS (
    SELECT i.id, i.stockout_at IS NOT NULL AS is_out,
           o.pickup_store_id AS store_id,
           sk.product_id,
           date_trunc('week', (o.created_at AT TIME ZONE 'Asia/Taipei'))::date AS wk,
           (i.qty * i.unit_price)::numeric AS amount
    FROM customer_order_items i
    JOIN customer_orders o ON o.id = i.order_id
    JOIN skus sk ON sk.id = i.sku_id
    CROSS JOIN params p
    WHERE o.created_at >= NOW() - (p.days * INTERVAL '1 day')
      AND o.status NOT IN ('expired', 'transferred_out')
  )
  SELECT jsonb_build_object(
    'days',      (SELECT days FROM params),
    'items',     (SELECT count(*) FROM it),
    'stockouts', (SELECT count(*) FILTER (WHERE is_out) FROM it),
    'lost_amount', (SELECT COALESCE(SUM(amount) FILTER (WHERE is_out), 0) FROM it),
    'by_week', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('wk', wk, 'items', n, 'stockouts', out_n,
                                          'rate', out_n::numeric / NULLIF(n, 0)) ORDER BY wk)
      FROM (SELECT wk, count(*) AS n, count(*) FILTER (WHERE is_out) AS out_n
              FROM it GROUP BY 1) z), '[]'::jsonb),
    'by_store', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('store_id', z.store_id, 'name', s.name,
                                          'items', z.n, 'stockouts', z.out_n,
                                          'rate', z.out_n::numeric / NULLIF(z.n, 0))
                       ORDER BY z.out_n::numeric / NULLIF(z.n, 0) DESC NULLS LAST)
      FROM (SELECT store_id, count(*) AS n, count(*) FILTER (WHERE is_out) AS out_n
              FROM it WHERE store_id IS NOT NULL GROUP BY 1) z
      JOIN stores s ON s.id = z.store_id), '[]'::jsonb),
    -- 常常開了團卻拿不到貨的商品；樣本 < 20 的不列（比例會亂跳）
    'top_products', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', z.product_id, 'name', COALESCE(pr.name, '#' || z.product_id),
                                          'items', z.n, 'stockouts', z.out_n,
                                          'rate', z.out_n::numeric / z.n,
                                          'lost_amount', z.lost)
                       ORDER BY z.out_n::numeric / z.n DESC, z.out_n DESC)
      FROM (SELECT product_id, count(*) AS n, count(*) FILTER (WHERE is_out) AS out_n,
                   COALESCE(SUM(amount) FILTER (WHERE is_out), 0) AS lost
              FROM it GROUP BY 1 HAVING count(*) >= 20 AND count(*) FILTER (WHERE is_out) > 0
             ORDER BY count(*) FILTER (WHERE is_out)::numeric / count(*) DESC LIMIT 25) z
      LEFT JOIN products pr ON pr.id = z.product_id), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_stockout_analysis(integer) IS
  '斷貨率分析：stockout_at IS NOT NULL 的品項比例，含逐週趨勢、各店、以及斷貨率最高的商品'
  '（樣本 < 20 的商品不列）。lost_amount = 斷掉的那些品項的金額，是實際少收的錢。';

GRANT EXECUTE ON FUNCTION public.rpc_stockout_analysis(integer) TO authenticated;
