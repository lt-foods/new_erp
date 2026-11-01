-- ============================================================================
-- 週曆：店長唯讀 + 每個排程標「人工排 / 系統推薦」，推薦成效頁比較兩邊（20261101000240）
--
-- Alex 2026-11-01：「店長也要可以看到週曆但是不能拖拉編輯；人工排的跟系統推薦的要分得出來，
-- 之後要看人排的比較好還是系統推薦的」。
--
-- 1. 來源 _reco_schedule_source(candidate)：
--      reco_explore / reco = 從週曆系統預選按「排入」（reco_slates accepted 且 decided_by 有值；
--                           新嘗試名額的是 reco_explore）
--      manual             = 其他（候選池自己挑的；就算剛好也在預選裡、但不是從預選按的，也算人工）
-- 2. rpc_calendar_week(from, to)：週曆改走這支讀。總部角色（同候選池 RLS）＋ store_manager 可讀；
--    成本 / 售價 / 廠商只回給總部角色（canSeeCost），店長拿到 NULL。
--    候選池表本身的 RLS 不放寬 —— 店長只能透過這支看到「已排程」的那幾筆。
-- 3. reco_outcomes：
--    - 加 source；11/1 起排程的全部收（人工排的多半沒有預估 → predicted 等欄位放寬可 NULL）。
--    - reco_refresh_outcomes（基底 20261101000180，唯一前版）：收全部、來源每次重算到結束為止。
--    - reco_eval_live（基底 20261101000180，唯一前版）：準度只算有預估的。
--    比較表在推薦成效頁前端算（已結束的平均 / 中位數 / 24 小時買家，分來源）。
--
-- rollback：
--   DROP FUNCTION public.rpc_calendar_week(DATE, DATE), public._reco_schedule_source(BIGINT);
--   重跑 20261101000180 的 reco_refresh_outcomes 與 reco_eval_live；
--   DELETE FROM reco_outcomes WHERE predicted IS NULL; ALTER TABLE reco_outcomes DROP COLUMN source;
--   再把 predicted / low / high / confidence / model_version 設回 NOT NULL。
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

-- 週曆讀取（總部可編輯、店長唯讀；編輯照舊直接寫候選池表，RLS 只開給總部）
CREATE OR REPLACE FUNCTION public.rpc_calendar_week(p_from DATE, p_to DATE)
RETURNS TABLE (
  id BIGINT, product_name_hint TEXT, scheduled_open_at DATE, scheduled_sort_order INT, owner_action TEXT,
  created_at TIMESTAMPTZ, adopted_supplier_name TEXT, adopted_cost NUMERIC, adopted_sale_price NUMERIC,
  source TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_hq     BOOLEAN := v_role IN ('owner', 'admin', 'hq_manager', 'assistant', '');
  v_cost   BOOLEAN := v_role IN ('owner', 'admin', 'hq_manager', 'hq_accountant', '');
BEGIN
  IF v_tenant IS NULL OR NOT (v_hq OR v_role = 'store_manager') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN QUERY
  SELECT c.id, c.product_name_hint, c.scheduled_open_at, c.scheduled_sort_order, c.owner_action, c.created_at,
         CASE WHEN v_cost THEN c.adopted_supplier_name END,
         CASE WHEN v_cost THEN c.adopted_cost END,
         CASE WHEN v_cost THEN c.adopted_sale_price END,
         public._reco_schedule_source(c.id)
    FROM community_product_candidates c
   WHERE c.tenant_id = v_tenant
     AND c.scheduled_open_at IS NOT NULL
     AND c.scheduled_open_at BETWEEN p_from AND p_to
   ORDER BY c.scheduled_open_at, c.scheduled_sort_order NULLS LAST, c.created_at;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_calendar_week(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_calendar_week(DATE, DATE) TO authenticated;

-- reco_outcomes：人工排的也收
ALTER TABLE public.reco_outcomes
  ADD COLUMN IF NOT EXISTS source TEXT CHECK (source IN ('manual', 'reco', 'reco_explore')),
  ALTER COLUMN model_version DROP NOT NULL,
  ALTER COLUMN predicted DROP NOT NULL,
  ALTER COLUMN low DROP NOT NULL,
  ALTER COLUMN high DROP NOT NULL,
  ALTER COLUMN confidence DROP NOT NULL;
COMMENT ON COLUMN public.reco_outcomes.source IS
  'manual = 人工排；reco = 週曆系統預選排入；reco_explore = 系統預選的新嘗試名額（20261101000240）';

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
                             slate_status, scheduled_at, source)
  SELECT c.id, c.tenant_id, c.adopted_product_id, p.model_version, p.buyers, p.low, p.high, p.confidence,
         (SELECT s.status FROM reco_slates s WHERE s.candidate_id = c.id AND s.status = 'accepted' LIMIT 1),
         c.scheduled_at, public._reco_schedule_source(c.id)
    FROM community_product_candidates c
    LEFT JOIN reco_predictions p ON p.candidate_id = c.id
   WHERE c.owner_action IN ('scheduled', 'adopted')
     AND (p.candidate_id IS NOT NULL OR c.scheduled_at >= TIMESTAMPTZ '2026-11-01 00:00+08')
  ON CONFLICT (candidate_id) DO NOTHING;

  -- 來源可能晚一步才確定（週曆「排入」是先排程、再記 accepted）→ 還沒結束的每次重算
  UPDATE reco_outcomes o SET source = public._reco_schedule_source(o.candidate_id)
   WHERE NOT o.settled AND o.source IS DISTINCT FROM public._reco_schedule_source(o.candidate_id);

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
   WHERE tenant_id = p_tenant AND settled AND start_date >= current_date - 56 AND predicted IS NOT NULL;
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

-- 補來源、補收 11/1 起人工排的
UPDATE public.reco_outcomes SET source = public._reco_schedule_source(candidate_id) WHERE source IS NULL;
SELECT public.reco_refresh_outcomes();
