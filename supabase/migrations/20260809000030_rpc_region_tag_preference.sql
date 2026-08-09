-- ============================================================================
-- 2026-08-09: 地區（門市）× 商品標籤 的偏好分析
--
-- 需求：老闆要找出「各地區的喜好商品」。關鍵字是**偏好**不是**業績** ——
--   所以一律用「買過的人數比例」，不能用金額或件數的絕對值：
--     中和店活躍會員 563 人、湖口店 84 人，看絕對值永遠是中和贏，
--     問不出「湖口的人特別愛什麼」。
--
-- 三個數字（每個 門市 × 標籤 的格子）：
--   pen（滲透率）  = 該店買過此標籤的會員數 ÷ 該店當期下單會員數
--   base（大盤）   = 全店買過此標籤的會員數 ÷ 全店當期下單會員數
--   lift（偏好指數）= pen ÷ base
--       1.0 = 跟大盤一樣；1.4 = 這一區特別愛（多 40%）；0.6 = 特別冷淡
--   lift 才是「偏好」，pen 只是「有多少人買」—— 兩個都回，UI 兩個都要顯示，
--   因為 lift 高但 pen 只有 2% 的格子沒有經營意義。
--
-- ⚠ 為什麼還要 lift_adj（校正偏好指數）：
--   客單品類數高的店（實測：松山店 179 位買家，幾乎每個標籤的 lift 都 > 1.3）
--   會在原始 lift 排行榜上洗版 —— 那不是「偏好海鮮」，是「什麼都買」。
--     breadth（廣度）= 該店所有標籤的 Σ實際人數 ÷ Σ期望人數
--                    = 這家店平均而言每個類別買到大盤的幾倍
--     lift_adj       = lift ÷ breadth
--   扣掉「這家店本來就買比較多」之後還突出的，才是真正的地區偏好。
--   兩個都回：UI 預設用 lift_adj 排序，原始 lift 仍要看得到。
--
-- 分母的定義（刻意寫死，兩支 RPC 一致）：
--   「該店當期下單會員數」＝ 期間內在該店取貨、且訂單不是 cancelled/expired/
--   transferred_out 的不重複 member_id，排除 member_type='store_internal'
--   （分店叫貨用的內部帳號，線上 19 筆，混進來會污染小店的比例）。
--   同一個人在兩家店都下單 → 兩家店各算一次，這是刻意的：問的是「這家店的
--   客群偏好」，不是把人指派給單一店。
--
-- 品項口徑與 rpc_order_overview / rpc_store_product_heat 一致：
--   排除 cancelled/expired 品項（斷貨的貨客人根本沒拿到，不算偏好）。
--
-- 標籤來源：product_tag_map（見 20260809000020）。一個商品多個標籤 →
--   同一張訂單可能同時算進「海鮮」和「冷凍」，這是多標籤的預期行為，
--   各標籤的滲透率**不會**加總成 100%，UI 不要拿它們做圓餅圖。
--
-- SECURITY INVOKER（預設）：RLS 套用 caller。
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_region_tag_matrix(integer);
--   DROP FUNCTION IF EXISTS public.rpc_region_tag_products(bigint, bigint, integer, integer);
-- ============================================================================

-- ============================================================================
-- 1. 矩陣：門市 × 標籤
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_region_tag_matrix(
  p_days INTEGER DEFAULT 90
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH bounds AS (
    SELECT
      LEAST(GREATEST(COALESCE(p_days, 90), 7), 365) AS days,
      ((date_trunc('day', (NOW() AT TIME ZONE 'Asia/Taipei'))
        - ((LEAST(GREATEST(COALESCE(p_days, 90), 7), 365) - 1) * INTERVAL '1 day'))
       AT TIME ZONE 'Asia/Taipei') AS since
  ),
  -- 期間內的有效訂單（會員層級；內部帳號排除）
  ord AS (
    SELECT o.id, o.pickup_store_id AS store_id, o.member_id
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN bounds b
    WHERE o.created_at >= b.since
      AND o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.pickup_store_id IS NOT NULL
  ),
  -- 分母：每店的下單會員數 / 全店的下單會員數
  store_base AS (
    SELECT store_id, count(DISTINCT member_id) AS buyers
    FROM ord GROUP BY store_id
  ),
  all_base AS (
    SELECT count(DISTINCT member_id) AS buyers FROM ord
  ),
  -- 會員 × 門市 × 標籤（去重後才數人頭）
  hits AS (
    SELECT DISTINCT o.store_id, o.member_id, m.tag_id
    FROM ord o
    JOIN customer_order_items i ON i.order_id = o.id
                               AND i.status NOT IN ('cancelled', 'expired')
    JOIN skus sk            ON sk.id = i.sku_id
    JOIN product_tag_map m  ON m.product_id = sk.product_id
  ),
  cell AS (
    SELECT store_id, tag_id, count(*) AS buyers   -- hits 已 DISTINCT，count(*) = 人數
    FROM hits GROUP BY store_id, tag_id
  ),
  tag_all AS (
    SELECT tag_id, count(DISTINCT member_id) AS buyers
    FROM hits GROUP BY tag_id
  ),
  -- 每店的「廣度」：Σ實際人數 ÷ Σ期望人數（期望 = 店買家數 × 該標籤大盤滲透率）
  store_breadth AS (
    SELECT c.store_id,
           SUM(c.buyers)::numeric
             / NULLIF(SUM(sb.buyers::numeric * ta.buyers / NULLIF((SELECT buyers FROM all_base), 0)), 0)
             AS breadth
    FROM cell c
    JOIN store_base sb ON sb.store_id = c.store_id
    JOIN tag_all ta    ON ta.tag_id   = c.tag_id
    GROUP BY c.store_id
  )
  SELECT jsonb_build_object(
    'days',  (SELECT days FROM bounds),
    'since', (SELECT since FROM bounds),
    'total_buyers', (SELECT buyers FROM all_base),
    'stores', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', s.id, 'code', s.code, 'name', s.name,
               'is_active', s.is_active, 'address', s.address,
               'buyers', sb.buyers,
               'breadth', bd.breadth
             ) ORDER BY sb.buyers DESC, s.name)
      FROM store_base sb
      JOIN stores s ON s.id = sb.store_id
      LEFT JOIN store_breadth bd ON bd.store_id = sb.store_id
      WHERE s.deleted_at IS NULL), '[]'::jsonb),
    'tags', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', t.id, 'code', t.code, 'name', t.name, 'group', t.tag_group,
               'buyers', COALESCE(ta.buyers, 0),
               'base', CASE WHEN (SELECT buyers FROM all_base) > 0
                            THEN COALESCE(ta.buyers, 0)::numeric / (SELECT buyers FROM all_base)
                            ELSE 0 END
             ) ORDER BY COALESCE(ta.buyers, 0) DESC, t.sort)
      FROM product_tags t
      LEFT JOIN tag_all ta ON ta.tag_id = t.id
      WHERE t.is_active AND COALESCE(ta.buyers, 0) > 0), '[]'::jsonb),
    'cells', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'store_id', c.store_id,
               'tag_id',   c.tag_id,
               'buyers',   c.buyers,
               'pen',      c.buyers::numeric / sb.buyers,
               'lift',     CASE
                             WHEN ta.buyers > 0 AND (SELECT buyers FROM all_base) > 0
                               THEN (c.buyers::numeric / sb.buyers)
                                    / (ta.buyers::numeric / (SELECT buyers FROM all_base))
                             ELSE NULL
                           END,
               'lift_adj', CASE
                             WHEN ta.buyers > 0 AND (SELECT buyers FROM all_base) > 0
                                  AND COALESCE(bd.breadth, 0) > 0
                               THEN ((c.buyers::numeric / sb.buyers)
                                    / (ta.buyers::numeric / (SELECT buyers FROM all_base)))
                                    / bd.breadth
                             ELSE NULL
                           END
             ))
      FROM cell c
      JOIN store_base sb ON sb.store_id = c.store_id AND sb.buyers > 0
      JOIN tag_all ta    ON ta.tag_id   = c.tag_id
      LEFT JOIN store_breadth bd ON bd.store_id = c.store_id), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_region_tag_matrix(integer) IS
  '地區（門市）× 商品標籤 偏好矩陣。pen=該店買過此標籤的會員比例、'
  'base=全店比例、lift=pen/base（>1 表示這一區特別偏好）。'
  '一律以「人數」為單位，不用金額/件數；分母排除 store_internal 會員。';

GRANT EXECUTE ON FUNCTION public.rpc_region_tag_matrix(integer) TO authenticated;

-- ============================================================================
-- 2. 下鑽：某店（或全店）某標籤（或全部）底下，哪些商品在這一區特別受歡迎
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_region_tag_products(
  p_store_id BIGINT  DEFAULT NULL,
  p_tag_id   BIGINT  DEFAULT NULL,
  p_days     INTEGER DEFAULT 90,
  p_limit    INTEGER DEFAULT 20
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH bounds AS (
    SELECT
      ((date_trunc('day', (NOW() AT TIME ZONE 'Asia/Taipei'))
        - ((LEAST(GREATEST(COALESCE(p_days, 90), 7), 365) - 1) * INTERVAL '1 day'))
       AT TIME ZONE 'Asia/Taipei') AS since,
      LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100) AS lim
  ),
  ord AS (
    SELECT o.id, o.pickup_store_id AS store_id, o.member_id
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN bounds b
    WHERE o.created_at >= b.since
      AND o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.pickup_store_id IS NOT NULL
  ),
  -- 會員 × 門市 × 商品（去重；金額/件數另外從品項加總）
  hits AS (
    SELECT o.store_id, o.member_id, sk.product_id,
           i.qty::numeric AS qty, (i.qty * i.unit_price)::numeric AS amount
    FROM ord o
    JOIN customer_order_items i ON i.order_id = o.id
                               AND i.status NOT IN ('cancelled', 'expired')
    JOIN skus sk ON sk.id = i.sku_id
    WHERE p_tag_id IS NULL OR EXISTS (
      SELECT 1 FROM product_tag_map m
       WHERE m.product_id = sk.product_id AND m.tag_id = p_tag_id)
  ),
  store_base AS (
    SELECT count(DISTINCT member_id) AS buyers FROM ord
     WHERE p_store_id IS NULL OR store_id = p_store_id
  ),
  all_base AS (
    SELECT count(DISTINCT member_id) AS buyers FROM ord
  ),
  here AS (
    SELECT product_id,
           count(DISTINCT member_id) AS buyers,
           SUM(qty)                  AS qty,
           SUM(amount)               AS amount
    FROM hits
    WHERE p_store_id IS NULL OR store_id = p_store_id
    GROUP BY product_id
  ),
  everywhere AS (
    SELECT product_id, count(DISTINCT member_id) AS buyers
    FROM hits GROUP BY product_id
  ),
  -- 與 matrix 同一套「廣度」校正：這家店本來就買比較多品項的效應要扣掉
  breadth AS (
    SELECT SUM(h.buyers)::numeric
             / NULLIF(SUM(e.buyers::numeric
                          * (SELECT buyers FROM store_base) / NULLIF((SELECT buyers FROM all_base), 0)), 0)
             AS v
    FROM here h JOIN everywhere e ON e.product_id = h.product_id
  )
  SELECT jsonb_build_object(
    'store_buyers', (SELECT buyers FROM store_base),
    'total_buyers', (SELECT buyers FROM all_base),
    'breadth',      (SELECT v FROM breadth),
    'products', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x ->> 'lift_adj')::numeric DESC NULLS LAST,
                                  (x ->> 'buyers')::int DESC)
      FROM (
        SELECT jsonb_build_object(
                 'id',     h.product_id,
                 'name',   COALESCE(pr.name, '#' || h.product_id),
                 'buyers', h.buyers,
                 'qty',    h.qty,
                 'amount', h.amount,
                 'pen',    h.buyers::numeric / NULLIF((SELECT buyers FROM store_base), 0),
                 'base',   e.buyers::numeric / NULLIF((SELECT buyers FROM all_base), 0),
                 'lift',   CASE
                             WHEN e.buyers > 0 AND (SELECT buyers FROM all_base) > 0
                                  AND (SELECT buyers FROM store_base) > 0
                               THEN (h.buyers::numeric / (SELECT buyers FROM store_base))
                                    / (e.buyers::numeric / (SELECT buyers FROM all_base))
                             ELSE NULL
                           END,
                 'lift_adj', CASE
                             WHEN e.buyers > 0 AND (SELECT buyers FROM all_base) > 0
                                  AND (SELECT buyers FROM store_base) > 0
                                  AND COALESCE((SELECT v FROM breadth), 0) > 0
                               THEN ((h.buyers::numeric / (SELECT buyers FROM store_base))
                                    / (e.buyers::numeric / (SELECT buyers FROM all_base)))
                                    / (SELECT v FROM breadth)
                             ELSE NULL
                           END,
                 'tags',   COALESCE((
                             SELECT jsonb_agg(t.name ORDER BY t.sort)
                             FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                             WHERE m.product_id = h.product_id), '[]'::jsonb)
               ) AS x
        FROM here h
        JOIN everywhere e ON e.product_id = h.product_id
        LEFT JOIN products pr ON pr.id = h.product_id
        -- 樣本太小的商品 lift 會亂跳，兩道門檻都要過（實測不擋的話，整頁都是
        -- 「4 個人買過、指數 3.7」的冷門品，看不到真正的地區特色）：
        --   本店至少 5 人且達該店買家數的 3%（大店門檻自動變高）
        --   全店至少 8 人（分母太小的話 base 本身就不可信）
        WHERE h.buyers >= GREATEST(5, ceil((SELECT buyers FROM store_base) * 0.03))
          AND e.buyers >= 8
        ORDER BY (CASE
                    WHEN e.buyers > 0 THEN (h.buyers::numeric / GREATEST((SELECT buyers FROM store_base), 1))
                                           / (e.buyers::numeric / GREATEST((SELECT buyers FROM all_base), 1))
                    ELSE 0 END) DESC,
                 h.buyers DESC
        LIMIT (SELECT lim FROM bounds)
      ) s), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_region_tag_products(bigint, bigint, integer, integer) IS
  '地區偏好下鑽：某店（p_store_id，NULL=全店）某標籤（p_tag_id，NULL=全部）底下'
  '偏好指數最高的商品。lift=該店滲透率/全店滲透率、lift_adj=lift/該店廣度'
  '（扣掉「這家店什麼都買比較多」的效應）。樣本門檻：本店買家 >= max(5, 該店買家數×3%) '
  '且全店買家 >= 8，否則 lift 會被冷門品洗版。';

GRANT EXECUTE ON FUNCTION public.rpc_region_tag_products(bigint, bigint, integer, integer) TO authenticated;
