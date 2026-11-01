-- ============================================================================
-- 推薦系統 M3：⑧ 回寫 + ⑨ 評估（20261101000180）
--
-- 架構見 docs/PLAN-選品系統-外部來源與商品媒合.md「零、模組化架構」。
--
-- ⑧ reco_outcomes（一個候選一列）：候選被排程 → rpc_schedule_candidate 建的商品
--    （adopted_product_id）→ 之後開的第一個總倉團 → 24 小時 / 7 天 / 最終買家。
--    預估在「第一次看到它被排程」時抄一份下來（reco_predictions 之後不再更新它，
--    但抄下來才不怕換模型時被覆蓋）。也記它是不是系統預選排入的（slate_status）。
--    reco_refresh_outcomes 每小時跑。
--
-- ⑨ reco_eval_runs：
--    backtest：每週一回測「3～4 週前第一次開、已經結束（settled）的團」——
--      用當時就知道的資料（開團前 10 天已開的團當歷史）重算 v1 特徵、丟 reco_predict_v1，
--      跟實際買家比。跟 2026-11-01 文件裡的回測同一套做法，但歷史只用「當時應該已經結束」的團。
--    live：已經開團、而且結束的候選（reco_outcomes.settled），預估 vs 實際；外加近 7 天預選採納率。
--    指標：Spearman ρ、平均誤差、誤差中位數、預估前 20% / 後 20% 實際買家倍數、0 買家率、
--      實際/預估中位數（校正）、落在區間內的比例。ρ < 0.5 → 推薦成效頁亮紅燈，該換模型版本。
--
-- 排程：reco-outcomes 每小時 :41；reco-eval 每週一台北 04:37。
-- 新表、新函式，沒有改既有函式。
-- rollback：
--   SELECT cron.unschedule('reco-outcomes'); SELECT cron.unschedule('reco-eval');
--   DROP FUNCTION public.reco_eval_weekly(), public.reco_eval_live(UUID), public.reco_eval_backtest(UUID, DATE, DATE),
--     public._reco_eval_metrics(JSONB), public.reco_refresh_outcomes();
--   DROP TABLE public.reco_eval_runs, public.reco_outcomes;
-- ============================================================================

-- ── ⑧ 回寫 ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reco_outcomes (
  candidate_id   BIGINT PRIMARY KEY REFERENCES public.community_product_candidates(id) ON DELETE CASCADE,
  tenant_id      UUID   NOT NULL,
  product_id     BIGINT,
  model_version  TEXT   NOT NULL,
  predicted      INT    NOT NULL,
  low            INT    NOT NULL,
  high           INT    NOT NULL,
  confidence     TEXT   NOT NULL,
  slate_status   TEXT,              -- accepted = 從系統預選排入；NULL = 人自己挑的
  scheduled_at   TIMESTAMPTZ,
  campaign_id    BIGINT,
  start_date     DATE,
  buyers_24h     INT,
  buyers_7d      INT,
  buyers_final   INT,
  settled        BOOLEAN NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reco_outcomes_tenant ON public.reco_outcomes (tenant_id, start_date);
COMMENT ON TABLE public.reco_outcomes IS
  '推薦系統 ⑧：被排程的候選 → 開的團 → 實際買家；預估是排程當下抄的。reco_refresh_outcomes 每小時更新';

CREATE OR REPLACE FUNCTION public.reco_refresh_outcomes()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  -- 1. 新被排程的、而且有預估的 → 抄預估
  INSERT INTO reco_outcomes (candidate_id, tenant_id, product_id, model_version, predicted, low, high, confidence,
                             slate_status, scheduled_at)
  SELECT c.id, c.tenant_id, c.adopted_product_id, p.model_version, p.buyers, p.low, p.high, p.confidence,
         (SELECT s.status FROM reco_slates s WHERE s.candidate_id = c.id AND s.status = 'accepted' LIMIT 1),
         c.scheduled_at
    FROM community_product_candidates c
    JOIN reco_predictions p ON p.candidate_id = c.id
   WHERE c.owner_action IN ('scheduled', 'adopted')
  ON CONFLICT (candidate_id) DO NOTHING;

  -- 2. 還沒結束的：接上團、更新買家
  WITH o AS (
    SELECT o.candidate_id, c.adopted_product_id AS product_id
      FROM reco_outcomes o JOIN community_product_candidates c ON c.id = o.candidate_id
     WHERE NOT o.settled
  ), g AS (
    SELECT DISTINCT ON (o.candidate_id) o.candidate_id, o.product_id, g.id AS campaign_id, g.start_at
      FROM o JOIN group_buy_campaigns g ON g.product_id = o.product_id
     WHERE g.owner_store_id IS NULL AND g.status NOT IN ('cancelled', 'draft')
     ORDER BY o.candidate_id, g.start_at
  ), b AS (
    SELECT g.candidate_id,
           count(DISTINCT co.member_id) FILTER (WHERE co.created_at < g.start_at + interval '24 hours') AS b24,
           count(DISTINCT co.member_id) FILTER (WHERE co.created_at < g.start_at + interval '7 days')   AS b7,
           count(DISTINCT co.member_id) AS bf
      FROM g
      JOIN customer_orders co ON co.campaign_id = g.campaign_id
      JOIN members m ON m.id = co.member_id
     WHERE co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND COALESCE(m.member_type, '') <> 'store_internal'
     GROUP BY 1
  )
  UPDATE reco_outcomes r
     SET product_id = g.product_id, campaign_id = g.campaign_id, start_date = g.start_at::date,
         buyers_24h = COALESCE(b.b24, 0), buyers_7d = COALESCE(b.b7, 0), buyers_final = COALESCE(b.bf, 0),
         settled = COALESCE(rcb.settled, FALSE), updated_at = now()
    FROM g
    LEFT JOIN b ON b.candidate_id = g.candidate_id
    LEFT JOIN reco_campaign_buyers rcb ON rcb.campaign_id = g.campaign_id
   WHERE r.candidate_id = g.candidate_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_refresh_outcomes() FROM PUBLIC, anon, authenticated;

-- ── ⑨ 評估 ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reco_eval_runs (
  id               BIGSERIAL PRIMARY KEY,
  tenant_id        UUID   NOT NULL,
  kind             TEXT   NOT NULL CHECK (kind IN ('backtest', 'live')),
  model_version    TEXT   NOT NULL,
  window_from      DATE,
  window_to        DATE,
  n                INT    NOT NULL,
  rho              NUMERIC,
  mae              NUMERIC,
  median_ae        NUMERIC,
  top_bottom_ratio NUMERIC,
  zero_rate        NUMERIC,
  ratio_median     NUMERIC,
  coverage         NUMERIC,
  accept_rate      NUMERIC,
  details          JSONB,
  run_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reco_eval_runs ON public.reco_eval_runs (tenant_id, kind, run_at DESC);
COMMENT ON TABLE public.reco_eval_runs IS
  '推薦系統 ⑨：每週回測（backtest）與實際上線結果（live）的準度。rho < 0.5 該換模型';

ALTER TABLE public.reco_outcomes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reco_eval_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY reco_outcomes_hq_read ON public.reco_outcomes FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
CREATE POLICY reco_eval_runs_hq_read ON public.reco_eval_runs FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.reco_outcomes, public.reco_eval_runs TO authenticated;

-- 一組 [{pred, low, high, actual}] → 指標
CREATE OR REPLACE FUNCTION public._reco_eval_metrics(p_rows JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  WITH x AS (
    SELECT (e ->> 'pred')::numeric AS pred, (e ->> 'low')::numeric AS low, (e ->> 'high')::numeric AS high,
           (e ->> 'actual')::numeric AS actual
      FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) e
  ), r AS (
    SELECT x.*, rank() OVER (ORDER BY pred) AS rp, rank() OVER (ORDER BY actual) AS ra,
           ntile(5) OVER (ORDER BY pred) AS q
      FROM x
  )
  SELECT jsonb_build_object(
    'n', count(*),
    'rho', round(corr(rp, ra)::numeric, 3),
    'mae', round(avg(abs(actual - pred)), 1),
    'median_ae', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(actual - pred))::numeric, 1),
    'top_bottom_ratio', round(avg(actual) FILTER (WHERE q = 5) / NULLIF(avg(actual) FILTER (WHERE q = 1), 0), 2),
    'zero_rate', round(avg(CASE WHEN actual = 0 THEN 1 ELSE 0 END), 3),
    'ratio_median', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY actual / NULLIF(pred, 0)))::numeric, 2),
    'coverage', round(avg(CASE WHEN actual BETWEEN low AND high THEN 1 ELSE 0 END), 3))
  FROM r;
$$;

-- 回測：[p_from, p_to] 第一次開、已結束的總倉團，用開團前 10 天以前的資料重算 v1
CREATE OR REPLACE FUNCTION public.reco_eval_backtest(p_tenant UUID, p_from DATE, p_to DATE)
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
    SELECT r.campaign_id, r.product_id, r.start_date AS d, r.buyers AS actual, r.price, e.embedding
      FROM reco_campaign_buyers r
      JOIN product_embeddings e ON e.product_id = r.product_id
     WHERE r.tenant_id = p_tenant AND r.settled AND r.start_date BETWEEN p_from AND p_to
       AND NOT EXISTS (SELECT 1 FROM reco_campaign_buyers r2
                        WHERE r2.product_id = r.product_id AND r2.start_date < r.start_date)
  ), f AS (
    SELECT t.*, k.knn_b, k.top_cos, tp.tag_prior, gp.glob,
           CASE WHEN t.price IS NULL OR t.price <= 0 THEN NULL WHEN t.price < 200 THEN 'lt200'
                WHEN t.price < 300 THEN '200_300' ELSE 'gt300' END AS band
      FROM t
      CROSS JOIN LATERAL (
        SELECT sum(power(h.cos, 4) * h.b) / NULLIF(sum(power(h.cos, 4)), 0) AS knn_b, max(h.cos) AS top_cos
          FROM (SELECT n.product_id, n.cos, avg(rb.buyers)::numeric AS b
                  FROM (SELECT e2.product_id, (1 - (e2.embedding <=> t.embedding))::numeric AS cos
                          FROM product_embeddings e2
                         WHERE e2.tenant_id = p_tenant AND e2.product_id <> t.product_id
                         ORDER BY e2.embedding <=> t.embedding LIMIT 40) n
                  JOIN reco_campaign_buyers rb ON rb.product_id = n.product_id AND rb.start_date <= t.d - 10
                 GROUP BY 1, 2 ORDER BY n.cos DESC LIMIT 5) h
      ) k
      CROSS JOIN LATERAL (
        SELECT avg(rb.buyers) AS tag_prior
          FROM reco_campaign_buyers rb
         WHERE rb.tenant_id = p_tenant AND rb.start_date BETWEEN t.d - 35 AND t.d - 10
           AND EXISTS (SELECT 1 FROM product_tag_map m1 JOIN product_tags g1 ON g1.id = m1.tag_id
                         JOIN product_tag_map m2 ON m2.tag_id = m1.tag_id
                        WHERE m1.product_id = t.product_id AND m2.product_id = rb.product_id AND g1.tag_group <> '溫層')
      ) tp
      CROSS JOIN LATERAL (
        SELECT avg(rb.buyers) AS glob FROM reco_campaign_buyers rb
         WHERE rb.tenant_id = p_tenant AND rb.start_date BETWEEN t.d - 35 AND t.d - 10
      ) gp
  ), p AS (
    SELECT f.actual,
           public.reco_predict_v1(jsonb_build_object(
             'knn_buyers', f.knn_b, 'top_cos', f.top_cos, 'tag_prior', f.tag_prior, 'global_prior', f.glob,
             'price', f.price, 'price_band', f.band)) AS pr
      FROM f
  )
  SELECT jsonb_agg(jsonb_build_object('pred', (pr ->> 'buyers')::numeric, 'low', (pr ->> 'low')::numeric,
                                      'high', (pr ->> 'high')::numeric, 'actual', actual))
    INTO v_rows
    FROM p WHERE pr IS NOT NULL;

  v_m := public._reco_eval_metrics(v_rows);
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, details)
  VALUES (p_tenant, 'backtest', 'v1', p_from, p_to, (v_m ->> 'n')::int, (v_m ->> 'rho')::numeric,
          (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric, (v_m ->> 'top_bottom_ratio')::numeric,
          (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric, (v_m ->> 'coverage')::numeric, v_m);
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_backtest(UUID, DATE, DATE) FROM PUBLIC, anon, authenticated;

-- 上線實績：已結束的被排程候選 + 近 7 天預選採納率
CREATE OR REPLACE FUNCTION public.reco_eval_live(p_tenant UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows   JSONB;
  v_m      JSONB;
  v_accept NUMERIC;
  v_dec    JSONB;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('pred', predicted, 'low', low, 'high', high, 'actual', buyers_final))
    INTO v_rows
    FROM reco_outcomes
   WHERE tenant_id = p_tenant AND settled AND start_date >= current_date - 56;
  v_m := public._reco_eval_metrics(v_rows);

  SELECT jsonb_build_object('accepted', count(*) FILTER (WHERE status = 'accepted'),
                            'skipped', count(*) FILTER (WHERE status = 'skipped'),
                            'expired', count(*) FILTER (WHERE status = 'expired')),
         round(count(*) FILTER (WHERE status = 'accepted')::numeric / NULLIF(count(*), 0), 3)
    INTO v_dec, v_accept
    FROM reco_slates
   WHERE tenant_id = p_tenant AND status <> 'suggested' AND slate_date > current_date - 7;

  v_m := v_m || jsonb_build_object('slates', v_dec);
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, accept_rate, details)
  VALUES (p_tenant, 'live', 'v1', current_date - 56, current_date, COALESCE((v_m ->> 'n')::int, 0),
          (v_m ->> 'rho')::numeric, (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric,
          (v_m ->> 'top_bottom_ratio')::numeric, (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric,
          (v_m ->> 'coverage')::numeric, v_accept, v_m);
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_live(UUID) FROM PUBLIC, anon, authenticated;

-- 每週一：回測 3～4 週前那一週（已經結束）+ 上線實績
CREATE OR REPLACE FUNCTION public.reco_eval_weekly()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t   RECORD;
  v_n INT := 0;
  v_today DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  PERFORM public.reco_refresh_campaign_buyers(200);
  PERFORM public.reco_refresh_outcomes();
  FOR t IN SELECT DISTINCT tenant_id FROM reco_campaign_buyers LOOP
    PERFORM public.reco_eval_backtest(t.tenant_id, v_today - 28, v_today - 22);
    PERFORM public.reco_eval_live(t.tenant_id);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_weekly() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('reco-outcomes', 'reco-eval');
SELECT cron.schedule('reco-outcomes', '41 * * * *', $cron$ SELECT public.reco_refresh_outcomes(); $cron$);
SELECT cron.schedule('reco-eval', '37 20 * * 0', $cron$ SELECT public.reco_eval_weekly(); $cron$);  -- 週一 04:37 台北

-- 第一次：回寫 + 回測最近 4 個已結束的週 + 上線實績（目前還沒有，n=0）
SELECT public.reco_refresh_outcomes();
SELECT public.reco_eval_backtest(t.tenant_id, w.d - 6, w.d)
  FROM (SELECT DISTINCT tenant_id FROM public.reco_campaign_buyers) t,
       (SELECT ((now() AT TIME ZONE 'Asia/Taipei')::date - 22 - 7 * g) AS d FROM generate_series(3, 0, -1) g) w;
SELECT public.reco_eval_live(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_campaign_buyers) t;
