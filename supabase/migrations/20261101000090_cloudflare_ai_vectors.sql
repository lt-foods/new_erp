-- ============================================================================
-- 20261101000090_cloudflare_ai_vectors.sql
--
-- 選品 AI 全部改走 Cloudflare Workers AI（老闆 2026-11-01 決定：不用 Claude 排程了）：
--   - 廠商貼文拆品項（含看圖）：Edge Function market-ai 呼叫 Workers AI 視覺模型，
--     寫回既有的 rpc_market_post_write（20261101000060 版）。
--   - 新品貼標：同上，寫回既有的 rpc_product_tag_llm_write（20261101000020）。
--   - 轉向量：@cf/baai/bge-m3（1024 維，多語言；2026-11-01 用 3,601 個已標商品本機實測
--     「最近 5 個鄰居投票猜類別」83.2%，Supabase 內建 gte-small 31.5%）。
-- 向量存在 Supabase（pgvector），才能直接跟銷售紀錄 join。
--
-- 本檔：
--   1. CREATE EXTENSION vector（extensions schema）。
--   2. product_embeddings：每個商品一列，text_hash 記轉向量時的文字（品名＋短名＋標籤名），
--      品名或標籤改了就重算。HNSW cosine 索引。
--   3. line_note_market_items.embedding：廠商貼文拆出來的品項向量。
--   4. _match_products_hybrid：向量最像的 20 個 ∪ 二字詞比對的候選，分數取兩者較高：
--        向量分 = clamp((cosine − 0.5) / 0.25, 0, 1)（bge-m3 同款約 0.69～0.72、不相干約 0.55～0.6，
--        換算後同款落在 0.76～0.88，跟二字詞的 0.75「賣過」門檻對齊；0.5「可能相似」≈ cosine 0.625）
--        二字詞分 = _bigram_hit（20261101000040）
--      門檻是用 7 個樣本粗估的，之後看實際候選池調。
--   5. claim / write RPC（service_role / postgres 專用）：商品向量、品項向量；品項向量寫回時
--      重算 matches 並同步候選池（similar_product_id / similarity_score / system_status / parsed.matches）。
--   6. pg_cron 'market-ai-tick' 每 5 分鐘：有工作（沒解析的貼文、沒標籤的新品、缺向量）才打
--      Edge Function market-ai。網址與密鑰沿用 vault 的 line_note_worker_url（把函式名換掉）
--      與 line_note_cron_secret（Edge Function 那邊比對同一個 LINE_NOTE_CRON_SECRET），不另開秘密。
--
-- rollback：SELECT cron.unschedule('market-ai-tick');
--   DROP FUNCTION public._market_ai_tick(), public._match_products_hybrid(UUID, extensions.vector, TEXT, TEXT[]),
--     public.rpc_ai_product_embed_claim(INT), public.rpc_ai_product_embed_write(JSONB),
--     public.rpc_ai_item_embed_claim(INT), public.rpc_ai_item_embed_write(JSONB), public._product_embed_text(BIGINT);
--   ALTER TABLE line_note_market_items DROP COLUMN embedding; DROP TABLE product_embeddings;
--   （vector extension 留著無妨）
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.product_embeddings (
  product_id BIGINT PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  tenant_id  UUID NOT NULL,
  model      TEXT NOT NULL,
  text_hash  TEXT NOT NULL,
  embedding  extensions.vector(1024) NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_product_embeddings_hnsw
  ON public.product_embeddings USING hnsw (embedding extensions.vector_cosine_ops);
COMMENT ON TABLE public.product_embeddings IS
  '商品向量（Cloudflare Workers AI bge-m3，20261101000090）。text_hash = md5(品名＋短名＋標籤名)，不同就重算';
ALTER TABLE public.product_embeddings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_embeddings FROM PUBLIC, anon, authenticated;

ALTER TABLE public.line_note_market_items
  ADD COLUMN IF NOT EXISTS embedding extensions.vector(1024);

-- 轉向量用的文字：品名＋短名＋標籤名（標籤是分類訊號，跟品名一起進向量）
CREATE OR REPLACE FUNCTION public._product_embed_text(p_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
SET search_path = public
AS $function$
  SELECT btrim(concat_ws(' ', p.name,
                 NULLIF(p.short_name, p.name),
                 (SELECT string_agg(t.name, ' ' ORDER BY t.name)
                    FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                   WHERE m.product_id = p.id)))
    FROM products p WHERE p.id = p_id;
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
           GREATEST(COALESCE(b.hit, 0),
                    COALESCE(LEAST(GREATEST((v.cos - 0.5) / 0.25, 0), 1), 0)) AS score,
           EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                    WHERE m.product_id = p.id AND t.code = ANY (COALESCE(p_tags, '{}'))) AS tag_ok
      FROM products p
      LEFT JOIN vec v ON v.id = p.id
      LEFT JOIN big b ON b.id = p.id
     WHERE p.tenant_id = p_tenant AND (v.id IS NOT NULL OR b.hit >= 0.5)
  ),
  top AS (
    SELECT * FROM cand WHERE score >= 0.5
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
REVOKE ALL ON FUNCTION public._match_products_hybrid(UUID, extensions.vector, TEXT, TEXT[]) FROM PUBLIC, anon, authenticated;

-- 商品向量：缺的或文字變了的
CREATE OR REPLACE FUNCTION public.rpc_ai_product_embed_claim(p_limit INT DEFAULT 50)
RETURNS TABLE (product_id BIGINT, body TEXT, hash TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT x.id, x.t, md5(x.t)
    FROM (SELECT p.id, public._product_embed_text(p.id) AS t, p.created_at FROM products p) x
    LEFT JOIN product_embeddings e ON e.product_id = x.id
   WHERE COALESCE(x.t, '') <> '' AND (e.product_id IS NULL OR e.text_hash <> md5(x.t))
   ORDER BY x.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_product_embed_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_product_embed_claim(INT) TO service_role;

--    p_rows：[{product_id, hash, model, embedding: [1024 個數字]}]
CREATE OR REPLACE FUNCTION public.rpc_ai_product_embed_write(p_rows JSONB)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_n INT;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  INSERT INTO product_embeddings AS pe (product_id, tenant_id, model, text_hash, embedding, updated_at)
  SELECT (x->>'product_id')::bigint, p.tenant_id, x->>'model', x->>'hash',
         (x->'embedding')::text::extensions.vector, now()
    FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) x
    JOIN products p ON p.id = (x->>'product_id')::bigint
   WHERE jsonb_array_length(x->'embedding') = 1024
  ON CONFLICT (product_id) DO UPDATE
     SET model = EXCLUDED.model, text_hash = EXCLUDED.text_hash,
         embedding = EXCLUDED.embedding, updated_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_product_embed_write(JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_product_embed_write(JSONB) TO service_role;

-- 品項向量：拆出來還沒轉的
CREATE OR REPLACE FUNCTION public.rpc_ai_item_embed_claim(p_limit INT DEFAULT 50)
RETURNS TABLE (item_id BIGINT, body TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', current_user) NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT i.id, btrim(concat_ws(' ', i.item_name, NULLIF(i.norm_name, i.item_name),
                (SELECT string_agg(t.name, ' ' ORDER BY t.name) FROM product_tags t
                  WHERE t.tenant_id = i.tenant_id AND t.code = ANY (i.tags))))
    FROM line_note_market_items i
   WHERE i.embedding IS NULL
   ORDER BY i.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_ai_item_embed_claim(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_item_embed_claim(INT) TO service_role;

--    p_rows：[{item_id, embedding}]；寫回後重算 matches，候選池同步
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
                                THEN CASE WHEN COALESCE((i.matches -> 0 ->> 'score')::numeric, 0) >= 0.75
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
REVOKE ALL ON FUNCTION public.rpc_ai_item_embed_write(JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_ai_item_embed_write(JSONB) TO service_role;

-- 排程：有工作才打 market-ai
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
                      WHERE NOT EXISTS (SELECT 1 FROM product_embeddings e WHERE e.product_id = p.id)) THEN
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

SELECT cron.unschedule('market-ai-tick')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'market-ai-tick');
SELECT cron.schedule('market-ai-tick', '*/5 * * * *', $cron$ SELECT public._market_ai_tick(); $cron$);
