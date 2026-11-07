-- ============================================================================
-- 選品週曆：人工排的卡，系統預選也有選到同一樣的 → 標出來（Alex 2026-11-07）
--
-- 「人工排」= 不是從週曆預選按「排入」來的（_reco_schedule_source = 'manual'），絕大多數是選品機器人
-- 收到的開團文直接排程。要知道系統有沒有也挑到同一樣東西，拿「排程卡採用的商品」跟
-- 「預選卡的廠商品項」比：
--   1. 同一筆候選本來就有預選（從候選池頁排程、不是按「排入」，reco_slates 有列但 decided_by 空）→ via='self'
--   2. 排程卡的商品向量（product_embeddings）vs 預選候選的品項向量（line_note_market_items.embedding）
--      cos ≥ 0.85（跟「賣過」同一個門檻），預選日期在排程日 ±14 天內 → via='product'，取最像的一筆
-- 11/7 正式庫實測：最近 14 天 262 張人工排，命中 1 張（阿里山山葵椒鹽，cos 0.868）；一週的量約 27ms。
--
-- rpc_calendar_week 多回一欄 also_picked JSONB（null = 系統沒選；有值 = {via, slate_date, status, pick_kind,
-- predicted, item_name, cos}）。RETURNS TABLE 加欄位要先 DROP 再建，權限重新給。
-- 總部與店長都看得到（預選本來兩邊都看得到，20261102000040）。
--
-- 基底版本：rpc_calendar_week ← 20261101000240_calendar_readonly_source.sql（唯一一支）
--   _reco_schedule_source 不動（最新 20261101000250）
-- rollback：DROP FUNCTION public.rpc_calendar_week(DATE, DATE); 重跑 20261101000240 的 rpc_calendar_week；
--   DROP FUNCTION public._reco_also_picked(BIGINT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public._reco_also_picked(p_candidate_id BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  WITH me AS (
    SELECT c.id, c.tenant_id, c.scheduled_open_at, e.embedding
      FROM community_product_candidates c
      LEFT JOIN product_embeddings e ON e.product_id = c.adopted_product_id
     WHERE c.id = p_candidate_id
  ),
  hits AS (
    -- 1. 自己就有預選
    SELECT 'self' AS via, s.slate_date, s.status, s.pick_kind, s.predicted, NULL::text AS item_name, NULL::numeric AS cos,
           0 AS pri
      FROM me, reco_slates s
     WHERE s.candidate_id = me.id
    UNION ALL
    -- 2. 預選裡有一樣的東西（商品向量 vs 廠商品項向量）
    SELECT 'product', s.slate_date, s.status, s.pick_kind, s.predicted, i.item_name,
           round((1 - (i.embedding <=> me.embedding))::numeric, 3), 1
      FROM me
      JOIN reco_slates s ON s.tenant_id = me.tenant_id
                        AND me.scheduled_open_at IS NOT NULL
                        AND s.slate_date BETWEEN me.scheduled_open_at - 14 AND me.scheduled_open_at + 14
      JOIN community_product_candidates sc ON sc.id = s.candidate_id
      JOIN line_note_market_items i ON i.id = (sc.raw ->> 'market_item_id')::bigint
     WHERE me.embedding IS NOT NULL AND i.embedding IS NOT NULL
       AND sc.id <> me.id
       AND 1 - (i.embedding <=> me.embedding) >= 0.85
  )
  SELECT to_jsonb(h) - 'pri'
    FROM (SELECT via, slate_date, status, pick_kind, predicted, item_name, cos, pri
            FROM hits ORDER BY pri, cos DESC NULLS LAST, slate_date LIMIT 1) h;
$$;
REVOKE ALL ON FUNCTION public._reco_also_picked(BIGINT) FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.rpc_calendar_week(DATE, DATE);
CREATE FUNCTION public.rpc_calendar_week(p_from DATE, p_to DATE)
RETURNS TABLE (
  id BIGINT, product_name_hint TEXT, scheduled_open_at DATE, scheduled_sort_order INT, owner_action TEXT,
  created_at TIMESTAMPTZ, adopted_supplier_name TEXT, adopted_cost NUMERIC, adopted_sale_price NUMERIC,
  source TEXT, also_picked JSONB
)
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
  SELECT c.id, c.product_name_hint, c.scheduled_open_at, c.scheduled_sort_order, c.owner_action, c.created_at,
         CASE WHEN v_cost THEN c.adopted_supplier_name END,
         CASE WHEN v_cost THEN c.adopted_cost END,
         CASE WHEN v_cost THEN c.adopted_sale_price END,
         public._reco_schedule_source(c.id),
         -- 人工排的才需要問「系統也有選嗎」；從預選排入的本來就是系統選的
         CASE WHEN public._reco_schedule_source(c.id) = 'manual' THEN public._reco_also_picked(c.id) END
    FROM community_product_candidates c
   WHERE c.tenant_id = v_tenant
     AND c.scheduled_open_at IS NOT NULL
     AND c.scheduled_open_at BETWEEN p_from AND p_to
   ORDER BY c.scheduled_open_at, c.scheduled_sort_order NULLS LAST, c.created_at;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_calendar_week(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_calendar_week(DATE, DATE) TO authenticated;
