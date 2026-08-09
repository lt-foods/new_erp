-- ============================================================================
-- 2026-08-09: 三張「操作型」圖表的資料來源
--   1. rpc_pickup_aging        未取貨貨齡（放在取貨頁）
--   2. rpc_campaign_pace       開團早期訊號（放在開團頁）
--   3. rpc_order_hour_heatmap  下單時段熱力圖 7×24
--
-- 為什麼這三張排最前面：查線上資料時它們就已經在指問題了 ——
--   ・16,569 張「可取貨」還沒被取走，其中 2,747 張放超過 36 天、最久 66 天
--   ・開團後 6/12/24 小時的累積訂單，對最終總量的相關係數是 0.64/0.75/0.81，
--     遠高於開團前的預測（ρ=0.36）→ 冷團當晚就救得回來
--   ・下單高峰極度集中在 22–23 點，週一 22:00 是全週最大單一時段
--
-- 口徑一律沿用既有慣例：排除 cancelled/expired/transferred_out 訂單、
-- cancelled/expired 品項、member_type='store_internal' 的內部帳號。
-- 三支都是 SECURITY INVOKER（預設），RLS 套 caller。
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_pickup_aging(bigint);
--   DROP FUNCTION IF EXISTS public.rpc_campaign_pace(integer, integer);
--   DROP FUNCTION IF EXISTS public.rpc_order_hour_heatmap(integer, bigint);
-- ============================================================================

-- ============================================================================
-- 1. 未取貨貨齡
--    只看 ready / partially_completed —— 這兩個狀態代表「貨已經到店在等人」。
--    confirmed / shipping 是還沒到貨，催也沒用。
--    貨齡起算點 ready_at；線上 99.8% 的 ready 單有值，缺的退回 updated_at
--    （與 v_admin_orders 的 event_at 同一套 fallback 邏輯）。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_pickup_aging(
  p_store_id BIGINT DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH waiting AS (
    SELECT o.id, o.order_no, o.pickup_store_id AS store_id, o.member_id,
           o.nickname_snapshot, o.pickup_deadline,
           GREATEST(0, (NOW()::date - COALESCE(o.ready_at, o.updated_at)::date)) AS age_days
    FROM customer_orders o
    WHERE o.status IN ('ready', 'partially_completed')
      AND (p_store_id IS NULL OR o.pickup_store_id = p_store_id)
  ),
  bucketed AS (
    SELECT w.*,
           CASE
             WHEN age_days <= 3  THEN '0-3'
             WHEN age_days <= 7  THEN '4-7'
             WHEN age_days <= 14 THEN '8-14'
             WHEN age_days <= 30 THEN '15-30'
             ELSE '31+'
           END AS bucket
    FROM waiting w
  )
  SELECT jsonb_build_object(
    'total',      (SELECT count(*) FROM waiting),
    'over_30',    (SELECT count(*) FROM waiting WHERE age_days > 30),
    'oldest_days',(SELECT COALESCE(max(age_days), 0) FROM waiting),
    -- 分桶總計（前端畫堆疊柱狀的 x 軸順序就用這個陣列的順序）
    'buckets', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('bucket', b.bucket, 'orders', COALESCE(c.n, 0))
                       ORDER BY b.sort)
      FROM (VALUES ('0-3',1),('4-7',2),('8-14',3),('15-30',4),('31+',5)) AS b(bucket, sort)
      LEFT JOIN (SELECT bucket, count(*) AS n FROM bucketed GROUP BY 1) c ON c.bucket = b.bucket
    ), '[]'::jsonb),
    -- 每家店各分桶幾張，堆疊柱狀一根＝一家店
    'stores', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'store_id', s.id, 'name', s.name,
               'total',    x.total,
               'over_30',  x.over_30,
               'by_bucket', x.by_bucket
             ) ORDER BY x.over_30 DESC, x.total DESC)
      FROM (
        SELECT b.store_id,
               count(*)                                   AS total,
               count(*) FILTER (WHERE b.age_days > 30)     AS over_30,
               (SELECT jsonb_object_agg(z.bucket, z.n)
                  FROM (SELECT b2.bucket, count(*) AS n FROM bucketed b2
                         WHERE b2.store_id = b.store_id GROUP BY 1) z) AS by_bucket
        FROM bucketed b
        GROUP BY b.store_id
      ) x
      JOIN stores s ON s.id = x.store_id
    ), '[]'::jsonb),
    -- 最該打電話的那批：放最久的 50 張
    'oldest', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', b.id, 'order_no', b.order_no, 'store_id', b.store_id,
               'store', s.name, 'member_id', b.member_id,
               'nickname', b.nickname_snapshot, 'age_days', b.age_days,
               'deadline', b.pickup_deadline) ORDER BY b.age_days DESC, b.id)
      FROM (SELECT * FROM bucketed ORDER BY age_days DESC, id LIMIT 50) b
      LEFT JOIN stores s ON s.id = b.store_id
    ), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_pickup_aging(bigint) IS
  '未取貨貨齡：ready / partially_completed 訂單依 ready_at 起算的放置天數分桶（0-3/4-7/8-14/15-30/31+），'
  '含各店分佈與放最久的 50 張。貨已到店在等人才算，confirmed/shipping 不列入。';

GRANT EXECUTE ON FUNCTION public.rpc_pickup_aging(bigint) TO authenticated;

-- ============================================================================
-- 2. 開團早期訊號
--    做法：先用歷史「已經跑完」的團建一條基準曲線 —— 開團後第 h 小時，
--    通常已經累積了最終訂單數的百分之幾（取中位數）。
--    然後把進行中的團套上去：目前 h 小時、累積 n 單 → 推估最終 n / share(h)。
--
--    t0 定義成「該團第一張訂單的時間」而不是 start_at：線上 start_at 常常是
--    空的或跟實際開賣差很遠，用第一張單反而穩定。
--    代價是「一張單都沒有的團」算不出 t0 —— 那種團本來就要另外看（見前端）。
--
--    ⚠ 這條曲線是「同一批歷史團的平均行為」，不分品類。之後有 Phase 2 的曝光
--      資料再細分才有意義，現在細分只會讓每格樣本數不足。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_campaign_pace(
  p_days      INTEGER DEFAULT 7,    -- 只看最近幾天開始的團
  p_hist_days INTEGER DEFAULT 90    -- 基準曲線取樣範圍
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 7), 1), 30)         AS days,
           LEAST(GREATEST(COALESCE(p_hist_days, 90), 30), 365) AS hist_days
  ),
  vo AS (
    SELECT o.campaign_id, o.created_at
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN params p
    WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND o.campaign_id IS NOT NULL
      AND o.created_at >= NOW() - ((p.hist_days + 30) * INTERVAL '1 day')
  ),
  -- 每團的 t0 與總量。用 GROUP BY 不用 window：第一版用 min() OVER 掃全表，
  -- 之後每個 CTE 都得帶著 64k 列跑，整支 6 秒起跳。
  camp AS (
    SELECT campaign_id, min(created_at) AS t0, count(*) AS total FROM vo GROUP BY 1
  ),
  -- 基準曲線只取「開超過 7 天、算是跑完」且有一定量的歷史團
  hist_camp AS (
    SELECT c.* FROM camp c, params p
    WHERE c.t0 <  NOW() - INTERVAL '7 days'
      AND c.t0 >= NOW() - (p.hist_days * INTERVAL '1 day')
      AND c.total >= 5
  ),
  hist_hour AS (
    SELECT v.campaign_id,
           floor(EXTRACT(EPOCH FROM (v.created_at - c.t0)) / 3600)::int AS h,
           count(*) AS n
    FROM vo v JOIN hist_camp c ON c.campaign_id = v.campaign_id
    WHERE v.created_at < c.t0 + INTERVAL '168 hours'
    GROUP BY 1, 2
  ),
  -- 每團補滿 0~168 小時的格子再累加。
  -- ⚠ 不補格子的話，第 h 小時的中位數只會由「剛好那一小時有訂單」的團組成，
  --   冷團被整排跳過 → 曲線系統性偏高，推估出來的最終量就偏低。
  grid AS (
    SELECT c.campaign_id, g.h, COALESCE(hh.n, 0) AS n, c.total
    FROM hist_camp c
    CROSS JOIN generate_series(0, 168) AS g(h)
    LEFT JOIN hist_hour hh ON hh.campaign_id = c.campaign_id AND hh.h = g.h
  ),
  hist_share AS (
    SELECT campaign_id, h,
           (sum(n) OVER (PARTITION BY campaign_id ORDER BY h))::numeric / total AS share
    FROM grid
  ),
  curve AS (
    SELECT h, percentile_cont(0.5) WITHIN GROUP (ORDER BY share) AS med_share, count(*) AS n
    FROM hist_share GROUP BY h
  ),
  live AS (
    SELECT c.campaign_id, c.t0, c.total AS orders_now,
           floor(EXTRACT(EPOCH FROM (NOW() - c.t0)) / 3600)::int AS elapsed_h
    FROM camp c, params p
    WHERE c.t0 >= NOW() - (p.days * INTERVAL '1 day')
  ),
  scored AS (
    SELECT l.*, cu.med_share,
           CASE WHEN COALESCE(cu.med_share, 0) > 0.02
                THEN round(l.orders_now / cu.med_share)
                ELSE NULL END AS projected
    FROM live l
    -- 超過 168 小時就用最後一格（曲線到那邊已經接近 1）
    LEFT JOIN curve cu ON cu.h = LEAST(l.elapsed_h, 168)
  ),
  bench AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) AS median_total FROM hist_camp
  )
  SELECT jsonb_build_object(
    'median_total', (SELECT median_total FROM bench),
    'hist_campaigns', (SELECT count(*) FROM hist_camp),
    'curve', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('h', h, 'share', med_share, 'n', n) ORDER BY h)
      FROM curve), '[]'::jsonb),
    'campaigns', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', s.campaign_id,
               'name', c.name,
               'campaign_no', c.campaign_no,
               'status', c.status,
               't0', s.t0,
               'elapsed_h', s.elapsed_h,
               'orders_now', s.orders_now,
               'med_share', s.med_share,
               'projected', s.projected,
               -- 相對於歷史中位數的倍數；< 0.6 就是該補推的冷團
               'vs_median', CASE WHEN (SELECT median_total FROM bench) > 0 AND s.projected IS NOT NULL
                                 THEN s.projected / (SELECT median_total FROM bench)
                                 ELSE NULL END
             ) ORDER BY s.t0 DESC)
      FROM scored s JOIN group_buy_campaigns c ON c.id = s.campaign_id), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_campaign_pace(integer, integer) IS
  '開團早期訊號：用歷史團建立「第 h 小時通常累積了最終幾成」的中位數曲線，'
  '再把進行中的團套上去推估最終訂單數。t0 取該團第一張訂單的時間（start_at 線上常缺）。'
  '線上實測 6/12/24 小時的累積量對最終總量相關係數 0.64/0.75/0.81。';

GRANT EXECUTE ON FUNCTION public.rpc_campaign_pace(integer, integer) TO authenticated;

-- ============================================================================
-- 3. 下單時段熱力圖 7×24（台北時間）
--    用途是決定 LINE 推播時間，所以回傳的是「下單時間」的分佈。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_order_hour_heatmap(
  p_days     INTEGER DEFAULT 90,
  p_store_id BIGINT  DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH params AS (
    SELECT LEAST(GREATEST(COALESCE(p_days, 90), 7), 365) AS days
  ),
  ord AS (
    SELECT o.id, o.member_id,
           (o.created_at AT TIME ZONE 'Asia/Taipei') AS ts
    FROM customer_orders o
    JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal'
                  AND m.status <> 'deleted'
    CROSS JOIN params p
    WHERE o.created_at >= NOW() - (p.days * INTERVAL '1 day')
      AND o.status NOT IN ('cancelled', 'expired', 'transferred_out')
      AND (p_store_id IS NULL OR o.pickup_store_id = p_store_id)
  ),
  cell AS (
    SELECT extract(dow  FROM ts)::int AS dow,
           extract(hour FROM ts)::int AS hh,
           count(*)                   AS orders,
           count(DISTINCT member_id)  AS members
    FROM ord GROUP BY 1,2
  )
  SELECT jsonb_build_object(
    'days',   (SELECT days FROM params),
    'total',  (SELECT count(*) FROM ord),
    'max',    (SELECT COALESCE(max(orders), 0) FROM cell),
    'cells',  COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'dow', dow, 'h', hh, 'orders', orders, 'members', members))
                        FROM cell), '[]'::jsonb),
    -- 前 10 名時段，UI 直接拿去寫「建議推播時間」
    'top',    COALESCE((SELECT jsonb_agg(jsonb_build_object('dow', dow, 'h', hh, 'orders', orders)
                                         ORDER BY orders DESC)
                        FROM (SELECT * FROM cell ORDER BY orders DESC LIMIT 10) z), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.rpc_order_hour_heatmap(integer, bigint) IS
  '下單時段熱力圖 7×24（台北時間，dow 0=週日）。用途：決定 LINE 推播時間。';

GRANT EXECUTE ON FUNCTION public.rpc_order_hour_heatmap(integer, bigint) TO authenticated;
