-- ============================================================================
-- 市場熱門：匯入蝦皮助手等外部熱銷榜 → 對上廠商有開的品項 → 預選加權（20261102000010）
--
-- Alex 2026-11-02：「用蝦皮助手分析現在最熱門的商品，再來看廠商有開的商品，然後再從系統推薦開團」。
-- 規劃見 docs/PLAN-選品系統-外部來源與商品媒合.md（① 進料：外部榜單；④ 特徵：市場熱度）。
--
-- ① 進料：market_hot_batches / market_hot_products。後台「市場熱門」頁上傳蝦皮助手匯出的
--    Excel / CSV，前端對欄位（品名、價格、月銷量、銷售額、成長、類目、店鋪、連結），
--    rpc_market_hot_import 寫進來。總部角色才能匯入 / 刪除批次。
-- ② 理解：market-ai 幫榜單商品算向量（rpc_ai_hot_embed_claim / write）、標品類
--    （rpc_ai_kind_claim / write 多一種 target 'hot'）；_market_ai_tick 也為它們叫醒。
-- ④ 特徵 _reco_market_heat：候選品對近 45 天匯入的熱銷品，向量 ≥ 0.75 或同品類的前 3 個
--    （heat_matches：品名、月銷、價格、相似度、來源、日期）。
-- ⑤ 預估數字不變（市場熱度還沒有歷史可驗證），理由多一行「蝦皮熱銷：「X」月銷 N 件」。
-- ⑥ 預選：有對上熱銷品的候選，照預估排序時 ×1.2（只影響排序，不改預估數字）。
-- 頁面用 rpc_market_hot_list：每個熱銷品 → 廠商有沒有在賣（候選池）→ 我們賣過沒有。
--
-- 基底（各自最新版，已 grep）：rpc_ai_kind_claim / rpc_ai_kind_write / reco_compute_features /
--   reco_predict_v3 @ 20261101000220；_market_ai_tick @ 20261101000230；reco_build_slates @ 20261101000190。
-- rollback：重跑上述基底版本；
--   DROP FUNCTION public.rpc_market_hot_list(INT), public.rpc_market_hot_import(TEXT, DATE, TEXT, JSONB),
--     public.rpc_market_hot_delete_batch(BIGINT), public.rpc_ai_hot_embed_claim(INT), public.rpc_ai_hot_embed_write(JSONB),
--     public._reco_market_heat(UUID, extensions.vector, TEXT), public._reco_heat_reason(JSONB, JSONB);
--   DROP TABLE public.market_hot_products, public.market_hot_batches;
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.market_hot_batches (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID   NOT NULL,
  source      TEXT   NOT NULL,
  file_name   TEXT,
  captured_at DATE   NOT NULL,
  rows        INT    NOT NULL DEFAULT 0,
  created_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.market_hot_batches IS '外部熱銷榜匯入批次（蝦皮助手等，20261102000010）';

CREATE TABLE IF NOT EXISTS public.market_hot_products (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID   NOT NULL,
  batch_id    BIGINT NOT NULL REFERENCES public.market_hot_batches(id) ON DELETE CASCADE,
  source      TEXT   NOT NULL,
  captured_at DATE   NOT NULL,
  name        TEXT   NOT NULL,
  price       NUMERIC,
  sales_30d   INT,
  revenue     NUMERIC,
  growth      NUMERIC,
  category    TEXT,
  shop        TEXT,
  url         TEXT,
  rank        INT,
  raw         JSONB,
  kind        TEXT,
  kind_at     TIMESTAMPTZ,
  embedding   extensions.vector(1024),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_mhp_tenant_date ON public.market_hot_products (tenant_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_mhp_kind ON public.market_hot_products (tenant_id, kind);
CREATE INDEX IF NOT EXISTS idx_mhp_embedding ON public.market_hot_products
  USING hnsw (embedding extensions.vector_cosine_ops);
COMMENT ON TABLE public.market_hot_products IS
  '外部熱銷榜的商品（蝦皮助手等）。推薦系統算「市場熱度」用（20261102000010）';

ALTER TABLE public.market_hot_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_hot_products ENABLE ROW LEVEL SECURITY;
CREATE POLICY market_hot_batches_hq_read ON public.market_hot_batches FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
CREATE POLICY market_hot_products_hq_read ON public.market_hot_products FOR SELECT TO authenticated
  USING (tenant_id = ((SELECT auth.jwt()) ->> 'tenant_id')::uuid
         AND COALESCE((SELECT auth.jwt()) -> 'app_metadata' ->> 'role', '') IN ('owner', 'admin', 'hq_manager', 'assistant', ''));
GRANT SELECT ON public.market_hot_batches, public.market_hot_products TO authenticated;

-- 匯入一批：p_rows = [{name, price, sales_30d, revenue, growth, category, shop, url, rank, raw}]
CREATE OR REPLACE FUNCTION public.rpc_market_hot_import(p_source TEXT, p_captured_at DATE, p_file_name TEXT, p_rows JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
  v_batch  BIGINT;
  v_n      INT;
BEGIN
  IF v_tenant IS NULL
     OR COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN RAISE EXCEPTION '沒有資料'; END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN RAISE EXCEPTION '一次最多 5000 筆'; END IF;

  INSERT INTO market_hot_batches (tenant_id, source, file_name, captured_at, created_by)
  VALUES (v_tenant, COALESCE(NULLIF(btrim(p_source), ''), 'shopee'), LEFT(p_file_name, 200),
          COALESCE(p_captured_at, (now() AT TIME ZONE 'Asia/Taipei')::date), auth.uid())
  RETURNING id INTO v_batch;

  INSERT INTO market_hot_products (tenant_id, batch_id, source, captured_at, name, price, sales_30d, revenue, growth,
                                   category, shop, url, rank, raw)
  SELECT v_tenant, v_batch, b.source, b.captured_at,
         LEFT(btrim(x ->> 'name'), 300),
         NULLIF(regexp_replace(COALESCE(x ->> 'price', ''), '[^0-9.]', '', 'g'), '')::numeric,
         NULLIF(regexp_replace(COALESCE(x ->> 'sales_30d', ''), '[^0-9]', '', 'g'), '')::int,
         NULLIF(regexp_replace(COALESCE(x ->> 'revenue', ''), '[^0-9.]', '', 'g'), '')::numeric,
         NULLIF(regexp_replace(COALESCE(x ->> 'growth', ''), '[^0-9.\-]', '', 'g'), '')::numeric,
         NULLIF(LEFT(btrim(x ->> 'category'), 120), ''),
         NULLIF(LEFT(btrim(x ->> 'shop'), 120), ''),
         NULLIF(LEFT(btrim(x ->> 'url'), 500), ''),
         NULLIF(regexp_replace(COALESCE(x ->> 'rank', ''), '[^0-9]', '', 'g'), '')::int,
         x -> 'raw'
    FROM jsonb_array_elements(p_rows) x
    CROSS JOIN market_hot_batches b
   WHERE b.id = v_batch AND COALESCE(btrim(x ->> 'name'), '') <> '';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE market_hot_batches SET rows = v_n WHERE id = v_batch;
  RETURN jsonb_build_object('batch_id', v_batch, 'rows', v_n);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_hot_import(TEXT, DATE, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_market_hot_import(TEXT, DATE, TEXT, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_market_hot_delete_batch(p_batch_id BIGINT)
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
  DELETE FROM market_hot_batches WHERE id = p_batch_id AND tenant_id = v_tenant;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_hot_delete_batch(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_market_hot_delete_batch(BIGINT) TO authenticated;

-- ② 向量（market-ai）
CREATE OR REPLACE FUNCTION public.rpc_ai_hot_embed_claim(p_limit INT DEFAULT 50)
RETURNS TABLE (id BIGINT, body TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT h.id, btrim(h.name || CASE WHEN h.category IS NOT NULL THEN '｜' || h.category ELSE '' END)
    FROM market_hot_products h
   WHERE h.embedding IS NULL
   ORDER BY h.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_hot_embed_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_hot_embed_claim(INT) TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_ai_hot_embed_write(p_rows JSONB)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_n INT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE market_hot_products h
     SET embedding = (x ->> 'embedding')::extensions.vector
    FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) x
   WHERE h.id = (x ->> 'id')::bigint;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- 有新的熱銷品 → 候選的預估（理由裡的熱銷那行）10 分鐘內重算
  IF v_n > 0 THEN
    UPDATE reco_predictions SET computed_at = '-infinity' WHERE computed_at > now() - interval '7 hours';
  END IF;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_hot_embed_write(JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_hot_embed_write(JSONB) TO service_role;

-- ② 品類（基底 20261101000220）：多一種 target 'hot'
CREATE OR REPLACE FUNCTION public.rpc_ai_kind_claim(p_limit INT DEFAULT 40)
RETURNS TABLE (target TEXT, id BIGINT, name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lim INT := LEAST(GREATEST(COALESCE(p_limit, 40), 1), 100);
  v_hot INT;
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

  -- 市場熱門（蝦皮助手等匯入的榜單，20261102000010）
  RETURN QUERY
  WITH picked AS (
    SELECT h.id FROM market_hot_products h
     WHERE h.kind IS NULL AND (h.kind_at IS NULL OR h.kind_at < now() - interval '1 day')
     ORDER BY h.id DESC LIMIT v_lim
     FOR UPDATE SKIP LOCKED
  ), marked AS (
    UPDATE market_hot_products h SET kind_at = now() FROM picked WHERE h.id = picked.id
    RETURNING h.id, h.name
  )
  SELECT 'hot'::text, m.id, m.name FROM marked m;
  GET DIAGNOSTICS v_hot = ROW_COUNT;
  v_lim := v_lim - v_hot;
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
    ELSIF r ->> 'target' = 'hot' THEN
      UPDATE market_hot_products SET kind = v_k, kind_at = now() WHERE id = (r ->> 'id')::bigint;
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

-- ④ 市場熱度：近 45 天匯入的熱銷品裡，跟這個候選最像（向量 ≥ 0.75）或同品類的前 3 個
CREATE OR REPLACE FUNCTION public._reco_market_heat(p_tenant UUID, p_emb extensions.vector, p_kind TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  WITH v AS (
    SELECT h.id, (1 - (h.embedding <=> p_emb))::numeric AS cos
      FROM market_hot_products h
     WHERE p_emb IS NOT NULL AND h.tenant_id = p_tenant AND h.embedding IS NOT NULL
       AND h.captured_at >= current_date - 45
     ORDER BY h.embedding <=> p_emb
     LIMIT 20
  ), k AS (
    SELECT h.id, NULL::numeric AS cos
      FROM market_hot_products h
     WHERE p_kind IS NOT NULL AND h.tenant_id = p_tenant AND h.kind = p_kind
       AND h.captured_at >= current_date - 45
  ), m AS (
    SELECT h.*, (SELECT max(v.cos) FROM v WHERE v.id = h.id) AS cos
      FROM market_hot_products h
     WHERE h.id IN (SELECT id FROM v WHERE cos >= 0.75 UNION SELECT id FROM k)
     ORDER BY COALESCE(h.sales_30d, 0) DESC, h.captured_at DESC
     LIMIT 3
  )
  SELECT jsonb_build_object('heat_matches', COALESCE(jsonb_agg(jsonb_build_object(
           'name', m.name, 'sales_30d', m.sales_30d, 'price', m.price, 'cos', round(m.cos, 3),
           'source', m.source, 'captured_at', m.captured_at, 'kind', m.kind) ORDER BY COALESCE(m.sales_30d, 0) DESC), '[]'::jsonb))
    FROM m;
$$;
REVOKE ALL ON FUNCTION public._reco_market_heat(UUID, extensions.vector, TEXT) FROM PUBLIC, anon, authenticated;

-- ⑤ 理由多一行熱銷（不改數字）
CREATE OR REPLACE FUNCTION public._reco_heat_reason(p_p JSONB, p_f JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_p IS NULL OR jsonb_array_length(COALESCE(p_f -> 'heat_matches', '[]'::jsonb)) = 0 THEN p_p
    ELSE p_p || jsonb_build_object('reasons', COALESCE(p_p -> 'reasons', '[]'::jsonb) || to_jsonb(format('%s熱銷：「%s」%s',
           CASE p_f -> 'heat_matches' -> 0 ->> 'source' WHEN 'shopee' THEN '蝦皮' WHEN '1688' THEN '1688' ELSE '市場' END,
           LEFT(p_f -> 'heat_matches' -> 0 ->> 'name', 24),
           CASE WHEN NULLIF(p_f -> 'heat_matches' -> 0 ->> 'sales_30d', '') IS NOT NULL
                THEN format('月銷 %s 件', p_f -> 'heat_matches' -> 0 ->> 'sales_30d') ELSE '在熱銷榜上' END)))
  END;
$$;

-- ④ 特徵（基底 20261101000220）：多市場熱度
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
    || public._reco_kind_features(v_c.tenant_id, v_i.kind, now(), FALSE)
    || public._reco_market_heat(v_c.tenant_id, v_i.embedding, v_i.kind);
END;
$$;
REVOKE ALL ON FUNCTION public.reco_compute_features(BIGINT) FROM PUBLIC, anon, authenticated;

-- ⑤ v3（基底 20261101000220）：數字不變，理由多熱銷一行
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
  IF v_kind IS NULL THEN RETURN public._reco_heat_reason(public.reco_predict_v2(p_f), p_f); END IF;
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
  RETURN public._reco_heat_reason(v_p || jsonb_build_object('reasons', v_rs, 'recent_open', v_open, 'kind', v_kind), p_f);
END;
$$;

-- 喚醒條件（基底 20261101000230）：榜單缺向量 / 品類也叫
CREATE OR REPLACE FUNCTION public._market_ai_tick()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM line_note_market_posts WHERE parsed_at IS NULL)
     AND NOT EXISTS (SELECT 1 FROM line_note_market_items WHERE embedding IS NULL)
     AND NOT EXISTS (SELECT 1 FROM products p
                      WHERE p.status <> 'discontinued'
                        AND NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id)
                        AND (p.tag_llm_at IS NULL OR p.tag_llm_at < now() - INTERVAL '30 days'))
     -- 只看「缺向量」（便宜）；品名／標籤改過、要重算的，等 market-ai 有被叫起來時 claim 會一起撿
     AND NOT EXISTS (SELECT 1 FROM products p
                      WHERE NOT EXISTS (SELECT 1 FROM product_embeddings e WHERE e.product_id = p.id))
     -- 品類（20261101000220）：品項或商品還沒標、或上次失敗滿一天
     AND NOT EXISTS (SELECT 1 FROM line_note_market_items i
                      WHERE i.kind IS NULL AND (i.kind_at IS NULL OR i.kind_at < now() - INTERVAL '1 day'))
     -- 市場熱門榜單（20261102000010）：缺向量或品類
     AND NOT EXISTS (SELECT 1 FROM market_hot_products h
                      WHERE h.embedding IS NULL
                         OR (h.kind IS NULL AND (h.kind_at IS NULL OR h.kind_at < now() - INTERVAL '1 day')))
     AND NOT EXISTS (SELECT 1 FROM products p
                      LEFT JOIN product_kinds k ON k.product_id = p.id
                      WHERE COALESCE(btrim(p.name), '') <> ''
                        AND (k.product_id IS NULL
                             OR (k.kind IS NULL AND (k.labeled_at IS NULL OR k.labeled_at < now() - INTERVAL '1 day')))) THEN
    RETURN;
  END IF;

  SELECT replace(decrypted_secret, 'line-note-worker', 'market-ai') INTO v_url
    FROM vault.decrypted_secrets WHERE name = 'line_note_worker_url' LIMIT 1;
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'line_note_cron_secret' LIMIT 1;
  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'market-ai-tick: vault 缺 line_note_worker_url / line_note_cron_secret，略過';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-line-note-secret', v_secret),
    body    := '{"action":"tick"}'::jsonb,
    timeout_milliseconds := 150000
  );
END;
$$;
REVOKE ALL ON FUNCTION public._market_ai_tick() FROM PUBLIC, anon, authenticated;

-- ⑥ 預選（基底 20261101000190）：對上熱銷品的 ×1.2 排序
CREATE OR REPLACE FUNCTION public.reco_build_slates(p_tenant UUID, p_days INT DEFAULT 6, p_per_day INT DEFAULT 10,
                                                    p_min_buyers INT DEFAULT 8, p_explore INT DEFAULT 2)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today   DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_exploit INT  := GREATEST(p_per_day - GREATEST(p_explore, 0), 0);
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
      CONTINUE WHEN r.tag <> 'other' AND EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND tag = r.tag);
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
           AND (sp.tag = 'other' OR NOT EXISTS (SELECT 1 FROM _slate_fill WHERE d = v_d AND tag = sp.tag))
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

-- 頁面：熱銷品 → 廠商有沒有在賣（候選池 14 天內）→ 我們賣過沒有
CREATE OR REPLACE FUNCTION public.rpc_market_hot_list(p_days INT DEFAULT 45)
RETURNS TABLE (
  id BIGINT, source TEXT, captured_at DATE, name TEXT, price NUMERIC, sales_30d INT, revenue NUMERIC, growth NUMERIC,
  category TEXT, shop TEXT, url TEXT, kind TEXT, ready BOOLEAN, supplier_matches JSONB, sold JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
BEGIN
  IF v_tenant IS NULL
     OR COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN QUERY
  SELECT h.id, h.source, h.captured_at, h.name, h.price, h.sales_30d, h.revenue, h.growth, h.category, h.shop, h.url, h.kind,
         h.embedding IS NOT NULL,
         -- 廠商有開：候選池（未處理 / 收藏 / 已排程、14 天內）的廠商品項，向量 ≥ 0.75 或同品類
         (SELECT COALESCE(jsonb_agg(s ORDER BY s.cos DESC NULLS LAST), '[]'::jsonb) FROM (
          SELECT * FROM (
            -- 同一個品名（廠商重複貼）只列一次
            SELECT DISTINCT ON (i.item_name) c.id AS candidate_id, i.item_name AS name, i.price, c.owner_action,
                   round((1 - (i.embedding <=> h.embedding))::numeric, 3) AS cos,
                   p.buyers AS predicted, p.confidence, p.low, p.high,
                   (SELECT sup.name FROM suppliers sup WHERE sup.id = (c.raw ->> 'supplier_id')::bigint) AS supplier
              FROM community_product_candidates c
              JOIN line_note_market_items i ON i.id = (c.raw ->> 'market_item_id')::bigint
              LEFT JOIN reco_predictions p ON p.candidate_id = c.id
             WHERE c.tenant_id = v_tenant AND c.created_at > now() - interval '14 days'
               AND c.owner_action IN ('none', 'collected', 'scheduled')
               AND h.embedding IS NOT NULL AND i.embedding IS NOT NULL
               AND ((1 - (i.embedding <=> h.embedding)) >= 0.75 OR (h.kind IS NOT NULL AND i.kind = h.kind))
             ORDER BY i.item_name, i.embedding <=> h.embedding) d
           ORDER BY d.cos DESC NULLS LAST
           LIMIT 3) s),
         -- 我們賣過：最像的已賣商品（向量 ≥ 0.85）
         (SELECT to_jsonb(x) FROM (
            SELECT pr.name, round((1 - (e.embedding <=> h.embedding))::numeric, 3) AS cos,
                   (SELECT round(avg(rb.buyers)) FROM reco_campaign_buyers rb WHERE rb.product_id = e.product_id AND rb.settled) AS buyers,
                   (SELECT count(*) FROM reco_campaign_buyers rb WHERE rb.product_id = e.product_id) AS campaigns
              FROM product_embeddings e JOIN products pr ON pr.id = e.product_id
             WHERE h.embedding IS NOT NULL AND e.tenant_id = v_tenant
             ORDER BY e.embedding <=> h.embedding LIMIT 1) x
           WHERE x.cos >= 0.85)
    FROM market_hot_products h
   WHERE h.tenant_id = v_tenant AND h.captured_at >= current_date - GREATEST(COALESCE(p_days, 45), 1)
   ORDER BY h.captured_at DESC, h.sales_30d DESC NULLS LAST, h.id
   LIMIT 500;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_hot_list(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_market_hot_list(INT) TO authenticated;

