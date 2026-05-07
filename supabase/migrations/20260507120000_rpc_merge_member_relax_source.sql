-- ============================================================================
-- rpc_merge_member: 放寬 source（被合併方）守衛
-- 原本：source 必須 member_type='guest'（LLM 從 LINE 留言解析的訪客）
-- 新：source 只要「未綁 LINE 的會員」即可（包含 guest + 從未綁 LINE 的 full）
--
-- 動機：實務上有大量舊會員 (member_type='full', line_user_id IS NULL) 後來綁了 LINE 後
--       建了第二筆會員資料，需要把舊那筆併進新的（已綁 LINE）那筆。
--
-- target（合併目標）守衛維持：必須非 merged、必須跟 source 不同 ID。
-- 不強制 target.line_user_id IS NOT NULL，因為偶爾兩個都還沒綁但要併重複建檔。
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
  v_points      NUMERIC(18,2);
  v_wallet      NUMERIC(18,2);
  v_cards       INTEGER;
  v_src_line    TEXT;
  v_src_status  TEXT;
BEGIN
  v_operator := COALESCE(p_operator, auth.uid());

  SELECT tenant_id, line_user_id, status
    INTO v_tenant, v_src_line, v_src_status
    FROM members WHERE id = p_guest_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'source member % not found', p_guest_id;
  END IF;

  -- 守衛：source 必須未綁 LINE（避免把已綁 LINE 的會員當被合併方）
  IF v_src_line IS NOT NULL THEN
    RAISE EXCEPTION 'source member % is already bound to LINE — pick the unbound one as source', p_guest_id;
  END IF;

  IF v_src_status = 'merged' THEN
    RAISE EXCEPTION 'source member % is already merged', p_guest_id;
  END IF;

  IF p_guest_id = p_real_id THEN
    RAISE EXCEPTION 'source and target must differ';
  END IF;

  -- 搬訂單
  UPDATE customer_orders SET member_id = p_real_id WHERE member_id = p_guest_id;

  -- 搬 LINE 暱稱對應
  UPDATE customer_line_aliases SET member_id = p_real_id WHERE member_id = p_guest_id;

  -- 搬標籤
  UPDATE member_tags SET member_id = p_real_id WHERE member_id = p_guest_id;

  -- 搬會員卡
  SELECT COUNT(*) INTO v_cards FROM member_cards WHERE member_id = p_guest_id;
  UPDATE member_cards SET member_id = p_real_id WHERE member_id = p_guest_id;

  -- 取得 source 點數 / 儲值金餘額
  SELECT COALESCE(balance, 0) INTO v_points
    FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  SELECT COALESCE(balance, 0) INTO v_wallet
    FROM wallet_balances       WHERE tenant_id = v_tenant AND member_id = p_guest_id;

  -- 搬流水帳
  UPDATE points_ledger  SET member_id = p_real_id WHERE member_id = p_guest_id;
  UPDATE wallet_ledger  SET member_id = p_real_id WHERE member_id = p_guest_id;

  -- 合併餘額（UPSERT）
  INSERT INTO member_points_balance (tenant_id, member_id, balance, version, updated_at)
  VALUES (v_tenant, p_real_id, GREATEST(v_points, 0), 1, NOW())
  ON CONFLICT (tenant_id, member_id) DO UPDATE
    SET balance          = member_points_balance.balance + GREATEST(EXCLUDED.balance, 0),
        version          = member_points_balance.version + 1,
        last_movement_at = NOW(),
        updated_at       = NOW();

  INSERT INTO wallet_balances (tenant_id, member_id, balance, version, updated_at)
  VALUES (v_tenant, p_real_id, GREATEST(v_wallet, 0), 1, NOW())
  ON CONFLICT (tenant_id, member_id) DO UPDATE
    SET balance          = wallet_balances.balance + GREATEST(EXCLUDED.balance, 0),
        version          = wallet_balances.version + 1,
        last_movement_at = NOW(),
        updated_at       = NOW();

  DELETE FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  DELETE FROM wallet_balances        WHERE tenant_id = v_tenant AND member_id = p_guest_id;

  -- 標記 source 為 merged
  UPDATE members
     SET status                = 'merged',
         merged_into_member_id = p_real_id,
         updated_at            = NOW(),
         updated_by            = v_operator
   WHERE id = p_guest_id;

  -- 寫合併紀錄
  INSERT INTO member_merges (
    tenant_id, primary_member_id, merged_member_id,
    points_moved, wallet_moved, cards_moved, reason, operator_id
  ) VALUES (
    v_tenant, p_real_id, p_guest_id,
    v_points, v_wallet, v_cards, p_reason, v_operator
  );
END;
$$;
