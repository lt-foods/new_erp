-- ============================================================================
-- 預估的價格分數改成「依種類」（Alex 2026-11-08：「金額評分要換成種類不同分數不同」）
--
-- 原本：全站一律 <200 ×1.25、200～300 ×0.85、>300 ×0.3（20261101000160，用 10 月開團售價校的）。
-- 11/8 查近 120 天已結束的總倉團，同樣 300 元以上：肉品每團 36 人（<200 是 41，幾乎沒掉）、海鮮 13 人、
-- 日用品 200 以上就只剩一半。海鮮肉品 300 元以上的候選有 87 筆被打三折、全部進不了推薦。
--
-- 改法（_reco_price_mult）：每個主標籤用自己近 120 天已結束團的價格分三段（p33 / p67），
-- 分數 = 該段每團平均買家 ÷ 該標籤整體平均，往 1 收縮（k=10）、夾在 0.25～1.4。
--   例：肉品 ≥155 元算「貴」，但貴的肉品買的人只少一成 → ×0.9；日用品 ≥109 元算貴 → ×0.4。
-- 該標籤不到 30 團 → 退回全站 200 / 300 兩條線（舊規則）。候選的標籤依序試，第一個夠資料的為準。
-- 算法帶 as-of 日期（只看那天之前 10 天以前結束的團），回測不偷看答案。
--
-- 動到的：
--   _reco_price_mult（新）、_reco_product_tags（新，商品的非溫層標籤依 sort）
--   reco_predict_v1（基底 20261101000160）：特徵裡有 price_mult 就用它，沒有退回舊兩條線；理由文字改寫
--   reco_compute_features（基底 20261102000010）、_reco_features_asof（基底 20261101000220）、
--   _reco_features_campaign（基底 20261101000250）：特徵多 price_mult
--   reco_refresh_predictions（基底 20261101000220）：feature_version f3 → f4；套用時把預估標舊，10 分鐘一批 300 重算
-- 回測（11/8，10/1～10/25 第一次開的團，v3）：套用前後的 ρ 寫在 PR。
--
-- rollback：重跑五支基底版本；DROP FUNCTION public._reco_price_mult(UUID, TEXT[], NUMERIC, DATE), public._reco_product_tags(BIGINT);
--   UPDATE reco_predictions SET computed_at = now() - interval '7 hours';（讓它用舊特徵重算）
-- ============================================================================

-- 商品的標籤（非溫層），照 product_tags.sort 排，第一個就是主標籤
CREATE OR REPLACE FUNCTION public._reco_product_tags(p_product BIGINT)
RETURNS TEXT[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(t.code ORDER BY t.sort, t.id), '{}')
    FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
   WHERE m.product_id = p_product AND t.tag_group <> '溫層';
$$;
REVOKE ALL ON FUNCTION public._reco_product_tags(BIGINT) FROM PUBLIC, anon, authenticated;

-- 依種類的價格分數
CREATE OR REPLACE FUNCTION public._reco_price_mult(p_tenant UUID, p_tags TEXT[], p_price NUMERIC, p_asof DATE)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tag   TEXT;
  v_name  TEXT;
  v_n     INT;
  v_p33   NUMERIC;
  v_p67   NUMERIC;
  v_avg   NUMERIC;
  v_band  TEXT;
  v_bavg  NUMERIC;
  v_bn    INT;
  v_mult  NUMERIC;
  v_asof  DATE := COALESCE(p_asof, current_date);
BEGIN
  IF p_price IS NULL OR p_price <= 0 THEN RETURN NULL; END IF;

  -- 候選的標籤依序試，第一個近 120 天有 ≥30 團的為準
  FOR v_tag IN SELECT x FROM unnest(COALESCE(p_tags, '{}')) x LOOP
    WITH s AS (
      SELECT pr.price, rb.buyers::numeric AS buyers
        FROM reco_campaign_buyers rb
        JOIN LATERAL (SELECT min(ci.unit_price) AS price FROM campaign_items ci
                       WHERE ci.campaign_id = rb.campaign_id AND NOT COALESCE(ci.is_gift, FALSE)) pr ON TRUE
       WHERE rb.tenant_id = p_tenant AND rb.settled
         AND rb.start_date BETWEEN v_asof - 120 AND v_asof - 10
         AND pr.price > 0
         AND EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                      WHERE m.product_id = rb.product_id AND t.code = v_tag)
    ), q AS (
      SELECT count(*) AS n, percentile_cont(0.33) WITHIN GROUP (ORDER BY price) AS p33,
             percentile_cont(0.67) WITHIN GROUP (ORDER BY price) AS p67, avg(buyers) AS a
        FROM s
    )
    SELECT q.n, q.p33, q.p67, q.a,
           -- 跟 p_price 同一段（低 / 中 / 高）的團
           avg(s.buyers) FILTER (WHERE (s.price < q.p33) = (p_price < q.p33) AND (s.price < q.p67) = (p_price < q.p67)),
           count(*)      FILTER (WHERE (s.price < q.p33) = (p_price < q.p33) AND (s.price < q.p67) = (p_price < q.p67))
      INTO v_n, v_p33, v_p67, v_avg, v_bavg, v_bn
      FROM q LEFT JOIN s ON TRUE
     GROUP BY q.n, q.p33, q.p67, q.a;
    IF COALESCE(v_n, 0) >= 30 AND COALESCE(v_avg, 0) > 0 THEN
      v_band := CASE WHEN p_price < v_p33 THEN 'low' WHEN p_price < v_p67 THEN 'mid' ELSE 'high' END;
      -- 往 1 收縮（k=10）、夾住
      v_mult := (COALESCE(v_bn, 0) * COALESCE(v_bavg / v_avg, 1) + 10) / (COALESCE(v_bn, 0) + 10);
      v_mult := LEAST(1.4, GREATEST(0.25, round(v_mult, 2)));
      SELECT name INTO v_name FROM product_tags WHERE tenant_id = p_tenant AND code = v_tag LIMIT 1;
      RETURN jsonb_build_object('basis', 'tag', 'tag', v_tag, 'tag_name', COALESCE(v_name, v_tag), 'band', v_band,
                                'mult', v_mult, 'p33', round(v_p33), 'p67', round(v_p67), 'n', v_n, 'band_n', v_bn);
    END IF;
  END LOOP;

  -- 沒有夠資料的標籤：退回全站兩條線
  RETURN jsonb_build_object('basis', 'global',
                            'band', CASE WHEN p_price < 200 THEN 'low' WHEN p_price < 300 THEN 'mid' ELSE 'high' END,
                            'mult', CASE WHEN p_price < 200 THEN 1.25 WHEN p_price < 300 THEN 0.85 ELSE 0.3 END);
END;
$$;
REVOKE ALL ON FUNCTION public._reco_price_mult(UUID, TEXT[], NUMERIC, DATE) FROM PUBLIC, anon, authenticated;

-- reco_predict_v1（基底 20261101000160）
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
  v_pmj   JSONB   := p_f -> 'price_mult';   -- 20261108000020：依種類的價格分數
  v_pm    NUMERIC;
  v_raw   NUMERIC;
  v_est   NUMERIC;
  v_conf  TEXT;
  v_rng   NUMERIC[];
  v_rs    TEXT[] := '{}';
  v_first JSONB  := p_f -> 'knn' -> 0;
BEGIN
  IF v_knn IS NULL AND v_tag IS NULL THEN RETURN NULL; END IF;
  -- 有依種類算的分數就用它（_reco_price_mult）；沒有（舊特徵）退回全站 200 / 300 兩條線
  v_pm := COALESCE(NULLIF(v_pmj ->> 'mult', '')::numeric,
                   CASE v_band WHEN 'lt200' THEN 1.25 WHEN '200_300' THEN 0.85 WHEN 'gt300' THEN 0.3 ELSE 1 END);
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
  IF v_pmj IS NOT NULL AND v_pmj ->> 'basis' = 'tag' THEN
    v_rs := v_rs || format('報價 $%s，在%s算%s（×%s）', round((p_f ->> 'price')::numeric), v_pmj ->> 'tag_name',
                           CASE v_pmj ->> 'band' WHEN 'low' THEN '便宜' WHEN 'high' THEN '貴' ELSE '中等' END,
                           v_pmj ->> 'mult');
  ELSIF v_band IS NOT NULL THEN
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

-- reco_compute_features（基底 20261102000010）
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
    'price_mult', public._reco_price_mult(v_c.tenant_id, v_tags, v_i.price, current_date),
    'crowding', COALESCE(v_crowd, 0),
    'recent_open', COALESCE(v_recent, '[]'::jsonb),
    'is_food', v_food)
    || public._reco_reopen(v_c.tenant_id, v_i.embedding, now(), 0.85)  -- 廠商品名 vs 我方品名，同款門檻同「賣過」
    || public._reco_kind_features(v_c.tenant_id, v_i.kind, now(), FALSE)
    || public._reco_market_heat(v_c.tenant_id, v_i.embedding, v_i.kind);
END;
$$;

-- _reco_features_asof（基底 20261101000220）
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
    'price_mult', public._reco_price_mult(p_tenant, public._reco_product_tags(p_product), p_price, p_d),
    'is_food', v_food)
    || public._reco_reopen(p_tenant, v_emb, (p_d::timestamp AT TIME ZONE 'Asia/Taipei'))
    || public._reco_kind_features(p_tenant, (SELECT pk.kind FROM product_kinds pk WHERE pk.product_id = p_product),
                                  (p_d::timestamp AT TIME ZONE 'Asia/Taipei'), TRUE);
END;
$$;

-- _reco_features_campaign（基底 20261101000250）
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
    'price_mult', public._reco_price_mult(p_tenant, public._reco_product_tags(p_product), p_price, p_d),
    'is_food', v_food)
    || public._reco_reopen(p_tenant, v_emb, (p_d::timestamp AT TIME ZONE 'Asia/Taipei'))
    || public._reco_kind_features(p_tenant, (SELECT pk.kind FROM product_kinds pk WHERE pk.product_id = p_product),
                                  (p_d::timestamp AT TIME ZONE 'Asia/Taipei'), TRUE);
END;
$$;

-- reco_refresh_predictions（基底 20261101000220）
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
    VALUES (r.id, r.tenant_id, 'f4', v_f, now())
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

-- 既有預估全部標舊：排程每 10 分鐘重算 300 筆（約 6,500 筆、3.5 小時內換完）；先立刻算一批
UPDATE public.reco_predictions SET computed_at = now() - interval '7 hours';
SELECT public.reco_refresh_predictions(400);
