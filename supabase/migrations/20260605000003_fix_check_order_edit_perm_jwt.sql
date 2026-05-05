-- ============================================================
-- _check_order_edit_perm: 修權限判斷
--   原版讀 auth.jwt() ->> 'role'，但這欄位是 PostgREST 預設 'authenticated'
--   而不是 app 自定義 role；admin user 在這欄永遠拿到 'authenticated'
--   → 改成優先讀 app_metadata.role（與 useRole() / canSeeCost() 一致）
--   → app_metadata.role 為 NULL 時視為 HQ tier
-- ============================================================

CREATE OR REPLACE FUNCTION _check_order_edit_perm(p_order_id BIGINT)
RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_tenant UUID   := (auth.jwt() ->> 'tenant_id')::uuid;
  -- 優先 app_metadata.role；若為 NULL/空 視為 admin tier
  v_role   TEXT   := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                       NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                       ''
                     );
  v_store  BIGINT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'store_id', '')::bigint,
                       NULLIF(auth.jwt() ->> 'store_id','')::bigint
                     );
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

  -- HQ tier（含 role NULL/空字串）
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
