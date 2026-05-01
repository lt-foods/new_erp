-- ============================================================
-- 5 RPCs for store self-service：
--   1. rpc_create_free_transfer       — case 1：自由轉貨（虛擬 SKU + description + estimated）
--   2. rpc_create_restock_request     — case 2：分店建補貨申請
--   3. rpc_approve_restock_to_transfer — HQ 派庫存出貨
--   4. rpc_approve_restock_to_pr      — HQ 改採購（append 到 24h 內 draft PR 或建新 PR）
--   5. rpc_reject_restock             — HQ 拒絕
--
-- TEST: docs/TEST-store-self-service.md §2.1-2.13
-- Rollback: DROP FUNCTION 5 支
-- ============================================================

-- ----------------------------------------------------------------
-- Helper: 生成 transfer_no （TR{YYMMDD}-{seq4}）
-- ----------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS transfer_no_seq;

CREATE OR REPLACE FUNCTION public._next_transfer_no()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN 'TR' || to_char(NOW(), 'YYMMDD') || lpad(nextval('transfer_no_seq')::TEXT, 4, '0');
END;
$$;

-- ----------------------------------------------------------------
-- 1. rpc_create_free_transfer — 自由轉貨
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_free_transfer(
  p_source_location BIGINT,
  p_dest_location   BIGINT,
  p_lines           JSONB,    -- [{ description, qty, estimated_amount, notes? }]
  p_notes           TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_user        UUID := auth.uid();
  v_role        TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_misc_sku_id BIGINT;
  v_transfer_id BIGINT;
  v_no          TEXT;
  v_line        JSONB;
  v_count       INT := 0;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create free transfer', v_role;
  END IF;

  IF p_source_location IS NULL OR p_dest_location IS NULL THEN
    RAISE EXCEPTION 'source / dest location required';
  END IF;
  IF p_source_location = p_dest_location THEN
    RAISE EXCEPTION 'source must differ from dest';
  END IF;

  -- 確認 location 都在同 tenant
  PERFORM 1 FROM locations WHERE id = p_source_location AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'source_location % not in tenant', p_source_location; END IF;
  PERFORM 1 FROM locations WHERE id = p_dest_location AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'dest_location % not in tenant', p_dest_location; END IF;

  -- 取 MISC virtual SKU
  SELECT s.id INTO v_misc_sku_id
    FROM skus s
    JOIN products p ON p.id = s.product_id
   WHERE s.tenant_id = v_tenant AND p.is_virtual = TRUE AND s.sku_code = 'MISC-01'
   LIMIT 1;
  IF v_misc_sku_id IS NULL THEN
    RAISE EXCEPTION 'MISC virtual SKU not found for tenant; run migration 20260515000000';
  END IF;

  -- 建 transfer 單頭
  v_no := public._next_transfer_no();
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location, status, transfer_type,
    requested_by, notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_no, p_source_location, p_dest_location, 'draft', 'store_to_store',
    v_user, p_notes, v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  -- 建 lines（虛擬 SKU + description + estimated_amount）
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    IF NULLIF(TRIM(v_line ->> 'description'), '') IS NULL THEN
      RAISE EXCEPTION 'line description must not be blank';
    END IF;
    IF (v_line ->> 'qty')::NUMERIC <= 0 THEN
      RAISE EXCEPTION 'line qty must be > 0';
    END IF;
    IF (v_line ->> 'estimated_amount')::NUMERIC < 0 THEN
      RAISE EXCEPTION 'estimated_amount must be >= 0';
    END IF;

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested,
      description, estimated_amount, notes,
      created_by, updated_by
    ) VALUES (
      v_transfer_id, v_misc_sku_id, (v_line ->> 'qty')::NUMERIC,
      TRIM(v_line ->> 'description'),
      (v_line ->> 'estimated_amount')::NUMERIC,
      v_line ->> 'notes',
      v_user, v_user
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_free_transfer(BIGINT, BIGINT, JSONB, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------
-- 2. rpc_create_restock_request — 分店建補貨申請
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_restock_request(
  p_store_id BIGINT,
  p_lines    JSONB,    -- [{ sku_id, qty, unit_price, notes? }]
  p_notes    TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_user       UUID := auth.uid();
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_request_id BIGINT;
  v_line       JSONB;
  v_sku_id     BIGINT;
  v_count      INT := 0;
  v_is_virtual BOOLEAN;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create restock request', v_role;
  END IF;

  -- 分店 role 只能建自家店；HQ role 任何店都行
  IF v_role IN ('store_manager','store_staff') THEN
    IF p_store_id::TEXT IS DISTINCT FROM (auth.jwt() ->> 'store_id') THEN
      RAISE EXCEPTION 'store role can only create request for own store';
    END IF;
  END IF;

  PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;

  -- 建 request
  INSERT INTO restock_requests (
    tenant_id, requesting_store_id, status, notes,
    requested_by, requested_at, created_by, updated_by
  ) VALUES (
    v_tenant, p_store_id, 'pending', p_notes,
    v_user, NOW(), v_user, v_user
  ) RETURNING id INTO v_request_id;

  -- 建 lines
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;

    -- 跨 tenant + 虛擬 SKU 拒絕
    SELECT p.is_virtual INTO v_is_virtual
      FROM skus s
      JOIN products p ON p.id = s.product_id
     WHERE s.id = v_sku_id AND s.tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sku % not in tenant', v_sku_id;
    END IF;
    IF v_is_virtual THEN
      RAISE EXCEPTION 'restock request cannot use virtual sku %', v_sku_id;
    END IF;

    IF (v_line ->> 'qty')::NUMERIC <= 0 THEN
      RAISE EXCEPTION 'line qty must be > 0';
    END IF;

    INSERT INTO restock_request_lines (
      tenant_id, request_id, sku_id, qty, unit_price, notes,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_request_id, v_sku_id,
      (v_line ->> 'qty')::NUMERIC,
      COALESCE((v_line ->> 'unit_price')::NUMERIC, 0),
      v_line ->> 'notes',
      v_user, v_user
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  RETURN v_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_restock_request(BIGINT, JSONB, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------
-- 3. rpc_approve_restock_to_transfer — HQ 派庫存出貨
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
    'restock request #' || p_request_id::TEXT || COALESCE(' / ' || v_req.notes, ''),
    v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  -- 鏡像 lines（真實 SKU、不用 description/estimated）
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, notes, created_by, updated_by)
  SELECT v_transfer_id, l.sku_id, l.qty, l.notes, v_user, v_user
    FROM restock_request_lines l
   WHERE l.request_id = p_request_id AND l.tenant_id = v_tenant;

  -- 標 request approved_transfer
  UPDATE restock_requests
     SET status = 'approved_transfer',
         linked_transfer_id = v_transfer_id,
         approved_by = v_user,
         approved_at = NOW(),
         updated_by  = v_user
   WHERE id = p_request_id;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_approve_restock_to_transfer(BIGINT)
  TO authenticated;

-- ----------------------------------------------------------------
-- 4. rpc_approve_restock_to_pr — HQ 改採購（24h 內 draft PR append、否則建新）
-- ----------------------------------------------------------------
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

  -- 找 24h 內 draft PR；有就 append
  SELECT id INTO v_pr_id FROM purchase_requests
   WHERE tenant_id = v_tenant
     AND status = 'draft'
     AND created_at > NOW() - INTERVAL '24 hours'
   ORDER BY id DESC LIMIT 1;

  IF v_pr_id IS NULL THEN
    v_no := public.rpc_next_pr_no();
    INSERT INTO purchase_requests (
      tenant_id, pr_no, source_location_id, status, raw_line_text,
      created_by, updated_by
    ) VALUES (
      v_tenant, v_no, v_hq_loc, 'draft',
      'restock request #' || p_request_id::TEXT,
      v_user, v_user
    ) RETURNING id INTO v_pr_id;
  END IF;

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

GRANT EXECUTE ON FUNCTION public.rpc_approve_restock_to_pr(BIGINT)
  TO authenticated;

-- ----------------------------------------------------------------
-- 5. rpc_reject_restock — HQ 拒絕
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_reject_restock(
  p_request_id BIGINT,
  p_reason     TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req    RECORD;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot reject restock', v_role;
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'rejection reason required';
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request % not found', p_request_id; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'request % already processed (status=%)', p_request_id, v_req.status;
  END IF;

  UPDATE restock_requests
     SET status = 'rejected',
         rejected_by = v_user,
         rejected_at = NOW(),
         rejected_reason = TRIM(p_reason),
         updated_by = v_user
   WHERE id = p_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_reject_restock(BIGINT, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------
-- Comments
-- ----------------------------------------------------------------
COMMENT ON FUNCTION public.rpc_create_free_transfer       IS 'Case 1：自由轉貨（虛擬 SKU + description + estimated_amount）';
COMMENT ON FUNCTION public.rpc_create_restock_request     IS 'Case 2：分店建補貨申請（pending 狀態、限真實 SKU）';
COMMENT ON FUNCTION public.rpc_approve_restock_to_transfer IS 'HQ 派既有庫存出貨（建 hq_to_store transfer + 連結）';
COMMENT ON FUNCTION public.rpc_approve_restock_to_pr      IS 'HQ 改採購（24h 內 draft PR append 或建新）';
COMMENT ON FUNCTION public.rpc_reject_restock             IS 'HQ 拒絕補貨申請（reason 必填）';
