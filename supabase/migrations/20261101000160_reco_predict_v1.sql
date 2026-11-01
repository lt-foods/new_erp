-- ============================================================================
-- 推薦系統 M1：④ 特徵 + ⑤ 預測 v1（20261101000160）
--
-- 架構見 docs/PLAN-選品系統-外部來源與商品媒合.md「零、模組化架構」。
-- 每個模組只寫自己的表：
--   reco_campaign_buyers  每團實際買家數（④ 的歷史來源，夜間重算近 200 天）
--   reco_features         候選品的特徵（一品一列 jsonb，feature_version）
--   reco_predictions      預估買家數、區間、信心、理由（model_version）
--
-- 預測 v1（2026-11-01 回測：10/1～10/25 第一次開的 818 團，Spearman ρ = 0.82）：
--   raw  = (0.6 × 最像 5 個已賣商品的每團買家（相似度⁴加權）+ 0.4 × 同標籤近 5 週已結束的團每團買家)
--          × 價格帶（<200 ×1.25、200～300 ×0.85、>300 ×0.3）
--   預估 = raw × 0.6（回測實際/預估中位數 0.58，校正高估）
--   區間 = 預估 × 回測 P20～P80 的實際/預估比（依最像相似度分三級，見 _reco_band）
--   信心：最像相似度 ≥0.85 高（賣過）、≥0.75 中、其餘低
-- 價格用候選品上的廠商報價；回測用的是實際開團售價，上線後由 ⑨ 評估再驗。
-- 0 買家的團佔回測 26～37%，所以區間下限常是 0 —— 那是真的，不要藏。
--
-- ⚠ 還在變的團不能當歷史（Alex 2026-11-01）：開團中 / 已收單（還能加單）/ 已鎖定但還沒到貨
--   的團，買家數還會變（加單、斷貨取消）。reco_campaign_buyers.settled = 已鎖定以後的狀態
--   且（已到貨 或 開團滿 21 天）才進 knn 與同類平均。沒結束的同款另外記成 recent_open，
--   理由寫「同款 X 10/28 剛開、還沒到貨」，⑥ 推薦排預選時避開。
--
-- 目前只算「廠商群組」來源的候選（有品項向量的）；社群機器人那批沒有品項，M4 再補。
-- 排程：reco-campaign-buyers 每晚台北 03:27；reco-predict 每 10 分鐘補算新的／過期的。
--
-- 新表、新函式，沒有改既有函式。
-- rollback：
--   SELECT cron.unschedule('reco-predict'); SELECT cron.unschedule('reco-campaign-buyers');
--   DROP FUNCTION public.reco_refresh_predictions(INT), public.reco_predict_v1(JSONB),
--     public.reco_compute_features(BIGINT), public._reco_band(TEXT),
--     public.reco_refresh_campaign_buyers(INT);
--   DROP TABLE public.reco_predictions, public.reco_features, public.reco_campaign_buyers;
-- ============================================================================

-- ── 每團實際買家 ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reco_campaign_buyers (
  campaign_id  BIGINT PRIMARY KEY REFERENCES public.group_buy_campaigns(id) ON DELETE CASCADE,
  tenant_id    UUID   NOT NULL,
  product_id   BIGINT NOT NULL,
  start_date   DATE   NOT NULL,
  buyers       INT    NOT NULL,
  price        NUMERIC,
  status       TEXT   NOT NULL,
  arrived      BOOLEAN NOT NULL DEFAULT FALSE,
  settled      BOOLEAN NOT NULL DEFAULT FALSE,
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rcb_product ON public.reco_campaign_buyers (product_id, start_date) WHERE settled;
CREATE INDEX IF NOT EXISTS idx_rcb_tenant_date ON public.reco_campaign_buyers (tenant_id, start_date);
COMMENT ON TABLE public.reco_campaign_buyers IS
  '推薦系統：每團實際買家數（排除 store_internal、取消/逾期/轉出；只算總倉團 owner_store_id IS NULL）。'
  'settled = 已鎖定以後且（已到貨或開團滿 21 天），只有 settled 的能當歷史。reco_refresh_campaign_buyers 夜間重算';

CREATE OR REPLACE FUNCTION public.reco_refresh_campaign_buyers(p_days INT DEFAULT 200)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  WITH g AS (
    SELECT g.id, g.tenant_id, g.product_id, g.start_at::date AS d, g.status, g.start_at
      FROM group_buy_campaigns g
     WHERE g.product_id IS NOT NULL AND g.owner_store_id IS NULL
       AND g.status NOT IN ('cancelled', 'draft')
       AND g.start_at >= now() - make_interval(days => GREATEST(p_days, 1))
  ), b AS (
    SELECT co.campaign_id, count(DISTINCT co.member_id) AS buyers
      FROM customer_orders co
      JOIN members m ON m.id = co.member_id
     WHERE co.campaign_id IN (SELECT id FROM g)
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND COALESCE(m.member_type, '') <> 'store_internal'
     GROUP BY 1
  ), a AS (
    -- 到貨：單頭被推到可取／部分取／完成（CLAUDE.md：到貨看單頭 status，不看取貨閘門）
    SELECT DISTINCT co.campaign_id
      FROM customer_orders co
     WHERE co.campaign_id IN (SELECT id FROM g)
       AND co.status IN ('ready', 'partially_completed', 'completed')
  ), p AS (
    SELECT ci.campaign_id, min(ci.unit_price) AS price
      FROM campaign_items ci
     WHERE ci.campaign_id IN (SELECT id FROM g) AND NOT COALESCE(ci.is_gift, FALSE)
     GROUP BY 1
  )
  INSERT INTO reco_campaign_buyers AS r
    (campaign_id, tenant_id, product_id, start_date, buyers, price, status, arrived, settled, refreshed_at)
  SELECT g.id, g.tenant_id, g.product_id, g.d, COALESCE(b.buyers, 0), p.price, g.status, a.campaign_id IS NOT NULL,
         g.status IN ('locked', 'ordered', 'receiving', 'ready', 'completed')
           AND (a.campaign_id IS NOT NULL OR g.start_at < now() - interval '21 days'),
         now()
    FROM g LEFT JOIN b ON b.campaign_id = g.id LEFT JOIN a ON a.campaign_id = g.id LEFT JOIN p ON p.campaign_id = g.id
  ON CONFLICT (campaign_id) DO UPDATE
     SET product_id = EXCLUDED.product_id, start_date = EXCLUDED.start_date, buyers = EXCLUDED.buyers,
         price = EXCLUDED.price, status = EXCLUDED.status, arrived = EXCLUDED.arrived, settled = EXCLUDED.settled,
         refreshed_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- 團被取消／改成分店團 → 移掉
  DELETE FROM reco_campaign_buyers r
   WHERE NOT EXISTS (SELECT 1 FROM group_buy_campaigns g
                      WHERE g.id = r.campaign_id AND g.owner_store_id IS NULL AND g.status NOT IN ('cancelled', 'draft'));
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_refresh_campaign_buyers(INT) FROM PUBLIC, anon, authenticated;

-- ── 特徵 / 預測 ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reco_features (
  candidate_id    BIGINT PRIMARY KEY REFERENCES public.community_product_candidates(id) ON DELETE CASCADE,
  tenant_id       UUID   NOT NULL,
  feature_version TEXT   NOT NULL,
  features        JSONB  NOT NULL,
  computed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.reco_features IS '推薦系統 ④：候選品特徵（開團前就知道的值），reco_compute_features 算';

CREATE TABLE IF NOT EXISTS public.reco_predictions (
  candidate_id  BIGINT PRIMARY KEY REFERENCES public.community_product_candidates(id) ON DELETE CASCADE,
  tenant_id     UUID   NOT NULL,
  model_version TEXT   NOT NULL,
  buyers        INT    NOT NULL,
  low           INT    NOT NULL,
  high          INT    NOT NULL,
  confidence    TEXT   NOT NULL CHECK (confidence IN ('high', 'mid', 'low')),
  reasons       TEXT[] NOT NULL DEFAULT '{}',
  recent_open   BOOLEAN NOT NULL DEFAULT FALSE,
  computed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reco_pred_tenant_buyers ON public.reco_predictions (tenant_id, buyers DESC);
COMMENT ON TABLE public.reco_predictions IS '推薦系統 ⑤：候選品預估買家數（目前模型的結果；一個候選一列）';

ALTER TABLE public.reco_campaign_buyers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reco_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reco_predictions ENABLE ROW LEVEL SECURITY;
-- 讀權限比照候選池（ccp_hq_all）：同租戶的總部角色
CREATE POLICY reco_features_hq_read ON public.reco_features FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
CREATE POLICY reco_predictions_hq_read ON public.reco_predictions FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
CREATE POLICY reco_campaign_buyers_hq_read ON public.reco_campaign_buyers FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.reco_features, public.reco_predictions, public.reco_campaign_buyers TO authenticated;

-- ④ 一個候選品的特徵（v1）。沒有品項或品項還沒向量 → NULL（還不能算）
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
BEGIN
  SELECT * INTO v_c FROM community_product_candidates WHERE id = p_candidate_id;
  IF NOT FOUND OR (v_c.raw ->> 'market_item_id') IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_i FROM line_note_market_items WHERE id = (v_c.raw ->> 'market_item_id')::bigint;
  IF NOT FOUND OR v_i.embedding IS NULL THEN RETURN NULL; END IF;

  -- 溫層標籤不算類別
  SELECT COALESCE(array_agg(t.code), '{}') INTO v_tags
    FROM unnest(COALESCE(v_i.tags, '{}')) AS x(code)
    JOIN product_tags t ON t.code = x.code AND t.tenant_id = v_c.tenant_id AND t.tag_group <> '溫層';

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

  -- 擁擠度：同類未來 7 天已排幾團（v1 只記錄、顯示，不進公式）
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
    'recent_open', COALESCE(v_recent, '[]'::jsonb));
END;
$$;
REVOKE ALL ON FUNCTION public.reco_compute_features(BIGINT) FROM PUBLIC, anon, authenticated;

-- 回測的實際/預估比 P20、P80（校正後），依最像相似度三級
CREATE OR REPLACE FUNCTION public._reco_band(p_conf TEXT)
RETURNS NUMERIC[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_conf
           WHEN 'high' THEN ARRAY[0.0, 2.0]
           WHEN 'mid'  THEN ARRAY[0.0, 2.8]
           ELSE             ARRAY[0.45, 2.2]
         END::numeric[];
$$;

-- ⑤ 預測 v1：純函式，吃特徵回結果（換模型＝加一支 reco_predict_v2，不改這支）
CREATE OR REPLACE FUNCTION public.reco_predict_v1(p_f JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_knn   NUMERIC := NULLIF(p_f ->> 'knn_buyers', '')::numeric;
  v_tag   NUMERIC := COALESCE(NULLIF(p_f ->> 'tag_prior', '')::numeric, NULLIF(p_f ->> 'global_prior', '')::numeric);
  v_top   NUMERIC := COALESCE(NULLIF(p_f ->> 'top_cos', '')::numeric, 0);
  v_band  TEXT    := p_f ->> 'price_band';
  v_pm    NUMERIC;
  v_raw   NUMERIC;
  v_est   NUMERIC;
  v_conf  TEXT;
  v_rng   NUMERIC[];
  v_rs    TEXT[] := '{}';
  v_first JSONB  := p_f -> 'knn' -> 0;
BEGIN
  IF v_knn IS NULL AND v_tag IS NULL THEN RETURN NULL; END IF;
  v_pm := CASE v_band WHEN 'lt200' THEN 1.25 WHEN '200_300' THEN 0.85 WHEN 'gt300' THEN 0.3 ELSE 1 END;
  v_raw := COALESCE(0.6 * v_knn + 0.4 * COALESCE(v_tag, v_knn), v_tag) * v_pm;
  v_est := v_raw * 0.6;
  v_conf := CASE WHEN v_top >= 0.85 THEN 'high' WHEN v_top >= 0.75 THEN 'mid' ELSE 'low' END;
  v_rng := public._reco_band(v_conf);

  IF v_first IS NOT NULL THEN
    v_rs := v_rs || format('%s「%s」每團 %s 人（開過 %s 團）',
                           CASE WHEN v_top >= 0.85 THEN '賣過：' ELSE '最像：' END,
                           v_first ->> 'name', round((v_first ->> 'buyers')::numeric), v_first ->> 'campaigns');
  END IF;
  IF NULLIF(p_f ->> 'tag_prior', '') IS NOT NULL THEN
    v_rs := v_rs || format('同類近 5 週每團 %s 人（%s 團）', round((p_f ->> 'tag_prior')::numeric), p_f ->> 'tag_campaigns');
  END IF;
  IF v_band IS NOT NULL THEN
    v_rs := v_rs || format('報價 $%s%s', round((p_f ->> 'price')::numeric),
                           CASE v_band WHEN 'gt300' THEN '（300 以上買的人少很多）'
                                       WHEN '200_300' THEN '（200～300 略降）' ELSE '' END);
  END IF;
  IF jsonb_array_length(COALESCE(p_f -> 'recent_open', '[]'::jsonb)) > 0 THEN
    v_rs := format('⚠ 同款「%s」%s %s',
                   p_f -> 'recent_open' -> 0 ->> 'name',
                   to_char((p_f -> 'recent_open' -> 0 ->> 'start')::date, 'MM/DD'),
                   CASE p_f -> 'recent_open' -> 0 ->> 'status'
                     WHEN 'draft' THEN '已排草稿' WHEN 'open' THEN '開團中' WHEN 'closed' THEN '已收單'
                     ELSE '開的，還沒到貨' END) || v_rs;
  END IF;
  IF COALESCE((p_f ->> 'crowding')::int, 0) >= 16 THEN
    v_rs := v_rs || format('同類未來 7 天已排 %s 團，偏擠', p_f ->> 'crowding');
  END IF;

  RETURN jsonb_build_object(
    'buyers', round(v_est), 'low', floor(v_est * v_rng[1]), 'high', ceil(v_est * v_rng[2]),
    'confidence', v_conf, 'reasons', to_jsonb(v_rs),
    'recent_open', jsonb_array_length(COALESCE(p_f -> 'recent_open', '[]'::jsonb)) > 0);
END;
$$;

-- 補算：新的、候選有改過的、超過 6 小時的（同款開團／到貨狀態會變）。只算還在池子裡（未處理／收藏、14 天內）的
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
    VALUES (r.id, r.tenant_id, 'f1', v_f, now())
    ON CONFLICT (candidate_id) DO UPDATE
       SET feature_version = EXCLUDED.feature_version, features = EXCLUDED.features, computed_at = now();
    v_p := public.reco_predict_v1(v_f);
    CONTINUE WHEN v_p IS NULL;
    INSERT INTO reco_predictions (candidate_id, tenant_id, model_version, buyers, low, high, confidence, reasons, recent_open, computed_at)
    VALUES (r.id, r.tenant_id, 'v1', (v_p ->> 'buyers')::int, (v_p ->> 'low')::int, (v_p ->> 'high')::int,
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

-- 排程
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('reco-campaign-buyers', 'reco-predict');
SELECT cron.schedule('reco-campaign-buyers', '27 19 * * *', $cron$ SELECT public.reco_refresh_campaign_buyers(200); $cron$);
SELECT cron.schedule('reco-predict', '*/10 * * * *', $cron$ SELECT public.reco_refresh_predictions(300); $cron$);

-- 第一次填
SELECT public.reco_refresh_campaign_buyers(200);
SELECT public.reco_refresh_predictions(500);
