-- ============================================================================
-- 20261101000130_sold_085_dedupe.sql
--
-- 1. 「賣過」門檻 0.80 → 0.85。品項向量補齊後（91 個）實際分布：
--      ≥ 0.88 全部是同一款（泡腳桶 0.96、貓咪蒲團 0.96、去油清潔布 0.95、文具收納包 0.90、擠牙膏器 0.88）
--      0.80～0.84 混著誤判（可愛貓咪收納包 → 貓咪車用垃圾袋 0.84、香椿抓餅 → 北方小餡餅 0.81、
--      黃金酥皮雞排 → 無骨雞排 0.81），同一款的（防霧濕巾 0.84、S&B 咖哩 0.82）改標「類似」也還看得到。
-- 2. 同一篇貼文模型拆出兩個同名品項時，rpc_market_post_write 寫候選池整句失敗
--    （21000 ON CONFLICT DO UPDATE command cannot affect row a second time，post 90）。
--    候選池那段改 DISTINCT ON (md5(品名))，同名只進一筆。
-- 最後重算候選池狀態。
--
-- 基底：rpc_market_post_write / rpc_ai_item_embed_write @ 20261101000110（最新版，已 grep）。
-- rollback：重跑 20261101000110 的兩支定義。
-- ============================================================================

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
  SELECT DISTINCT ON (md5(i.item_name)) v_tenant,
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
         CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.85 THEN 'duplicate_hint' ELSE 'new' END,
         (i.matches -> 0 ->> 'product_id')::bigint,
         LEAST((i.matches -> 0 ->> 'score')::numeric, 1)
    FROM line_note_market_items i
    JOIN line_note_market_posts p ON p.id = i.post_id
    JOIN line_note_communities c ON c.id = p.community_id
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id
   WHERE i.post_id = p_post_id
   ORDER BY md5(i.item_name), i.id
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
                                THEN CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.85
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

UPDATE community_product_candidates cc
   SET system_status = CASE WHEN COALESCE((cc.parsed -> 'matches' -> 0 ->> 'score')::numeric, 0) >= 0.85
                            THEN 'duplicate_hint' ELSE 'new' END
 WHERE cc.source_external_id LIKE 'ln:%'
   AND cc.owner_action = 'none' AND cc.system_status IN ('new', 'duplicate_hint');
