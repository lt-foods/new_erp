-- ============================================================================
-- 系統預選：同一細品類一週別重複太多、自有品牌類別直接排除（Alex 2026-11-08）
--
-- 老闆：「一週重覆類型太多了，餛飩、牛肉麵，還有包子、饅頭、港點類的都直接排除，我們有自有品牌」。
-- 11/8 正式庫：未來 6 天 240 個預選裡饅頭 9 個、餛飩 6 個、洗衣精 5 個。原本只擋「同一天同主標籤 ≤ 4 個」
-- （主標籤只有 28 種、很粗），細品類（items.kind）沒擋、跨天也沒擋。
--
-- 1. reco_slate_exclusions：排除清單（正規表示式）。scope='kind' 對 items.kind 整字比（^(…)$），
--    scope='name' 對品名 / 候選名稱子字串比。先放自有品牌那組：包子、饅頭、花捲、水煎包、小籠包、叉燒包、
--    流沙包、奶黃包、流心包、蝦餃、燒賣、腸粉、蘿蔔糕、鳳爪、港點 / 港式點心，以及包子的各種叫法（肉包、菜包、湯包、
--    生煎包、刈包…）。品名那條用了 lookaround 避開已知誤殺：麻花捲（餅）、牛奶小饅頭（餅乾）、肉包造型束口袋、泡菜包；
--    「湯包」只放 kind（品名子字串會誤殺「濃湯包」）。品類標籤（items.kind）有不少亂碼（駕頭、飯颥），主要靠品名那條。
--    scope='allow' 是例外：品名符合就不排除（牛奶小饅頭、麻花捲、束口袋 —— 品類被標成饅頭 / 花捲的非包子類）。
--    以後要加直接 INSERT 一列（還沒做後台頁）。_reco_slate_excluded() 給 reco_build_slates 用。
-- 2. reco_build_slates（基底 20261107000040）：母體先過排除清單；同一細品類一天最多 1 個、整個 6 天視窗
--    最多 p_kind_week（預設 2）個；照預估與試新兩段都套。kind 是 NULL 的（還沒標）不受細品類限制。
--    簽名多一個參數（有預設值），排程與 rpc_reco_rebuild_slates 不用改。
--
-- 老闆的「排除」只動推薦（預選），候選池照常收、照常預估，老闆自己在候選池排程不受影響。
--
-- rollback：重跑 20261107000040 的 reco_build_slates；DROP FUNCTION public.reco_build_slates(UUID, INT, INT, INT, INT, INT);
--   DROP FUNCTION public._reco_slate_excluded(UUID, TEXT, TEXT, TEXT); DROP TABLE public.reco_slate_exclusions;
--   再 SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.reco_slate_exclusions (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  UUID NOT NULL,
  scope      TEXT NOT NULL CHECK (scope IN ('kind', 'name', 'allow')),
  pattern    TEXT NOT NULL,
  note       TEXT,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.reco_slate_exclusions IS
  '系統預選排除清單（20261108000010）：scope=kind 對品類整字比、scope=name 對品名子字串比、scope=allow 品名符合就不排除（例外）；正規表示式。只影響推薦，不影響候選池。';
ALTER TABLE public.reco_slate_exclusions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reco_slate_exclusions_hq_read ON public.reco_slate_exclusions;
CREATE POLICY reco_slate_exclusions_hq_read ON public.reco_slate_exclusions FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.reco_slate_exclusions TO authenticated;

INSERT INTO public.reco_slate_exclusions (tenant_id, scope, pattern, note)
SELECT t.tenant_id, x.scope, x.pattern, '自有品牌（包子媽）'
  FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t,
       (VALUES
         ('kind', '包子|肉包|菜包|酸菜包|薺菜包|芝麻包|湯包|生煎包|水煎包|小籠包|叉燒包|流沙包|奶黃包|奶皇包|流心包|豆沙包|芋泥包|刈包|割包|饅頭|小饅頭|花捲|花卷|銀絲卷|蝦餃|燒賣|腸粉|蘿蔔糕|鳳爪|港點|港式點心'),
         ('allow', '牛奶小饅頭|麻花捲|束口袋'),
         ('name', '包子|肉包(?![絨娃玩抱吊])|(?<!泡)菜包|芝麻包|生煎包|水煎包|小籠包|叉燒包|流沙包|奶黃包|奶皇包|流心包|豆沙包|芋泥包|刈包|割包|(?<!牛奶小)(?<!鮮奶小)饅頭|(?<!麻)花捲|銀絲卷|蝦餃|燒賣|腸粉|蘿蔔糕|鳳爪|港點|港式點心')
       ) AS x(scope, pattern)
 WHERE NOT EXISTS (SELECT 1 FROM public.reco_slate_exclusions e WHERE e.tenant_id = t.tenant_id AND e.scope = x.scope AND e.pattern = x.pattern);

CREATE OR REPLACE FUNCTION public._reco_slate_excluded(p_tenant UUID, p_kind TEXT, p_item_name TEXT, p_hint TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT EXISTS (
    -- 例外：品名符合 allow 的一律不排除（牛奶小饅頭是餅乾、麻花捲是餅，品類標籤卻標成饅頭 / 花捲）
    SELECT 1 FROM reco_slate_exclusions a
     WHERE a.tenant_id = p_tenant AND a.is_active AND a.scope = 'allow'
       AND (COALESCE(p_item_name, '') ~ a.pattern OR COALESCE(p_hint, '') ~ a.pattern)
  ) AND EXISTS (
    SELECT 1 FROM reco_slate_exclusions e
     WHERE e.tenant_id = p_tenant AND e.is_active
       AND ((e.scope = 'kind' AND COALESCE(p_kind, '') ~ ('^(' || e.pattern || ')$'))
         OR (e.scope = 'name' AND (COALESCE(p_item_name, '') ~ e.pattern OR COALESCE(p_hint, '') ~ e.pattern)))
  );
$$;
REVOKE ALL ON FUNCTION public._reco_slate_excluded(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- reco_build_slates（基底 20261107000040）：簽名多 p_kind_week，先丟舊的
DROP FUNCTION IF EXISTS public.reco_build_slates(UUID, INT, INT, INT, INT);
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
                AND (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = r.tag) >= v_tag_cap;
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
           AND (sp.tag = 'other' OR (SELECT count(*) FROM _slate_fill WHERE d = v_d AND tag = sp.tag) < v_tag_cap)
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

-- 馬上重排一次（未來還沒處理的預選整批重排，已排入 / 略過的不動）
SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
