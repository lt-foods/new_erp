-- ============================================================================
-- 推薦成效「人工排 vs 系統推薦」：近 30 天開的總倉團依來源比（20261101000260）
--
-- Alex 2026-11-01：「人工排的應該從今天往回推一個月來算成效」。
-- 原本寫在 20261101000250 的同一支 PR 裡，但 PR 合併時只帶到第一個 commit，這支函式沒進 main、
-- 也沒套上線（250 已經照 main 的版本套了）→ 另開這支補。
--
-- rpc_reco_source_compare(p_days)：近 p_days 天開的總倉團（reco_campaign_predictions 有來源與開團前預估），
--   依來源給：開團數、已結束數、平均 / 中位數買家（只算 settled）、平均預估、賣贏預估比例、開團 24 小時平均。
--   總部角色才能呼叫。
-- rollback：DROP FUNCTION public.rpc_reco_source_compare(INT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_reco_source_compare(p_days INT DEFAULT 30)
RETURNS TABLE (source TEXT, campaigns INT, settled INT, avg_buyers NUMERIC, median_buyers NUMERIC,
               avg_predicted NUMERIC, beat_rate NUMERIC, avg_24h NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
BEGIN
  IF v_tenant IS NULL
     OR COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN QUERY
  WITH g AS (
    SELECT g.id, g.start_at, cp.source, cp.buyers AS pred, rb.buyers AS actual, COALESCE(rb.settled, FALSE) AS done
      FROM group_buy_campaigns g
      JOIN reco_campaign_predictions cp ON cp.campaign_id = g.id
      LEFT JOIN reco_campaign_buyers rb ON rb.campaign_id = g.id
     WHERE g.tenant_id = v_tenant AND g.owner_store_id IS NULL AND g.status NOT IN ('cancelled', 'draft')
       AND g.start_at >= now() - make_interval(days => GREATEST(p_days, 1)) AND g.start_at <= now()
  ), b24 AS (
    SELECT g.id, count(DISTINCT co.member_id) AS n
      FROM g
      JOIN customer_orders co ON co.campaign_id = g.id AND co.created_at < g.start_at + interval '24 hours'
      JOIN members m ON m.id = co.member_id
     WHERE g.start_at <= now() - interval '24 hours'
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND COALESCE(m.member_type, '') <> 'store_internal'
     GROUP BY 1
  )
  SELECT g.source,
         count(*)::int,
         count(*) FILTER (WHERE g.done)::int,
         round(avg(g.actual) FILTER (WHERE g.done), 1),
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY g.actual) FILTER (WHERE g.done))::numeric, 1),
         round(avg(g.pred) FILTER (WHERE g.done), 1),
         round(avg(CASE WHEN g.actual >= g.pred THEN 1 ELSE 0 END) FILTER (WHERE g.done AND g.pred IS NOT NULL), 3),
         round(avg(COALESCE(b24.n, 0)) FILTER (WHERE g.start_at <= now() - interval '24 hours'), 1)
    FROM g LEFT JOIN b24 ON b24.id = g.id
   GROUP BY g.source
   ORDER BY g.source;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_reco_source_compare(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reco_source_compare(INT) TO authenticated;

-- 近一個月的開團預估一次補齊（250 套用時只先算了 600 團；排程每 10 分鐘 500 團也會補）
SELECT public.reco_refresh_campaign_predictions(1000);
