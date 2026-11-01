-- ============================================================================
-- 推薦系統 M2：⑥ 推薦（每日預選）+ ⑦ 決策紀錄（20261101000170）
--
-- 架構見 docs/PLAN-選品系統-外部來源與商品媒合.md「零、模組化架構」。
-- 讀 reco_predictions / reco_features（M1, 20261101000160），寫 reco_slates：
-- 週曆上明天起 6 天，每天最多 5 個「系統預選」。只是建議 —— 不建商品、不開團；
-- 老闆在週曆按「排入」才走既有的 rpc_schedule_candidate，按「略過」就不再推這一項。
--
-- 挑法（reco_build_slates，每小時重排一次，也可以從週曆按「重新產生」）：
--   母體：未處理／收藏、14 天內進來、預估 ≥ 8 位、**同款沒有還在開／還沒到貨的團**
--         （recent_open，Alex 2026-11-01）、沒被略過過、沒被排入過
--   依預估買家多→少（同分信心高的先），一個一個往最早還有空位的那天放；
--   同一天同主標籤最多 1 個；整週同一個東西（同款商品／同品名不同規格）只推 1 次
-- 狀態：suggested → accepted（排入，或候選後來被人排程了）/ skipped（略過）/ expired（日子過了沒處理）
-- 探索名額（勝率不明的類別抽樣）留到 M4。
--
-- 新表、新函式，沒有改既有函式。
-- rollback：
--   SELECT cron.unschedule('reco-slates');
--   DROP FUNCTION public.rpc_reco_slate_decide(BIGINT, TEXT), public.rpc_reco_rebuild_slates(),
--     public.reco_build_slates(UUID, INT, INT, INT);
--   DROP TABLE public.reco_slates;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.reco_slates (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID   NOT NULL,
  slate_date    DATE   NOT NULL,
  rank          INT    NOT NULL,
  candidate_id  BIGINT NOT NULL REFERENCES public.community_product_candidates(id) ON DELETE CASCADE,
  model_version TEXT   NOT NULL,
  predicted     INT    NOT NULL,
  reason        TEXT,
  status        TEXT   NOT NULL DEFAULT 'suggested'
                CHECK (status IN ('suggested', 'accepted', 'skipped', 'expired')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at    TIMESTAMPTZ,
  decided_by    UUID
);
CREATE INDEX IF NOT EXISTS idx_reco_slates_day ON public.reco_slates (tenant_id, slate_date, status);
CREATE INDEX IF NOT EXISTS idx_reco_slates_candidate ON public.reco_slates (candidate_id, status);
COMMENT ON TABLE public.reco_slates IS
  '推薦系統 ⑥⑦：每日系統預選與老闆的決定（suggested/accepted/skipped/expired）。⑨ 評估拿來算採納率';

ALTER TABLE public.reco_slates ENABLE ROW LEVEL SECURITY;
CREATE POLICY reco_slates_hq_read ON public.reco_slates FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.reco_slates TO authenticated;

-- ⑥ 排一個租戶未來 p_days 天（明天起）的預選
CREATE OR REPLACE FUNCTION public.reco_build_slates(p_tenant UUID, p_days INT DEFAULT 6, p_per_day INT DEFAULT 5,
                                                    p_min_buyers INT DEFAULT 8)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today  DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  r        RECORD;
  v_d      DATE;
  v_cnt    INT;
  v_n      INT := 0;
  v_keys   TEXT[] := '{}';
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

  CREATE TEMP TABLE IF NOT EXISTS _slate_fill (d DATE, tag TEXT) ON COMMIT DROP;
  TRUNCATE _slate_fill;

  FOR r IN
    SELECT p.candidate_id, p.buyers, p.confidence, p.model_version, p.reasons,
           COALESCE(f.features -> 'tags' ->> 0, 'other') AS tag,
           -- 同一個東西：賣過的看同款商品，其餘看去掉括號規格的品名
           CASE WHEN (f.features ->> 'top_cos')::numeric >= 0.85
                THEN 'p' || (f.features -> 'knn' -> 0 ->> 'product_id')
                ELSE 'n' || lower(regexp_replace(COALESCE(f.features ->> 'item_name', c.product_name_hint, ''),
                                                 '[（(].*?[）)]|\s', '', 'g'))
           END AS dedupe_key
      FROM reco_predictions p
      JOIN community_product_candidates c ON c.id = p.candidate_id
      LEFT JOIN reco_features f ON f.candidate_id = p.candidate_id
     WHERE p.tenant_id = p_tenant
       AND c.owner_action IN ('none', 'collected')
       AND c.created_at > now() - interval '14 days'
       AND NOT p.recent_open
       AND p.buyers >= p_min_buyers
       AND NOT EXISTS (SELECT 1 FROM reco_slates s
                        WHERE s.candidate_id = p.candidate_id AND s.status IN ('accepted', 'skipped'))
     ORDER BY p.buyers DESC, CASE p.confidence WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, p.candidate_id DESC
  LOOP
    CONTINUE WHEN r.dedupe_key = ANY (v_keys);
    FOR i IN 1 .. GREATEST(p_days, 1) LOOP
      v_d := v_today + i;
      SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d;
      CONTINUE WHEN v_cnt >= p_per_day;
      CONTINUE WHEN r.tag <> 'other' AND EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND tag = r.tag);
      INSERT INTO _slate_fill VALUES (v_d, r.tag);
      INSERT INTO reco_slates (tenant_id, slate_date, rank, candidate_id, model_version, predicted, reason)
      VALUES (p_tenant, v_d, v_cnt + 1, r.candidate_id, r.model_version, r.buyers, r.reasons[1]);
      v_keys := v_keys || r.dedupe_key;
      v_n := v_n + 1;
      EXIT;
    END LOOP;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_build_slates(UUID, INT, INT, INT) FROM PUBLIC, anon, authenticated;

-- 週曆「重新產生預選」：排呼叫者自己租戶的
CREATE OR REPLACE FUNCTION public.rpc_reco_rebuild_slates()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
BEGIN
  IF v_tenant IS NULL
     OR COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN public.reco_build_slates(v_tenant);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_reco_rebuild_slates() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reco_rebuild_slates() TO authenticated;

-- ⑦ 老闆的決定：accepted（已經用 rpc_schedule_candidate 排進去之後呼叫）/ skipped（不再推）
CREATE OR REPLACE FUNCTION public.rpc_reco_slate_decide(p_slate_id BIGINT, p_action TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
BEGIN
  IF v_tenant IS NULL
     OR COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  IF p_action NOT IN ('accepted', 'skipped') THEN RAISE EXCEPTION 'invalid action %', p_action; END IF;
  UPDATE reco_slates SET status = p_action, decided_at = now(), decided_by = auth.uid()
   WHERE id = p_slate_id AND tenant_id = v_tenant AND status = 'suggested';
  IF NOT FOUND THEN RAISE EXCEPTION '這個預選已經處理過或不存在'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_reco_slate_decide(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reco_slate_decide(BIGINT, TEXT) TO authenticated;

-- 每小時重排（預估每 10 分鐘補算，預選不用那麼勤）
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'reco-slates';
SELECT cron.schedule('reco-slates', '23 * * * *',
  $cron$ SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t; $cron$);

-- 第一次排
SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
