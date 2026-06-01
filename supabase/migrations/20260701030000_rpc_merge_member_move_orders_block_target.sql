-- ============================================================================
-- 2026-07-01: rpc_merge_member — 搬訂單版（虛擬會員可有訂單、LINE 會員不可有）
-- ----------------------------------------------------------------------------
-- 以哪個版本為基底：20260618000030_rpc_merge_member_block_if_guest_has_orders.sql
-- rollback 指回　 ：20260618000030_rpc_merge_member_block_if_guest_has_orders.sql
--   （要還原成「來源有訂單就擋、訂單不搬」的版本，重跑該檔的 CREATE OR REPLACE 即可。）
--
-- 需求修正（使用者 2026-07-01）：
--   情境 — 客人原本都用「虛擬會員（未綁 LINE）」加單；某天來門市取貨時才註冊 App、
--   綁定 LINE，於是把虛擬會員「合併進」這個 LINE 會員。
--   因此規則改為：
--     * 來源（虛擬 / 未綁 LINE）：可以有訂單 → 訂單一起搬到 LINE 會員。
--     * 目標（已綁 LINE）       ：剛註冊、身上不該有訂單 → 若已有訂單則擋下。
--       （一方面符合情境；一方面確保把 customer_orders.member_id 搬過去時，
--        不會撞 UNIQUE(tenant_id, campaign_id, channel_id, member_id)。因為目標
--        無任何訂單，搬移必不衝突。）
--
-- 變更（相對 20260618000030）：
--   1. 移除「來源(guest)有訂單 → RAISE」守門。
--   2. 新增「目標(real)有訂單  → RAISE」守門。
--   3. 加回 `UPDATE customer_orders SET member_id = p_real_id ...`（把訂單搬到目標）。
--   其餘（儲值 / 點數 / 卡片 / 標籤 / 暱稱對應 / 流水 / merged 標記 / 稽核）逐字保留。
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

  -- 守門：目標（已綁 LINE）會員不可有任何訂單。
  -- 情境上 LINE 會員是剛註冊、身上沒單；技術上也確保把來源訂單搬過去時，
  -- 不會撞 customer_orders 的 UNIQUE(tenant_id, campaign_id, channel_id, member_id)。
  PERFORM 1 FROM customer_orders
    WHERE member_id = p_real_id AND tenant_id = v_tenant
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'target member % already has orders, cannot merge', p_real_id;
  END IF;

  -- 把來源（虛擬會員）的訂單搬到目標（LINE 會員）：目標保證無單，不會撞唯一索引
  UPDATE customer_orders        SET member_id = p_real_id WHERE member_id = p_guest_id AND tenant_id = v_tenant;
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
