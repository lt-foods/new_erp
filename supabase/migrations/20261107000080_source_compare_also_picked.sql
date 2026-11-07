-- ============================================================================
-- 「系統也有選」記進結果，人工排 vs 系統推薦拆成四組（Alex 2026-11-07：「這樣是不是也可以再回歸回去」）
--
-- 20261107000070 讓週曆能標出「人工排、但系統預選也有選到同一樣」。這支把同一個判斷記下來，
-- 之後週報和「人工排 vs 系統推薦」比較表就能分四組看：
--   manual_also_picked（人排、系統也選到）/ manual（人排、系統沒選到）/ reco（系統選、人按排入）/ reco_explore
-- 等樣本夠了（11/7 時人工排只結束 3 團、系統排 0 團）才回答得了「系統沒選到但人排了的，是人比系統準、
-- 還是系統漏掉的類別」。
--
-- 改四處：
--   1. reco_campaign_predictions 加 also_picked BOOLEAN；reco_refresh_campaign_predictions（基底 20261101000250）
--      寫入時算、人工排且近 45 天開的每 10 分鐘對一次（預選可能在排程之後才出現，±14 天；11/7 實測 ~1.4s）。
--      判斷走新的 _reco_campaign_also_picked（跟 _reco_campaign_source 同一套「團 → 候選」對法）。
--   2. reco_outcomes 加 also_picked JSONB；reco_refresh_outcomes（基底 20261101000240）寫入時算、沒結束的人工排每小時對一次。
--   3. rpc_reco_source_compare（基底 20261101000260）：source 多一個值 'manual_also_picked'（前端照此分行）。
--   4. reco_eval_live（基底 20261101000240）：details 多 by_source（四組的 n / 平均 / 中位數 / hit_rate / beat_rate）
--      與 hit_threshold。hit = 買家數 ≥ 這 56 天所有已結束團的中位數（跟 reco_tag_stats 的「中」同一個定義）。
--
-- rollback：重跑上面四支的基底定義；DROP FUNCTION public._reco_campaign_also_picked(BIGINT);
--   ALTER TABLE reco_campaign_predictions DROP COLUMN also_picked; ALTER TABLE reco_outcomes DROP COLUMN also_picked;
--   （前端 performance 頁的 manual_also_picked 那一列會變成空的，不會壞）
-- ============================================================================

ALTER TABLE public.reco_campaign_predictions ADD COLUMN IF NOT EXISTS also_picked BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.reco_outcomes ADD COLUMN IF NOT EXISTS also_picked JSONB;
COMMENT ON COLUMN public.reco_campaign_predictions.also_picked IS '人工排的團，系統預選也有選到同一樣（_reco_also_picked，20261107000080）';
COMMENT ON COLUMN public.reco_outcomes.also_picked IS '人工排的候選，系統預選也有選到同一樣：{via, slate_date, status, pick_kind, predicted, item_name, cos}（20261107000080）';

CREATE OR REPLACE FUNCTION public._reco_campaign_also_picked(p_campaign_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT public._reco_schedule_source(c.id) = 'manual' AND public._reco_also_picked(c.id) IS NOT NULL
       FROM group_buy_campaigns g
       JOIN community_product_candidates c ON c.adopted_product_id = g.product_id AND c.tenant_id = g.tenant_id
      WHERE g.id = p_campaign_id AND c.owner_action IN ('scheduled', 'adopted')
      ORDER BY c.scheduled_at DESC NULLS LAST LIMIT 1),
    FALSE);
$$;
REVOKE ALL ON FUNCTION public._reco_campaign_also_picked(BIGINT) FROM PUBLIC, anon, authenticated;

-- 1. reco_refresh_campaign_predictions（基底 20261101000250）
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
      (campaign_id, tenant_id, product_id, source, also_picked, model_version, buyers, low, high, confidence, reasons, computed_at)
    VALUES (r.id, r.tenant_id, r.product_id, public._reco_campaign_source(r.id), public._reco_campaign_also_picked(r.id),
            CASE WHEN v_p IS NOT NULL THEN 'v3' END,
            (v_p ->> 'buyers')::int, (v_p ->> 'low')::int, (v_p ->> 'high')::int, v_p ->> 'confidence',
            CASE WHEN v_p IS NOT NULL THEN ARRAY(SELECT jsonb_array_elements_text(v_p -> 'reasons')) END, now())
    ON CONFLICT (campaign_id) DO UPDATE
       SET product_id = EXCLUDED.product_id, source = EXCLUDED.source, also_picked = EXCLUDED.also_picked,
           model_version = EXCLUDED.model_version,
           buyers = EXCLUDED.buyers, low = EXCLUDED.low, high = EXCLUDED.high, confidence = EXCLUDED.confidence,
           reasons = EXCLUDED.reasons, computed_at = now();
    v_n := v_n + 1;
  END LOOP;
  -- 來源可能在算完預估之後才確定（週曆排入、候選後來才被排程）→ 便宜，全部對一次
  UPDATE reco_campaign_predictions cp SET source = public._reco_campaign_source(cp.campaign_id)
   WHERE cp.source IS DISTINCT FROM public._reco_campaign_source(cp.campaign_id)
     AND cp.computed_at > now() - interval '90 days';
  -- 系統也有選：預選可能在排程之後才出現（±14 天）→ 人工排、近 45 天開的每次對一次（11/7 實測 ~1.4s）
  UPDATE reco_campaign_predictions cp SET also_picked = public._reco_campaign_also_picked(cp.campaign_id)
    FROM group_buy_campaigns g
   WHERE g.id = cp.campaign_id AND cp.source = 'manual'
     AND g.start_at > now() - interval '45 days'
     AND cp.also_picked IS DISTINCT FROM public._reco_campaign_also_picked(cp.campaign_id);
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_refresh_campaign_predictions(INT) FROM PUBLIC, anon, authenticated;

-- 2. reco_refresh_outcomes（基底 20261101000240）
CREATE OR REPLACE FUNCTION public.reco_refresh_outcomes()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  -- 1. 新被排程的 → 抄預估（有的話）。11/1 系統上線起排的全部收（人工排的多半沒有預估，也要拿來比）
  INSERT INTO reco_outcomes (candidate_id, tenant_id, product_id, model_version, predicted, low, high, confidence,
                             slate_status, scheduled_at, source, also_picked)
  SELECT c.id, c.tenant_id, c.adopted_product_id, p.model_version, p.buyers, p.low, p.high, p.confidence,
         (SELECT s.status FROM reco_slates s WHERE s.candidate_id = c.id AND s.status = 'accepted' LIMIT 1),
         c.scheduled_at, public._reco_schedule_source(c.id),
         CASE WHEN public._reco_schedule_source(c.id) = 'manual' THEN public._reco_also_picked(c.id) END
    FROM community_product_candidates c
    LEFT JOIN reco_predictions p ON p.candidate_id = c.id
   WHERE c.owner_action IN ('scheduled', 'adopted')
     AND (p.candidate_id IS NOT NULL OR c.scheduled_at >= TIMESTAMPTZ '2026-11-01 00:00+08')
  ON CONFLICT (candidate_id) DO NOTHING;

  -- 來源可能晚一步才確定（週曆「排入」是先排程、再記 accepted）→ 還沒結束的每次重算
  UPDATE reco_outcomes o SET source = public._reco_schedule_source(o.candidate_id)
   WHERE NOT o.settled AND o.source IS DISTINCT FROM public._reco_schedule_source(o.candidate_id);
  -- 系統也有選（20261107000080）：預選可能在排程之後才出現（±14 天）→ 還沒結束的人工排每次對一次
  UPDATE reco_outcomes o SET also_picked = public._reco_also_picked(o.candidate_id)
   WHERE NOT o.settled AND o.source = 'manual'
     AND (o.also_picked IS NULL) <> (public._reco_also_picked(o.candidate_id) IS NULL);

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

-- 3. rpc_reco_source_compare（基底 20261101000260）
CREATE OR REPLACE FUNCTION public.rpc_reco_source_compare(p_days INT DEFAULT 30)
RETURNS TABLE (source TEXT, campaigns INT, settled INT, avg_buyers NUMERIC, median_buyers NUMERIC,
               avg_predicted NUMERIC, beat_rate NUMERIC, avg_24h NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
BEGIN
  IF v_tenant IS NULL
     OR COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN QUERY
  WITH g AS (
    SELECT g.id, g.start_at,
           -- 20261107000080：人工排再分「系統也有選」
           CASE WHEN cp.source = 'manual' AND cp.also_picked THEN 'manual_also_picked' ELSE cp.source END AS source,
           cp.buyers AS pred, rb.buyers AS actual, COALESCE(rb.settled, FALSE) AS done
      FROM group_buy_campaigns g
      JOIN reco_campaign_predictions cp ON cp.campaign_id = g.id
      LEFT JOIN reco_campaign_buyers rb ON rb.campaign_id = g.id
     WHERE g.tenant_id = v_tenant AND g.owner_store_id IS NULL AND g.status NOT IN ('cancelled', 'draft')
       AND g.start_at >= now() - make_interval(days => GREATEST(p_days, 1)) AND g.start_at <= now()
  ), b24 AS (
    SELECT g.id, count(DISTINCT co.member_id) AS n
      FROM g
      JOIN customer_orders co ON co.campaign_id = g.id AND co.created_at < g.start_at + interval '24 hours'
      JOIN members m ON m.id = co.member_id
     WHERE g.start_at <= now() - interval '24 hours'
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND COALESCE(m.member_type, '') <> 'store_internal'
     GROUP BY 1
  )
  SELECT g.source,
         count(*)::int,
         count(*) FILTER (WHERE g.done)::int,
         round(avg(g.actual) FILTER (WHERE g.done), 1),
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY g.actual) FILTER (WHERE g.done))::numeric, 1),
         round(avg(g.pred) FILTER (WHERE g.done), 1),
         round(avg(CASE WHEN g.actual >= g.pred THEN 1 ELSE 0 END) FILTER (WHERE g.done AND g.pred IS NOT NULL), 3),
         round(avg(COALESCE(b24.n, 0)) FILTER (WHERE g.start_at <= now() - interval '24 hours'), 1)
    FROM g LEFT JOIN b24 ON b24.id = g.id
   GROUP BY g.source
   ORDER BY g.source;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_reco_source_compare(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reco_source_compare(INT) TO authenticated;

-- 4. reco_eval_live（基底 20261101000240）
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
  v_src    JSONB;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('pred', predicted, 'low', low, 'high', high, 'actual', buyers_final))
    INTO v_rows
    FROM reco_outcomes
   WHERE tenant_id = p_tenant AND settled AND start_date >= current_date - 56 AND predicted IS NOT NULL;
  v_m := public._reco_eval_metrics(v_rows);

  SELECT jsonb_build_object('accepted', count(*) FILTER (WHERE status = 'accepted'),
                            'skipped', count(*) FILTER (WHERE status = 'skipped'),
                            'expired', count(*) FILTER (WHERE status = 'expired')),
         round(count(*) FILTER (WHERE status = 'accepted')::numeric / NULLIF(count(*), 0), 3)
    INTO v_dec, v_accept
    FROM reco_slates
   WHERE tenant_id = p_tenant AND status <> 'suggested' AND slate_date > current_date - 7;

  -- 20261107000080：依來源分四組（人工排・系統也有選 / 人工排 / 系統推薦 / 新嘗試）；
  -- hit = 買家數 ≥ 這段期間所有已結束團的中位數（跟 reco_tag_stats 的「中」同一個定義）
  WITH o AS (
    SELECT CASE WHEN source = 'manual' AND also_picked IS NOT NULL THEN 'manual_also_picked' ELSE COALESCE(source, 'manual') END AS src,
           buyers_final AS actual, predicted AS pred
      FROM reco_outcomes
     WHERE tenant_id = p_tenant AND settled AND start_date >= current_date - 56 AND buyers_final IS NOT NULL
  ), med AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY actual) AS m FROM o)
  SELECT jsonb_object_agg(src, jsonb_build_object(
           'n', n, 'avg_buyers', avg_b, 'median_buyers', med_b, 'hit_rate', hit, 'beat_rate', beat, 'n_pred', n_pred))
    INTO v_src
    FROM (SELECT o.src, count(*) AS n, round(avg(o.actual), 1) AS avg_b,
                 round((percentile_cont(0.5) WITHIN GROUP (ORDER BY o.actual))::numeric, 1) AS med_b,
                 round(avg(CASE WHEN o.actual >= med.m THEN 1 ELSE 0 END), 3) AS hit,
                 round(avg(CASE WHEN o.actual >= o.pred THEN 1 ELSE 0 END) FILTER (WHERE o.pred IS NOT NULL), 3) AS beat,
                 count(o.pred) AS n_pred
            FROM o, med GROUP BY o.src) x;
  v_m := v_m || jsonb_build_object('slates', v_dec, 'by_source', COALESCE(v_src, '{}'::jsonb),
                                   'hit_threshold', (SELECT round(m::numeric, 1) FROM (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY buyers_final) AS m FROM reco_outcomes WHERE tenant_id = p_tenant AND settled AND start_date >= current_date - 56 AND buyers_final IS NOT NULL) t));
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

-- 一次補齊：近 45 天人工排的團、還沒結束的人工排候選
UPDATE public.reco_campaign_predictions cp SET also_picked = public._reco_campaign_also_picked(cp.campaign_id)
  FROM public.group_buy_campaigns g
 WHERE g.id = cp.campaign_id AND cp.source = 'manual' AND g.start_at > now() - interval '45 days';
UPDATE public.reco_outcomes o SET also_picked = public._reco_also_picked(o.candidate_id)
 WHERE o.source = 'manual' AND o.scheduled_at > now() - interval '45 days';
