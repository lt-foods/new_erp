-- ============================================================================
-- 20261101000060_supplier_post_quick_candidate.sql
--
-- 「廠商群組」按「立即讀取」要馬上看到東西：原本讀到的貼文要等半夜 02:53 Claude 拆成品項才進
-- 候選池。改成讀到就先整篇進候選池（source_external_id = 'ln:<貼文>:raw'，parsed.pending = true，
-- 後台標「待整理」）：
--   - 商品名：第一行至少 4 個中文字、沒有價格字眼（$／元／價／優惠／團購／免運／截止…）的那行，
--     去掉表情符號，最多 40 字；找不到就用第一行。
--   - 價格：第一個「$ / ＄ 後面的數字」或「數字＋元」。
-- 半夜 Claude 拆品項（rpc_market_post_write）時：
--   - 待整理那筆老闆還沒動過 → 刪掉，由正式品項取代；
--   - 動過的（收藏／排程／採用／忽略）→ 改掛到第一個品項的 id 上，upsert 只更新內容、保留狀態。
--   - Claude 判定不是商品（0 個品項）→ 沒動過的待整理一起刪掉。
--
-- 基底：rpc_line_note_market_ingest / rpc_market_post_write @ 20261101000040（唯一前版，已 grep）。
-- rollback：重跑 20261101000040 的兩支函式定義；DROP FUNCTION public._market_post_quick_candidate(BIGINT);
--   DELETE FROM community_product_candidates WHERE source_external_id LIKE 'ln:%:raw' AND owner_action = 'none';
-- ============================================================================

CREATE OR REPLACE FUNCTION public._market_post_quick_candidate(p_post_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_p     line_note_market_posts%ROWTYPE;
  v_c     line_note_communities%ROWTYPE;
  v_sup   TEXT;
  v_name  TEXT;
  v_price NUMERIC;
  v_m     TEXT;
BEGIN
  SELECT * INTO v_p FROM line_note_market_posts WHERE id = p_post_id;
  IF NOT FOUND OR btrim(v_p.text) = '' THEN RETURN; END IF;
  -- 已經被 Claude 拆過（有正式品項）就不用待整理
  IF EXISTS (SELECT 1 FROM line_note_market_items WHERE post_id = p_post_id) THEN RETURN; END IF;
  SELECT * INTO v_c FROM line_note_communities WHERE id = v_p.community_id;
  SELECT name INTO v_sup FROM suppliers WHERE id = v_c.crawl_supplier_id;

  SELECT l INTO v_name
    FROM (SELECT btrim(regexp_replace(line, '[^一-龥ぁ-んァ-ンA-Za-z0-9（）()／/．.\-×xX*＊+% ]', '', 'g')) AS l, n
            FROM regexp_split_to_table(v_p.text, '\n') WITH ORDINALITY AS t(line, n)) s
   WHERE length(regexp_replace(l, '[^一-龥]', '', 'g')) >= 4
     AND l !~ '(\$|＄|元|價|優惠|團購|免運|截止|結單|出貨|匯款|下單|\+1)'
   ORDER BY n LIMIT 1;
  IF v_name IS NULL THEN
    v_name := btrim(regexp_replace(split_part(btrim(v_p.text), E'\n', 1), '[^一-龥ぁ-んァ-ンA-Za-z0-9（）()／/．.\-×xX*＊+%$ ]', '', 'g'));
  END IF;
  v_name := LEFT(COALESCE(NULLIF(v_name, ''), '（廠商貼文）'), 40);

  v_m := substring(v_p.text from '[$＄]\s*([0-9][0-9,]*)');
  IF v_m IS NULL THEN v_m := substring(v_p.text from '([0-9][0-9,]*)\s*元'); END IF;
  v_price := NULLIF(replace(COALESCE(v_m, ''), ',', ''), '')::numeric;

  INSERT INTO community_product_candidates AS cc
    (tenant_id, source_channel, source_user_name, source_external_id, product_name_hint, raw_text,
     raw, parsed, parsed_at, system_status)
  VALUES
    (v_p.tenant_id,
     '廠商群組｜' || COALESCE(v_sup, v_c.home_name, ''),
     v_p.author_name,
     'ln:' || v_p.line_post_id || ':raw',
     v_name,
     v_p.text,
     jsonb_build_object('source', 'line_note_supplier', 'market_post_id', v_p.id, 'community_id', v_c.id,
                        'supplier_id', v_c.crawl_supplier_id, 'posted_at', v_p.posted_at, 'pending', TRUE),
     jsonb_build_object('pending', TRUE, 'price', v_price, 'supplier', v_sup, 'comment_count', v_p.comment_count,
                        'matches', '[]'::jsonb),
     NULL,
     'new')
  ON CONFLICT (tenant_id, source_external_id) WHERE source_external_id IS NOT NULL DO UPDATE
     SET product_name_hint = CASE WHEN cc.owner_action = 'none' THEN EXCLUDED.product_name_hint ELSE cc.product_name_hint END,
         raw_text = EXCLUDED.raw_text,
         parsed = EXCLUDED.parsed;
END;
$$;
REVOKE ALL ON FUNCTION public._market_post_quick_candidate(BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_line_note_market_ingest(p_community_id BIGINT, p_posts JSONB)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_c        line_note_communities%ROWTYPE;
  v_today    DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_new      INT;
  v_changed  INT;
  v_total    INT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT * INTO v_c FROM line_note_communities WHERE id = p_community_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not found', p_community_id; END IF;

  CREATE TEMP TABLE _in ON COMMIT DROP AS
  SELECT DISTINCT ON (x->>'postId')
         x->>'postId'                                   AS line_post_id,
         NULLIF(x->>'authorMid', '')                    AS author_mid,
         NULLIF(x->>'authorName', '')                   AS author_name,
         LEFT(COALESCE(x->>'text', ''), 8000)           AS text,
         md5(COALESCE(x->>'text', ''))                  AS text_hash,
         COALESCE(x->'media', '[]'::jsonb)              AS media,
         NULLIF(x->>'createdAt', '')::timestamptz       AS posted_at,
         NULLIF(x->>'updatedAt', '')::timestamptz       AS line_updated_at,
         COALESCE((x->>'commentCount')::int, 0)         AS comment_count,
         COALESCE((x->>'likeCount')::int, 0)            AS like_count
    FROM jsonb_array_elements(COALESCE(p_posts, '[]'::jsonb)) x
   WHERE COALESCE(x->>'postId', '') <> '';

  -- 我方自己發的不收
  DELETE FROM _in i
   WHERE EXISTS (SELECT 1 FROM line_note_posts lp WHERE lp.line_post_id = i.line_post_id)
      OR (i.author_mid IS NOT NULL AND EXISTS (SELECT 1 FROM line_note_accounts a WHERE a.line_mid = i.author_mid));
  SELECT count(*) INTO v_total FROM _in;

  SELECT count(*) INTO v_new FROM _in i
   WHERE NOT EXISTS (SELECT 1 FROM line_note_market_posts p WHERE p.community_id = p_community_id AND p.line_post_id = i.line_post_id);
  SELECT count(*) INTO v_changed FROM _in i JOIN line_note_market_posts p
      ON p.community_id = p_community_id AND p.line_post_id = i.line_post_id AND p.text_hash IS DISTINCT FROM i.text_hash;

  INSERT INTO line_note_market_posts AS p
    (tenant_id, community_id, line_post_id, author_mid, author_name, text, text_hash, media,
     posted_at, line_updated_at, comment_count, like_count)
  SELECT v_c.tenant_id, p_community_id, line_post_id, author_mid, author_name, text, text_hash, media,
         posted_at, line_updated_at, comment_count, like_count
    FROM _in
  ON CONFLICT (community_id, line_post_id) DO UPDATE
     SET author_name = COALESCE(EXCLUDED.author_name, p.author_name),
         text = EXCLUDED.text,
         media = EXCLUDED.media,
         line_updated_at = EXCLUDED.line_updated_at,
         comment_count = EXCLUDED.comment_count,
         like_count = EXCLUDED.like_count,
         last_seen_at = now(),
         -- 文字改過 → 重新解析
         parsed_at = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parsed_at END,
         parse_error = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parse_error END,
         text_hash = EXCLUDED.text_hash;

  INSERT INTO line_note_market_post_stats AS s (post_id, stat_date, comment_count, like_count)
  SELECT p.id, v_today, i.comment_count, i.like_count
    FROM _in i JOIN line_note_market_posts p ON p.community_id = p_community_id AND p.line_post_id = i.line_post_id
  ON CONFLICT (post_id, stat_date) DO UPDATE
     SET comment_count = EXCLUDED.comment_count, like_count = EXCLUDED.like_count;

  UPDATE line_note_communities SET crawl_last_at = now() WHERE id = p_community_id;

  -- 先整篇進候選池（待整理），半夜 Claude 拆品項時再換成正式品項
  PERFORM public._market_post_quick_candidate(p.id)
     FROM _in i JOIN line_note_market_posts p ON p.community_id = p_community_id AND p.line_post_id = i.line_post_id
    WHERE p.parsed_at IS NULL AND btrim(p.text) <> '';

  DROP TABLE IF EXISTS _in;

  RETURN jsonb_build_object('kept', v_total, 'new', v_new, 'text_changed', v_changed);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_market_ingest(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_market_ingest(BIGINT, JSONB) TO service_role;

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

  UPDATE line_note_market_posts SET parse_error = NULL WHERE id = p_post_id;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_post_write(BIGINT, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_write(BIGINT, JSONB, TEXT) TO service_role;

