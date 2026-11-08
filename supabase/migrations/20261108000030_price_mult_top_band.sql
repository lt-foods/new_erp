-- ============================================================================
-- 依種類的價格分數：最貴那段再切一刀（20261108000020 的補強）
--
-- 20261108000020 把價格分低 / 中 / 高三段，「高」沒有上限：肉品 180 元和 600 元拿一樣的 ×1.07，
-- 原本 300 元以上的懲罰等於消失。加第四段「很貴」= 該種類價格最高的 10%（p90 以上），
-- 分數一樣用那一段實際賣多少算（肉品 p90 234、海鮮 229、零食 599）。
--
-- 基底版本：_reco_price_mult、reco_predict_v1 ← 20261108000020_price_mult_by_category.sql
-- rollback：重跑 20261108000020 的兩支；UPDATE reco_predictions SET computed_at = now() - interval '7 hours';
-- ============================================================================

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
  v_p90   NUMERIC;
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
             percentile_cont(0.67) WITHIN GROUP (ORDER BY price) AS p67,
             percentile_cont(0.90) WITHIN GROUP (ORDER BY price) AS p90, avg(buyers) AS a
        FROM s
    )
    SELECT q.n, q.p33, q.p67, q.p90, q.a,
           -- 跟 p_price 同一段（低 / 中 / 高 / 很貴）的團
           avg(s.buyers) FILTER (WHERE (s.price < q.p33) = (p_price < q.p33) AND (s.price < q.p67) = (p_price < q.p67)
                                   AND (s.price < q.p90) = (p_price < q.p90)),
           count(*)      FILTER (WHERE (s.price < q.p33) = (p_price < q.p33) AND (s.price < q.p67) = (p_price < q.p67)
                                   AND (s.price < q.p90) = (p_price < q.p90))
      INTO v_n, v_p33, v_p67, v_p90, v_avg, v_bavg, v_bn
      FROM q LEFT JOIN s ON TRUE
     GROUP BY q.n, q.p33, q.p67, q.p90, q.a;
    IF COALESCE(v_n, 0) >= 30 AND COALESCE(v_avg, 0) > 0 THEN
      v_band := CASE WHEN p_price < v_p33 THEN 'low' WHEN p_price < v_p67 THEN 'mid'
                     WHEN p_price < v_p90 THEN 'high' ELSE 'top' END;
      -- 往 1 收縮（k=10）、夾住
      v_mult := (COALESCE(v_bn, 0) * COALESCE(v_bavg / v_avg, 1) + 10) / (COALESCE(v_bn, 0) + 10);
      v_mult := LEAST(1.4, GREATEST(0.25, round(v_mult, 2)));
      SELECT name INTO v_name FROM product_tags WHERE tenant_id = p_tenant AND code = v_tag LIMIT 1;
      RETURN jsonb_build_object('basis', 'tag', 'tag', v_tag, 'tag_name', COALESCE(v_name, v_tag), 'band', v_band,
                                'mult', v_mult, 'p33', round(v_p33), 'p67', round(v_p67), 'p90', round(v_p90), 'n', v_n, 'band_n', v_bn);
    END IF;
  END LOOP;

  -- 沒有夠資料的標籤：退回全站兩條線
  RETURN jsonb_build_object('basis', 'global',
                            'band', CASE WHEN p_price < 200 THEN 'low' WHEN p_price < 300 THEN 'mid' ELSE 'high' END,
                            'mult', CASE WHEN p_price < 200 THEN 1.25 WHEN p_price < 300 THEN 0.85 ELSE 0.3 END);
END;
$$;
REVOKE ALL ON FUNCTION public._reco_price_mult(UUID, TEXT[], NUMERIC, DATE) FROM PUBLIC, anon, authenticated;

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
                           CASE v_pmj ->> 'band' WHEN 'low' THEN '便宜' WHEN 'high' THEN '貴' WHEN 'top' THEN '很貴' ELSE '中等' END,
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

-- 已經用三段算過的（f4）再重算一次
UPDATE public.reco_predictions SET computed_at = now() - interval '7 hours';
SELECT public.reco_refresh_predictions(400);
