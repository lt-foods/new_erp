-- ============================================================
-- Wallet phase A: 寫入操作 RPCs (refund / adjust / reverse)
--   + 一致性檢查工具
-- 沿用 rpc_wallet_topup / rpc_wallet_spend 既有鎖定模式
-- (參考 20260422120002_member_schema.sql:472-550)
-- ============================================================

-- 儲值金退款 (type='refund', change=+amount)
CREATE OR REPLACE FUNCTION rpc_wallet_refund(
  p_tenant_id    UUID,
  p_member_id    BIGINT,
  p_amount       NUMERIC,
  p_source_type  TEXT,
  p_source_id    BIGINT,
  p_reason       TEXT,
  p_operator     UUID
) RETURNS BIGINT AS $$
DECLARE
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
  v_member_status TEXT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Refund amount must be positive';
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
    RAISE EXCEPTION 'member status=% cannot receive refund', v_member_status;
  END IF;

  INSERT INTO wallet_balances (tenant_id, member_id)
  VALUES (p_tenant_id, p_member_id) ON CONFLICT DO NOTHING;

  SELECT balance INTO v_cur_balance FROM wallet_balances
  WHERE tenant_id = p_tenant_id AND member_id = p_member_id FOR UPDATE;

  v_new_balance := v_cur_balance + p_amount;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after,
                             type, source_type, source_id, reason, operator_id)
  VALUES (p_tenant_id, p_member_id, p_amount, v_new_balance,
          'refund', p_source_type, p_source_id, p_reason, p_operator)
  RETURNING id INTO v_id;

  UPDATE wallet_balances
     SET balance = v_new_balance, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = p_member_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 儲值金調整 (客訴/補償/修正；signed change；role gate)
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
  v_role TEXT := COALESCE(auth.jwt() ->> 'role', '');
  v_member_status TEXT;
BEGIN
  -- Role gate: BRANCH_ROLES from apps/admin/src/lib/role.ts
  --   '' (admin role NULL legacy) / owner / admin / hq_manager / hq_accountant / store_manager
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

  -- 高層 audit (低頻動作多寫一條無妨)
  INSERT INTO member_audit_log (tenant_id, entity_type, entity_id, action,
                                before_value, after_value, reason, operator_id)
  VALUES (p_tenant_id, 'wallet', p_member_id, 'adjust',
          jsonb_build_object('balance', v_cur_balance),
          jsonb_build_object('balance', v_new_balance, 'change', p_change),
          p_reason, p_operator);

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 反向某筆 ledger (新增 type='reversal' row；原 row 不更新，append-only)
CREATE OR REPLACE FUNCTION rpc_wallet_reverse(
  p_tenant_id  UUID,
  p_ledger_id  BIGINT,
  p_reason     TEXT,
  p_operator   UUID
) RETURNS BIGINT AS $$
DECLARE
  v_orig wallet_ledger;
  v_cur_balance NUMERIC;
  v_new_balance NUMERIC;
  v_id BIGINT;
  v_already_reversed BOOLEAN;
BEGIN
  IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) < 4 THEN
    RAISE EXCEPTION 'reason required (>=4 chars)';
  END IF;

  -- 鎖原 ledger row (FOR UPDATE 只是 row-lock，不觸發 UPDATE trigger)
  SELECT * INTO v_orig FROM wallet_ledger
   WHERE id = p_ledger_id AND tenant_id = p_tenant_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'ledger % not found', p_ledger_id;
  END IF;

  -- 拒絕反向 reversal
  IF v_orig.type = 'reversal' THEN
    RAISE EXCEPTION 'cannot reverse a reversal (id=%)', p_ledger_id;
  END IF;

  -- 拒絕重複反向 (用 reverses 反查；不寫 reversed_by 避開 append-only trigger)
  SELECT EXISTS(
    SELECT 1 FROM wallet_ledger
     WHERE tenant_id = p_tenant_id AND reverses = p_ledger_id
  ) INTO v_already_reversed;
  IF v_already_reversed THEN
    RAISE EXCEPTION 'ledger % already reversed', p_ledger_id;
  END IF;

  -- 鎖餘額 row
  SELECT balance INTO v_cur_balance FROM wallet_balances
  WHERE tenant_id = p_tenant_id AND member_id = v_orig.member_id FOR UPDATE;
  IF v_cur_balance IS NULL THEN
    RAISE EXCEPTION 'wallet_balances row missing for member %', v_orig.member_id;
  END IF;

  v_new_balance := v_cur_balance - v_orig.change;
  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'reverse would make balance negative: current=%, undoing=%',
      v_cur_balance, v_orig.change;
  END IF;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after,
                             type, source_type, source_id, reverses,
                             reason, operator_id)
  VALUES (p_tenant_id, v_orig.member_id, -v_orig.change, v_new_balance,
          'reversal', v_orig.source_type, v_orig.source_id, p_ledger_id,
          p_reason, p_operator)
  RETURNING id INTO v_id;

  UPDATE wallet_balances
     SET balance = v_new_balance, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = p_tenant_id AND member_id = v_orig.member_id;

  INSERT INTO member_audit_log (tenant_id, entity_type, entity_id, action,
                                before_value, after_value, reason, operator_id)
  VALUES (p_tenant_id, 'wallet', v_orig.member_id, 'reverse',
          jsonb_build_object('balance', v_cur_balance,
                             'reversing_ledger_id', p_ledger_id,
                             'reversing_type', v_orig.type,
                             'reversing_change', v_orig.change),
          jsonb_build_object('balance', v_new_balance,
                             'new_ledger_id', v_id),
          p_reason, p_operator);

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ops 工具：找 ledger 累加 ≠ balance 的 member
CREATE OR REPLACE FUNCTION fn_check_wallet_consistency()
RETURNS TABLE(tenant_id UUID, member_id BIGINT,
              balance NUMERIC, ledger_sum NUMERIC, diff NUMERIC) AS $$
  SELECT wb.tenant_id, wb.member_id,
         wb.balance,
         COALESCE(SUM(wl.change), 0) AS ledger_sum,
         wb.balance - COALESCE(SUM(wl.change), 0) AS diff
    FROM wallet_balances wb
    LEFT JOIN wallet_ledger wl USING (tenant_id, member_id)
   GROUP BY wb.tenant_id, wb.member_id, wb.balance
  HAVING wb.balance <> COALESCE(SUM(wl.change), 0);
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION rpc_wallet_refund(UUID, BIGINT, NUMERIC, TEXT, BIGINT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_wallet_adjust(UUID, BIGINT, NUMERIC, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_wallet_reverse(UUID, BIGINT, TEXT, UUID) TO authenticated;
-- fn_check_wallet_consistency 不對 authenticated grant；只給 ops 用 service_role 跑

COMMENT ON FUNCTION rpc_wallet_refund(UUID, BIGINT, NUMERIC, TEXT, BIGINT, TEXT, UUID)
  IS '儲值金退款 (type=refund, change=+amount); reason 必填';
COMMENT ON FUNCTION rpc_wallet_adjust(UUID, BIGINT, NUMERIC, TEXT, UUID)
  IS '儲值金調整 (客訴補償/修正; signed change; role gate: owner/store_manager/HQ)';
COMMENT ON FUNCTION rpc_wallet_reverse(UUID, BIGINT, TEXT, UUID)
  IS '反向某筆 ledger (type=reversal; 不更新原 row; reverses 指針)';
COMMENT ON FUNCTION fn_check_wallet_consistency()
  IS 'ops 工具：找 ledger 累加 ≠ balance 的 member';
