-- ============================================================================
-- 廠商網站商品進候選池（① 進料的新來源：vendor_site）
--
-- 背景：tools/vendor-scraper 用會員帳號登入廠商網站（辛普森德日韓、有鮮實業…，都是 shop2000 平台）
-- 把分類列表＋商品詳細抓下來。要讓它們走跟 LINE 廠商貼文同一條路（理解 → 媒合 → 預估 → 推薦），
-- 但 line_note_market_posts 綁死 LINE 社群（community_id NOT NULL），沒有「廠商網站」這個來源。
--
-- 做法：
-- 1. line_note_market_posts 加 source（'line_note' | 'vendor_site'）、supplier_id、source_url；
--    community_id 改成可空（vendor_site 一律 NULL、line_note 一律非 NULL，CHECK 擋住）。
--    vendor_site 的去重鍵是 (tenant_id, line_post_id)，line_post_id = 'web:<vendor_key>:<平台商品id>'。
-- 2. rpc_market_post_claim / rpc_market_post_write / _market_post_quick_candidate 三支改成
--    LEFT JOIN 社群、廠商取 COALESCE(post.supplier_id, community.crawl_supplier_id)，
--    候選池的 source_channel 前綴依來源（廠商網站｜ / 廠商群組｜）、raw.source = 'vendor_site'、
--    source_post_url 帶商品網址。
-- 3. 新 RPC rpc_vendor_site_market_ingest(p_supplier_id, p_vendor_key, p_products)：
--    一個商品一篇貼文（text = 品名 + 價格 + 規格 + 說明），文字沒變就不重解析；
--    圖片由呼叫端先上傳到 products bucket（vendor-site/<key>/<psn>/<n>.jpg）再把路徑帶進來。
--
-- 基底版本（重 grep 確認過）：
--   rpc_market_post_claim        ← 20261101000080_supplier_post_images.sql
--   rpc_market_post_write        ← 20261101000130_sold_085_dedupe.sql
--   _market_post_quick_candidate ← 20261101000060_supplier_post_quick_candidate.sql
-- rollback：重跑上面三支的基底定義；DROP FUNCTION public.rpc_vendor_site_market_ingest(BIGINT, TEXT, JSONB);
--   DELETE FROM line_note_market_posts WHERE source = 'vendor_site';（candidates 由 rpc 寫的 raw.source='vendor_site' 可一起刪）
--   ALTER TABLE line_note_market_posts DROP CONSTRAINT lnmp_source_community_chk, DROP COLUMN source, DROP COLUMN supplier_id,
--     DROP COLUMN source_url; ALTER COLUMN community_id SET NOT NULL;
-- ============================================================================

ALTER TABLE public.line_note_market_posts
  ADD COLUMN IF NOT EXISTS source      TEXT NOT NULL DEFAULT 'line_note',
  ADD COLUMN IF NOT EXISTS supplier_id BIGINT REFERENCES public.suppliers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_url  TEXT;

ALTER TABLE public.line_note_market_posts ALTER COLUMN community_id DROP NOT NULL;

ALTER TABLE public.line_note_market_posts DROP CONSTRAINT IF EXISTS lnmp_source_community_chk;
ALTER TABLE public.line_note_market_posts
  ADD CONSTRAINT lnmp_source_community_chk CHECK (
    source IN ('line_note', 'vendor_site')
    AND ((source = 'line_note') = (community_id IS NOT NULL))
    AND (source <> 'vendor_site' OR supplier_id IS NOT NULL)
  );

-- vendor_site 的去重鍵（原本的 UNIQUE (community_id, line_post_id) 對 NULL community 不會擋）
CREATE UNIQUE INDEX IF NOT EXISTS uniq_lnmp_tenant_post_no_community
  ON public.line_note_market_posts (tenant_id, line_post_id) WHERE community_id IS NULL;

-- ----------------------------------------------------------------------------
-- rpc_market_post_claim（基底 20261101000080）：LEFT JOIN 社群、廠商看 post.supplier_id
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_market_post_claim(p_limit INT DEFAULT 20)
RETURNS TABLE (post_id BIGINT, community TEXT, supplier TEXT, author TEXT, posted TIMESTAMPTZ,
               comments INT, body TEXT, images TEXT[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- 沒有文字的（只有圖）直接標解析完，不送模型
  UPDATE line_note_market_posts mp SET parsed_at = now()
   WHERE mp.parsed_at IS NULL AND btrim(mp.text) = '';

  RETURN QUERY
  WITH picked AS (
    SELECT p.id FROM line_note_market_posts p
     WHERE p.parsed_at IS NULL
     ORDER BY p.posted_at DESC NULLS LAST, p.id DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 60)
     FOR UPDATE SKIP LOCKED
  ),
  marked AS (
    UPDATE line_note_market_posts p SET parsed_at = now(), parse_error = NULL
      FROM picked WHERE p.id = picked.id
    RETURNING p.id, p.community_id, p.supplier_id, p.source, p.author_name, p.posted_at, p.comment_count, p.text, p.image_paths
  )
  SELECT m.id,
         COALESCE(c.home_name, CASE WHEN m.source = 'vendor_site' THEN '廠商網站' END),
         s.name, m.author_name, m.posted_at, m.comment_count, m.text,
         COALESCE(m.image_paths, '{}')
    FROM marked m
    LEFT JOIN line_note_communities c ON c.id = m.community_id
    LEFT JOIN suppliers s ON s.id = COALESCE(m.supplier_id, c.crawl_supplier_id);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_post_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_market_post_claim(INT) TO service_role;

-- ----------------------------------------------------------------------------
-- _market_post_quick_candidate（基底 20261101000060）：vendor_site 的品名就是第一行、價格在第二行
-- ----------------------------------------------------------------------------
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
  -- 已經被模型拆過（有正式品項）就不用待整理
  IF EXISTS (SELECT 1 FROM line_note_market_items WHERE post_id = p_post_id) THEN RETURN; END IF;
  IF v_p.community_id IS NOT NULL THEN
    SELECT * INTO v_c FROM line_note_communities WHERE id = v_p.community_id;
  END IF;
  SELECT name INTO v_sup FROM suppliers WHERE id = COALESCE(v_p.supplier_id, v_c.crawl_supplier_id);

  IF v_p.source = 'vendor_site' THEN
    -- 進料時第一行就是商品頁的品名，不用猜
    v_name := btrim(split_part(btrim(v_p.text), E'\n', 1));
  ELSE
    SELECT l INTO v_name
      FROM (SELECT btrim(regexp_replace(line, '[^一-龥ぁ-んァ-ンA-Za-z0-9（）()／/．.\-×xX*＊+% ]', '', 'g')) AS l, n
              FROM regexp_split_to_table(v_p.text, '\n') WITH ORDINALITY AS t(line, n)) s
     WHERE length(regexp_replace(l, '[^一-龥]', '', 'g')) >= 4
       AND l !~ '(\$|＄|元|價|優惠|團購|免運|截止|結單|出貨|匯款|下單|\+1)'
     ORDER BY n LIMIT 1;
    IF v_name IS NULL THEN
      v_name := btrim(regexp_replace(split_part(btrim(v_p.text), E'\n', 1), '[^一-龥ぁ-んァ-ンA-Za-z0-9（）()／/．.\-×xX*＊+%$ ]', '', 'g'));
    END IF;
  END IF;
  v_name := LEFT(COALESCE(NULLIF(v_name, ''), '（廠商貼文）'), 40);

  v_m := substring(v_p.text from '[$＄]\s*([0-9][0-9,]*)');
  IF v_m IS NULL THEN v_m := substring(v_p.text from '([0-9][0-9,]*)\s*元'); END IF;
  v_price := NULLIF(replace(COALESCE(v_m, ''), ',', ''), '')::numeric;

  INSERT INTO community_product_candidates AS cc
    (tenant_id, source_channel, source_user_name, source_external_id, source_post_url, product_name_hint, raw_text,
     raw, parsed, parsed_at, system_status)
  VALUES
    (v_p.tenant_id,
     CASE WHEN v_p.source = 'vendor_site' THEN '廠商網站｜' ELSE '廠商群組｜' END || COALESCE(v_sup, v_c.home_name, ''),
     v_p.author_name,
     'ln:' || v_p.line_post_id || ':raw',
     v_p.source_url,
     v_name,
     v_p.text,
     jsonb_build_object('source', CASE WHEN v_p.source = 'vendor_site' THEN 'vendor_site' ELSE 'line_note_supplier' END,
                        'market_post_id', v_p.id, 'community_id', v_c.id,
                        'supplier_id', COALESCE(v_p.supplier_id, v_c.crawl_supplier_id), 'posted_at', v_p.posted_at,
                        'source_url', v_p.source_url, 'pending', TRUE),
     jsonb_build_object('pending', TRUE, 'price', v_price, 'supplier', v_sup, 'comment_count', v_p.comment_count,
                        'matches', '[]'::jsonb),
     NULL,
     'new')
  ON CONFLICT (tenant_id, source_external_id) WHERE source_external_id IS NOT NULL DO UPDATE
     SET product_name_hint = CASE WHEN cc.owner_action = 'none' THEN EXCLUDED.product_name_hint ELSE cc.product_name_hint END,
         raw_text = EXCLUDED.raw_text,
         source_post_url = COALESCE(EXCLUDED.source_post_url, cc.source_post_url),
         parsed = EXCLUDED.parsed;
END;
$$;
REVOKE ALL ON FUNCTION public._market_post_quick_candidate(BIGINT) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- rpc_market_post_write（基底 20261101000130）：候選池來源欄位依 post.source
-- ----------------------------------------------------------------------------
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
    (tenant_id, source_channel, source_user_name, source_external_id, source_post_url, product_name_hint, raw_text,
     raw, parsed, parsed_at, system_status, similar_product_id, similarity_score)
  SELECT DISTINCT ON (md5(i.item_name)) v_tenant,
         CASE WHEN p.source = 'vendor_site' THEN '廠商網站｜' ELSE '廠商群組｜' END || COALESCE(s.name, c.home_name, ''),
         p.author_name,
         'ln:' || p.line_post_id || ':' || md5(i.item_name),
         p.source_url,
         i.item_name || COALESCE('（' || i.spec || '）', ''),
         CASE WHEN btrim(p.text) = '' THEN i.item_name ELSE p.text END,
         jsonb_build_object('source', CASE WHEN p.source = 'vendor_site' THEN 'vendor_site' ELSE 'line_note_supplier' END,
                            'market_post_id', p.id, 'market_item_id', i.id,
                            'community_id', c.id, 'supplier_id', COALESCE(p.supplier_id, c.crawl_supplier_id),
                            'posted_at', p.posted_at, 'source_url', p.source_url),
         jsonb_build_object('price', i.price, 'price_text', i.price_text, 'spec', i.spec,
                            'deadline_text', i.deadline_text, 'norm_name', i.norm_name, 'tags', to_jsonb(i.tags),
                            'matches', i.matches, 'supplier', s.name, 'comment_count', p.comment_count),
         now(),
         CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.85 THEN 'duplicate_hint' ELSE 'new' END,
         (i.matches -> 0 ->> 'product_id')::bigint,
         LEAST((i.matches -> 0 ->> 'score')::numeric, 1)
    FROM line_note_market_items i
    JOIN line_note_market_posts p ON p.id = i.post_id
    LEFT JOIN line_note_communities c ON c.id = p.community_id
    LEFT JOIN suppliers s ON s.id = COALESCE(p.supplier_id, c.crawl_supplier_id)
   WHERE i.post_id = p_post_id
   ORDER BY md5(i.item_name), i.id
  ON CONFLICT (tenant_id, source_external_id) WHERE source_external_id IS NOT NULL DO UPDATE
     SET product_name_hint = EXCLUDED.product_name_hint,
         raw_text = EXCLUDED.raw_text,
         raw = EXCLUDED.raw,
         parsed = EXCLUDED.parsed,
         parsed_at = EXCLUDED.parsed_at,
         source_post_url = COALESCE(EXCLUDED.source_post_url, cc.source_post_url),
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

-- ----------------------------------------------------------------------------
-- rpc_vendor_site_market_ingest：廠商網站商品 → 貼文（一商品一篇）
--   p_products 元素：{ psn, name, url, text, image_paths: [...], scraped_at }
--   text 由呼叫端組（第一行品名、第二行價格 …），模型跟 LINE 貼文一樣讀 text + 圖拆品項；
--   文字沒變就不重解析（跟 rpc_line_note_market_ingest 同一套 text_hash 規則）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_vendor_site_market_ingest(p_supplier_id BIGINT, p_vendor_key TEXT, p_products JSONB)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID;
  v_new      INT;
  v_changed  INT;
  v_total    INT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF COALESCE(btrim(p_vendor_key), '') = '' OR p_vendor_key !~ '^[a-z0-9_-]+$' THEN
    RAISE EXCEPTION 'vendor_key 只能是小寫英數、底線、減號：%', p_vendor_key;
  END IF;
  SELECT tenant_id INTO v_tenant FROM suppliers WHERE id = p_supplier_id;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'supplier % not found', p_supplier_id; END IF;

  CREATE TEMP TABLE _vin ON COMMIT DROP AS
  SELECT DISTINCT ON (x->>'psn')
         'web:' || p_vendor_key || ':' || (x->>'psn')              AS line_post_id,
         LEFT(COALESCE(x->>'text', ''), 8000)                       AS text,
         md5(LEFT(COALESCE(x->>'text', ''), 8000))                  AS text_hash,
         NULLIF(x->>'url', '')                                      AS source_url,
         CASE WHEN jsonb_typeof(x->'image_paths') = 'array' AND jsonb_array_length(x->'image_paths') > 0
              THEN ARRAY(SELECT jsonb_array_elements_text(x->'image_paths')) END AS image_paths,
         COALESCE(NULLIF(x->>'scraped_at', '')::timestamptz, now())  AS posted_at
    FROM jsonb_array_elements(COALESCE(p_products, '[]'::jsonb)) x
   WHERE COALESCE(x->>'psn', '') <> '' AND COALESCE(btrim(x->>'text'), '') <> '';
  SELECT count(*) INTO v_total FROM _vin;

  SELECT count(*) INTO v_new FROM _vin i
   WHERE NOT EXISTS (SELECT 1 FROM line_note_market_posts p
                      WHERE p.tenant_id = v_tenant AND p.community_id IS NULL AND p.line_post_id = i.line_post_id);
  SELECT count(*) INTO v_changed FROM _vin i JOIN line_note_market_posts p
      ON p.tenant_id = v_tenant AND p.community_id IS NULL AND p.line_post_id = i.line_post_id
     AND p.text_hash IS DISTINCT FROM i.text_hash;

  INSERT INTO line_note_market_posts AS p
    (tenant_id, community_id, source, supplier_id, line_post_id, text, text_hash, source_url, image_paths, posted_at)
  SELECT v_tenant, NULL, 'vendor_site', p_supplier_id, line_post_id, text, text_hash, source_url, image_paths, posted_at
    FROM _vin
  ON CONFLICT (tenant_id, line_post_id) WHERE community_id IS NULL DO UPDATE
     SET text = EXCLUDED.text,
         supplier_id = EXCLUDED.supplier_id,
         source_url = COALESCE(EXCLUDED.source_url, p.source_url),
         image_paths = COALESCE(EXCLUDED.image_paths, p.image_paths),
         last_seen_at = now(),
         -- 文字改過（價格／規格變了）→ 重新解析
         parsed_at = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parsed_at END,
         parse_error = CASE WHEN p.text_hash IS DISTINCT FROM EXCLUDED.text_hash THEN NULL ELSE p.parse_error END,
         text_hash = EXCLUDED.text_hash;

  -- 先整篇進候選池（待整理），模型拆品項時再換成正式品項
  PERFORM public._market_post_quick_candidate(p.id)
     FROM _vin i JOIN line_note_market_posts p
       ON p.tenant_id = v_tenant AND p.community_id IS NULL AND p.line_post_id = i.line_post_id
    WHERE p.parsed_at IS NULL;

  DROP TABLE IF EXISTS _vin;

  RETURN jsonb_build_object('kept', v_total, 'new', v_new, 'text_changed', v_changed);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_vendor_site_market_ingest(BIGINT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_vendor_site_market_ingest(BIGINT, TEXT, JSONB) TO service_role;
