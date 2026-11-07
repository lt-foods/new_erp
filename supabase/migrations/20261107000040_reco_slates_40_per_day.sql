-- ============================================================================
-- 系統預選每天 10 個 → 40 個（老闆 2026-11-07 指示）
--
-- 改兩件事：
--   1. reco_build_slates 的 p_per_day 預設 10 → 40。排程 reco-slates 與週曆「重新產生」
--      （rpc_reco_rebuild_slates）都用預設值，兩邊一起生效。試新名額維持每天 2 個。
--   2. 「同一天同主標籤最多 1 個」改成每 10 個名額 1 個（40 個 → 同主標籤最多 4 個）。
--      11/7 正式庫交易內試跑：預估 8 人以上的候選有 580 筆、主標籤只有 28 種，
--      維持 1 個的話 6 天只排得到 30 / 23 / 20 / 17 / 15 / 14 個。
--
-- 基底版本：reco_build_slates ← 20261102000010_market_hot.sql（重 grep 確認是最新）
-- rollback：重跑 20261102000010 的 reco_build_slates 定義，再
--   SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reco_build_slates(p_tenant UUID, p_days INT DEFAULT 6, p_per_day INT DEFAULT 40,
                                                    p_min_buyers INT DEFAULT 8, p_explore INT DEFAULT 2)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today   DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_exploit INT  := GREATEST(p_per_day - GREATEST(p_explore, 0), 0);
  -- 同一天同主標籤最多幾個：每 10 個名額 1 個（10 個 → 1，40 個 → 4）。
  -- 主標籤只有 ~28 種，一天 40 個還維持「同主標籤 1 個」會排不滿（20261107000040 檔頭）
  v_tag_cap INT  := GREATEST(1, CEIL(GREATEST(p_per_day, 1) / 10.0)::int);
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
                                               reasons TEXT[], tag TEXT, dedupe_key TEXT, hot BOOLEAN) ON COMMIT DROP;
  TRUNCATE _slate_pool;
  INSERT INTO _slate_pool
  SELECT p.candidate_id, p.buyers, p.confidence, p.model_version, p.reasons,
         COALESCE(f.features -> 'tags' ->> 0, 'other'),
         CASE WHEN (f.features ->> 'top_cos')::numeric >= 0.85
              THEN 'p' || (f.features -> 'knn' -> 0 ->> 'product_id')
              ELSE 'n' || lower(regexp_replace(COALESCE(f.features ->> 'item_name', c.product_name_hint, ''),
                                               '[（(].*?[）)]|\s', '', 'g'))
         END,
         jsonb_array_length(COALESCE(f.features -> 'heat_matches', '[]'::jsonb)) > 0
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
     -- 市場上正熱賣的同類（蝦皮助手榜單）排前面一點：×1.2（還沒驗證，⑨ 會分開看命中率）
     ORDER BY buyers * CASE WHEN hot THEN 1.2 ELSE 1 END DESC,
              CASE confidence WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, candidate_id DESC
  LOOP
    CONTINUE WHEN r.dedupe_key = ANY (v_keys);
    FOR i IN 1 .. GREATEST(p_days, 1) LOOP
      v_d := v_today + i;
      SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d AND kind = 'exploit';
      CONTINUE WHEN v_cnt >= v_exploit;
      CONTINUE WHEN r.tag <> 'other'
                AND (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = r.tag) >= v_tag_cap;
      INSERT INTO _slate_fill VALUES (v_d, r.tag, 'exploit');
      INSERT INTO reco_slates (tenant_id, slate_date, rank, candidate_id, model_version, predicted, reason, pick_kind)
      VALUES (p_tenant, v_d, v_cnt + 1, r.candidate_id, r.model_version, r.buyers,
              CASE WHEN r.hot THEN COALESCE((SELECT x FROM unnest(r.reasons) x WHERE x LIKE '%熱銷%' LIMIT 1), r.reasons[1])
                   ELSE r.reasons[1] END, 'exploit');
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
           AND (sp.tag = 'other' OR (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = sp.tag) < v_tag_cap)
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

-- 馬上重排一次（未來還沒處理的預選整批重排，已排入 / 略過的不動）
SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
