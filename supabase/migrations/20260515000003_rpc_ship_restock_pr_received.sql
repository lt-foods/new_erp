-- ============================================================
-- rpc_ship_restock_pr_received(p_request_id) — restock approved_pr 走完 PO 後派貨
--
-- 流程：
--   restock_request approved_pr → linked_pr → 拆 PO → 收貨 (HQ 倉)
--   到此 RPC：建 hq_to_store transfer，把 restock_request_lines 的數量轉入
--           transfer_items；status 改 'shipped'、linked_transfer_id 寫入
--
-- 不強制 check PR/PO 已收完 — admin 是人工 in the loop（避免太早 ship）
--
-- TEST: docs/TEST-store-self-service.md (新增 §2.14)
-- Rollback: DROP FUNCTION public.rpc_ship_restock_pr_received(BIGINT);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_ship_restock_pr_received(
  p_request_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_user        UUID := auth.uid();
  v_role        TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req         RECORD;
  v_hq_loc      BIGINT;
  v_dest_loc    BIGINT;
  v_transfer_id BIGINT;
  v_no          TEXT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot ship restock', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;

  IF v_req.status <> 'approved_pr' THEN
    RAISE EXCEPTION 'request % must be in approved_pr (current: %)', p_request_id, v_req.status;
  END IF;

  IF v_req.linked_pr_id IS NULL THEN
    RAISE EXCEPTION 'request % missing linked_pr_id', p_request_id;
  END IF;

  -- 防止重複建 transfer
  IF v_req.linked_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'request % already has linked_transfer_id=%', p_request_id, v_req.linked_transfer_id;
  END IF;

  -- HQ 倉
  SELECT id INTO v_hq_loc FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    RAISE EXCEPTION 'no active central_warehouse location for tenant';
  END IF;

  -- 目的店 location
  SELECT location_id INTO v_dest_loc FROM stores
   WHERE id = v_req.requesting_store_id AND tenant_id = v_tenant;
  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'requesting store % has no location_id', v_req.requesting_store_id;
  END IF;

  -- 建 transfer
  v_no := public._next_transfer_no();
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location, status, transfer_type,
    requested_by, notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_hq_loc, v_dest_loc, 'draft', 'hq_to_store',
    v_user,
    'restock #' || p_request_id::TEXT || ' / PR #' || v_req.linked_pr_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  -- 鏡像 lines
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, notes, created_by, updated_by)
  SELECT v_transfer_id, l.sku_id, l.qty, l.notes, v_user, v_user
    FROM restock_request_lines l
   WHERE l.request_id = p_request_id AND l.tenant_id = v_tenant;

  -- 更 request status
  UPDATE restock_requests
     SET status = 'shipped',
         linked_transfer_id = v_transfer_id,
         updated_by = v_user
   WHERE id = p_request_id;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_ship_restock_pr_received(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_ship_restock_pr_received(BIGINT) IS
  'restock approved_pr → 收貨後派貨：建 hq_to_store transfer + status 改 shipped';
