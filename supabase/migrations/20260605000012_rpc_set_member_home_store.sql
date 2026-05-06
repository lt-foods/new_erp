-- ============================================================
-- 改 home_store_id 專用 RPC（給 admin 會員明細頁用）
--   守衛同 rpc_upsert_member: 仍有未取貨訂單時不允許改取貨店
--   SECURITY DEFINER 繞過 admin JWT role NULL 的 RLS 限制
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_set_member_home_store(
  p_member_id     BIGINT,
  p_home_store_id BIGINT
) RETURNS members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant      UUID := public._current_tenant_id();
  v_old_store   BIGINT;
  v_open_orders INT;
  v_row         members;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;

  IF p_home_store_id IS NOT NULL THEN
    PERFORM 1 FROM stores WHERE id = p_home_store_id AND tenant_id = v_tenant AND is_active = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant or inactive', p_home_store_id; END IF;
  END IF;

  SELECT home_store_id INTO v_old_store FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;

  IF v_old_store IS DISTINCT FROM p_home_store_id THEN
    SELECT COUNT(*) INTO v_open_orders FROM customer_orders
     WHERE tenant_id = v_tenant
       AND member_id = p_member_id
       AND status NOT IN ('completed','cancelled','expired');
    IF v_open_orders > 0 THEN
      RAISE EXCEPTION '會員仍有 % 筆未取貨訂單，請先處理完才能改取貨店', v_open_orders;
    END IF;
  END IF;

  UPDATE members
     SET home_store_id = p_home_store_id,
         updated_by    = auth.uid(),
         updated_at    = NOW()
   WHERE id = p_member_id AND tenant_id = v_tenant
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_set_member_home_store(BIGINT, BIGINT) TO authenticated;
