-- ============================================================================
-- 2026-05-18: rpc_merge_member — 來源(虛擬/未綁 LINE)會員有訂單則禁止合併
-- ----------------------------------------------------------------------------
-- 決策（使用者 2026-05-18）：合併只在「來源會員身上沒有任何 customer_orders」
-- 時才允許。訂單個別是個別的、永遠不搬移（避免搬 member_id 撞同團同頻道
-- 唯一索引、避免破壞訂單歷史）。儲值金 / 點數 / 卡片 / 標籤 / 暱稱對應 /
-- 流水等「其他」資料照舊 merge 搬到正式會員。
--
-- 變更（相對 20260507130000）：
--   1. 新增守門：guest 有任何 customer_orders → RAISE，整個合併中止。
--   2. 移除原本的 `UPDATE customer_orders SET member_id = p_real_id ...`
--      （守門後此句必為 0 列、且與「訂單不搬」原則矛盾）。
--   其餘邏輯逐字保留。
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_merge_member(
  p_guest_id BIGINT,
  p_real_id  BIGINT,
  p_operator UUID DEFAULT NULL,
  p_reason   TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant      UUID;
  v_operator    UUID;
  v_points      NUMERIC(18,2) := 0;
  v_wallet      NUMERIC(18,2) := 0;
  v_cards       INTEGER       := 0;
  v_src_line    TEXT;
  v_src_status  TEXT;
BEGIN
  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT tenant_id, line_user_id, status
    INTO v_tenant, v_src_line, v_src_status
    FROM members WHERE id = p_guest_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'source member % not found', p_guest_id;
  END IF;

  IF v_src_line IS NOT NULL THEN
    RAISE EXCEPTION 'source member % is already bound to LINE — pick the unbound one as source', p_guest_id;
  END IF;

  IF v_src_status = 'merged' THEN
    RAISE EXCEPTION 'source member % is already merged', p_guest_id;
  END IF;

  IF p_guest_id = p_real_id THEN
    RAISE EXCEPTION 'source and target must differ';
  END IF;

  -- 守門：來源會員有任何訂單就禁止合併（訂單個別是個別的、不搬移）
  PERFORM 1 FROM customer_orders
    WHERE member_id = p_guest_id AND tenant_id = v_tenant
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'source member % has orders, cannot merge', p_guest_id;
  END IF;

  -- 訂單不搬移（刻意：留在原會員）；以下「其他」資料照舊 merge
  UPDATE customer_line_aliases  SET member_id = p_real_id WHERE member_id = p_guest_id;
  UPDATE member_tags            SET member_id = p_real_id WHERE member_id = p_guest_id;

  SELECT COUNT(*) INTO v_cards FROM member_cards WHERE member_id = p_guest_id;
  v_cards := COALESCE(v_cards, 0);
  UPDATE member_cards SET member_id = p_real_id WHERE member_id = p_guest_id;

  SELECT COALESCE(balance, 0) INTO v_points
    FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_points := COALESCE(v_points, 0);

  SELECT COALESCE(balance, 0) INTO v_wallet
    FROM wallet_balances       WHERE tenant_id = v_tenant AND member_id = p_guest_id;
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

COMMENT ON FUNCTION rpc_merge_member(BIGINT, BIGINT, UUID, TEXT) IS
  '會員合併：來源(未綁 LINE)有任何 customer_orders 即禁止；訂單不搬（個別是個別的），其餘卡片/點數/儲值/標籤/暱稱/流水照搬至正式會員。';
