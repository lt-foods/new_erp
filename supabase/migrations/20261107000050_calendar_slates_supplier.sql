-- ============================================================================
-- 選品週曆的系統預選卡直接顯示廠商（Alex 2026-11-07：「在這邊直接出現廠商」）
--
-- rpc_calendar_slates 的 candidate JSONB 多兩個鍵：
--   supplier：suppliers.name（候選 raw.supplier_id），沒有就退 parsed.supplier
--   source：raw.source（'vendor_site' 廠商網站 / 'line_note_supplier' 廠商群組 / 其他）
-- 只回給總部角色（v_hq）；店長的唯讀週曆拿到 NULL，維持 20261102000040「店長只看推薦、不看廠商報價」的口徑。
-- 回傳欄位形狀沒變（candidate 本來就是 JSONB），舊前端忽略新鍵、不會壞。
--
-- 基底版本：rpc_calendar_slates ← 20261102000040_calendar_store_slates.sql（唯一一支）
-- rollback：重跑 20261102000040 的 rpc_calendar_slates 定義
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
           -- 20261107000050：廠商名（總部才給；店長的唯讀週曆不顯示）
           'supplier', CASE WHEN v_hq THEN COALESCE(sup.name, NULLIF(c.parsed ->> 'supplier', '')) END,
           'source', CASE WHEN v_hq THEN c.raw ->> 'source' END,
           'reco_predictions', CASE WHEN p.candidate_id IS NULL THEN NULL ELSE jsonb_build_object(
             'buyers', p.buyers, 'low', p.low, 'high', p.high, 'confidence', p.confidence,
             'reasons', to_jsonb(ARRAY(SELECT x FROM unnest(p.reasons) x WHERE v_cost OR x NOT LIKE '報價%')))
           END)
    FROM reco_slates s
    JOIN community_product_candidates c ON c.id = s.candidate_id
    LEFT JOIN reco_predictions p ON p.candidate_id = c.id
    LEFT JOIN suppliers sup ON sup.id = CASE WHEN (c.raw ->> 'supplier_id') ~ '^\d+$'
                                             THEN (c.raw ->> 'supplier_id')::bigint END
   WHERE s.tenant_id = v_tenant AND s.status = 'suggested'
     AND s.slate_date BETWEEN p_from AND p_to
   ORDER BY s.slate_date, s.rank;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_calendar_slates(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_calendar_slates(DATE, DATE) TO authenticated;
