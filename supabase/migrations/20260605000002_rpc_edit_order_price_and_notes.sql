-- ============================================================
-- /orders 改售價 + 加備註 RPC 集
--   全部 SECURITY DEFINER（admin user JWT role 常為 NULL，需繞 RLS）
--   權限：HQ (owner/admin/hq_manager) 全 + 店家僅自店訂單
--   role 為 NULL 視同 admin tier（reference_admin_jwt_role_null.md）
--   每次修改寫一筆 customer_order_audit_log；no-op (新值=舊值) 不寫
-- ============================================================

-- ---------- helper：權限檢查 + 鎖 order ----------
CREATE OR REPLACE FUNCTION _check_order_edit_perm(p_order_id BIGINT)
RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_tenant UUID   := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role   TEXT   := COALESCE(auth.jwt() ->> 'role', '');
  v_store  BIGINT := NULLIF(auth.jwt() ->> 'store_id','')::bigint;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found in tenant %', p_order_id, v_tenant;
  END IF;

  -- HQ tier（含 role NULL）
  IF v_role IN ('owner','admin','hq_manager','hq_accountant','') THEN
    RETURN v_order;
  END IF;

  -- 店家：限自店
  IF v_store IS NOT NULL AND v_order.pickup_store_id = v_store THEN
    RETURN v_order;
  END IF;

  RAISE EXCEPTION 'permission denied: role=% store=% cannot edit order %',
    v_role, COALESCE(v_store::text,'NULL'), p_order_id;
END;
$$;

-- ---------- 1. line item unit_price ----------
CREATE OR REPLACE FUNCTION rpc_update_order_item_price(
  p_order_id       BIGINT,
  p_item_id        BIGINT,
  p_new_unit_price NUMERIC,
  p_operator       UUID,
  p_reason         TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_order_items;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  IF p_new_unit_price IS NULL OR p_new_unit_price < 0 THEN
    RAISE EXCEPTION 'unit_price must be >= 0';
  END IF;

  SELECT unit_price INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  IF v_old = p_new_unit_price THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET unit_price = p_new_unit_price,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'unit_price',
     to_jsonb(v_old), to_jsonb(p_new_unit_price), p_reason, p_operator);

  RETURN v_row;
END;
$$;

-- ---------- 2. order header discount_amount ----------
CREATE OR REPLACE FUNCTION rpc_update_order_discount(
  p_order_id     BIGINT,
  p_new_discount NUMERIC,
  p_operator     UUID,
  p_reason       TEXT DEFAULT NULL
) RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_orders;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  IF p_new_discount IS NULL OR p_new_discount < 0 THEN
    RAISE EXCEPTION 'discount must be >= 0';
  END IF;

  v_old := v_order.discount_amount;

  IF v_old = p_new_discount THEN
    RETURN v_order;
  END IF;

  UPDATE customer_orders
     SET discount_amount = p_new_discount,
         updated_by      = p_operator,
         updated_at      = NOW()
   WHERE id = p_order_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'order', NULL, 'discount_amount',
     to_jsonb(v_old), to_jsonb(p_new_discount), p_reason, p_operator);

  RETURN v_row;
END;
$$;

-- ---------- 3. order header notes ----------
CREATE OR REPLACE FUNCTION rpc_update_order_notes(
  p_order_id  BIGINT,
  p_new_notes TEXT,
  p_operator  UUID,
  p_reason    TEXT DEFAULT NULL
) RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   TEXT;
  v_row   customer_orders;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  v_old := v_order.notes;

  IF v_old IS NOT DISTINCT FROM p_new_notes THEN
    RETURN v_order;
  END IF;

  UPDATE customer_orders
     SET notes      = p_new_notes,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_order_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'order', NULL, 'order_notes',
     to_jsonb(v_old), to_jsonb(p_new_notes), p_reason, p_operator);

  RETURN v_row;
END;
$$;

-- ---------- 4. line item notes ----------
CREATE OR REPLACE FUNCTION rpc_update_order_item_notes(
  p_order_id  BIGINT,
  p_item_id   BIGINT,
  p_new_notes TEXT,
  p_operator  UUID,
  p_reason    TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   TEXT;
  v_row   customer_order_items;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  SELECT notes INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  IF v_old IS NOT DISTINCT FROM p_new_notes THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET notes      = p_new_notes,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'item_notes',
     to_jsonb(v_old), to_jsonb(p_new_notes), p_reason, p_operator);

  RETURN v_row;
END;
$$;

-- ---------- GRANT EXECUTE（4 個對外 RPC；helper 不開 grant） ----------
GRANT EXECUTE ON FUNCTION rpc_update_order_item_price(BIGINT, BIGINT, NUMERIC, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_order_discount(BIGINT, NUMERIC, UUID, TEXT)           TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_order_notes(BIGINT, TEXT, UUID, TEXT)                 TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_order_item_notes(BIGINT, BIGINT, TEXT, UUID, TEXT)    TO authenticated;
