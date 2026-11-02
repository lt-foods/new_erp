-- ============================================================================
-- 市場熱門：配對門檻收緊、清單上限放寬（20261102000020）
--
-- 20261102000010 上線後第一次同步蝦皮助手（1,199 筆）實測：「向量 ≥ 0.75」只配到 3 筆，
-- 其餘 28 筆都是「同品類」配到的，而品類標太籠統時會亂配 ——「保健品」把葉黃素、維他命、
-- 益生菌全配給「有機枸杞原漿」，向量相似度只有 0.36～0.52。0.55 以上幾乎都是真的同類
-- （各家牙膏 → 獅王牙膏、兒童吸管 → 吸管替換組、浴巾、蒸氣眼罩）。
-- 改成：向量 ≥ 0.75，或「同品類而且向量 ≥ 0.55」。清單上限 500 → 1500（一次同步 1,199 筆）。
--
-- 基底：_reco_market_heat / rpc_market_hot_list @ 20261102000010（唯一前版）。
-- rollback：重跑 20261102000010 的這兩支函式。
-- ============================================================================

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
    -- 同品類也要有一點像（≥ 0.55）：品類標得太籠統時（例「保健品」）不然會亂配，見檔頭
    SELECT h.id, (1 - (h.embedding <=> p_emb))::numeric AS cos
      FROM market_hot_products h
     WHERE p_kind IS NOT NULL AND p_emb IS NOT NULL AND h.tenant_id = p_tenant AND h.kind = p_kind
       AND h.embedding IS NOT NULL AND h.captured_at >= current_date - 45
       AND (1 - (h.embedding <=> p_emb)) >= 0.55
  ), m AS (
    SELECT h.*, COALESCE((SELECT max(v.cos) FROM v WHERE v.id = h.id), (SELECT max(k.cos) FROM k WHERE k.id = h.id)) AS cos
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

CREATE OR REPLACE FUNCTION public.rpc_market_hot_list(p_days INT DEFAULT 45)
RETURNS TABLE (
  id BIGINT, source TEXT, captured_at DATE, name TEXT, price NUMERIC, sales_30d INT, revenue NUMERIC, growth NUMERIC,
  category TEXT, shop TEXT, url TEXT, kind TEXT, ready BOOLEAN, supplier_matches JSONB, sold JSONB, image TEXT
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
               AND ((1 - (i.embedding <=> h.embedding)) >= 0.75
                    OR (h.kind IS NOT NULL AND i.kind = h.kind AND (1 - (i.embedding <=> h.embedding)) >= 0.55))
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
           WHERE x.cos >= 0.85),
         h.raw ->> 'productImg'
    FROM market_hot_products h
   WHERE h.tenant_id = v_tenant AND h.captured_at >= current_date - GREATEST(COALESCE(p_days, 45), 1)
   ORDER BY h.captured_at DESC, h.sales_30d DESC NULLS LAST, h.id
   LIMIT 1500;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_hot_list(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_market_hot_list(INT) TO authenticated;

-- 候選的熱銷理由跟著重算
UPDATE public.reco_predictions SET computed_at = '-infinity';
