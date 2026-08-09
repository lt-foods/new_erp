-- ============================================================================
-- 2026-08-09: rpc_merge_member — 合併時把「搬走了哪些列」記進 member_merges.moved
-- ----------------------------------------------------------------------------
-- 以哪個版本為基底：20260714000070_rpc_merge_member_target_orders_collision_only.sql
--                  （grep 過 supabase/migrations/ 全部 8 支動過本函式的檔，那支是最新的）
-- rollback 指回　 ：20260714000070_rpc_merge_member_target_orders_collision_only.sql
--
-- 變更（相對 20260714000070）：**只有記錄，沒有任何行為改變**。
--   1. 原本 `UPDATE ... SET member_id = p_real_id` 的六張表，改成 CTE + RETURNING id，
--      把被搬走的 id 收進陣列。WHERE 條件逐字不動。
--   2. 來源會員被標成 merged 之前的 status 記進 src_status_before（復原要還原成它，
--      不能一律假設 active —— 來源可能本來是 inactive / blocked）。
--   3. INSERT INTO member_merges 多帶一個 moved 欄位。
--   其餘（來源已綁 LINE / 已合併 / 自己併自己 的守門、撞唯一索引的精準守門、
--   點數與儲值的加總與搬移、卡片計數、稽核欄位）全部逐字保留。
--
-- 為什麼要記：搬完之後那些列跟目標自己的列無法區分，沒有這份清單就無法精準復原。
-- 見 20260809000000 與 rpc_unmerge_member。
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
  -- 被搬走的列 id（供 rpc_unmerge_member 精準搬回）
  v_order_ids   BIGINT[] := '{}';
  v_alias_ids   BIGINT[] := '{}';
  v_tag_ids     BIGINT[] := '{}';
  v_card_ids    BIGINT[] := '{}';
  v_pl_ids      BIGINT[] := '{}';
  v_wl_ids      BIGINT[] := '{}';
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
  WITH upd AS (
    UPDATE customer_orders SET member_id = p_real_id
     WHERE member_id = p_guest_id AND tenant_id = v_tenant
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_order_ids FROM upd;

  WITH upd AS (
    UPDATE customer_line_aliases SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_alias_ids FROM upd;

  WITH upd AS (
    UPDATE member_tags SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_tag_ids FROM upd;

  SELECT COUNT(*) INTO v_cards FROM member_cards WHERE member_id = p_guest_id;
  v_cards := COALESCE(v_cards, 0);
  WITH upd AS (
    UPDATE member_cards SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_card_ids FROM upd;

  SELECT COALESCE(balance, 0) INTO v_points
    FROM member_points_balance WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_points := COALESCE(v_points, 0);

  SELECT COALESCE(balance, 0) INTO v_wallet
    FROM wallet_balances       WHERE tenant_id = v_tenant AND member_id = p_guest_id;
  v_wallet := COALESCE(v_wallet, 0);

  WITH upd AS (
    UPDATE points_ledger SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_pl_ids FROM upd;

  WITH upd AS (
    UPDATE wallet_ledger SET member_id = p_real_id
     WHERE member_id = p_guest_id
    RETURNING id
  ) SELECT COALESCE(array_agg(id), '{}') INTO v_wl_ids FROM upd;

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
    points_moved, wallet_moved, cards_moved, reason, operator_id, moved
  ) VALUES (
    v_tenant, p_real_id, p_guest_id,
    v_points, v_wallet, v_cards, p_reason, v_operator,
    jsonb_build_object(
      'v', 1,
      'source', 'recorded',
      'src_status_before', v_src_status,
      'order_ids',         to_jsonb(v_order_ids),
      'alias_ids',         to_jsonb(v_alias_ids),
      'tag_ids',           to_jsonb(v_tag_ids),
      'card_ids',          to_jsonb(v_card_ids),
      'points_ledger_ids', to_jsonb(v_pl_ids),
      'wallet_ledger_ids', to_jsonb(v_wl_ids)
    )
  );
END;
$$;

COMMENT ON FUNCTION rpc_merge_member(BIGINT, BIGINT, UUID, TEXT) IS
  '會員合併：把未綁 LINE 的來源併入已綁 LINE 的目標，訂單一起搬。目標可有訂單；'
  '僅當來源與目標各有一筆 active 訂單且落在同一 (tenant,campaign,channel,order_kind) '
  '時才擋（會撞 customer_orders_trio_kind_active_uniq）。卡片/點數/儲值/標籤/暱稱/流水照搬，'
  '並把被搬走的列 id 記進 member_merges.moved 供 rpc_unmerge_member 精準復原。';
