-- ============================================================================
-- 市場熱門：自動同步只留 3 天、頁面與配對只看最新一天（20261102000030）
--
-- Alex 2026-11-02：「是不是只保留 3 天熱門」。蝦皮助手每天同步一次（約 1,200 筆），
-- 不清的話第二天起同一個商品每天多一列 → 頁面重複、熱度配對也重複算。
-- 月銷量本來就是近 30 天滾動，只看最新一天就夠。
--
-- _market_hot_is_current(tenant, source, captured_at)：這一列是不是該來源最新的資料日。
--   自動同步（shopeefans）→ 只看最新一天；手動上傳（shopee / 1688 / other）每批都算（不是每天都有）。
-- _reco_market_heat / rpc_market_hot_list 加上這個條件（基底 20261102000020，唯一前版）。
-- _purge_market_hot()：自動同步的批次只留最近 3 個資料日；手動上傳留 45 天。
--   排程 'market-hot-purge' 每天台北 05:53（同步 05:23 之後）。
-- rollback：SELECT cron.unschedule('market-hot-purge');
--   重跑 20261102000020 的兩支函式；DROP FUNCTION public._purge_market_hot(), public._market_hot_is_current(UUID, TEXT, DATE);
-- ============================================================================

CREATE OR REPLACE FUNCTION public._market_hot_is_current(p_tenant UUID, p_source TEXT, p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_source <> 'shopeefans'
      OR p_date = (SELECT max(b.captured_at) FROM market_hot_batches b
                    WHERE b.tenant_id = p_tenant AND b.source = 'shopeefans');
$$;
REVOKE ALL ON FUNCTION public._market_hot_is_current(UUID, TEXT, DATE) FROM PUBLIC, anon, authenticated;

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
       AND h.captured_at >= current_date - 45 AND public._market_hot_is_current(h.tenant_id, h.source, h.captured_at)
     ORDER BY h.embedding <=> p_emb
     LIMIT 20
  ), k AS (
    -- 同品類也要有一點像（≥ 0.55）：品類標得太籠統時（例「保健品」）不然會亂配，見檔頭
    SELECT h.id, (1 - (h.embedding <=> p_emb))::numeric AS cos
      FROM market_hot_products h
     WHERE p_kind IS NOT NULL AND p_emb IS NOT NULL AND h.tenant_id = p_tenant AND h.kind = p_kind
       AND h.embedding IS NOT NULL AND h.captured_at >= current_date - 45
       AND public._market_hot_is_current(h.tenant_id, h.source, h.captured_at)
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
     AND public._market_hot_is_current(h.tenant_id, h.source, h.captured_at)
   ORDER BY h.captured_at DESC, h.sales_30d DESC NULLS LAST, h.id
   LIMIT 1500;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_market_hot_list(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_market_hot_list(INT) TO authenticated;

CREATE OR REPLACE FUNCTION public._purge_market_hot()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  WITH keep AS (
    SELECT tenant_id, captured_at
      FROM (SELECT DISTINCT tenant_id, captured_at FROM market_hot_batches WHERE source = 'shopeefans') d
     WHERE (SELECT count(DISTINCT b2.captured_at) FROM market_hot_batches b2
             WHERE b2.tenant_id = d.tenant_id AND b2.source = 'shopeefans' AND b2.captured_at > d.captured_at) < 3
  )
  DELETE FROM market_hot_batches b
   WHERE (b.source = 'shopeefans' AND NOT EXISTS (SELECT 1 FROM keep k WHERE k.tenant_id = b.tenant_id AND k.captured_at = b.captured_at))
      OR (b.source <> 'shopeefans' AND b.captured_at < current_date - 45);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._purge_market_hot() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'market-hot-purge';
SELECT cron.schedule('market-hot-purge', '53 21 * * *', $cron$ SELECT public._purge_market_hot(); $cron$);
