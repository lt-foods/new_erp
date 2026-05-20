-- ============================================================
-- rpc_set_member_flags：權限放寬到店長
--
-- 既有 gate：owner / admin / hq_manager / hq_accountant / ''（HQ tier）
-- 使用者要求（2026-05-20）：店長也應該能設黑名單 / admin_note，
-- 不然第一線遇到狀況沒辦法即時擋。
--
-- 加 store_manager 進允許名單。store_staff 暫不開放（先看店長使用情形）。
--
-- 其餘 RPC 簽名 / 行為 / RETURNING 完全不變。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_set_member_flags(
  p_member_id        BIGINT,
  p_no_notify_pickup BOOLEAN,
  p_no_new_order     BOOLEAN,
  p_admin_note       TEXT,
  p_operator         UUID DEFAULT NULL
) RETURNS members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role     TEXT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                       NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                       ''
                     );
  v_operator UUID := COALESCE(p_operator, auth.uid());
  v_row      members;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','store_manager','') THEN
    RAISE EXCEPTION 'permission denied: only HQ tier or store_manager can edit member flags';
  END IF;

  UPDATE members
     SET no_notify_pickup = p_no_notify_pickup,
         no_new_order     = p_no_new_order,
         admin_note       = NULLIF(TRIM(COALESCE(p_admin_note, '')), ''),
         updated_by       = v_operator,
         updated_at       = NOW()
   WHERE id = p_member_id AND tenant_id = v_tenant
   RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'member % not found in tenant %', p_member_id, v_tenant;
  END IF;
  RETURN v_row;
END;
$$;
