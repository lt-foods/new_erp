-- ============================================================================
-- 推薦系統：品類（kind）→ 開團頻率改「同品類」算，模型 v3（20261101000220）
--
-- Alex 2026-11-01：「豬排我們還有兩團還沒到貨」。v2 只認「同一款」（向量 ≥ 0.85），
-- 所以只抓到卡哇伊鮮嫩厚豬排；大登豬排（0.77）、大排檔醃豬排（0.72）都沒算到。
-- 光靠向量分不出同類：0.7～0.8 這段豬排、雞排、「豬排御用米」（0.70）混在一起，
-- 青花椒帶骨豬排只有 0.69。所以加一個 AI 標的「品類」：最通用的名詞（豬排、地瓜、鴨翅、洗衣精）。
--
-- ② 理解：
--   product_kinds（一商品一列；不直接寫 products，因為 products 有 updated_at 觸發器）、
--   line_note_market_items.kind。market-ai（Cloudflare）每次 tick 用剩下的時間標：
--   rpc_ai_kind_claim 先給廠商品項、再給商品（最近開過團的優先）；rpc_ai_kind_write 寫回；
--   rpc_ai_kind_vocab 給模型看已經用過的品類，讓同一種東西盡量用同一個詞。
--   品項標好會碰一下候選（updated_at），10 分鐘內重算預估。
-- ④ 特徵（_reco_kind_features）：kind、kind_unfinished（同品類還沒結束的團：開團中／已收單／
--   還沒到貨／已排草稿，近 45 天）、kind_days / kind_last_name / kind_last_date、kind_opens_60d。
--   回測（p_asof）時「還沒結束」用「開團前 10 天內開的同品類團」近似。
-- ⑤ reco_predict_v3 = v1 ×（同品類頻率；品類還沒標好時退回 v2 的同一款）：
--   - 同品類有還沒結束的團 → 理由第一行「⚠ 豬排還有 2 團沒結束：大登豬排 10/19（沒到貨）、…」，
--     標成 recent_open（週曆預選不推）。
--   - 食品、同品類 30 天內開過或還有沒結束的 → 預估 ×0.75（同一款實查 0.74；
--     品類層級等全部商品標好後用回測再校）。
--   - 其他只寫「同品類上次 MM/DD 開」，近 60 天開過 ≥2 團再加一行。
--   reco_refresh_predictions / reco_eval_backtest / reco_eval_daily 改用 v3（評估可指定 v1/v2/v3 比較）。
--
-- 基底（各自最新版，已 grep）：reco_compute_features / reco_refresh_predictions / _reco_features_asof /
--   reco_eval_backtest / reco_eval_daily @ 20261101000200。
-- rollback：
--   重跑 20261101000200 的上述五支（eval 兩支先 DROP 新簽名），
--   DROP FUNCTION public.reco_predict_v3(JSONB), public._reco_kind_features(UUID, TEXT, TIMESTAMPTZ, BOOLEAN),
--     public.rpc_ai_kind_claim(INT), public.rpc_ai_kind_write(JSONB), public.rpc_ai_kind_vocab(INT);
--   DROP TABLE public.product_kinds; ALTER TABLE line_note_market_items DROP COLUMN kind, DROP COLUMN kind_at;
--   UPDATE reco_predictions SET computed_at = '-infinity'; SELECT reco_refresh_predictions(1000);
-- ============================================================================

-- ── ② 品類 ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.product_kinds (
  product_id BIGINT PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  tenant_id  UUID   NOT NULL,
  kind       TEXT,
  labeled_at TIMESTAMPTZ,       -- 送去標的時間（NULL = 還沒）
  error      TEXT
);
CREATE INDEX IF NOT EXISTS idx_product_kinds_kind ON public.product_kinds (tenant_id, kind);
COMMENT ON TABLE public.product_kinds IS
  '商品品類（AI 標，最通用的名詞：豬排、地瓜、洗衣精）。推薦系統算「同品類開團頻率」用（20261101000220）';
ALTER TABLE public.product_kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY product_kinds_hq_read ON public.product_kinds FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.product_kinds TO authenticated;

ALTER TABLE public.line_note_market_items
  ADD COLUMN IF NOT EXISTS kind    TEXT,
  ADD COLUMN IF NOT EXISTS kind_at TIMESTAMPTZ;
COMMENT ON COLUMN public.line_note_market_items.kind IS '品類（AI 標，同 product_kinds 的詞彙）';

-- 已經用過的品類（給模型參考，讓同一種東西用同一個詞）
CREATE OR REPLACE FUNCTION public.rpc_ai_kind_vocab(p_limit INT DEFAULT 200)
RETURNS TABLE (kind TEXT, n BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT kind, count(*) FROM product_kinds WHERE kind IS NOT NULL
   GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT GREATEST(COALESCE(p_limit, 200), 1);
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_kind_vocab(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_kind_vocab(INT) TO service_role;

-- 領一批要標品類的：廠商品項優先，再來商品（最近開過團的先）。領走就蓋 labeled_at / kind_at，失敗的一天後重領
CREATE OR REPLACE FUNCTION public.rpc_ai_kind_claim(p_limit INT DEFAULT 40)
RETURNS TABLE (target TEXT, id BIGINT, name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_lim INT := LEAST(GREATEST(COALESCE(p_limit, 40), 1), 100);
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  WITH picked AS (
    SELECT i.id FROM line_note_market_items i
     WHERE i.kind IS NULL AND (i.kind_at IS NULL OR i.kind_at < now() - interval '1 day')
     ORDER BY i.id DESC LIMIT v_lim
     FOR UPDATE SKIP LOCKED
  ), marked AS (
    UPDATE line_note_market_items i SET kind_at = now() FROM picked WHERE i.id = picked.id
    RETURNING i.id, i.item_name
  )
  SELECT 'item'::text, m.id, m.item_name FROM marked m;
  GET DIAGNOSTICS v_lim = ROW_COUNT;
  v_lim := LEAST(GREATEST(COALESCE(p_limit, 40), 1), 100) - v_lim;
  IF v_lim <= 0 THEN RETURN; END IF;

  RETURN QUERY
  WITH cand AS (
    SELECT p.id, p.tenant_id, p.name,
           (SELECT max(g.start_at) FROM group_buy_campaigns g WHERE g.product_id = p.id) AS last_start
      FROM products p
      LEFT JOIN product_kinds k ON k.product_id = p.id
     WHERE (k.product_id IS NULL OR (k.kind IS NULL AND (k.labeled_at IS NULL OR k.labeled_at < now() - interval '1 day')))
       AND COALESCE(btrim(p.name), '') <> ''
     ORDER BY last_start DESC NULLS LAST, p.id DESC
     LIMIT v_lim
  ), ins AS (
    INSERT INTO product_kinds AS k (product_id, tenant_id, labeled_at)
    SELECT c.id, c.tenant_id, now() FROM cand c
    ON CONFLICT (product_id) DO UPDATE SET labeled_at = now()
    RETURNING k.product_id
  )
  SELECT 'product'::text, c.id, c.name FROM cand c JOIN ins ON ins.product_id = c.id;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_kind_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_kind_claim(INT) TO service_role;

-- 寫回：[{target, id, kind, error}]。品類去空白、最多 8 字
CREATE OR REPLACE FUNCTION public.rpc_ai_kind_write(p_rows JSONB)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r     JSONB;
  v_k   TEXT;
  v_n   INT := 0;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
    v_k := NULLIF(LEFT(regexp_replace(COALESCE(r ->> 'kind', ''), '\s', '', 'g'), 8), '');
    IF r ->> 'target' = 'item' THEN
      UPDATE line_note_market_items SET kind = v_k, kind_at = now() WHERE id = (r ->> 'id')::bigint;
      -- 讓預估 10 分鐘內重算
      IF v_k IS NOT NULL THEN
        UPDATE community_product_candidates SET updated_at = now()
         WHERE (raw ->> 'market_item_id') = (r ->> 'id') AND owner_action IN ('none', 'collected');
      END IF;
    ELSE
      UPDATE product_kinds SET kind = v_k, error = NULLIF(r ->> 'error', ''), labeled_at = now()
       WHERE product_id = (r ->> 'id')::bigint;
    END IF;
    IF v_k IS NOT NULL THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_kind_write(JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_kind_write(JSONB) TO service_role;

-- ── ④ 同品類的開團紀錄 ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._reco_kind_features(p_tenant UUID, p_kind TEXT, p_before TIMESTAMPTZ, p_asof BOOLEAN)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH g AS (
    SELECT g.id, g.start_at, g.status, p.name,
           EXISTS (SELECT 1 FROM customer_orders co
                    WHERE co.campaign_id = g.id AND co.status IN ('ready', 'partially_completed', 'completed')) AS arrived
      FROM product_kinds k
      JOIN group_buy_campaigns g ON g.product_id = k.product_id
      JOIN products p ON p.id = g.product_id
     WHERE p_kind IS NOT NULL AND k.tenant_id = p_tenant AND k.kind = p_kind
       AND g.owner_store_id IS NULL AND g.status <> 'cancelled'
       AND g.start_at >= p_before - interval '180 days'
       AND (g.status <> 'draft' OR (NOT p_asof AND g.start_at < p_before + interval '14 days'))
  ), done AS (
    SELECT * FROM g WHERE g.status <> 'draft' AND g.start_at < p_before
  ), last AS (
    SELECT * FROM done ORDER BY start_at DESC LIMIT 1
  ), unf AS (
    SELECT * FROM g
     WHERE CASE WHEN p_asof
                THEN g.status <> 'draft' AND g.start_at < p_before AND g.start_at >= p_before - interval '10 days'
                ELSE g.start_at >= p_before - interval '45 days'
                     AND (g.status IN ('draft', 'open', 'closed') OR NOT g.arrived)
           END
  )
  SELECT CASE WHEN p_kind IS NULL THEN jsonb_build_object('kind', NULL) ELSE jsonb_build_object(
    'kind', p_kind,
    'kind_days', (SELECT ((p_before AT TIME ZONE 'Asia/Taipei')::date - (start_at AT TIME ZONE 'Asia/Taipei')::date) FROM last),
    'kind_last_name', (SELECT name FROM last),
    'kind_last_date', (SELECT (start_at AT TIME ZONE 'Asia/Taipei')::date FROM last),
    'kind_opens_60d', (SELECT count(*) FROM done WHERE start_at >= p_before - interval '60 days'),
    'kind_unfinished', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'name', name, 'start', (start_at AT TIME ZONE 'Asia/Taipei')::date,
                          'status', status, 'arrived', arrived) ORDER BY start_at) FROM unf), '[]'::jsonb))
  END;
$$;
REVOKE ALL ON FUNCTION public._reco_kind_features(UUID, TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- ── ④ 特徵（基底 20261101000200，多同品類）─────────────────────────────────
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
  v_food   BOOLEAN;
BEGIN
  SELECT * INTO v_c FROM community_product_candidates WHERE id = p_candidate_id;
  IF NOT FOUND OR (v_c.raw ->> 'market_item_id') IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_i FROM line_note_market_items WHERE id = (v_c.raw ->> 'market_item_id')::bigint;
  IF NOT FOUND OR v_i.embedding IS NULL THEN RETURN NULL; END IF;

  -- 溫層標籤不算類別
  SELECT COALESCE(array_agg(t.code), '{}') INTO v_tags
    FROM unnest(COALESCE(v_i.tags, '{}')) AS x(code)
    JOIN product_tags t ON t.code = x.code AND t.tenant_id = v_c.tenant_id AND t.tag_group <> '溫層';
  -- 食品＝標籤裡沒有任何「非食品」組
  v_food := NOT EXISTS (SELECT 1 FROM unnest(COALESCE(v_i.tags, '{}')) AS x(code)
                          JOIN product_tags t ON t.code = x.code AND t.tenant_id = v_c.tenant_id AND t.tag_group = '非食品');

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

  -- 擁擠度：同類未來 7 天已排幾團（只記錄、顯示，不進公式）
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
    'recent_open', COALESCE(v_recent, '[]'::jsonb),
    'is_food', v_food)
    || public._reco_reopen(v_c.tenant_id, v_i.embedding, now(), 0.85)  -- 廠商品名 vs 我方品名，同款門檻同「賣過」
    || public._reco_kind_features(v_c.tenant_id, v_i.kind, now(), FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.reco_compute_features(BIGINT) FROM PUBLIC, anon, authenticated;


-- ⑤ 模型 v3 = v1 × 同品類頻率（品類還沒標好 → 跟 v2 一樣看同一款）
CREATE OR REPLACE FUNCTION public.reco_predict_v3(p_f JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_kind TEXT := NULLIF(p_f ->> 'kind', '');
  v_unf  JSONB := COALESCE(p_f -> 'kind_unfinished', '[]'::jsonb);
  v_nunf INT;
  v_p    JSONB;
  v_rs   JSONB;
  v_days INT;
  v_name TEXT;
  v_date DATE;
  v_n60  INT;
  v_food BOOLEAN := COALESCE((p_f ->> 'is_food')::boolean, TRUE);
  v_open BOOLEAN;
  v_pen  BOOLEAN;
  v_list TEXT;
BEGIN
  IF v_kind IS NULL THEN RETURN public.reco_predict_v2(p_f); END IF;
  v_p := public.reco_predict_v1(p_f);
  IF v_p IS NULL THEN RETURN NULL; END IF;
  v_rs := COALESCE(v_p -> 'reasons', '[]'::jsonb);
  v_nunf := jsonb_array_length(v_unf);
  v_days := NULLIF(p_f ->> 'kind_days', '')::int;
  v_name := p_f ->> 'kind_last_name';
  v_date := NULLIF(p_f ->> 'kind_last_date', '')::date;
  v_n60  := COALESCE(NULLIF(p_f ->> 'kind_opens_60d', '')::int, 0);
  -- 同品類清單會列出來，v1 那行「⚠ 同款…」就不重複
  IF v_nunf > 0 AND (v_rs ->> 0) LIKE '⚠ 同款%' THEN v_rs := v_rs - 0; END IF;
  v_open := COALESCE((v_p ->> 'recent_open')::boolean, FALSE) OR v_nunf > 0;
  v_pen  := v_food AND (v_nunf > 0 OR (v_days IS NOT NULL AND v_days < 30));

  IF v_pen THEN
    v_p := v_p || jsonb_build_object(
      'buyers', round((v_p ->> 'buyers')::numeric * 0.75),
      'low', floor((v_p ->> 'low')::numeric * 0.75),
      'high', ceil((v_p ->> 'high')::numeric * 0.75));
  END IF;

  IF v_nunf > 0 THEN
    SELECT string_agg(format('%s %s（%s）', LEFT(regexp_replace(x ->> 'name', '[^一-龥A-Za-z]', '', 'g'), 10),
                             to_char((x ->> 'start')::date, 'MM/DD'),
                             CASE x ->> 'status' WHEN 'draft' THEN '已排草稿' WHEN 'open' THEN '開團中'
                                                 WHEN 'closed' THEN '已收單' ELSE '沒到貨' END), '、')
      INTO v_list
      FROM (SELECT x FROM jsonb_array_elements(v_unf) x LIMIT 3) s;
    v_rs := to_jsonb(format('⚠ %s還有 %s 團沒結束：%s%s', v_kind, v_nunf, v_list, CASE WHEN v_nunf > 3 THEN '…' ELSE '' END))
            || CASE WHEN v_pen THEN to_jsonb('食品同品類還沒吃完，預估打 75 折'::text) ELSE '[]'::jsonb END
            || v_rs;
  ELSIF v_days IS NOT NULL THEN
    IF v_pen THEN
      v_rs := to_jsonb(format('⚠ %s %s 才開過（%s，%s 天前），還沒吃完的人多，預估打 75 折',
                              v_kind, to_char(v_date, 'MM/DD'), LEFT(regexp_replace(v_name, '[^一-龥A-Za-z]', '', 'g'), 12), v_days))
              || v_rs;
    ELSE
      v_rs := v_rs || to_jsonb(format('%s上次 %s 開（%s 天前）', v_kind, to_char(v_date, 'MM/DD'), v_days));
    END IF;
  END IF;
  IF v_n60 >= 2 THEN
    v_rs := v_rs || to_jsonb(format('近 60 天%s開過 %s 團', v_kind, v_n60));
  END IF;
  RETURN v_p || jsonb_build_object('reasons', v_rs, 'recent_open', v_open, 'kind', v_kind);
END;
$$;

-- 補算（基底 20261101000200；換成 v3）
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
    VALUES (r.id, r.tenant_id, 'f3', v_f, now())
    ON CONFLICT (candidate_id) DO UPDATE
       SET feature_version = EXCLUDED.feature_version, features = EXCLUDED.features, computed_at = now();
    v_p := public.reco_predict_v3(v_f);
    CONTINUE WHEN v_p IS NULL;
    INSERT INTO reco_predictions (candidate_id, tenant_id, model_version, buyers, low, high, confidence, reasons, recent_open, computed_at)
    VALUES (r.id, r.tenant_id, 'v3', (v_p ->> 'buyers')::int, (v_p ->> 'low')::int, (v_p ->> 'high')::int,
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

-- ⑨ 評估特徵（基底 20261101000200，多同品類）
CREATE OR REPLACE FUNCTION public._reco_features_asof(p_tenant UUID, p_product BIGINT, p_d DATE, p_price NUMERIC)
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
  v_food BOOLEAN;
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
  v_food := NOT EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                         WHERE m.product_id = p_product AND t.tag_group = '非食品');
  RETURN jsonb_build_object(
    'knn_buyers', v_knn, 'top_cos', v_top, 'tag_prior', v_tag, 'global_prior', v_glob, 'price', p_price,
    'price_band', CASE WHEN p_price IS NULL OR p_price <= 0 THEN NULL WHEN p_price < 200 THEN 'lt200'
                       WHEN p_price < 300 THEN '200_300' ELSE 'gt300' END,
    'is_food', v_food)
    || public._reco_reopen(p_tenant, v_emb, (p_d::timestamp AT TIME ZONE 'Asia/Taipei'))
    || public._reco_kind_features(p_tenant, (SELECT pk.kind FROM product_kinds pk WHERE pk.product_id = p_product),
                                  (p_d::timestamp AT TIME ZONE 'Asia/Taipei'), TRUE);
END;
$$;
REVOKE ALL ON FUNCTION public._reco_features_asof(UUID, BIGINT, DATE, NUMERIC) FROM PUBLIC, anon, authenticated;

-- 每週回測（基底 20261101000200）：預設 v3
DROP FUNCTION IF EXISTS public.reco_eval_backtest(UUID, DATE, DATE, TEXT);
CREATE OR REPLACE FUNCTION public.reco_eval_backtest(p_tenant UUID, p_from DATE, p_to DATE, p_model TEXT DEFAULT 'v3')
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
    SELECT r.product_id, r.start_date AS d, r.buyers AS actual, r.price
      FROM reco_campaign_buyers r
     WHERE r.tenant_id = p_tenant AND r.settled AND r.start_date BETWEEN p_from AND p_to
       AND NOT EXISTS (SELECT 1 FROM reco_campaign_buyers r2
                        WHERE r2.product_id = r.product_id AND r2.start_date < r.start_date)
  ), f AS (
    SELECT t.actual, public._reco_features_asof(p_tenant, t.product_id, t.d, t.price) AS feat FROM t
  ), p AS (
    SELECT actual, CASE p_model WHEN 'v1' THEN public.reco_predict_v1(feat) WHEN 'v2' THEN public.reco_predict_v2(feat)
                  ELSE public.reco_predict_v3(feat) END AS pr
      FROM f WHERE feat IS NOT NULL
  )
  SELECT jsonb_agg(jsonb_build_object('pred', (pr ->> 'buyers')::numeric, 'low', (pr ->> 'low')::numeric,
                                      'high', (pr ->> 'high')::numeric, 'actual', actual))
    INTO v_rows
    FROM p WHERE pr IS NOT NULL;

  v_m := public._reco_eval_metrics(v_rows);
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, details)
  VALUES (p_tenant, 'backtest', p_model, p_from, p_to, (v_m ->> 'n')::int, (v_m ->> 'rho')::numeric,
          (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric, (v_m ->> 'top_bottom_ratio')::numeric,
          (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric, (v_m ->> 'coverage')::numeric, v_m);
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_backtest(UUID, DATE, DATE, TEXT) FROM PUBLIC, anon, authenticated;

-- 每日回測（基底 20261101000200）：預設 v3
DROP FUNCTION IF EXISTS public.reco_eval_daily(UUID, DATE, TEXT);
CREATE OR REPLACE FUNCTION public.reco_eval_daily(p_tenant UUID, p_day DATE, p_model TEXT DEFAULT 'v3')
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
  ), f AS (
    SELECT COALESCE(a.b, 0) AS actual, public._reco_features_asof(p_tenant, t.product_id, t.start_d, t.price) AS feat
      FROM t LEFT JOIN a ON a.id = t.id
  ), p AS (
    SELECT actual, CASE p_model WHEN 'v1' THEN public.reco_predict_v1(feat) WHEN 'v2' THEN public.reco_predict_v2(feat)
                  ELSE public.reco_predict_v3(feat) END AS pr
      FROM f WHERE feat IS NOT NULL
  )
  SELECT jsonb_agg(jsonb_build_object('pred', (pr ->> 'buyers')::numeric, 'low', (pr ->> 'low')::numeric,
                                      'high', (pr ->> 'high')::numeric, 'actual', actual))
    INTO v_rows
    FROM p WHERE pr IS NOT NULL;

  v_m := public._reco_eval_metrics(v_rows);
  DELETE FROM reco_eval_runs WHERE tenant_id = p_tenant AND kind = 'daily' AND window_from = p_day AND model_version = p_model;
  INSERT INTO reco_eval_runs (tenant_id, kind, model_version, window_from, window_to, n, rho, mae, median_ae,
                              top_bottom_ratio, zero_rate, ratio_median, coverage, details)
  VALUES (p_tenant, 'daily', p_model, p_day, p_day, COALESCE((v_m ->> 'n')::int, 0), (v_m ->> 'rho')::numeric,
          (v_m ->> 'mae')::numeric, (v_m ->> 'median_ae')::numeric, (v_m ->> 'top_bottom_ratio')::numeric,
          (v_m ->> 'zero_rate')::numeric, (v_m ->> 'ratio_median')::numeric, (v_m ->> 'coverage')::numeric,
          v_m || jsonb_build_object('actual', 'at_close'));
  RETURN v_m;
END;
$$;
REVOKE ALL ON FUNCTION public.reco_eval_daily(UUID, DATE, TEXT) FROM PUBLIC, anon, authenticated;

-- 套用當下：全部預估用 v3 重算（品類還沒標好的會跟 v2 一樣）、預選重排
UPDATE public.reco_predictions SET computed_at = '-infinity';
SELECT public.reco_refresh_predictions(1000);
SELECT public.reco_build_slates(t.tenant_id) FROM (SELECT DISTINCT tenant_id FROM public.reco_predictions) t;
