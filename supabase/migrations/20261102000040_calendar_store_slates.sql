-- ============================================================================
-- 週曆：店長也看得到「系統推薦、還沒排入」的預選（唯讀）（20261102000040）
--
-- Alex 2026-11-02：「一般店長也要可以看到系統推薦但是未排入的項目」。
-- reco_slates 的 RLS 只開給總部，店長的週曆原本不撈預選。改成週曆一律走 rpc_calendar_slates：
--   總部角色（同候選池 RLS）＋ store_manager 可讀，回傳形狀跟前端原本的 embed 一樣
--   （candidate → reco_predictions），所以前端只換讀法。
--   成本相關的只給看得到成本的角色（canSeeCost：owner/admin/hq_manager/hq_accountant/''）：
--   其他人拿不到 raw_text（廠商貼文原文含報價），理由裡「報價 $…」那行拿掉。
--   排入 / 略過照舊只有總部（rpc_reco_slate_decide 本來就擋）。
-- rollback：DROP FUNCTION public.rpc_calendar_slates(DATE, DATE);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_calendar_slates(p_from DATE, p_to DATE)
RETURNS TABLE (id BIGINT, slate_date DATE, rank INT, predicted INT, reason TEXT, pick_kind TEXT, candidate JSONB)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_hq     BOOLEAN := v_role IN ('owner', 'admin', 'hq_manager', 'assistant', '');
  v_cost   BOOLEAN := v_role IN ('owner', 'admin', 'hq_manager', 'hq_accountant', '');
BEGIN
  IF v_tenant IS NULL OR NOT (v_hq OR v_role = 'store_manager') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;
  RETURN QUERY
  SELECT s.id, s.slate_date, s.rank, s.predicted,
         CASE WHEN v_cost OR COALESCE(s.reason, '') NOT LIKE '報價%' THEN s.reason END,
         s.pick_kind,
         jsonb_build_object(
           'id', c.id,
           'product_name_hint', c.product_name_hint,
           'raw_text', CASE WHEN v_cost THEN c.raw_text END,
           'reco_predictions', CASE WHEN p.candidate_id IS NULL THEN NULL ELSE jsonb_build_object(
             'buyers', p.buyers, 'low', p.low, 'high', p.high, 'confidence', p.confidence,
             'reasons', to_jsonb(ARRAY(SELECT x FROM unnest(p.reasons) x WHERE v_cost OR x NOT LIKE '報價%')))
           END)
    FROM reco_slates s
    JOIN community_product_candidates c ON c.id = s.candidate_id
    LEFT JOIN reco_predictions p ON p.candidate_id = c.id
   WHERE s.tenant_id = v_tenant AND s.status = 'suggested'
     AND s.slate_date BETWEEN p_from AND p_to
   ORDER BY s.slate_date, s.rank;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_calendar_slates(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_calendar_slates(DATE, DATE) TO authenticated;
