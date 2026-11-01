-- ============================================================================
-- 20261101000100_market_post_write_cleanup_stale.sql
--
-- 廠商貼文重新整理時，候選池會留下舊品項（重複）：rpc_market_post_write 用
-- 'ln:<貼文>:<md5(品名)>' upsert，品名寫法一變（貼文改過、換模型重跑）就是新的一筆，舊的那筆沒人清。
-- 寫回後把同一篇裡「老闆還沒動過（owner_action = 'none'）、這次沒出現」的舊品項刪掉；
-- 動過的（收藏／排程…）一律保留。
--
-- 另外：2026-11-01 第一輪 Cloudflare（Llama 4 Scout）貼的商品標籤，照 market-ai 的 fixTags 規則清一次
-- （非食品不給溫層；同時有非食品標籤時拿掉生鮮／食品群標籤）。只動 source = 'llm' 的列。
--
-- 基底：rpc_market_post_write @ 20261101000060（最新一版，已 grep）。
-- rollback：重跑 20261101000060 的 rpc_market_post_write。
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
         CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.75 THEN 'duplicate_hint' ELSE 'new' END,
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
REVOKE ALL ON FUNCTION public.rpc_market_post_write(BIGINT, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_write(BIGINT, JSONB, TEXT) TO service_role;

-- 第一輪 Cloudflare 標籤清理（同 market-ai fixTags）
WITH g AS (
  SELECT m.product_id,
         bool_or(t.tag_group IN ('生鮮', '食品')) AS food,
         bool_or(t.tag_group = '非食品') AS nonfood
    FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
   WHERE m.source = 'llm'
   GROUP BY 1
)
DELETE FROM product_tag_map m
 USING product_tags t, g
 WHERE t.id = m.tag_id AND g.product_id = m.product_id AND m.source = 'llm'
   AND (
         (t.tag_group = '溫層' AND (NOT g.food OR g.nonfood))
      OR (t.tag_group IN ('生鮮', '食品') AND g.food AND g.nonfood)
       );
