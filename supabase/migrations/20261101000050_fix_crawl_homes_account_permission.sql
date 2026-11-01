-- ============================================================================
-- 20261101000050_fix_crawl_homes_account_permission.sql
--
-- 「社群選品 → 廠商群組」頁一打開就「permission denied for table line_note_accounts」。
-- rpc_line_note_crawl_homes（20261101000040）是 SECURITY INVOKER，直接 JOIN 了
-- line_note_accounts —— 那張表身上有 auth_token / refresh_token，authenticated 本來就沒有
-- SELECT 權限（後台都走 v_line_note_accounts）。
--
-- 改成 SECURITY DEFINER，自己檢查租戶與總部角色（同 lnc_hq_all 的允許清單），
-- 帳號只回 label / status，不碰憑證欄位。回傳格式不變，前端不用改。
--
-- 基底：20261101000040 的 rpc_line_note_crawl_homes（唯一前版）。
-- rollback：重跑 20261101000040 裡的 rpc_line_note_crawl_homes 定義。
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_line_note_crawl_homes();

CREATE FUNCTION public.rpc_line_note_crawl_homes()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_out    jsonb;
BEGIN
  IF v_role NOT IN ('owner', 'admin', 'hq_manager', 'assistant', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有總部可以看廠商群組設定';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', c.id, 'home_id', c.home_id, 'home_name', c.home_name, 'home_kind', c.home_kind,
           'account_id', COALESCE(c.crawl_account_id, c.account_id),
           'account_label', a.label, 'account_status', a.status,
           'crawl_enabled', c.crawl_enabled, 'crawl_supplier_id', c.crawl_supplier_id,
           'supplier_name', s.name, 'crawl_last_at', c.crawl_last_at, 'crawl_days', c.crawl_days,
           'posts', (SELECT count(*) FROM line_note_market_posts p WHERE p.community_id = c.id),
           'candidates', (SELECT count(*) FROM community_product_candidates cc
                           WHERE cc.tenant_id = v_tenant AND cc.source_external_id LIKE 'ln:%'
                             AND (cc.raw ->> 'community_id')::bigint = c.id),
           'last_job', (SELECT jsonb_build_object('status', j.status, 'error', LEFT(j.error, 300),
                                                  'at', COALESCE(j.finished_at, j.created_at), 'result', j.result)
                          FROM line_note_jobs j WHERE j.kind = 'crawl' AND j.community_id = c.id
                         ORDER BY j.id DESC LIMIT 1)
         ) ORDER BY c.crawl_enabled DESC, c.home_name), '[]'::jsonb)
    INTO v_out
    FROM line_note_communities c
    LEFT JOIN line_note_accounts a ON a.id = COALESCE(c.crawl_account_id, c.account_id)
    LEFT JOIN suppliers s ON s.id = c.crawl_supplier_id
   WHERE c.tenant_id = v_tenant
     AND (c.crawl_enabled OR c.crawl_last_at IS NOT NULL);

  RETURN v_out;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_line_note_crawl_homes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_crawl_homes() TO authenticated;
