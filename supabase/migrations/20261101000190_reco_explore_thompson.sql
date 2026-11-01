-- ============================================================================
-- 推薦系統：預選一天 10 個 + 探索名額（Thompson Sampling，「抖音式下注」）（20261101000190）
--
-- Alex 2026-11-01：一天要開 20～30 團，系統推薦大概 10 個；要有之前說的「像字節那樣
-- 賭下一個會不會中」的演算法。
--
-- 做法（docs/PLAN 選品 §五 Phase C 的「Thompson Sampling、10% 探索槽」，這裡給 20%）：
--   1. 類別勝率 reco_tag_stats：每個標籤（排除溫層）近 120 天已結束的總倉團，
--      「中」＝買家數 ≥ 同期中位數。每團權重 0.5^(距今天數/14)（半衰期 14 天，越新越重），
--      後驗 Beta(1 + Σ權重×中, 1 + Σ權重×沒中)。每晚 03:47 重算 —— 開團結果一進來，
--      下一輪的勝率就跟著變（這就是「下注 → 看結果 → 再下注」的回饋）。
--   2. 每天 10 個預選：
--      - 8 個「照預估」（exploit）：跟 20261101000170 一樣，依預估買家多→少。
--      - 2 個「試新」（explore）：剩下的候選，每一個從它主標籤的 Beta 抽一個勝率，抽到最高的進來。
--        團數少的類別分布很寬，偶爾會抽到很高 → 自然會被拿出來試；試過幾次沒中就會沉下去。
--        試新的門檻放寬到預估 ≥ 3 位（照預估那邊是 ≥ 8）。
--   3. 其餘規則不變：同款還沒結束的不推、同一天同主標籤最多 1 個、整週同一個東西只推 1 次。
--
-- reco_slates 加 pick_kind（exploit / explore），週曆把試新的標出來；⑨ 評估之後可以分開看兩種的命中率。
--
-- 基底：reco_build_slates @ 20261101000170（唯一前版，已 grep）。參數多一個 p_explore，
--   所以 DROP 舊簽名再建；rpc_reco_rebuild_slates 與 cron 'reco-slates' 都是只傳 tenant，不用改。
-- 另外（Alex 2026-11-01「每天回測」→「不能回測昨天開的，應該關團了才來回測」）：
--   每日回測 reco_eval_daily：**昨天關團**（end_at 在昨天、狀態已離開開團中）的總倉團，
--   只算第一次開的商品；用「開團那天之前」就知道的資料算 v1 預估，跟關團時的買家數比。
--   關團後還能補加單、斷貨還會取消，最終數字以每週一「已結束」回測為準；每日這份看的是排名準不準。
--   每天台北 23:53 跑。reco_eval_runs.kind 加 'daily'（window_from = 關團日）；同一天重跑會蓋掉。
--
-- rollback：
--   SELECT cron.unschedule('reco-tag-stats'); SELECT cron.unschedule('reco-eval-daily');
--   DROP FUNCTION public.reco_eval_daily(UUID, DATE), public._reco_v1_asof(UUID, BIGINT, DATE, NUMERIC);
--   DELETE FROM reco_eval_runs WHERE kind = 'daily'; 再把 reco_eval_runs_kind_check 改回 ('backtest','live')；
--   DROP FUNCTION public.reco_build_slates(UUID, INT, INT, INT, INT), public.reco_refresh_tag_stats(),
--     public._reco_rand_beta(NUMERIC, NUMERIC), public._reco_rand_gamma(NUMERIC), public._reco_rand_normal();
--   DROP TABLE public.reco_tag_stats; ALTER TABLE public.reco_slates DROP COLUMN pick_kind;
--   再重跑 20261101000170 的 reco_build_slates 定義。
-- ============================================================================

-- ── 類別勝率 ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reco_tag_stats (
  tenant_id    UUID    NOT NULL,
  tag          TEXT    NOT NULL,
  alpha        NUMERIC NOT NULL,
  beta         NUMERIC NOT NULL,
  campaigns    INT     NOT NULL,      -- 近 120 天團數（未加權）
  hits         INT     NOT NULL,      -- 其中「中」的團數（未加權）
  threshold    NUMERIC NOT NULL,      -- 「中」的門檻（同期買家中位數）
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, tag)
);
COMMENT ON TABLE public.reco_tag_stats IS
  '推薦系統：類別勝率 Beta 後驗（半衰期 14 天）。試新名額用它做 Thompson Sampling';
ALTER TABLE public.reco_tag_stats ENABLE ROW LEVEL SECURITY;
CREATE POLICY reco_tag_stats_hq_read ON public.reco_tag_stats FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.reco_tag_stats TO authenticated;

CREATE OR REPLACE FUNCTION public.reco_refresh_tag_stats()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  WITH base AS (
    SELECT r.tenant_id, r.product_id, r.buyers, r.start_date,
           power(0.5, (current_date - r.start_date) / 14.0) AS w
      FROM reco_campaign_buyers r
     WHERE r.settled AND r.start_date >= current_date - 120
  ), th AS (
    SELECT tenant_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY buyers) AS med
      FROM base GROUP BY 1
  ), x AS (
    SELECT b.tenant_id, t.code AS tag, b.w, (b.buyers >= th.med) AS hit, th.med
      FROM base b
      JOIN th ON th.tenant_id = b.tenant_id
      JOIN product_tag_map m ON m.product_id = b.product_id
      JOIN product_tags t ON t.id = m.tag_id AND t.tag_group <> '溫層'
  )
  INSERT INTO reco_tag_stats AS s (tenant_id, tag, alpha, beta, campaigns, hits, threshold, refreshed_at)
  SELECT tenant_id, tag,
         1 + COALESCE(sum(w) FILTER (WHERE hit), 0), 1 + COALESCE(sum(w) FILTER (WHERE NOT hit), 0),
         count(*), count(*) FILTER (WHERE hit), max(med), now()
    FROM x GROUP BY 1, 2
  ON CONFLICT (tenant_id, tag) DO UPDATE
     SET alpha = EXCLUDED.alpha, beta = EXCLUDED.beta, campaigns = EXCLUDED.campaigns,
         hits = EXCLUDED.hits, threshold = EXCLUDED.threshold, refreshed_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_refresh_tag_stats() FROM PUBLIC, anon, authenticated;

-- ── 抽樣：Box-Muller 常態 → Marsaglia-Tsang Gamma → Beta ─────────────────────
CREATE OR REPLACE FUNCTION public._reco_rand_normal()
RETURNS DOUBLE PRECISION
LANGUAGE sql
VOLATILE
AS $$
  SELECT sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());
$$;

CREATE OR REPLACE FUNCTION public._reco_rand_gamma(p_k NUMERIC)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  k DOUBLE PRECISION := GREATEST(p_k, 1e-6);
  d DOUBLE PRECISION;
  c DOUBLE PRECISION;
  x DOUBLE PRECISION;
  v DOUBLE PRECISION;
  u DOUBLE PRECISION;
BEGIN
  IF k < 1 THEN
    -- Gamma(k) = Gamma(k+1) × U^(1/k)
    RETURN public._reco_rand_gamma((k + 1)::numeric) * power(1 - random(), 1.0 / k);
  END IF;
  d := k - 1.0 / 3;
  c := 1.0 / sqrt(9 * d);
  LOOP
    x := public._reco_rand_normal();
    v := power(1 + c * x, 3);
    CONTINUE WHEN v <= 0;
    u := 1 - random();
    IF ln(u) < 0.5 * x * x + d - d * v + d * ln(v) THEN
      RETURN d * v;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public._reco_rand_beta(p_a NUMERIC, p_b NUMERIC)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE x DOUBLE PRECISION; y DOUBLE PRECISION;
BEGIN
  x := public._reco_rand_gamma(COALESCE(p_a, 1));
  y := public._reco_rand_gamma(COALESCE(p_b, 1));
  RETURN x / NULLIF(x + y, 0);
END;
$$;

-- ── 預選 ────────────────────────────────────────────────────────────────────
ALTER TABLE public.reco_slates
  ADD COLUMN IF NOT EXISTS pick_kind TEXT NOT NULL DEFAULT 'exploit' CHECK (pick_kind IN ('exploit', 'explore'));
COMMENT ON COLUMN public.reco_slates.pick_kind IS 'exploit = 照預估排；explore = 試新（類別勝率 Thompson Sampling 抽中的）';

DROP FUNCTION IF EXISTS public.reco_build_slates(UUID, INT, INT, INT);

CREATE OR REPLACE FUNCTION public.reco_build_slates(p_tenant UUID, p_days INT DEFAULT 6, p_per_day INT DEFAULT 10,
                                                    p_min_buyers INT DEFAULT 8, p_explore INT DEFAULT 2)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today   DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_exploit INT  := GREATEST(p_per_day - GREATEST(p_explore, 0), 0);
  r         RECORD;
  v_d       DATE;
  v_cnt     INT;
  v_n       INT := 0;
  v_keys    TEXT[] := '{}';
BEGIN
  -- 1. 收尾：候選後來被人排程了 → accepted；日子過了沒處理 → expired
  UPDATE reco_slates s SET status = 'accepted', decided_at = now()
    FROM community_product_candidates c
   WHERE s.tenant_id = p_tenant AND s.status = 'suggested' AND c.id = s.candidate_id
     AND c.owner_action IN ('scheduled', 'adopted');
  UPDATE reco_slates SET status = 'expired'
   WHERE tenant_id = p_tenant AND status = 'suggested' AND slate_date <= v_today;

  -- 2. 未來的建議整批重排（已決定的留著）
  DELETE FROM reco_slates WHERE tenant_id = p_tenant AND status = 'suggested' AND slate_date > v_today;

  CREATE TEMP TABLE IF NOT EXISTS _slate_fill (d DATE, tag TEXT, kind TEXT) ON COMMIT DROP;
  TRUNCATE _slate_fill;

  -- 母體（照預估、試新共用）
  CREATE TEMP TABLE IF NOT EXISTS _slate_pool (candidate_id BIGINT, buyers INT, confidence TEXT, model_version TEXT,
                                               reasons TEXT[], tag TEXT, dedupe_key TEXT) ON COMMIT DROP;
  TRUNCATE _slate_pool;
  INSERT INTO _slate_pool
  SELECT p.candidate_id, p.buyers, p.confidence, p.model_version, p.reasons,
         COALESCE(f.features -> 'tags' ->> 0, 'other'),
         CASE WHEN (f.features ->> 'top_cos')::numeric >= 0.85
              THEN 'p' || (f.features -> 'knn' -> 0 ->> 'product_id')
              ELSE 'n' || lower(regexp_replace(COALESCE(f.features ->> 'item_name', c.product_name_hint, ''),
                                               '[（(].*?[）)]|\s', '', 'g'))
         END
    FROM reco_predictions p
    JOIN community_product_candidates c ON c.id = p.candidate_id
    LEFT JOIN reco_features f ON f.candidate_id = p.candidate_id
   WHERE p.tenant_id = p_tenant
     AND c.owner_action IN ('none', 'collected')
     AND c.created_at > now() - interval '14 days'
     AND NOT p.recent_open
     AND p.buyers >= LEAST(p_min_buyers, 3)
     AND NOT EXISTS (SELECT 1 FROM reco_slates s
                      WHERE s.candidate_id = p.candidate_id AND s.status IN ('accepted', 'skipped'));

  -- 3. 照預估（每天 v_exploit 個）
  FOR r IN
    SELECT * FROM _slate_pool
     WHERE buyers >= p_min_buyers
     ORDER BY buyers DESC, CASE confidence WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, candidate_id DESC
  LOOP
    CONTINUE WHEN r.dedupe_key = ANY (v_keys);
    FOR i IN 1 .. GREATEST(p_days, 1) LOOP
      v_d := v_today + i;
      SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d AND kind = 'exploit';
      CONTINUE WHEN v_cnt >= v_exploit;
      CONTINUE WHEN r.tag <> 'other' AND EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND tag = r.tag);
      INSERT INTO _slate_fill VALUES (v_d, r.tag, 'exploit');
      INSERT INTO reco_slates (tenant_id, slate_date, rank, candidate_id, model_version, predicted, reason, pick_kind)
      VALUES (p_tenant, v_d, v_cnt + 1, r.candidate_id, r.model_version, r.buyers, r.reasons[1], 'exploit');
      v_keys := v_keys || r.dedupe_key;
      v_n := v_n + 1;
      EXIT;
    END LOOP;
  END LOOP;

  -- 4. 試新（每天 p_explore 個）：剩下的候選各從主標籤的 Beta 抽一個勝率，一天一天挑最高的
  IF p_explore > 0 THEN
    FOR i IN 1 .. GREATEST(p_days, 1) LOOP
      v_d := v_today + i;
      FOR j IN 1 .. p_explore LOOP
        SELECT sp.*, ts.campaigns AS t_camps, ts.hits AS t_hits, pt.name AS tag_name,
               public._reco_rand_beta(COALESCE(ts.alpha, 1), COALESCE(ts.beta, 1)) AS theta
          INTO r
          FROM _slate_pool sp
          LEFT JOIN reco_tag_stats ts ON ts.tenant_id = p_tenant AND ts.tag = sp.tag
          LEFT JOIN product_tags pt ON pt.tenant_id = p_tenant AND pt.code = sp.tag
         WHERE NOT (sp.dedupe_key = ANY (v_keys))
           AND (sp.tag = 'other' OR NOT EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND tag = sp.tag))
         ORDER BY theta DESC
         LIMIT 1;
        EXIT WHEN NOT FOUND;
        SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d;
        INSERT INTO _slate_fill VALUES (v_d, r.tag, 'explore');
        INSERT INTO reco_slates (tenant_id, slate_date, rank, candidate_id, model_version, predicted, reason, pick_kind)
        VALUES (p_tenant, v_d, v_cnt + 1, r.candidate_id, r.model_version, r.buyers,
                format('試新：%s 近 4 個月 %s 團、%s 團賣贏中位數（這次抽到 %s%%）',
                       COALESCE(r.tag_name, r.tag), COALESCE(r.t_camps, 0), COALESCE(r.t_hits, 0),
                       round((r.theta * 100)::numeric)),
                'explore');
        v_keys := v_keys || r.dedupe_key;
        v_n := v_n + 1;
      END LOOP;
    END LOOP;
  END IF;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_build_slates(UUID, INT, INT, INT, INT) FROM PUBLIC, anon, authenticated;

-- 每晚 03:47 台北重算類別勝率（在 03:27 重算每團買家之後）
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'reco-tag-stats';
SELECT cron.schedule('reco-tag-stats', '47 19 * * *', $cron$ SELECT public.reco_refresh_tag_stats(); $cron$);

-- 第一次
SELECT public.reco_refresh_tag_stats();
SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;

-- ── 每日回測：昨天關團的團，關團時的買家數 ──────────────────────────────────
ALTER TABLE public.reco_eval_runs DROP CONSTRAINT IF EXISTS reco_eval_runs_kind_check;
ALTER TABLE public.reco_eval_runs ADD CONSTRAINT reco_eval_runs_kind_check CHECK (kind IN ('backtest', 'live', 'daily'));

-- 某商品「在 p_d 那天開團前」的 v1 預估（歷史只用開團前 10 天以前開的、已結束的團；同 reco_eval_backtest）
CREATE OR REPLACE FUNCTION public._reco_v1_asof(p_tenant UUID, p_product BIGINT, p_d DATE, p_price NUMERIC)
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
  RETURN public.reco_predict_v1(jsonb_build_object(
    'knn_buyers', v_knn, 'top_cos', v_top, 'tag_prior', v_tag, 'global_prior', v_glob, 'price', p_price,
    'price_band', CASE WHEN p_price IS NULL OR p_price <= 0 THEN NULL WHEN p_price < 200 THEN 'lt200'
                       WHEN p_price < 300 THEN '200_300' ELSE 'gt300' END));
END;
$$;
REVOKE ALL ON FUNCTION public._reco_v1_asof(UUID, BIGINT, DATE, NUMERIC) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reco_eval_daily(p_tenant UUID, p_day DATE)
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
  ), p AS (
    SELECT t.id, COALESCE(a.b, 0) AS actual, public._reco_v1_asof(p_tenant, t.product_id, t.start_d, t.price) AS pr
      FROM t LEFT JOIN a ON a.id = t.id
  )
  SELECT jsonb_agg(jsonb_build_object('pred', (pr ->> 'buyers')::numeric, 'low', (pr ->> 'low')::numeric,
                                      'high', (pr ->> 'high')::numeric, 'actual', actual))
    INTO v_rows
    FROM p WHERE pr IS NOT NULL;

  v_m := public._reco_eval_metrics(v_rows);
  DELETE FROM reco_eval_runs WHERE tenant_id = p_tenant AND kind = 'daily' AND window_from = p_day;
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, details)
  VALUES (p_tenant, 'daily', 'v1', p_day, p_day, COALESCE((v_m ->> 'n')::int, 0), (v_m ->> 'rho')::numeric,
          (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric, (v_m ->> 'top_bottom_ratio')::numeric,
          (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric, (v_m ->> 'coverage')::numeric,
          v_m || jsonb_build_object('actual', 'at_close'));
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_daily(UUID, DATE) FROM PUBLIC, anon, authenticated;

-- 每天台北 23:53 回測昨天關團的
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'reco-eval-daily';
SELECT cron.schedule('reco-eval-daily', '53 15 * * *',
  $cron$ SELECT public.reco_eval_daily(t.tenant_id, (now() AT TIME ZONE 'Asia/Taipei')::date - 1)
           FROM (SELECT DISTINCT tenant_id FROM public.reco_campaign_buyers) t; $cron$);

-- 先補最近 14 天
SELECT public.reco_eval_daily(t.tenant_id, (now() AT TIME ZONE 'Asia/Taipei')::date - g)
  FROM (SELECT DISTINCT tenant_id FROM public.reco_campaign_buyers) t, generate_series(14, 1, -1) g;
