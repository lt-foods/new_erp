-- ============================================================================
-- reco_build_slates 加鎖：同一個 tenant 同時只跑一個重排
--
-- 11/8 19:49 套 20261108000040 時順帶重排，同一秒週曆有人按「重新產生預選」，兩個交易各自
-- 「刪未來的 suggested → 插新的」，彼此看不到對方未送出的列 → 6 天 480 筆（應 240），每個名次兩張卡。
-- 當下已手動重排一次清掉。這支在函式開頭拿 pg_advisory_xact_lock，第二個呼叫會等第一個 commit，
-- 再把它的結果刪掉重排，最後只留一份。
--
-- 基底版本：reco_build_slates ← 20261108000040_slate_fresh_quota.sql
-- rollback：重跑 20261108000040 的 reco_build_slates
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reco_build_slates(p_tenant UUID, p_days INT DEFAULT 6, p_per_day INT DEFAULT 40,
                                                    p_min_buyers INT DEFAULT 8, p_explore INT DEFAULT 2,
                                                    p_kind_week INT DEFAULT 2)
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
  -- 20261108000010：細品類（items.kind，例：餛飩、牛肉麵）一天最多 1 個、整個視窗最多 p_kind_week 個
  v_kind_week INT := GREATEST(COALESCE(p_kind_week, 2), 1);
  -- 20261108000040：保底名額（reco_slate_quotas）。保底的大類，一天上限至少放到保底數
  v_quota   JSONB := COALESCE((SELECT jsonb_object_agg(q.tag, q.per_day) FROM reco_slate_quotas q
                                WHERE q.tenant_id = p_tenant AND q.is_active AND q.per_day > 0), '{}'::jsonb);
  q         RECORD;
  r         RECORD;
  v_d       DATE;
  v_cnt     INT;
  v_n       INT := 0;
  v_keys    TEXT[] := '{}';
BEGIN
  -- 20261108000050：同一個 tenant 同時只能有一個重排。兩個交易同時跑（排程 + 週曆「重新產生預選」）時，
  -- 各自只刪得到對方還沒送出前的舊列、再各插一份 → 預選變兩倍（11/8 19:49 實際發生，480 筆）。
  -- 拿交易層級的 advisory lock：第二個等第一個 commit，再刪掉它的結果重排。
  PERFORM pg_advisory_xact_lock(hashtext('reco_build_slates'), hashtext(p_tenant::text));

  -- 1. 收尾：候選後來被人排程了 → accepted；日子過了沒處理 → expired
  UPDATE reco_slates s SET status = 'accepted', decided_at = now()
    FROM community_product_candidates c
   WHERE s.tenant_id = p_tenant AND s.status = 'suggested' AND c.id = s.candidate_id
     AND c.owner_action IN ('scheduled', 'adopted');
  UPDATE reco_slates SET status = 'expired'
   WHERE tenant_id = p_tenant AND status = 'suggested' AND slate_date <= v_today;

  -- 2. 未來的建議整批重排（已決定的留著）
  DELETE FROM reco_slates WHERE tenant_id = p_tenant AND status = 'suggested' AND slate_date > v_today;

  DROP TABLE IF EXISTS _slate_fill;
  CREATE TEMP TABLE _slate_fill (d DATE, tag TEXT, kind TEXT, item_kind TEXT) ON COMMIT DROP;

  -- 母體（照預估、試新共用）
  DROP TABLE IF EXISTS _slate_pool;
  CREATE TEMP TABLE _slate_pool (candidate_id BIGINT, buyers INT, confidence TEXT, model_version TEXT,
                                 reasons TEXT[], tag TEXT, dedupe_key TEXT, hot BOOLEAN, item_kind TEXT) ON COMMIT DROP;
  INSERT INTO _slate_pool
  SELECT p.candidate_id, p.buyers, p.confidence, p.model_version, p.reasons,
         COALESCE(f.features -> 'tags' ->> 0, 'other'),
         CASE WHEN (f.features ->> 'top_cos')::numeric >= 0.85
              THEN 'p' || (f.features -> 'knn' -> 0 ->> 'product_id')
              ELSE 'n' || lower(regexp_replace(COALESCE(f.features ->> 'item_name', c.product_name_hint, ''),
                                               '[（(].*?[）)]|\s', '', 'g'))
         END,
         jsonb_array_length(COALESCE(f.features -> 'heat_matches', '[]'::jsonb)) > 0,
         NULLIF(btrim(i.kind), '')
    FROM reco_predictions p
    JOIN community_product_candidates c ON c.id = p.candidate_id
    LEFT JOIN reco_features f ON f.candidate_id = p.candidate_id
    LEFT JOIN line_note_market_items i ON i.id = (c.raw ->> 'market_item_id')::bigint
   WHERE p.tenant_id = p_tenant
     -- 20261108000010：排除清單（自有品牌：包子、饅頭、港點…）
     AND NOT public._reco_slate_excluded(p_tenant, i.kind, i.item_name, c.product_name_hint)
     AND c.owner_action IN ('none', 'collected')
     AND c.created_at > now() - interval '14 days'
     AND NOT p.recent_open
     AND p.buyers >= LEAST(p_min_buyers, 3)
     AND NOT EXISTS (SELECT 1 FROM reco_slates s
                      WHERE s.candidate_id = p.candidate_id AND s.status IN ('accepted', 'skipped'));

  -- 2b. 保底名額（20261108000040）：每天先把保底的大類填滿，排在當天最前面。
  --     照預估高到低挑，同款、細品類一天 1 個 / 一週 v_kind_week 個的規則照套；挑不滿就算了，不硬塞低預估的。
  FOR q IN SELECT x.key AS tag, (x.value)::int AS per_day FROM jsonb_each_text(v_quota) x ORDER BY x.key LOOP
    FOR i IN 1 .. GREATEST(p_days, 1) LOOP
      v_d := v_today + i;
      FOR r IN
        SELECT * FROM _slate_pool
         WHERE tag = q.tag AND buyers >= p_min_buyers
         ORDER BY buyers * CASE WHEN hot THEN 1.2 ELSE 1 END DESC,
                  CASE confidence WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, candidate_id DESC
      LOOP
        EXIT WHEN (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = q.tag) >= q.per_day;
        EXIT WHEN (SELECT count(*) FROM _slate_fill WHERE d = v_d AND kind = 'exploit') >= v_exploit;
        CONTINUE WHEN r.dedupe_key = ANY (v_keys);
        CONTINUE WHEN r.item_kind IS NOT NULL
                  AND ((SELECT count(*) FROM _slate_fill WHERE item_kind = r.item_kind) >= v_kind_week
                       OR EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND item_kind = r.item_kind));
        SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d AND kind = 'exploit';
        INSERT INTO _slate_fill VALUES (v_d, r.tag, 'exploit', r.item_kind);
        INSERT INTO reco_slates (tenant_id, slate_date, rank, candidate_id, model_version, predicted, reason, pick_kind)
        VALUES (p_tenant, v_d, v_cnt + 1, r.candidate_id, r.model_version, r.buyers,
                CASE WHEN r.hot THEN COALESCE((SELECT x FROM unnest(r.reasons) x WHERE x LIKE '%熱銷%' LIMIT 1), r.reasons[1])
                     ELSE r.reasons[1] END, 'exploit');
        v_keys := v_keys || r.dedupe_key;
        v_n := v_n + 1;
      END LOOP;
    END LOOP;
  END LOOP;

  -- 3. 照預估（每天 v_exploit 個）
  FOR r IN
    SELECT * FROM _slate_pool
     WHERE buyers >= p_min_buyers
     -- 市場上正熱賣的同類（蝦皮助手榜單）排前面一點：×1.2（還沒驗證，⑨ 會分開看命中率）
     ORDER BY buyers * CASE WHEN hot THEN 1.2 ELSE 1 END DESC,
              CASE confidence WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, candidate_id DESC
  LOOP
    CONTINUE WHEN r.dedupe_key = ANY (v_keys);
    -- 同一細品類整週最多 v_kind_week 個
    CONTINUE WHEN r.item_kind IS NOT NULL
              AND (SELECT count(*) FROM _slate_fill WHERE item_kind = r.item_kind) >= v_kind_week;
    FOR i IN 1 .. GREATEST(p_days, 1) LOOP
      v_d := v_today + i;
      SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d AND kind = 'exploit';
      CONTINUE WHEN v_cnt >= v_exploit;
      CONTINUE WHEN r.tag <> 'other'
                AND (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = r.tag)
                    >= GREATEST(v_tag_cap, COALESCE((v_quota ->> r.tag)::int, 0));
      -- 同一細品類一天最多 1 個
      CONTINUE WHEN r.item_kind IS NOT NULL
                AND EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND item_kind = r.item_kind);
      INSERT INTO _slate_fill VALUES (v_d, r.tag, 'exploit', r.item_kind);
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
           AND (sp.tag = 'other' OR (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = sp.tag)
                                       < GREATEST(v_tag_cap, COALESCE((v_quota ->> sp.tag)::int, 0)))
           AND (sp.item_kind IS NULL
                OR (NOT EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND item_kind = sp.item_kind)
                    AND (SELECT count(*) FROM _slate_fill WHERE item_kind = sp.item_kind) < v_kind_week))
         ORDER BY theta DESC
         LIMIT 1;
        EXIT WHEN NOT FOUND;
        SELECT count(*) INTO v_cnt FROM _slate_fill WHERE d = v_d;
        INSERT INTO _slate_fill VALUES (v_d, r.tag, 'explore', r.item_kind);
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
REVOKE ALL ON FUNCTION public.reco_build_slates(UUID, INT, INT, INT, INT, INT) FROM PUBLIC, anon, authenticated;
