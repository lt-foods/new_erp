-- ============================================================================
-- 20261101000120_match_speed.sql
--
-- 廠商品項比對逾時：market-ai 寫回時 rpc_ai_item_embed_write / rpc_market_post_write 一直回
-- 57014 statement timeout，2026-11-01 上線後 78 個品項一個向量都存不進去。
-- 原因：_bigram_hit(p.name, p_norm) 對 4,391 個商品「每一個」都重新把查詢詞拆一次二字詞
-- （regexp_split + generate_series 的 SQL 函式，不會被 inline），實測一個品項 1,231ms；
-- 一次寫 50 個品項就 60 秒。
--
-- 改法：查詢詞的二字詞只拆一次（CTE q），每個商品只做幾次 strpos；標籤比對（tag_ok）只對
-- 過門檻的候選算。同一個查詢實測 1,231ms → 13ms，對到的商品一樣（3 個）。分數規則不變
-- （20261101000110：二字詞最多 0.7、賣過只看 cosine ≥ 0.8、≥ 0.6 列進 matches）。
--
-- 基底：_match_products_by_norm / _match_products_hybrid @ 20261101000110（最新版，已 grep）。
-- rollback：重跑 20261101000110 的兩支定義。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._match_products_by_norm(p_tenant UUID, p_norm TEXT, p_tags TEXT[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH q AS (
    SELECT DISTINCT substr(tok, i, 2) AS b
      FROM regexp_split_to_table(COALESCE(p_norm, ''), '\s+') AS tok,
           generate_series(1, GREATEST(length(tok) - 1, 1)) AS i
     WHERE tok <> ''
  ),
  nq AS (SELECT count(*)::numeric AS c FROM q),
  cand AS (
    SELECT p.id, p.name, (SELECT count(*) FROM q WHERE strpos(p.name, q.b) > 0) / NULLIF(nq.c, 0) AS hit
      FROM products p, nq
     WHERE p.tenant_id = p_tenant AND nq.c > 0
  ),
  top AS (
    SELECT c.*,
           EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                    WHERE m.product_id = c.id AND t.code = ANY (COALESCE(p_tags, '{}'))) AS tag_ok
      FROM cand c WHERE c.hit >= 0.5
     ORDER BY c.hit DESC, tag_ok DESC, c.id DESC
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
REVOKE ALL ON FUNCTION public._match_products_by_norm(UUID, TEXT, TEXT[]) FROM PUBLIC, anon, authenticated;

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
  q AS (
    SELECT DISTINCT substr(tok, i, 2) AS b
      FROM regexp_split_to_table(COALESCE(p_norm, ''), '\s+') AS tok,
           generate_series(1, GREATEST(length(tok) - 1, 1)) AS i
     WHERE tok <> ''
  ),
  nq AS (SELECT count(*)::numeric AS c FROM q),
  big AS (
    SELECT x.id, x.hit FROM (
      SELECT p.id, (SELECT count(*) FROM q WHERE strpos(p.name, q.b) > 0) / NULLIF(nq.c, 0) AS hit
        FROM products p, nq
       WHERE p.tenant_id = p_tenant AND nq.c > 0
    ) x WHERE x.hit >= 0.5
  ),
  cand AS (
    SELECT p.id, p.name, COALESCE(b.hit, 0) AS hit, v.cos,
           GREATEST(COALESCE(v.cos, 0), LEAST(COALESCE(b.hit, 0), 0.7)) AS score
      FROM (SELECT id FROM vec UNION SELECT id FROM big) ids
      JOIN products p ON p.id = ids.id
      LEFT JOIN vec v ON v.id = ids.id
      LEFT JOIN big b ON b.id = ids.id
  ),
  top AS (
    SELECT c.*,
           EXISTS (SELECT 1 FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
                    WHERE m.product_id = c.id AND t.code = ANY (COALESCE(p_tags, '{}'))) AS tag_ok
      FROM cand c WHERE c.score >= 0.6
     ORDER BY c.score DESC, tag_ok DESC, c.id DESC
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
