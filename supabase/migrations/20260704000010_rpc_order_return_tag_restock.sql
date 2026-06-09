-- ============================================================
-- rpc_create_order_return：把「客戶已取貨後退回 (restock_first)」記進 notes
--
-- 動機：退貨 modal 的「客戶已取貨後退回」勾選 (p_restock_first) 原本只影響
--   出入庫流程（先 inbound 店端再 outbound 回總倉），不留任何痕跡。導致訂單
--   明細頁的「退貨記錄」無從分辨某筆退貨是「取貨後退回」還是「取貨前退回」。
--
-- 改法：沿用既有 v_type_tag 機制（破損 = |破損），新增 p_restock_first=true 時
--   在 notes 追加 |取貨後退回 標記。前端解析 notes 即可顯示「客戶已取貨後退回」。
--   notes 範例：
--     [order return]                      一般退貨
--     [order return|破損]                  破損
--     [order return|取貨後退回]            取貨後退回
--     [order return|破損|取貨後退回: 原因]  破損 + 取貨後退回 + 原因
--
-- 其餘行為（status gate 含 expired、movement_type 驗證、returnable = 訂單量 -
-- 已退量、restock_first 的 inbound→outbound、store-role 自店限制、tenant scoping）
-- 全部與基底版本一致、逐字保留。
--
-- 基底版本：20260615000020_rpc_order_return_movement_type_restock.sql（線上現行、
--   6-arg signature，含 p_movement_type / p_restock_first）。
-- Rollback：CREATE OR REPLACE 回 20260615000020 版本（v_type_tag 改回只判 damage）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_create_order_return(
  p_order_id      BIGINT,
  p_lines         JSONB,
  p_reason        TEXT    DEFAULT NULL,
  p_operator      UUID    DEFAULT NULL,
  p_movement_type TEXT    DEFAULT 'customer_return',
  p_restock_first BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_user           UUID := COALESCE(p_operator, auth.uid());
  v_role           TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_order          customer_orders%ROWTYPE;
  v_store_loc      BIGINT;
  v_hq_loc         BIGINT;
  v_transfer_id    BIGINT;
  v_transfer_no    TEXT;
  v_line           JSONB;
  v_sku_id         BIGINT;
  v_qty            NUMERIC;
  v_delivered      NUMERIC;
  v_already_ret    NUMERIC;
  v_returnable     NUMERIC;
  v_mov_id         BIGINT;
  v_count          INT := 0;
  v_result_lines   JSONB := '[]'::JSONB;
  v_reason_note    TEXT;
  v_type_tag       TEXT;
BEGIN
  -- P1: 驗 movement_type（只允許這兩種、皆在 stock_movements CHECK 內）
  IF p_movement_type IS NULL OR p_movement_type NOT IN ('customer_return','damage') THEN
    RAISE EXCEPTION 'invalid p_movement_type % (must be customer_return or damage)', p_movement_type;
  END IF;

  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot create order return', v_role;
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % not found in tenant', p_order_id;
  END IF;
  IF v_order.status NOT IN ('shipping','ready','partially_completed','completed','expired') THEN
    RAISE EXCEPTION 'order % status=% cannot be returned (must be shipping/ready/partially_completed/completed/expired)',
      p_order_id, v_order.status;
  END IF;

  SELECT location_id INTO v_store_loc
    FROM stores
   WHERE id = v_order.pickup_store_id AND tenant_id = v_tenant;
  IF v_store_loc IS NULL THEN
    RAISE EXCEPTION 'pickup store % has no location_id', v_order.pickup_store_id;
  END IF;

  SELECT id INTO v_hq_loc
    FROM locations
   WHERE tenant_id = v_tenant AND type = 'central_warehouse' AND is_active = TRUE
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    RAISE EXCEPTION 'no active central_warehouse location for tenant';
  END IF;
  IF v_hq_loc = v_store_loc THEN
    RAISE EXCEPTION 'pickup store location is HQ; cannot return to self';
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  IF v_role IN ('store_manager','store_staff') THEN
    IF v_order.pickup_store_id::TEXT IS DISTINCT FROM (auth.jwt() ->> 'store_id') THEN
      RAISE EXCEPTION 'store role can only return orders for own store';
    END IF;
  END IF;

  v_transfer_no := public._next_transfer_no();
  -- 在 notes 加標記（HQ 收貨端 / 對帳 / 訂單退貨記錄看得出退貨情境）：
  --   破損 → |破損；客戶已取貨後退回 (restock_first) → |取貨後退回
  v_type_tag := '';
  IF p_movement_type = 'damage' THEN
    v_type_tag := v_type_tag || '|破損';
  END IF;
  IF p_restock_first THEN
    v_type_tag := v_type_tag || '|取貨後退回';
  END IF;
  v_reason_note := CASE
    WHEN NULLIF(TRIM(COALESCE(p_reason,'')),'') IS NOT NULL
    THEN '[order return' || v_type_tag || ': ' || TRIM(p_reason) || ']'
    ELSE '[order return' || v_type_tag || ']'
  END;

  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, customer_order_id,
    requested_by, shipped_by, shipped_at,
    notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_transfer_no, v_store_loc, v_hq_loc,
    'shipped', 'return_to_hq', p_order_id,
    v_user, v_user, NOW(),
    v_reason_note, v_user, v_user
  ) RETURNING id INTO v_transfer_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_sku_id := (v_line ->> 'sku_id')::BIGINT;
    v_qty    := (v_line ->> 'qty')::NUMERIC;

    IF v_sku_id IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'invalid line: sku_id=% qty=%', v_sku_id, v_qty;
    END IF;

    SELECT COALESCE(SUM(coi.qty), 0) INTO v_delivered
      FROM customer_order_items coi
     WHERE coi.order_id = p_order_id
       AND coi.sku_id = v_sku_id
       AND coi.status NOT IN ('cancelled','expired');

    IF v_delivered <= 0 THEN
      RAISE EXCEPTION 'sku % is not in order % (or is cancelled/expired)', v_sku_id, p_order_id;
    END IF;

    SELECT COALESCE(SUM(ti.qty_shipped), 0) INTO v_already_ret
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.customer_order_id = p_order_id
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('shipped','received')
       AND t.source_location = v_store_loc
       AND t.id <> v_transfer_id
       AND ti.sku_id = v_sku_id;

    v_returnable := v_delivered - v_already_ret;
    IF v_qty > v_returnable THEN
      RAISE EXCEPTION 'sku %: qty % exceeds returnable % (delivered=%, already_returned=%)',
        v_sku_id, v_qty, v_returnable, v_delivered, v_already_ret;
    END IF;

    -- P2-A: 取貨後反悔 — 先把退回的貨入庫店端（customer_return inbound），
    -- 之後 outbound 才有庫存可扣。unit_cost=0 → 不動 avg_cost。
    IF p_restock_first THEN
      PERFORM rpc_inbound(
        p_tenant_id       => v_tenant,
        p_location_id     => v_store_loc,
        p_sku_id          => v_sku_id,
        p_quantity        => v_qty,
        p_unit_cost       => 0,
        p_movement_type   => 'customer_return',
        p_source_doc_type => 'customer_order',
        p_source_doc_id   => p_order_id,
        p_operator        => v_user
      );
    END IF;

    -- 出庫店端 → 在途回總倉。P1: movement_type 由參數決定。
    v_mov_id := rpc_outbound(
      p_tenant_id       => v_tenant,
      p_location_id     => v_store_loc,
      p_sku_id          => v_sku_id,
      p_quantity        => v_qty,
      p_movement_type   => p_movement_type,
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_transfer_id,
      p_operator        => v_user
    );

    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped,
      out_movement_id, notes, created_by, updated_by
    ) VALUES (
      v_transfer_id, v_sku_id, v_qty, v_qty,
      v_mov_id, v_line ->> 'notes', v_user, v_user
    );

    v_result_lines := v_result_lines || jsonb_build_object(
      'sku_id', v_sku_id,
      'qty', v_qty,
      'out_movement_id', v_mov_id
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines must not be empty';
  END IF;

  RETURN jsonb_build_object(
    'return_transfer_id', v_transfer_id,
    'transfer_no', v_transfer_no,
    'order_id', p_order_id,
    'source_location', v_store_loc,
    'dest_location', v_hq_loc,
    'movement_type', p_movement_type,
    'restocked_first', p_restock_first,
    'lines', v_result_lines
  );
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_create_order_return(BIGINT, JSONB, TEXT, UUID, TEXT, BOOLEAN)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_create_order_return IS
  '分店發起退訂單回總倉。allowed status: shipping/ready/partially_completed/completed/expired。'
  'p_movement_type: customer_return(預設) / damage（破損、會計分流，notes 加|破損標記）。'
  'p_restock_first=true: 取貨後反悔情境，先 customer_return inbound 店端再 outbound 回總倉（整合原手動兩步）；'
  'notes 加 |取貨後退回 標記供前端退貨記錄顯示。'
  'returnable = 訂單量 - 已退量；不夠店端庫存（未 restock_first 時）由 rpc_outbound 擋 Insufficient stock。';
