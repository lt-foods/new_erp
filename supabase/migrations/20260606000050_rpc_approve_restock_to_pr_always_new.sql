-- ============================================================
-- rpc_approve_restock_to_pr — 改成「每按一次都建新 PR」
--
-- 原本邏輯：找 24h 內 draft PR 就 append；無就建新。
-- 新邏輯：每次呼叫都產生獨立的 draft PR，不再合併。
--
-- 動機：HQ 在 Inbox 點「下訂單」希望一張補貨申請對應一張採購單，
-- 才方便分開追蹤 / 對供應商。
--
-- Rollback: CREATE OR REPLACE 回 24h append 版本（見
--           supabase/migrations/20260515000002_rpc_store_self_service.sql）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_approve_restock_to_pr(
  p_request_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_user     UUID := auth.uid();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req      RECORD;
  v_pr_id    BIGINT;
  v_hq_loc   BIGINT;
  v_no       TEXT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot approve restock', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  SELECT id INTO v_hq_loc FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;

  -- 每次都建新 PR（不再 append 到既有 24h draft）
  v_no := public.rpc_next_pr_no();
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_location_id, status, raw_line_text,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_hq_loc, 'draft',
    'restock request #' || p_request_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_pr_id;

  -- 鏡像 lines 進 PR
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, raw_line, notes, created_by, updated_by
  )
  SELECT v_pr_id, l.sku_id, l.qty,
         'restock #' || p_request_id::TEXT,
         l.notes, v_user, v_user
    FROM restock_request_lines l
   WHERE l.request_id = p_request_id AND l.tenant_id = v_tenant;

  -- 標 request approved_pr
  UPDATE restock_requests
     SET status = 'approved_pr',
         linked_pr_id = v_pr_id,
         approved_by = v_user,
         approved_at = NOW(),
         updated_by  = v_user
   WHERE id = p_request_id;

  RETURN v_pr_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_approve_restock_to_pr(BIGINT) IS
  '把補貨申請 approve_pr 化：每次都建新 draft PR + 鏡像 lines；不再 append 到 24h 內既有 draft。';
