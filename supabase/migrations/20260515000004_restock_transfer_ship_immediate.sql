-- ============================================================
-- restock approve_to_transfer + ship_pr_received 改為直接建 'shipped' 狀態 transfer
--
-- 原因：HQ 在「派貨」/「PO 到貨」按下時等於承諾出貨，沒必要再經過 dispatch 二次確認。
-- 直接建 status='shipped' + 扣 HQ 庫存（rpc_outbound transfer_out），分店端在 /transfers/inbox
-- 立刻看到待收貨單。
--
-- 不影響 free transfer（仍 draft，使用者要在 dispatch 確認後才出貨）。
--
-- TEST: docs/TEST-store-self-service.md §2.7 / §2.14
-- Rollback: 重新 apply 20260515000002 / 20260515000003 對應段
-- ============================================================

-- ----------------------------------------------------------------
-- 改 rpc_approve_restock_to_transfer：建 shipped transfer + outbound HQ 庫存
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_approve_restock_to_transfer(
  p_request_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req          RECORD;
  v_hq_loc       BIGINT;
  v_dest_loc     BIGINT;
  v_transfer_id  BIGINT;
  v_no           TEXT;
  v_line         RECORD;
  v_out_mov_id   BIGINT;
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
  IF v_hq_loc IS NULL THEN RAISE EXCEPTION 'no active central_warehouse'; END IF;

  SELECT location_id INTO v_dest_loc FROM stores
   WHERE id = v_req.requesting_store_id AND tenant_id = v_tenant;
  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'requesting store % has no location_id', v_req.requesting_store_id;
  END IF;

  v_no := public._next_transfer_no();

  -- 直接 shipped 狀態
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_hq_loc, v_dest_loc,
    'shipped', 'hq_to_store',
    v_user, v_user, NOW(),
    'restock request #' || p_request_id::TEXT || COALESCE(' / ' || v_req.notes, ''),
    v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  -- 對每行：HQ outbound + 建 transfer_items（qty_shipped = qty_requested）
  FOR v_line IN
    SELECT sku_id, qty, notes FROM restock_request_lines
     WHERE request_id = p_request_id AND tenant_id = v_tenant
  LOOP
    v_out_mov_id := public.rpc_outbound(
      p_tenant_id       => v_tenant,
      p_location_id     => v_hq_loc,
      p_sku_id          => v_line.sku_id,
      p_quantity        => v_line.qty,
      p_movement_type   => 'transfer_out',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_transfer_id,
      p_operator        => v_user,
      p_allow_negative  => FALSE
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, notes, created_by, updated_by
    ) VALUES (
      v_transfer_id, v_line.sku_id, v_line.qty, v_line.qty,
      v_out_mov_id, v_line.notes, v_user, v_user
    );
  END LOOP;

  UPDATE restock_requests
     SET status = 'shipped',          -- 直接 shipped，不再經 approved_transfer 中繼狀態
         linked_transfer_id = v_transfer_id,
         approved_by = v_user,
         approved_at = NOW(),
         updated_by  = v_user
   WHERE id = p_request_id;

  RETURN v_transfer_id;
END;
$$;

-- ----------------------------------------------------------------
-- 改 rpc_ship_restock_pr_received：同上、直接 shipped + outbound
-- ----------------------------------------------------------------
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
  v_line        RECORD;
  v_out_mov_id  BIGINT;
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
  IF v_req.linked_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'request % already shipped (transfer #%)', p_request_id, v_req.linked_transfer_id;
  END IF;

  SELECT id INTO v_hq_loc FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN RAISE EXCEPTION 'no active central_warehouse'; END IF;

  SELECT location_id INTO v_dest_loc FROM stores
   WHERE id = v_req.requesting_store_id AND tenant_id = v_tenant;
  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'requesting store % has no location_id', v_req.requesting_store_id;
  END IF;

  v_no := public._next_transfer_no();

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_no, v_hq_loc, v_dest_loc,
    'shipped', 'hq_to_store',
    v_user, v_user, NOW(),
    'restock #' || p_request_id::TEXT || ' / PR #' || v_req.linked_pr_id::TEXT,
    v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  FOR v_line IN
    SELECT sku_id, qty, notes FROM restock_request_lines
     WHERE request_id = p_request_id AND tenant_id = v_tenant
  LOOP
    v_out_mov_id := public.rpc_outbound(
      p_tenant_id       => v_tenant,
      p_location_id     => v_hq_loc,
      p_sku_id          => v_line.sku_id,
      p_quantity        => v_line.qty,
      p_movement_type   => 'transfer_out',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_transfer_id,
      p_operator        => v_user,
      p_allow_negative  => FALSE
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, notes, created_by, updated_by
    ) VALUES (
      v_transfer_id, v_line.sku_id, v_line.qty, v_line.qty,
      v_out_mov_id, v_line.notes, v_user, v_user
    );
  END LOOP;

  UPDATE restock_requests
     SET status = 'shipped',
         linked_transfer_id = v_transfer_id,
         updated_by = v_user
   WHERE id = p_request_id;

  RETURN v_transfer_id;
END;
$$;

-- ----------------------------------------------------------------
-- 既有 status='approved_transfer' 的 row：仍是合法狀態（CHECK 沒改），
-- 因為 backfill 不動歷史 — 但新建 row 都會直接走 'shipped'
-- ----------------------------------------------------------------
COMMENT ON FUNCTION public.rpc_approve_restock_to_transfer(BIGINT) IS
  'HQ 派庫存：建 shipped transfer + outbound HQ 庫存；request status=shipped';
COMMENT ON FUNCTION public.rpc_ship_restock_pr_received(BIGINT) IS
  'restock approved_pr → 收貨後派貨：建 shipped transfer + outbound HQ 庫存';
