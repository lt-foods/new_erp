-- ============================================================================
-- 20261101000110_sold_threshold_vector_only.sql
--
-- 候選池「賣過」誤判（老闆 2026-11-01 回報：「韓國 MUNGYO 衣物去漬棒」被標賣過「日本衣物去漬清潔巾」）。
-- 原因：Claude / Cloudflare 整理的 norm_name 常是籠統的品類詞（「衣物去漬棒」「收納包」「長袖 T 恤」），
-- 二字詞比對對上同類商品就 0.75～1.00，被當成「賣過」。當時 24 個品項有 7 個這樣標成賣過。
--
-- bge-m3 本機實測（同一款 vs 只是同類）：
--   同一款：0.86～1.00（老師傅岡山羊肉爐 0.87、挪威鯖魚片 0.86、MUNGYO 去漬棒 0.89）；
--           行銷字很多的標題會低（Holista 蜂膠 0.73、晴王 vs Shine Muscat 0.54）
--   同類：  大多 0.48～0.62（MUNGYO 去漬棒 vs 去漬清潔巾 0.57）；例外 收納包 0.75、防霧濕巾 0.82
-- 新規則：
--   - 「賣過」只看向量：cosine ≥ 0.80（score 直接用 cosine）。二字詞分數最多算 0.7，不能單獨判賣過。
--   - score ≥ 0.6 列進 matches（前端標「類似」，附那款的團數／人數給老闆參考）。
--   - 候選池 duplicate_hint 門檻 0.75 → 0.8（rpc_market_post_write、rpc_ai_item_embed_write）。
-- 寧可把真的賣過的標成「類似」，也不要把沒賣過的說成賣過。
--
-- 基底：_match_products_by_norm @ 20261101000040、_match_products_hybrid @ 20261101000090、
--       rpc_market_post_write @ 20261101000100、rpc_ai_item_embed_write @ 20261101000090（皆已 grep，為最新版）。
-- 本檔最後把現有品項的 matches 重算一次、候選池狀態同步。
-- rollback：重跑上述四支基底版本的定義。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._match_products_by_norm(p_tenant UUID, p_norm TEXT, p_tags TEXT[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH cand AS (
    SELECT p.id, p.name, public._bigram_hit(p.name, p_norm) AS hit,
           EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                    WHERE m.product_id = p.id AND t.code = ANY (COALESCE(p_tags, '{}'))) AS tag_ok
      FROM products p
     WHERE p.tenant_id = p_tenant
  ),
  top AS (
    SELECT * FROM cand WHERE hit >= 0.5
     ORDER BY hit DESC, tag_ok DESC, id DESC
     LIMIT 5
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id', t.id, 'name', t.name, 'score', round(LEAST(t.hit, 0.7), 2), 'bigram', round(t.hit, 2), 'same_tag', t.tag_ok,
           'campaigns', h.campaigns, 'last_start', h.last_start, 'buyers', h.buyers
         ) ORDER BY t.hit DESC, t.tag_ok DESC, t.id DESC), '[]'::jsonb)
    FROM top t
    LEFT JOIN LATERAL (
      SELECT count(DISTINCT g.id) AS campaigns,
             max(g.start_at)::date AS last_start,
             (SELECT count(DISTINCT co.member_id)
                FROM customer_orders co
                JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
               WHERE co.campaign_id IN (SELECT id FROM group_buy_campaigns WHERE product_id = t.id)
                 AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')) AS buyers
        FROM group_buy_campaigns g WHERE g.product_id = t.id
    ) h ON TRUE;
$function$;

CREATE OR REPLACE FUNCTION public._match_products_hybrid(p_tenant UUID, p_vec extensions.vector, p_norm TEXT, p_tags TEXT[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
  WITH vec AS (
    SELECT e.product_id AS id, 1 - (e.embedding <=> p_vec) AS cos
      FROM product_embeddings e
     WHERE p_vec IS NOT NULL AND e.tenant_id = p_tenant
     ORDER BY e.embedding <=> p_vec
     LIMIT 20
  ),
  big AS (
    SELECT p.id, public._bigram_hit(p.name, p_norm) AS hit
      FROM products p
     WHERE p.tenant_id = p_tenant AND COALESCE(p_norm, '') <> ''
  ),
  cand AS (
    SELECT p.id, p.name,
           COALESCE(b.hit, 0) AS hit,
           v.cos,
           GREATEST(COALESCE(v.cos, 0), LEAST(COALESCE(b.hit, 0), 0.7)) AS score,
           EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                    WHERE m.product_id = p.id AND t.code = ANY (COALESCE(p_tags, '{}'))) AS tag_ok
      FROM products p
      LEFT JOIN vec v ON v.id = p.id
      LEFT JOIN big b ON b.id = p.id
     WHERE p.tenant_id = p_tenant AND (v.id IS NOT NULL OR b.hit >= 0.5)
  ),
  top AS (
    SELECT * FROM cand WHERE score >= 0.6
     ORDER BY score DESC, tag_ok DESC, id DESC
     LIMIT 5
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id', t.id, 'name', t.name, 'score', round(t.score::numeric, 2),
           'cos', round(t.cos::numeric, 3), 'bigram', round(t.hit::numeric, 2), 'same_tag', t.tag_ok,
           'campaigns', h.campaigns, 'last_start', h.last_start, 'buyers', h.buyers
         ) ORDER BY t.score DESC, t.tag_ok DESC, t.id DESC), '[]'::jsonb)
    FROM top t
    LEFT JOIN LATERAL (
      SELECT count(DISTINCT g.id) AS campaigns,
             max(g.start_at)::date AS last_start,
             (SELECT count(DISTINCT co.member_id)
                FROM customer_orders co
                JOIN members m ON m.id = co.member_id AND m.member_type <> 'store_internal'
               WHERE co.campaign_id IN (SELECT id FROM group_buy_campaigns WHERE product_id = t.id)
                 AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')) AS buyers
        FROM group_buy_campaigns g WHERE g.product_id = t.id
    ) h ON TRUE;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_market_post_write(p_post_id BIGINT, p_items JSONB, p_error TEXT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID;
  v_n            INT := 0;
  v_line_post_id TEXT;
  v_raw_id       BIGINT;
  v_raw_action   TEXT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT tenant_id, line_post_id INTO v_tenant, v_line_post_id FROM line_note_market_posts WHERE id = p_post_id;
  IF v_tenant IS NULL THEN RETURN 0; END IF;

  IF p_error IS NOT NULL THEN
    UPDATE line_note_market_posts SET parsed_at = NULL, parse_error = LEFT(p_error, 500) WHERE id = p_post_id;
    RETURN 0;
  END IF;

  DELETE FROM line_note_market_items WHERE post_id = p_post_id;

  INSERT INTO line_note_market_items
    (tenant_id, post_id, item_name, norm_name, price, price_text, spec, deadline_text, tags, matches)
  SELECT v_tenant, p_post_id,
         LEFT(btrim(e->>'item_name'), 200),
         NULLIF(LEFT(btrim(COALESCE(e->>'norm_name', '')), 100), ''),
         CASE WHEN (e->>'price') ~ '^\d+(\.\d+)?$' THEN (e->>'price')::numeric END,
         NULLIF(LEFT(e->>'price_text', 200), ''),
         NULLIF(LEFT(e->>'spec', 200), ''),
         NULLIF(LEFT(e->>'deadline_text', 200), ''),
         COALESCE((SELECT array_agg(t.code) FROM product_tags t
                    WHERE t.tenant_id = v_tenant AND t.is_active
                      AND t.code IN (SELECT jsonb_array_elements_text(COALESCE(e->'tags', '[]'::jsonb)))), '{}'),
         public._match_products_by_norm(
           v_tenant,
           COALESCE(NULLIF(btrim(e->>'norm_name'), ''), e->>'item_name'),
           ARRAY(SELECT jsonb_array_elements_text(COALESCE(e->'tags', '[]'::jsonb))))
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
   WHERE COALESCE(btrim(e->>'item_name'), '') <> ''
   LIMIT 30;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- 「待整理」那一筆：老闆還沒動過就刪掉（由正式品項取代）；動過的（收藏／排程…）改掛到
  -- 第一個品項的 id 上，下面的 upsert 只更新內容、保留老闆的狀態，不會多出一筆重複的
  SELECT id, owner_action INTO v_raw_id, v_raw_action
    FROM community_product_candidates
   WHERE tenant_id = v_tenant AND source_external_id = 'ln:' || v_line_post_id || ':raw';
  IF v_raw_id IS NOT NULL THEN
    IF v_raw_action = 'none' OR v_n = 0 THEN
      IF v_raw_action = 'none' THEN DELETE FROM community_product_candidates WHERE id = v_raw_id; END IF;
    ELSE
      UPDATE community_product_candidates
         SET source_external_id = 'ln:' || v_line_post_id || ':' ||
               md5((SELECT i.item_name FROM line_note_market_items i WHERE i.post_id = p_post_id ORDER BY i.id LIMIT 1))
       WHERE id = v_raw_id
         AND NOT EXISTS (SELECT 1 FROM community_product_candidates x
                          WHERE x.tenant_id = v_tenant AND x.source_external_id = 'ln:' || v_line_post_id || ':' ||
                                md5((SELECT i.item_name FROM line_note_market_items i WHERE i.post_id = p_post_id ORDER BY i.id LIMIT 1)));
    END IF;
  END IF;

  -- 每個商品進候選池（老闆動過的不改狀態，只更新內容）
  INSERT INTO community_product_candidates AS cc
    (tenant_id, source_channel, source_user_name, source_external_id, product_name_hint, raw_text,
     raw, parsed, parsed_at, system_status, similar_product_id, similarity_score)
  SELECT v_tenant,
         '廠商群組｜' || COALESCE(s.name, c.home_name, ''),
         p.author_name,
         'ln:' || p.line_post_id || ':' || md5(i.item_name),
         i.item_name || COALESCE('（' || i.spec || '）', ''),
         CASE WHEN btrim(p.text) = '' THEN i.item_name ELSE p.text END,
         jsonb_build_object('source', 'line_note_supplier', 'market_post_id', p.id, 'market_item_id', i.id,
                            'community_id', c.id, 'supplier_id', c.crawl_supplier_id, 'posted_at', p.posted_at),
         jsonb_build_object('price', i.price, 'price_text', i.price_text, 'spec', i.spec,
                            'deadline_text', i.deadline_text, 'norm_name', i.norm_name, 'tags', to_jsonb(i.tags),
                            'matches', i.matches, 'supplier', s.name, 'comment_count', p.comment_count),
         now(),
         CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.8 THEN 'duplicate_hint' ELSE 'new' END,
         (i.matches -> 0 ->> 'product_id')::bigint,
         LEAST((i.matches -> 0 ->> 'score')::numeric, 1)
    FROM line_note_market_items i
    JOIN line_note_market_posts p ON p.id = i.post_id
    JOIN line_note_communities c ON c.id = p.community_id
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id
   WHERE i.post_id = p_post_id
  ON CONFLICT (tenant_id, source_external_id) WHERE source_external_id IS NOT NULL DO UPDATE
     SET product_name_hint = EXCLUDED.product_name_hint,
         raw_text = EXCLUDED.raw_text,
         raw = EXCLUDED.raw,
         parsed = EXCLUDED.parsed,
         parsed_at = EXCLUDED.parsed_at,
         similar_product_id = EXCLUDED.similar_product_id,
         similarity_score = EXCLUDED.similarity_score,
         system_status = CASE WHEN cc.owner_action = 'none' AND cc.system_status IN ('new', 'duplicate_hint')
                              THEN EXCLUDED.system_status ELSE cc.system_status END;

  -- 重新整理（貼文改過、或人工重跑）時品名寫法變了：同一篇裡老闆還沒動過、這次沒出現的舊品項清掉，
  -- 不然候選池會同一個商品掛兩筆
  DELETE FROM community_product_candidates cc
   WHERE cc.tenant_id = v_tenant
     AND cc.source_external_id LIKE 'ln:' || v_line_post_id || ':%'
     AND cc.source_external_id <> 'ln:' || v_line_post_id || ':raw'
     AND cc.owner_action = 'none'
     AND cc.source_external_id NOT IN (
           SELECT 'ln:' || v_line_post_id || ':' || md5(i.item_name)
             FROM line_note_market_items i WHERE i.post_id = p_post_id);

  UPDATE line_note_market_posts SET parse_error = NULL WHERE id = p_post_id;
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_ai_item_embed_write(p_rows JSONB)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_n INT := 0;
  r   RECORD;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  FOR r IN
    SELECT i.id, i.tenant_id, i.post_id, i.item_name, i.norm_name, i.tags,
           (x->'embedding')::text::extensions.vector AS vec
      FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) x
      JOIN line_note_market_items i ON i.id = (x->>'item_id')::bigint
     WHERE jsonb_array_length(x->'embedding') = 1024
  LOOP
    UPDATE line_note_market_items
       SET embedding = r.vec,
           matches = public._match_products_hybrid(r.tenant_id, r.vec, COALESCE(NULLIF(r.norm_name, ''), r.item_name), r.tags)
     WHERE id = r.id;

    UPDATE community_product_candidates cc
       SET parsed = jsonb_set(COALESCE(cc.parsed, '{}'::jsonb), '{matches}', i.matches),
           similar_product_id = (i.matches -> 0 ->> 'product_id')::bigint,
           similarity_score = LEAST((i.matches -> 0 ->> 'score')::numeric, 1),
           system_status = CASE WHEN cc.owner_action = 'none' AND cc.system_status IN ('new', 'duplicate_hint')
                                THEN CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.8
                                          THEN 'duplicate_hint' ELSE 'new' END
                                ELSE cc.system_status END
      FROM line_note_market_items i
      JOIN line_note_market_posts p ON p.id = i.post_id
     WHERE i.id = r.id
       AND cc.tenant_id = r.tenant_id
       AND cc.source_external_id = 'ln:' || p.line_post_id || ':' || md5(i.item_name);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;

-- 現有品項重算（有向量的用混合比對，沒有的用二字詞，分數最多 0.7）
UPDATE line_note_market_items i
   SET matches = CASE WHEN i.embedding IS NOT NULL
                      THEN public._match_products_hybrid(i.tenant_id, i.embedding, COALESCE(NULLIF(i.norm_name, ''), i.item_name), i.tags)
                      ELSE public._match_products_by_norm(i.tenant_id, COALESCE(NULLIF(i.norm_name, ''), i.item_name), i.tags) END;

UPDATE community_product_candidates cc
   SET parsed = jsonb_set(COALESCE(cc.parsed, '{}'::jsonb), '{matches}', i.matches),
       similar_product_id = (i.matches -> 0 ->> 'product_id')::bigint,
       similarity_score = LEAST((i.matches -> 0 ->> 'score')::numeric, 1),
       system_status = CASE WHEN cc.owner_action = 'none' AND cc.system_status IN ('new', 'duplicate_hint')
                            THEN CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.8
                                      THEN 'duplicate_hint' ELSE 'new' END
                            ELSE cc.system_status END
  FROM line_note_market_items i
  JOIN line_note_market_posts p ON p.id = i.post_id
 WHERE cc.tenant_id = i.tenant_id
   AND cc.source_external_id = 'ln:' || p.line_post_id || ':' || md5(i.item_name);
