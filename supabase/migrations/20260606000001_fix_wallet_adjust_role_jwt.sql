-- ============================================================
-- rpc_wallet_adjust: 修 role 讀取 (對齊 20260605000003 fix pattern)
--   原版讀 auth.jwt() ->> 'role'，但這欄位是 PostgREST 預設 'authenticated'
--   而非 app 自定義 role；admin user 在這欄永遠拿到 'authenticated'，被誤擋
--   → 改成優先讀 app_metadata.role（與 useRole() / canAdjustWallet() 一致）
--   → app_metadata.role 為 NULL/空 視為 HQ tier
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_wallet_adjust(
  p_tenant_id  UUID,
  p_member_id  BIGINT,
  p_change     NUMERIC,
  p_reason     TEXT,
  p_operator   UUID
) RETURNS BIGINT AS $$
DECLARE
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
  v_role TEXT := COALESCE(
                   NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                   NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                   ''
                 );
  v_member_status TEXT;
BEGIN
  -- Role gate: BRANCH_ROLES from apps/admin/src/lib/role.ts
  --   '' (HQ admin / 無自定 role) / owner / admin / hq_manager / hq_accountant / store_manager
  -- 排除：assistant / store_staff (低權限店員)
  IF v_role NOT IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant', 'store_manager') THEN
    RAISE EXCEPTION 'permission denied for wallet adjust (role=%)', v_role;
  END IF;

  IF p_change IS NULL OR p_change = 0 THEN
    RAISE EXCEPTION 'adjust change must be non-zero';
  END IF;
  IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) < 4 THEN
    RAISE EXCEPTION 'reason required (>=4 chars)';
  END IF;

  SELECT status INTO v_member_status FROM members
   WHERE id = p_member_id AND tenant_id = p_tenant_id;
  IF v_member_status IS NULL THEN
    RAISE EXCEPTION 'member % not found', p_member_id;
  END IF;
  IF v_member_status <> 'active' THEN
    RAISE EXCEPTION 'member status=% cannot adjust', v_member_status;
  END IF;

  INSERT INTO wallet_balances (tenant_id, member_id)
  VALUES (p_tenant_id, p_member_id) ON CONFLICT DO NOTHING;

  SELECT balance INTO v_cur_balance FROM wallet_balances
  WHERE tenant_id = p_tenant_id AND member_id = p_member_id FOR UPDATE;

  v_new_balance := v_cur_balance + p_change;
  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'adjust would make balance negative: current=%, change=%',
      v_cur_balance, p_change;
  END IF;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after,
                             type, reason, operator_id)
  VALUES (p_tenant_id, p_member_id, p_change, v_new_balance,
          'adjust', p_reason, p_operator)
  RETURNING id INTO v_id;

  UPDATE wallet_balances
     SET balance = v_new_balance, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = p_member_id;

  INSERT INTO member_audit_log (tenant_id, entity_type, entity_id, action,
                                before_value, after_value, reason, operator_id)
  VALUES (p_tenant_id, 'wallet', p_member_id, 'adjust',
          jsonb_build_object('balance', v_cur_balance),
          jsonb_build_object('balance', v_new_balance, 'change', p_change),
          p_reason, p_operator);

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_wallet_adjust(UUID, BIGINT, NUMERIC, TEXT, UUID) TO authenticated;
