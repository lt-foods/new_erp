-- ============================================================================
-- 2026-07-11: rpc_merge_member — 目標(已綁 LINE)有訂單不再一律擋，只擋「真的會撞唯一索引」的情形
-- ----------------------------------------------------------------------------
-- 以哪個版本為基底：20260701030000_rpc_merge_member_move_orders_block_target.sql
-- rollback 指回　 ：20260701030000_rpc_merge_member_move_orders_block_target.sql
--   （要還原成「目標有任何訂單就擋」的版本，重跑該檔的 CREATE OR REPLACE 即可。）
--
-- 需求修正（使用者 2026-07-11，個案：M20260701073103771「tde美 715890-古華」）：
--   情境 — 客人早就綁了 LINE 並用 LINE 會員下過單；同時又有一筆「未綁 LINE 的
--   虛擬會員」也累積了訂單。要把虛擬會員併進 LINE 會員時，20260701030000 版本因為
--   「目標(LINE)已有訂單」一律擋下 → 無法合併。
--
--   但 20260701030000 之所以擋，純粹是怕把來源訂單 `UPDATE member_id = 目標` 時
--   撞到 customer_orders 的 partial UNIQUE 索引。該索引現況（20260516000000 起）是：
--     customer_orders_trio_kind_active_uniq
--       ON (tenant_id, campaign_id, channel_id, member_id, order_kind)
--       WHERE status NOT IN ('transferred_out','expired','cancelled')
--   也就是說：只有當「來源 active 訂單」與「目標 active 訂單」落在**同一個**
--   (tenant, campaign, channel, order_kind) 時，搬移才會真的撞索引。目標身上有其他
--   互不重疊的訂單，搬移完全不衝突。「目標有任何訂單就擋」因此過度保守。
--
-- 變更（相對 20260701030000）：
--   1. 移除「目標(real)有任何訂單 → RAISE」的守門。
--   2. 改為精準守門：只有當來源與目標各有一筆 active 訂單、且落在同一
--      (tenant, campaign, channel, order_kind) 時才 RAISE（這種才真的會撞唯一索引，
--      需人工先處理其中一筆）。
--   3. `UPDATE customer_orders SET member_id = p_real_id`（把來源訂單搬到目標）保留不變。
--   其餘（儲值 / 點數 / 卡片 / 標籤 / 暱稱對應 / 流水 / merged 標記 / 稽核）逐字保留。
--
-- 註：守門的 JOIN 等值語意與 partial UNIQUE 的 NULL 語意一致 —
--     campaign_id / channel_id 為 NULL 時，索引本就不強制唯一（NULL 彼此不相等），
--     JOIN 的 `=` 也不會把兩個 NULL 視為相等，兩者對「NULL 不撞」的判定相同。
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

  -- 精準守門：目標(已綁 LINE)可以有訂單；只有當「來源 active 訂單」與「目標 active
  -- 訂單」落在同一個 (tenant, campaign, channel, order_kind) 時，把來源訂單搬過去
  -- 才會撞 customer_orders_trio_kind_active_uniq。這種情形才擋（需先人工處理其一）。
  PERFORM 1
    FROM customer_orders s
    JOIN customer_orders t
      ON t.tenant_id   = s.tenant_id
     AND t.campaign_id = s.campaign_id
     AND t.channel_id  = s.channel_id
     AND t.order_kind  = s.order_kind
   WHERE s.member_id = p_guest_id
     AND t.member_id = p_real_id
     AND s.tenant_id = v_tenant
     AND s.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND t.status NOT IN ('transferred_out', 'expired', 'cancelled')
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'merge would collide: source % and target % both have an active order in the same campaign/channel, cannot merge', p_guest_id, p_real_id;
  END IF;

  -- 把來源（虛擬會員）的訂單搬到目標（LINE 會員）：已確認無同 trio+kind 的 active 撞單
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

COMMENT ON FUNCTION rpc_merge_member(BIGINT, BIGINT, UUID, TEXT) IS
  '會員合併：把未綁 LINE 的來源併入已綁 LINE 的目標，訂單一起搬。目標可有訂單；'
  '僅當來源與目標各有一筆 active 訂單且落在同一 (tenant,campaign,channel,order_kind) '
  '時才擋（會撞 customer_orders_trio_kind_active_uniq）。卡片/點數/儲值/標籤/暱稱/流水照搬。';
