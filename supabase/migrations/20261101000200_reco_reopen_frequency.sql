-- ============================================================================
-- 推薦系統：開團頻率因子 → 預估模型 v2（20261101000200）
--
-- Alex 2026-11-01：「開的頻率是不是也要考慮進去，太頻繁開加單率也不高（豬排還沒吃完一直開）」。
-- 實查（7 月起已結束的總倉團，同款＝向量 ≥ 0.9 的商品，206 組「再開一次」）：
--   食品    隔 <30 天  28 組  這次人數 = 上次 0.74 倍
--           隔 30～59  61 組            0.90 倍
--           隔 60+     65 組            0.82 倍
--   非食品  隔 <30 天  30 組            1.00 倍（組數少，還看不出來）
--   上次買過的人這次又買：只有 9～20%，重開主要靠新客人。
--
-- 改動：
--   ④ 特徵多四個（reco_compute_features，基底 20261101000160 —— 唯一前版，已 grep）：
--      same_days（同款上次開團距今幾天）、same_name / same_date / same_buyers、
--      same_opens_60d（近 60 天同款開過幾團）、is_food（品項標籤沒有任何「非食品」組＝食品）。
--      同款：候選品（廠商寫法）對我方商品用 0.85（同「賣過」門檻；用 0.9 只抓得到 7 / 108 筆），
--      回測時商品對商品用 0.9（實查用的門檻）。只算總倉團、不含取消／草稿。
--   ⑤ reco_predict_v2 = v1 × 頻率：食品、同款 30 天內開過 → 預估 / 區間 ×0.75，理由第一行寫
--      「同款 X 10/14 才開過（18 天前），還沒吃完的人多」；其他情況只把「上次開的日期」寫進理由，不扣分。
--      非食品等資料夠了（每週回測累積）再依各類別自己的回購週期扣。
--   reco_refresh_predictions 改用 v2（model_version 'v2'），套用當下全部重算一次。
--   ⑨ 評估跟著換 v2：reco_eval_backtest / reco_eval_daily 多一個 p_model（預設 'v2'），
--      開團前的特徵（含「當時」的同款頻率）統一由 _reco_features_asof 算。
--      基底：reco_eval_backtest @ 20261101000180、reco_eval_daily @ 20261101000190（各自唯一前版，已 grep）。
--      reco_eval_weekly 與 cron 呼叫時只傳前兩～三個參數，不用改。
--
-- rollback：
--   重跑 20261101000160 的 reco_compute_features、reco_refresh_predictions；
--   DROP FUNCTION public.reco_eval_backtest(UUID, DATE, DATE, TEXT), public.reco_eval_daily(UUID, DATE, TEXT),
--     public._reco_features_asof(UUID, BIGINT, DATE, NUMERIC), public.reco_predict_v2(JSONB),
--     public._reco_reopen(UUID, extensions.vector, TIMESTAMPTZ, NUMERIC);
--   再重跑 20261101000180 的 reco_eval_backtest 與 20261101000190 的 reco_eval_daily；
--   UPDATE reco_predictions SET computed_at = '-infinity'; SELECT reco_refresh_predictions(1000);
-- ============================================================================

-- 同款（向量 ≥ 0.9）在 p_before 之前的開團紀錄
CREATE OR REPLACE FUNCTION public._reco_reopen(p_tenant UUID, p_emb extensions.vector, p_before TIMESTAMPTZ,
                                               p_min_cos NUMERIC DEFAULT 0.9)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  WITH same AS (
    SELECT e.product_id
      FROM product_embeddings e
     WHERE e.tenant_id = p_tenant AND (1 - (e.embedding <=> p_emb)) >= p_min_cos
     ORDER BY e.embedding <=> p_emb
     LIMIT 10
  ), g AS (
    SELECT g.id, g.start_at, p.name
      FROM same
      JOIN group_buy_campaigns g ON g.product_id = same.product_id
      JOIN products p ON p.id = g.product_id
     WHERE g.tenant_id = p_tenant AND g.owner_store_id IS NULL AND g.status NOT IN ('cancelled', 'draft')
       AND g.start_at < p_before AND g.start_at >= p_before - interval '180 days'
  ), last AS (
    SELECT g.*, r.buyers FROM g LEFT JOIN reco_campaign_buyers r ON r.campaign_id = g.id
     ORDER BY g.start_at DESC LIMIT 1
  )
  SELECT jsonb_build_object(
    'same_days', (SELECT ((p_before AT TIME ZONE 'Asia/Taipei')::date - (start_at AT TIME ZONE 'Asia/Taipei')::date) FROM last),
    'same_date', (SELECT (start_at AT TIME ZONE 'Asia/Taipei')::date FROM last),
    'same_name', (SELECT name FROM last),
    'same_buyers', (SELECT buyers FROM last),
    'same_opens_60d', (SELECT count(*) FROM g WHERE g.start_at >= p_before - interval '60 days'));
$$;
REVOKE ALL ON FUNCTION public._reco_reopen(UUID, extensions.vector, TIMESTAMPTZ, NUMERIC) FROM PUBLIC, anon, authenticated;

-- ④ 特徵（v1 全部 + 開團頻率 + 是不是食品）
CREATE OR REPLACE FUNCTION public.reco_compute_features(p_candidate_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_c      community_product_candidates%ROWTYPE;
  v_i      line_note_market_items%ROWTYPE;
  v_tags   TEXT[];
  v_knn    JSONB;
  v_knn_b  NUMERIC;
  v_top    NUMERIC;
  v_tagp   NUMERIC;
  v_tagn   INT;
  v_glob   NUMERIC;
  v_crowd  INT;
  v_band   TEXT;
  v_recent JSONB;
  v_food   BOOLEAN;
BEGIN
  SELECT * INTO v_c FROM community_product_candidates WHERE id = p_candidate_id;
  IF NOT FOUND OR (v_c.raw ->> 'market_item_id') IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_i FROM line_note_market_items WHERE id = (v_c.raw ->> 'market_item_id')::bigint;
  IF NOT FOUND OR v_i.embedding IS NULL THEN RETURN NULL; END IF;

  -- 溫層標籤不算類別
  SELECT COALESCE(array_agg(t.code), '{}') INTO v_tags
    FROM unnest(COALESCE(v_i.tags, '{}')) AS x(code)
    JOIN product_tags t ON t.code = x.code AND t.tenant_id = v_c.tenant_id AND t.tag_group <> '溫層';
  -- 食品＝標籤裡沒有任何「非食品」組
  v_food := NOT EXISTS (SELECT 1 FROM unnest(COALESCE(v_i.tags, '{}')) AS x(code)
                          JOIN product_tags t ON t.code = x.code AND t.tenant_id = v_c.tenant_id AND t.tag_group = '非食品');

  -- 最像 5 個「開過、而且已經結束（settled）」的商品（向量前 40 個裡挑）
  WITH n AS (
    SELECT e.product_id, (1 - (e.embedding <=> v_i.embedding))::numeric AS cos
      FROM product_embeddings e
     WHERE e.tenant_id = v_c.tenant_id
     ORDER BY e.embedding <=> v_i.embedding
     LIMIT 40
  ), h AS (
    SELECT n.product_id, n.cos, avg(r.buyers)::numeric AS b, count(*) AS camps
      FROM n JOIN reco_campaign_buyers r ON r.product_id = n.product_id AND r.settled
     GROUP BY 1, 2
     ORDER BY n.cos DESC
     LIMIT 5
  )
  SELECT jsonb_agg(jsonb_build_object('product_id', h.product_id, 'name', p.name, 'cos', round(h.cos, 3),
                                      'buyers', round(h.b, 1), 'campaigns', h.camps) ORDER BY h.cos DESC),
         sum(power(h.cos, 4) * h.b) / NULLIF(sum(power(h.cos, 4)), 0),
         max(h.cos)
    INTO v_knn, v_knn_b, v_top
    FROM h JOIN products p ON p.id = h.product_id;

  -- 同標籤近 5 週每團平均（只算 settled；剛開的還沒結束，窗口因此往前多拉一週）
  SELECT avg(r.buyers), count(*) INTO v_tagp, v_tagn
    FROM reco_campaign_buyers r
   WHERE r.tenant_id = v_c.tenant_id AND r.settled
     AND r.start_date >= current_date - 35
     AND cardinality(v_tags) > 0
     AND EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                  WHERE m.product_id = r.product_id AND t.code = ANY (v_tags));
  SELECT avg(r.buyers) INTO v_glob
    FROM reco_campaign_buyers r
   WHERE r.tenant_id = v_c.tenant_id AND r.settled AND r.start_date >= current_date - 35;

  -- 同款最近開過、還沒結束（開團中／已收單／還沒到貨）或已排草稿：向量 ≥ 0.85 的商品
  WITH same AS (
    SELECT e.product_id
      FROM product_embeddings e
     WHERE e.tenant_id = v_c.tenant_id
       AND (1 - (e.embedding <=> v_i.embedding)) >= 0.85
     ORDER BY e.embedding <=> v_i.embedding
     LIMIT 10
  )
  SELECT jsonb_agg(jsonb_build_object('campaign_id', g.id, 'name', p.name, 'status', g.status,
                                      'start', g.start_at::date, 'buyers', r.buyers) ORDER BY g.start_at DESC)
    INTO v_recent
    FROM same
    JOIN group_buy_campaigns g ON g.product_id = same.product_id AND g.tenant_id = v_c.tenant_id
    JOIN products p ON p.id = g.product_id
    LEFT JOIN reco_campaign_buyers r ON r.campaign_id = g.id
   WHERE g.status <> 'cancelled'
     AND (g.status IN ('draft', 'open', 'closed') OR NOT COALESCE(r.settled, FALSE))
     AND g.start_at > now() - interval '45 days';

  -- 擁擠度：同類未來 7 天已排幾團（只記錄、顯示，不進公式）
  SELECT count(*) INTO v_crowd
    FROM group_buy_campaigns g
   WHERE g.tenant_id = v_c.tenant_id AND g.status NOT IN ('cancelled')
     AND g.start_at >= now() AND g.start_at < now() + interval '7 days'
     AND cardinality(v_tags) > 0
     AND EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                  WHERE m.product_id = g.product_id AND t.code = ANY (v_tags));

  v_band := CASE WHEN v_i.price IS NULL OR v_i.price <= 0 THEN NULL
                 WHEN v_i.price < 200 THEN 'lt200' WHEN v_i.price < 300 THEN '200_300' ELSE 'gt300' END;

  RETURN jsonb_build_object(
    'item_id', v_i.id, 'item_name', v_i.item_name,
    'knn', COALESCE(v_knn, '[]'::jsonb), 'knn_buyers', round(v_knn_b, 2), 'top_cos', round(v_top, 3),
    'tags', to_jsonb(v_tags), 'tag_prior', round(v_tagp, 2), 'tag_campaigns', COALESCE(v_tagn, 0),
    'global_prior', round(v_glob, 2),
    'price', v_i.price, 'price_band', v_band,
    'crowding', COALESCE(v_crowd, 0),
    'recent_open', COALESCE(v_recent, '[]'::jsonb),
    'is_food', v_food)
    || public._reco_reopen(v_c.tenant_id, v_i.embedding, now(), 0.85);  -- 廠商品名 vs 我方品名，同款門檻同「賣過」
END;
$$;
REVOKE ALL ON FUNCTION public.reco_compute_features(BIGINT) FROM PUBLIC, anon, authenticated;

-- ⑤ 模型 v2 = v1 × 開團頻率
CREATE OR REPLACE FUNCTION public.reco_predict_v2(p_f JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_p    JSONB := public.reco_predict_v1(p_f);
  v_days INT   := NULLIF(p_f ->> 'same_days', '')::int;
  v_n60  INT   := COALESCE(NULLIF(p_f ->> 'same_opens_60d', '')::int, 0);
  v_food BOOLEAN := COALESCE((p_f ->> 'is_food')::boolean, TRUE);
  v_rs   JSONB;
  v_what TEXT;
  v_open BOOLEAN;
BEGIN
  IF v_p IS NULL THEN RETURN NULL; END IF;
  v_rs := COALESCE(v_p -> 'reasons', '[]'::jsonb);
  v_open := COALESCE((v_p ->> 'recent_open')::boolean, FALSE);
  IF v_days IS NOT NULL THEN
    v_what := format('同款「%s」%s 開過（%s 天前%s）', p_f ->> 'same_name',
                     to_char((p_f ->> 'same_date')::date, 'MM/DD'), v_days,
                     CASE WHEN NULLIF(p_f ->> 'same_buyers', '') IS NOT NULL
                          THEN format('，%s 人', p_f ->> 'same_buyers') ELSE '' END);
    IF v_food AND v_days < 30 THEN
      -- 食品 30 天內重開：實查 0.74 倍
      v_p := v_p || jsonb_build_object(
        'buyers', round((v_p ->> 'buyers')::numeric * 0.75),
        'low', floor((v_p ->> 'low')::numeric * 0.75),
        'high', ceil((v_p ->> 'high')::numeric * 0.75));
      IF v_open THEN
        -- 同款還沒結束的警告（v1 放在第一行）已經講了是哪一團，只補一句為什麼打折
        v_rs := (v_rs -> 0) || to_jsonb('食品 30 天內重開，還沒吃完的人多，預估打 75 折'::text) || (v_rs - 0);
      ELSE
        v_rs := to_jsonb('⚠ ' || v_what || '，還沒吃完的人多，預估打 75 折') || v_rs;
      END IF;
    ELSIF NOT v_open THEN
      v_rs := v_rs || to_jsonb(v_what);
    END IF;
    IF v_n60 >= 2 THEN
      v_rs := v_rs || to_jsonb(format('近 60 天同款開過 %s 團', v_n60));
    END IF;
  END IF;
  RETURN v_p || jsonb_build_object('reasons', v_rs);
END;
$$;

-- 補算（基底 20261101000160；只換成 v2）
CREATE OR REPLACE FUNCTION public.reco_refresh_predictions(p_limit INT DEFAULT 300)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  r     RECORD;
  v_f   JSONB;
  v_p   JSONB;
  v_n   INT := 0;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  FOR r IN
    SELECT c.id, c.tenant_id
      FROM community_product_candidates c
      LEFT JOIN reco_predictions p ON p.candidate_id = c.id
     WHERE c.owner_action IN ('none', 'collected')
       AND c.created_at > now() - interval '14 days'
       AND (c.raw ->> 'market_item_id') IS NOT NULL
       AND (p.candidate_id IS NULL OR p.computed_at < c.updated_at OR p.computed_at < now() - interval '6 hours')
     ORDER BY p.computed_at NULLS FIRST, c.id DESC
     LIMIT GREATEST(COALESCE(p_limit, 300), 1)
  LOOP
    v_f := public.reco_compute_features(r.id);
    CONTINUE WHEN v_f IS NULL;
    INSERT INTO reco_features (candidate_id, tenant_id, feature_version, features, computed_at)
    VALUES (r.id, r.tenant_id, 'f2', v_f, now())
    ON CONFLICT (candidate_id) DO UPDATE
       SET feature_version = EXCLUDED.feature_version, features = EXCLUDED.features, computed_at = now();
    v_p := public.reco_predict_v2(v_f);
    CONTINUE WHEN v_p IS NULL;
    INSERT INTO reco_predictions (candidate_id, tenant_id, model_version, buyers, low, high, confidence, reasons, recent_open, computed_at)
    VALUES (r.id, r.tenant_id, 'v2', (v_p ->> 'buyers')::int, (v_p ->> 'low')::int, (v_p ->> 'high')::int,
            v_p ->> 'confidence', ARRAY(SELECT jsonb_array_elements_text(v_p -> 'reasons')),
            COALESCE((v_p ->> 'recent_open')::boolean, FALSE), now())
    ON CONFLICT (candidate_id) DO UPDATE
       SET model_version = EXCLUDED.model_version, buyers = EXCLUDED.buyers, low = EXCLUDED.low, high = EXCLUDED.high,
           confidence = EXCLUDED.confidence, reasons = EXCLUDED.reasons, recent_open = EXCLUDED.recent_open,
           computed_at = now();
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_refresh_predictions(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reco_refresh_predictions(INT) TO service_role;

-- ⑨ 評估：某商品「在 p_d 那天開團前」的特徵（歷史只用開團前 10 天以前開的、已結束的團）
CREATE OR REPLACE FUNCTION public._reco_features_asof(p_tenant UUID, p_product BIGINT, p_d DATE, p_price NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_emb  extensions.vector;
  v_knn  NUMERIC;
  v_top  NUMERIC;
  v_tag  NUMERIC;
  v_glob NUMERIC;
  v_food BOOLEAN;
BEGIN
  SELECT embedding INTO v_emb FROM product_embeddings WHERE product_id = p_product;
  IF v_emb IS NULL THEN RETURN NULL; END IF;
  SELECT sum(power(h.cos, 4) * h.b) / NULLIF(sum(power(h.cos, 4)), 0), max(h.cos)
    INTO v_knn, v_top
    FROM (SELECT n.product_id, n.cos, avg(rb.buyers)::numeric AS b
            FROM (SELECT e.product_id, (1 - (e.embedding <=> v_emb))::numeric AS cos
                    FROM product_embeddings e
                   WHERE e.tenant_id = p_tenant AND e.product_id <> p_product
                   ORDER BY e.embedding <=> v_emb LIMIT 40) n
            JOIN reco_campaign_buyers rb ON rb.product_id = n.product_id AND rb.settled AND rb.start_date <= p_d - 10
           GROUP BY 1, 2 ORDER BY n.cos DESC LIMIT 5) h;
  SELECT avg(rb.buyers) INTO v_tag
    FROM reco_campaign_buyers rb
   WHERE rb.tenant_id = p_tenant AND rb.settled AND rb.start_date BETWEEN p_d - 35 AND p_d - 10
     AND EXISTS (SELECT 1 FROM product_tag_map m1 JOIN product_tags g1 ON g1.id = m1.tag_id
                   JOIN product_tag_map m2 ON m2.tag_id = m1.tag_id
                  WHERE m1.product_id = p_product AND m2.product_id = rb.product_id AND g1.tag_group <> '溫層');
  SELECT avg(rb.buyers) INTO v_glob
    FROM reco_campaign_buyers rb
   WHERE rb.tenant_id = p_tenant AND rb.settled AND rb.start_date BETWEEN p_d - 35 AND p_d - 10;
  v_food := NOT EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                         WHERE m.product_id = p_product AND t.tag_group = '非食品');
  RETURN jsonb_build_object(
    'knn_buyers', v_knn, 'top_cos', v_top, 'tag_prior', v_tag, 'global_prior', v_glob, 'price', p_price,
    'price_band', CASE WHEN p_price IS NULL OR p_price <= 0 THEN NULL WHEN p_price < 200 THEN 'lt200'
                       WHEN p_price < 300 THEN '200_300' ELSE 'gt300' END,
    'is_food', v_food)
    || public._reco_reopen(p_tenant, v_emb, (p_d::timestamp AT TIME ZONE 'Asia/Taipei'));
END;
$$;
REVOKE ALL ON FUNCTION public._reco_features_asof(UUID, BIGINT, DATE, NUMERIC) FROM PUBLIC, anon, authenticated;

-- 每週回測（基底 20261101000180）：特徵改由 _reco_features_asof 算，可指定模型
DROP FUNCTION IF EXISTS public.reco_eval_backtest(UUID, DATE, DATE);
CREATE OR REPLACE FUNCTION public.reco_eval_backtest(p_tenant UUID, p_from DATE, p_to DATE, p_model TEXT DEFAULT 'v2')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_rows JSONB;
  v_m    JSONB;
BEGIN
  WITH t AS (
    SELECT r.product_id, r.start_date AS d, r.buyers AS actual, r.price
      FROM reco_campaign_buyers r
     WHERE r.tenant_id = p_tenant AND r.settled AND r.start_date BETWEEN p_from AND p_to
       AND NOT EXISTS (SELECT 1 FROM reco_campaign_buyers r2
                        WHERE r2.product_id = r.product_id AND r2.start_date < r.start_date)
  ), f AS (
    SELECT t.actual, public._reco_features_asof(p_tenant, t.product_id, t.d, t.price) AS feat FROM t
  ), p AS (
    SELECT actual, CASE p_model WHEN 'v1' THEN public.reco_predict_v1(feat) ELSE public.reco_predict_v2(feat) END AS pr
      FROM f WHERE feat IS NOT NULL
  )
  SELECT jsonb_agg(jsonb_build_object('pred', (pr ->> 'buyers')::numeric, 'low', (pr ->> 'low')::numeric,
                                      'high', (pr ->> 'high')::numeric, 'actual', actual))
    INTO v_rows
    FROM p WHERE pr IS NOT NULL;

  v_m := public._reco_eval_metrics(v_rows);
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, details)
  VALUES (p_tenant, 'backtest', p_model, p_from, p_to, (v_m ->> 'n')::int, (v_m ->> 'rho')::numeric,
          (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric, (v_m ->> 'top_bottom_ratio')::numeric,
          (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric, (v_m ->> 'coverage')::numeric, v_m);
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_backtest(UUID, DATE, DATE, TEXT) FROM PUBLIC, anon, authenticated;

-- 每日回測（基底 20261101000190）：同上
DROP FUNCTION IF EXISTS public.reco_eval_daily(UUID, DATE);
CREATE OR REPLACE FUNCTION public.reco_eval_daily(p_tenant UUID, p_day DATE, p_model TEXT DEFAULT 'v2')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows JSONB;
  v_m    JSONB;
BEGIN
  WITH t AS (
    SELECT g.id, g.product_id, g.start_at, (g.start_at AT TIME ZONE 'Asia/Taipei')::date AS start_d,
           (SELECT min(ci.unit_price) FROM campaign_items ci
             WHERE ci.campaign_id = g.id AND NOT COALESCE(ci.is_gift, FALSE)) AS price
      FROM group_buy_campaigns g
     WHERE g.tenant_id = p_tenant AND g.product_id IS NOT NULL AND g.owner_store_id IS NULL
       AND g.status NOT IN ('cancelled', 'draft', 'open')
       AND (g.end_at AT TIME ZONE 'Asia/Taipei')::date = p_day
       AND NOT EXISTS (SELECT 1 FROM group_buy_campaigns g2
                        WHERE g2.product_id = g.product_id AND g2.start_at < g.start_at
                          AND g2.status NOT IN ('cancelled', 'draft'))
  ), a AS (
    SELECT t.id, count(DISTINCT co.member_id) AS b
      FROM t
      JOIN customer_orders co ON co.campaign_id = t.id
      JOIN members m ON m.id = co.member_id
     WHERE co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND COALESCE(m.member_type, '') <> 'store_internal'
     GROUP BY 1
  ), f AS (
    SELECT COALESCE(a.b, 0) AS actual, public._reco_features_asof(p_tenant, t.product_id, t.start_d, t.price) AS feat
      FROM t LEFT JOIN a ON a.id = t.id
  ), p AS (
    SELECT actual, CASE p_model WHEN 'v1' THEN public.reco_predict_v1(feat) ELSE public.reco_predict_v2(feat) END AS pr
      FROM f WHERE feat IS NOT NULL
  )
  SELECT jsonb_agg(jsonb_build_object('pred', (pr ->> 'buyers')::numeric, 'low', (pr ->> 'low')::numeric,
                                      'high', (pr ->> 'high')::numeric, 'actual', actual))
    INTO v_rows
    FROM p WHERE pr IS NOT NULL;

  v_m := public._reco_eval_metrics(v_rows);
  DELETE FROM reco_eval_runs WHERE tenant_id = p_tenant AND kind = 'daily' AND window_from = p_day AND model_version = p_model;
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, details)
  VALUES (p_tenant, 'daily', p_model, p_day, p_day, COALESCE((v_m ->> 'n')::int, 0), (v_m ->> 'rho')::numeric,
          (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric, (v_m ->> 'top_bottom_ratio')::numeric,
          (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric, (v_m ->> 'coverage')::numeric,
          v_m || jsonb_build_object('actual', 'at_close'));
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_daily(UUID, DATE, TEXT) FROM PUBLIC, anon, authenticated;

-- 套用當下：全部預估用 v2 重算、預選重排、回測用 v2 重跑最近 4 週與 14 天
UPDATE public.reco_predictions SET computed_at = '-infinity';
SELECT public.reco_refresh_predictions(1000);
SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
DELETE FROM public.reco_eval_runs WHERE kind IN ('backtest', 'daily');
SELECT public.reco_eval_backtest(t.tenant_id, w.d - 6, w.d)
  FROM (SELECT DISTINCT tenant_id FROM public.reco_campaign_buyers) t,
       (SELECT ((now() AT TIME ZONE 'Asia/Taipei')::date - 22 - 7 * g) AS d FROM generate_series(3, 0, -1) g) w;
SELECT public.reco_eval_daily(t.tenant_id, (now() AT TIME ZONE 'Asia/Taipei')::date - g)
  FROM (SELECT DISTINCT tenant_id FROM public.reco_campaign_buyers) t, generate_series(14, 1, -1) g;
