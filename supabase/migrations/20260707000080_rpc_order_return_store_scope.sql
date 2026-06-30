-- ============================================================
-- rpc_create_order_return：修店長(store role)自店檢查
--
-- 問題：原本店員角色的「只能退自家店訂單」檢查比對 auth.jwt() ->> 'store_id'，
--   但本系統 store_manager 帳號 JWT **沒有 store_id claim**（只有
--   app_metadata.stores 店名陣列），導致該檢查恆為 DISTINCT → 店長一律被擋，
--   完全無法建退貨單（線上退貨單至今只有 admin 建過即為佐證）。
--
-- 修法：改用 20260707000070 的 _jwt_store_ids()（app_metadata.stores 店名 →
--   store_id），檢查「訂單取貨店是否在店長管理的店清單內」。角色集合補上
--   'clerk' 與後續政策對齊。
--
-- 其餘行為（退貨上限分流、status gate、movement_type、tag、restock_first 等）
-- 與基底版本逐字保留。
--
-- 基底版本：20260707000060_rpc_order_return_cap_unpicked.sql（線上現行）。
-- Rollback：CREATE OR REPLACE 回 20260707000060 版本（店長檢查改回比對 jwt.store_id）。
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
  v_delivered      NUMERIC;  -- R：該 SKU 已收(訂單)量（含已取貨）
  v_picked         NUMERIC;  -- P：該 SKU 已取貨量（status='picked_up'）
  v_ret_unpicked   NUMERIC;  -- 已退量：一般退貨（未帶 |取貨後退回 tag）
  v_ret_picked     NUMERIC;  -- 已退量：取貨後退回（帶 |取貨後退回 tag）
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

  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','clerk','') THEN
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

  -- role 限制：店端只能退自家店訂單。store role 的「自己店」由 app_metadata.stores
  -- 店名經 _jwt_store_ids() 推導（本系統 JWT 無 store_id claim）。
  IF v_role IN ('store_manager','store_staff','clerk') THEN
    IF NOT (v_order.pickup_store_id = ANY (public._jwt_store_ids())) THEN
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

    -- R：該 SKU 已收(訂單)量（含已取貨；single source of truth = customer_order_items）
    SELECT COALESCE(SUM(coi.qty), 0) INTO v_delivered
      FROM customer_order_items coi
     WHERE coi.order_id = p_order_id
       AND coi.sku_id = v_sku_id
       AND coi.status NOT IN ('cancelled','expired');

    IF v_delivered <= 0 THEN
      RAISE EXCEPTION 'sku % is not in order % (or is cancelled/expired)', v_sku_id, p_order_id;
    END IF;

    -- P：該 SKU 已取貨量（部分取貨會拆出獨立的 picked_up 行）
    SELECT COALESCE(SUM(coi.qty), 0) INTO v_picked
      FROM customer_order_items coi
     WHERE coi.order_id = p_order_id
       AND coi.sku_id = v_sku_id
       AND coi.status = 'picked_up';

    -- 已退量分兩池（依 notes 是否含 |取貨後退回 tag），本筆 transfer 還沒含進來
    SELECT
      COALESCE(SUM(ti.qty_shipped) FILTER (WHERE t.notes LIKE '%|取貨後退回%'), 0),
      COALESCE(SUM(ti.qty_shipped) FILTER (WHERE t.notes IS NULL OR t.notes NOT LIKE '%|取貨後退回%'), 0)
      INTO v_ret_picked, v_ret_unpicked
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.customer_order_id = p_order_id
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('shipped','received')
       AND t.source_location = v_store_loc
       AND t.id <> v_transfer_id
       AND ti.sku_id = v_sku_id;

    -- 退貨上限：依是否「已取貨後退回」分流
    IF p_restock_first THEN
      -- 客戶取走又拿回來：上限 = 已取貨量 − 已退(取貨後)量
      v_returnable := v_picked - v_ret_picked;
      IF v_qty > v_returnable THEN
        RAISE EXCEPTION 'sku %: 取貨後退回 qty % exceeds picked-up returnable % (picked=%, already_returned_after_pickup=%)',
          v_sku_id, v_qty, v_returnable, v_picked, v_ret_picked;
      END IF;
    ELSE
      -- 退店端「未取貨」的貨：上限 = (已收 − 已取) − 已退(一般)量
      v_returnable := (v_delivered - v_picked) - v_ret_unpicked;
      IF v_qty > v_returnable THEN
        RAISE EXCEPTION 'sku %: qty % exceeds returnable % (delivered=%, picked_up=%, already_returned=%)',
          v_sku_id, v_qty, v_returnable, v_delivered, v_picked, v_ret_unpicked;
      END IF;
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
  'p_movement_type: customer_return(預設) / damage（破損、notes 加|破損標記）。'
  'p_restock_first=true: 取貨後反悔，先 customer_return inbound 再 outbound 回總倉；notes 加 |取貨後退回。'
  '退貨上限分流：restock_first=true → 已取貨量 − 已退(取貨後)；false → (已收 − 已取) − 已退(一般)。'
  '店端角色只能退自家店訂單，自己店由 app_metadata.stores 經 _jwt_store_ids() 判定。'
  '非 restock 路徑不夠店端庫存時由 rpc_outbound 擋 Insufficient stock。';
