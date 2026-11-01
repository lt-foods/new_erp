-- ============================================================================
-- 開團列表：每一團標「人工排 / 系統推薦」＋預估人數（20261101000250）
--
-- Alex 2026-11-01：「可以在開團那邊標註是人工排的還是系統排的，然後兩個都出現預估人數」。
--
-- reco_campaign_predictions（一團一列）：總倉團（owner_store_id IS NULL）近 60 天～未來 30 天，
--   用「開團那天之前」就知道的資料算 v3 預估（_reco_features_campaign；跟回測版
--   _reco_features_asof 唯一差別是同一個商品自己以前的成績也算進最像的商品）。
--   人工排、系統推薦用同一套算，兩邊才比得起來。
--   開團前每 6 小時重算；開團之後凍結（那就是開團前的預估，不再改）。
-- 來源：開團的商品 = 某個候選排程時建的商品（adopted_product_id）→ 照 _reco_schedule_source；
--   其他（直接開團、不是從候選來的）都算人工排。
-- 排程 reco-campaign-predict 每 10 分鐘補 500 團。讀權限：同租戶的登入者（開團頁分店也會看）。
--
-- _reco_schedule_source 跟 20261101000240 的定義一字不差（兩支 PR 誰先套都可以）。
-- rollback：
--   SELECT cron.unschedule('reco-campaign-predict');
--   DROP FUNCTION public.reco_refresh_campaign_predictions(INT), public._reco_campaign_source(BIGINT),
--     public._reco_features_campaign(UUID, BIGINT, DATE, NUMERIC);
--   DROP TABLE public.reco_campaign_predictions;
-- ============================================================================

CREATE OR REPLACE FUNCTION public._reco_schedule_source(p_candidate_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT CASE WHEN s.pick_kind = 'explore' THEN 'reco_explore' ELSE 'reco' END
       FROM reco_slates s
      WHERE s.candidate_id = p_candidate_id AND s.status = 'accepted' AND s.decided_by IS NOT NULL
      ORDER BY s.decided_at DESC LIMIT 1),
    'manual');
$$;
REVOKE ALL ON FUNCTION public._reco_schedule_source(BIGINT) FROM PUBLIC, anon, authenticated;

-- 開團的來源
CREATE OR REPLACE FUNCTION public._reco_campaign_source(p_campaign_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT public._reco_schedule_source(c.id)
       FROM group_buy_campaigns g
       JOIN community_product_candidates c ON c.adopted_product_id = g.product_id AND c.tenant_id = g.tenant_id
      WHERE g.id = p_campaign_id AND c.owner_action IN ('scheduled', 'adopted')
      ORDER BY c.scheduled_at DESC NULLS LAST LIMIT 1),
    'manual');
$$;
REVOKE ALL ON FUNCTION public._reco_campaign_source(BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._reco_features_campaign(p_tenant UUID, p_product BIGINT, p_d DATE, p_price NUMERIC)
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
  v_tagn INT;
  v_glob NUMERIC;
  v_food BOOLEAN;
  v_list JSONB;
BEGIN
  SELECT embedding INTO v_emb FROM product_embeddings WHERE product_id = p_product;
  IF v_emb IS NULL THEN RETURN NULL; END IF;
  SELECT sum(power(h.cos, 4) * h.b) / NULLIF(sum(power(h.cos, 4)), 0), max(h.cos),
         jsonb_agg(jsonb_build_object('product_id', h.product_id, 'name', p.name, 'cos', round(h.cos, 3),
                                      'buyers', round(h.b, 1), 'campaigns', h.camps) ORDER BY h.cos DESC)
    INTO v_knn, v_top, v_list
    FROM (SELECT n.product_id, n.cos, avg(rb.buyers)::numeric AS b, count(*) AS camps
            FROM (SELECT e.product_id, (1 - (e.embedding <=> v_emb))::numeric AS cos
                    FROM product_embeddings e
                   WHERE e.tenant_id = p_tenant  -- 開團預估：同一個商品以前開過的成績也要算（回測版才排除自己）
                   ORDER BY e.embedding <=> v_emb LIMIT 40) n
            JOIN reco_campaign_buyers rb ON rb.product_id = n.product_id AND rb.settled AND rb.start_date <= p_d - 10
           GROUP BY 1, 2 ORDER BY n.cos DESC LIMIT 5) h
    JOIN products p ON p.id = h.product_id;
  SELECT avg(rb.buyers), count(*) INTO v_tag, v_tagn
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
    'knn', COALESCE(v_list, '[]'::jsonb), 'knn_buyers', v_knn, 'top_cos', v_top,
    'tag_prior', v_tag, 'tag_campaigns', COALESCE(v_tagn, 0), 'global_prior', v_glob, 'price', p_price,
    'price_band', CASE WHEN p_price IS NULL OR p_price <= 0 THEN NULL WHEN p_price < 200 THEN 'lt200'
                       WHEN p_price < 300 THEN '200_300' ELSE 'gt300' END,
    'is_food', v_food)
    || public._reco_reopen(p_tenant, v_emb, (p_d::timestamp AT TIME ZONE 'Asia/Taipei'))
    || public._reco_kind_features(p_tenant, (SELECT pk.kind FROM product_kinds pk WHERE pk.product_id = p_product),
                                  (p_d::timestamp AT TIME ZONE 'Asia/Taipei'), TRUE);
END;
$$;
REVOKE ALL ON FUNCTION public._reco_features_campaign(UUID, BIGINT, DATE, NUMERIC) FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.reco_campaign_predictions (
  campaign_id   BIGINT PRIMARY KEY REFERENCES public.group_buy_campaigns(id) ON DELETE CASCADE,
  tenant_id     UUID   NOT NULL,
  product_id    BIGINT,
  source        TEXT   NOT NULL CHECK (source IN ('manual', 'reco', 'reco_explore')),
  model_version TEXT,
  buyers        INT,
  low           INT,
  high          INT,
  confidence    TEXT,
  reasons       TEXT[],
  computed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.reco_campaign_predictions IS
  '開團的來源（人工排 / 系統推薦）與開團前預估人數；開團後凍結（20261101000250）';
ALTER TABLE public.reco_campaign_predictions ENABLE ROW LEVEL SECURITY;
CREATE POLICY reco_campaign_predictions_read ON public.reco_campaign_predictions FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid);
GRANT SELECT ON public.reco_campaign_predictions TO authenticated;

CREATE OR REPLACE FUNCTION public.reco_refresh_campaign_predictions(p_limit INT DEFAULT 500)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r     RECORD;
  v_f   JSONB;
  v_p   JSONB;
  v_n   INT := 0;
BEGIN
  FOR r IN
    SELECT g.id, g.tenant_id, g.product_id, (g.start_at AT TIME ZONE 'Asia/Taipei')::date AS d,
           (SELECT min(ci.unit_price) FROM campaign_items ci
             WHERE ci.campaign_id = g.id AND NOT COALESCE(ci.is_gift, FALSE)) AS price
      FROM group_buy_campaigns g
      LEFT JOIN reco_campaign_predictions p ON p.campaign_id = g.id
     WHERE g.owner_store_id IS NULL AND g.product_id IS NOT NULL AND g.status <> 'cancelled'
       AND g.campaign_no <> '__INTERNAL_RESTOCK__'
       AND g.start_at BETWEEN now() - interval '60 days' AND now() + interval '30 days'
       -- 沒算過的；還沒開團、超過 6 小時的重算（開團後凍結）
       AND (p.campaign_id IS NULL OR (g.start_at > now() AND p.computed_at < now() - interval '6 hours'))
     ORDER BY p.computed_at NULLS FIRST, g.start_at DESC
     LIMIT GREATEST(COALESCE(p_limit, 500), 1)
  LOOP
    v_f := public._reco_features_campaign(r.tenant_id, r.product_id, r.d, r.price);
    v_p := CASE WHEN v_f IS NULL THEN NULL ELSE public.reco_predict_v3(v_f) END;
    INSERT INTO reco_campaign_predictions AS cp
      (campaign_id, tenant_id, product_id, source, model_version, buyers, low, high, confidence, reasons, computed_at)
    VALUES (r.id, r.tenant_id, r.product_id, public._reco_campaign_source(r.id),
            CASE WHEN v_p IS NOT NULL THEN 'v3' END,
            (v_p ->> 'buyers')::int, (v_p ->> 'low')::int, (v_p ->> 'high')::int, v_p ->> 'confidence',
            CASE WHEN v_p IS NOT NULL THEN ARRAY(SELECT jsonb_array_elements_text(v_p -> 'reasons')) END, now())
    ON CONFLICT (campaign_id) DO UPDATE
       SET product_id = EXCLUDED.product_id, source = EXCLUDED.source, model_version = EXCLUDED.model_version,
           buyers = EXCLUDED.buyers, low = EXCLUDED.low, high = EXCLUDED.high, confidence = EXCLUDED.confidence,
           reasons = EXCLUDED.reasons, computed_at = now();
    v_n := v_n + 1;
  END LOOP;
  -- 來源可能在算完預估之後才確定（週曆排入、候選後來才被排程）→ 便宜，全部對一次
  UPDATE reco_campaign_predictions cp SET source = public._reco_campaign_source(cp.campaign_id)
   WHERE cp.source IS DISTINCT FROM public._reco_campaign_source(cp.campaign_id)
     AND cp.computed_at > now() - interval '90 days';
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_refresh_campaign_predictions(INT) FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'reco-campaign-predict';
SELECT cron.schedule('reco-campaign-predict', '*/10 * * * *', $cron$ SELECT public.reco_refresh_campaign_predictions(500); $cron$);

-- 先算一批（剩下的排程 10 分鐘內補）
SELECT public.reco_refresh_campaign_predictions(600);
