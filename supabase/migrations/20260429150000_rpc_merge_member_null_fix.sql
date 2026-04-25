-- ============================================================================
-- Fix: rpc_merge_member 在 guest 沒有 balance 列時 v_points/v_wallet 留 NULL
-- 違反 member_merges.points_moved/wallet_moved/cards_moved NOT NULL
-- ============================================================================
CREATE OR REPLACE FUNCTION rpc_merge_member(
  p_guest_id BIGINT,
  p_real_id  BIGINT,
  p_operator UUID DEFAULT NULL,
  p_reason   TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant    UUID;
  v_operator  UUID;
  v_points    NUMERIC(18,2) := 0;
  v_wallet    NUMERIC(18,2) := 0;
  v_cards     INTEGER := 0;
BEGIN
  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT tenant_id INTO v_tenant FROM members WHERE id = p_guest_id;

  IF (SELECT member_type FROM members WHERE id = p_guest_id) <> 'guest' THEN
    RAISE EXCEPTION 'member % is not a guest', p_guest_id;
  END IF;
  IF (SELECT status FROM members WHERE id = p_guest_id) = 'merged' THEN
    RAISE EXCEPTION 'member % is already merged', p_guest_id;
  END IF;
  IF p_guest_id = p_real_id THEN
    RAISE EXCEPTION 'guest_id and real_id must differ';
  END IF;

  UPDATE customer_orders         SET member_id = p_real_id WHERE member_id = p_guest_id;
  UPDATE customer_line_aliases   SET member_id = p_real_id WHERE member_id = p_guest_id;
  UPDATE member_tags             SET member_id = p_real_id WHERE member_id = p_guest_id;

  SELECT COUNT(*) INTO v_cards FROM member_cards WHERE member_id = p_guest_id;
  UPDATE member_cards SET member_id = p_real_id WHERE member_id = p_guest_id;

  SELECT COALESCE(balance, 0) INTO v_points
    FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_points := COALESCE(v_points, 0);

  SELECT COALESCE(balance, 0) INTO v_wallet
    FROM wallet_balances WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_wallet := COALESCE(v_wallet, 0);

  UPDATE points_ledger  SET member_id = p_real_id WHERE member_id = p_guest_id;
  UPDATE wallet_ledger  SET member_id = p_real_id WHERE member_id = p_guest_id;

  IF v_points > 0 THEN
    INSERT INTO member_points_balance (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, p_real_id, v_points, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance          = member_points_balance.balance + EXCLUDED.balance,
          version          = member_points_balance.version + 1,
          last_movement_at = NOW(),
          updated_at       = NOW();
  END IF;

  IF v_wallet > 0 THEN
    INSERT INTO wallet_balances (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, p_real_id, v_wallet, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance          = wallet_balances.balance + EXCLUDED.balance,
          version          = wallet_balances.version + 1,
          last_movement_at = NOW(),
          updated_at       = NOW();
  END IF;

  DELETE FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  DELETE FROM wallet_balances        WHERE tenant_id = v_tenant AND member_id = p_guest_id;

  UPDATE members
     SET status                = 'merged',
         merged_into_member_id = p_real_id,
         updated_at            = NOW(),
         updated_by            = v_operator
   WHERE id = p_guest_id;

  INSERT INTO member_merges (
    tenant_id, primary_member_id, merged_member_id,
    points_moved, wallet_moved, cards_moved, reason, operator_id
  ) VALUES (
    v_tenant, p_real_id, p_guest_id,
    v_points, v_wallet, v_cards, p_reason, v_operator
  );
END;
$$;
