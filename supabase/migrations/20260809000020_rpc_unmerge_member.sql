-- ============================================================================
-- 2026-08-09: rpc_unmerge_member —— 合併綁錯人可以復原
--
-- 合併是店員在「疑似同一人」的兩筆會員之間用眼睛判斷的，併錯的代價很重：來源會員
-- 整個消失（status='merged'）、他的訂單全部掛到別人名下。以前唯一的救法是找工程師
-- 手動改 DB，所以這條路一定要留在後台。
--
-- ── 兩種復原依據 ──────────────────────────────────────────────────────────
--
-- A. moved 有值（20260809000010 之後做的合併）：精準復原。
--    合併當下記下了每張表被搬走的 id，原封不動搬回去，不多不少。
--
-- B. moved 是 NULL（本功能上線前的 816 筆舊紀錄）：靠時間戳推回，且**條件收緊**。
--    customer_orders 有 BEFORE UPDATE 的 touch_updated_at trigger，而 NOW() 在同一
--    交易內是固定值 —— 所以被那次合併搬走的訂單，updated_at 會**精確等於**
--    member_merges.created_at（微秒級）。別的交易不可能剛好落在同一個微秒，
--    所以不會誤抓目標自己的訂單（無偽陽性）。
--    但反過來會漏：搬過去之後又被改過狀態（取貨、取消…）的訂單，updated_at 已被
--    覆蓋，推不回來（偽陰性）。所以 B 路徑：
--      - 只在 points_moved / wallet_moved / cards_moved 全為 0 時允許
--        （線上 816 筆裡 815 筆符合；ledger 沒有 updated_at，動到錢的那筆推不了，
--         寧可擋下讓人工處理，也不要把錢還錯位置）
--      - 回傳 reconstructed=true 與 orders_left_behind，讓 UI 明講「可能有漏，
--        請自己核對」，而不是假裝復原得很乾淨
--
-- ── 不做的事 ──────────────────────────────────────────────────────────────
-- 不刪 member_merges 那一列：改標 reverted_at/by/reason，稽核要看得到「併過又復原」。
-- 前端清單要自己加 `reverted_at IS NULL`。
--
-- 依賴：20260809000000（moved / reverted_* 欄位）、20260809000010（寫 moved 的合併）
-- Rollback：DROP FUNCTION public.rpc_unmerge_member(BIGINT, UUID, TEXT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_unmerge_member(
  p_merge_id BIGINT,
  p_operator UUID DEFAULT NULL,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  -- ⚠ 應用角色走 app_metadata（見 CLAUDE.md / 20260807000040）
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_operator   UUID;
  v_mm         member_merges%ROWTYPE;
  v_guest      BIGINT;
  v_real       BIGINT;
  v_moved      JSONB;
  v_recon      BOOLEAN := FALSE;
  v_status_to  TEXT;
  v_order_ids  BIGINT[] := '{}';
  v_alias_ids  BIGINT[] := '{}';
  v_tag_ids    BIGINT[] := '{}';
  v_card_ids   BIGINT[] := '{}';
  v_pl_ids     BIGINT[] := '{}';
  v_wl_ids     BIGINT[] := '{}';
  v_n_orders   INT := 0;
  v_n_alias    INT := 0;
  v_n_tags     INT := 0;
  v_n_cards    INT := 0;
  v_n_pl       INT := 0;
  v_n_wl       INT := 0;
  v_left       INT := 0;
  v_src_status TEXT;
  v_src_merged BIGINT;
  v_bal        NUMERIC(18,2);
BEGIN
  -- 復原比合併危險（會把錢與訂單搬回去），限管理員層級。
  -- '' = 沒有顯式 role 的 legacy/dev admin，對齊 apps/admin/src/lib/role.ts 的 isAdmin。
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT * INTO v_mm FROM member_merges
   WHERE id = p_merge_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'merge_not_found: 找不到這筆合併紀錄';
  END IF;
  IF v_mm.reverted_at IS NOT NULL THEN
    RAISE EXCEPTION 'merge_already_reverted: 這筆合併已經復原過了';
  END IF;

  v_guest := v_mm.merged_member_id;
  v_real  := v_mm.primary_member_id;

  -- 來源會員必須還停在「被這次合併併掉」的狀態。之後被 GDPR 刪除、或被再併去
  -- 別人身上的話，硬搬回來只會製造更難救的狀態 —— 擋下來讓人工處理。
  SELECT status, merged_into_member_id INTO v_src_status, v_src_merged
    FROM members WHERE id = v_guest AND tenant_id = v_tenant
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'merge_state_changed: 來源會員已不存在，無法復原';
  END IF;
  IF v_src_status <> 'merged' OR v_src_merged IS DISTINCT FROM v_real THEN
    RAISE EXCEPTION 'merge_state_changed: 來源會員目前的狀態不是「被併入此會員」（可能已被刪除或再次合併），無法自動復原';
  END IF;

  v_moved := v_mm.moved;

  IF v_moved ? 'order_ids' THEN
    -- A：合併當下記下來的精準清單
    v_status_to := COALESCE(v_moved ->> 'src_status_before', 'active');
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_order_ids FROM jsonb_array_elements_text(v_moved -> 'order_ids') x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_alias_ids FROM jsonb_array_elements_text(COALESCE(v_moved -> 'alias_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_tag_ids   FROM jsonb_array_elements_text(COALESCE(v_moved -> 'tag_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_card_ids  FROM jsonb_array_elements_text(COALESCE(v_moved -> 'card_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_pl_ids    FROM jsonb_array_elements_text(COALESCE(v_moved -> 'points_ledger_ids', '[]'::jsonb)) x;
    SELECT COALESCE(array_agg(x::BIGINT), '{}') INTO v_wl_ids    FROM jsonb_array_elements_text(COALESCE(v_moved -> 'wallet_ledger_ids', '[]'::jsonb)) x;
  ELSE
    -- B：舊紀錄，靠 updated_at 時間戳推回（理由見檔頭）
    IF v_mm.points_moved <> 0 OR v_mm.wallet_moved <> 0 OR v_mm.cards_moved <> 0 THEN
      RAISE EXCEPTION 'unmerge_needs_manual: 這筆合併在記錄功能上線前完成，且動到了點數／儲值／卡片，無法安全地自動復原，請聯絡工程師處理';
    END IF;
    v_recon     := TRUE;
    v_status_to := 'active';
    SELECT COALESCE(array_agg(id), '{}') INTO v_order_ids
      FROM customer_orders
     WHERE tenant_id = v_tenant AND member_id = v_real AND updated_at = v_mm.created_at;
    SELECT COALESCE(array_agg(id), '{}') INTO v_alias_ids
      FROM customer_line_aliases
     WHERE member_id = v_real AND updated_at = v_mm.created_at;
  END IF;

  -- 搬回去之前先確認不會撞唯一索引：來源會員身上若已經有同 (campaign, channel, kind)
  -- 的 active 訂單（合併後又補單之類），硬搬會炸在 customer_orders_trio_kind_active_uniq。
  --
  -- ⚠ campaign_id / channel_id 用 `=` 而不是 IS NOT DISTINCT FROM：btree unique 視
  --   NULL 彼此為相異、本來就不強制唯一，用 IS NOT DISTINCT FROM 會把兩筆 NULL 當成
  --   撞到而擋掉根本不會撞的復原。這跟 rpc_merge_member 的守門是同一套語意。
  PERFORM 1
    FROM customer_orders s
    JOIN customer_orders t
      ON t.tenant_id   = s.tenant_id
     AND t.campaign_id = s.campaign_id
     AND t.channel_id  = s.channel_id
     AND t.order_kind  = s.order_kind
   WHERE s.id = ANY(v_order_ids)
     AND t.member_id = v_guest
     AND t.tenant_id = v_tenant
     AND s.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND t.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND s.order_kind <> 'restock'
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'unmerge_would_collide: 來源會員身上已有同一團同通路的有效訂單，搬回去會撞單，請先人工處理';
  END IF;

  -- ── 搬回來源 ─────────────────────────────────────────────────────────────
  UPDATE customer_orders       SET member_id = v_guest WHERE id = ANY(v_order_ids) AND tenant_id = v_tenant AND member_id = v_real;
  GET DIAGNOSTICS v_n_orders = ROW_COUNT;
  UPDATE customer_line_aliases SET member_id = v_guest WHERE id = ANY(v_alias_ids) AND member_id = v_real;
  GET DIAGNOSTICS v_n_alias = ROW_COUNT;
  UPDATE member_tags           SET member_id = v_guest WHERE id = ANY(v_tag_ids)   AND member_id = v_real;
  GET DIAGNOSTICS v_n_tags = ROW_COUNT;
  UPDATE member_cards          SET member_id = v_guest WHERE id = ANY(v_card_ids)  AND member_id = v_real;
  GET DIAGNOSTICS v_n_cards = ROW_COUNT;
  UPDATE points_ledger         SET member_id = v_guest WHERE id = ANY(v_pl_ids)    AND member_id = v_real;
  GET DIAGNOSTICS v_n_pl = ROW_COUNT;
  UPDATE wallet_ledger         SET member_id = v_guest WHERE id = ANY(v_wl_ids)    AND member_id = v_real;
  GET DIAGNOSTICS v_n_wl = ROW_COUNT;

  -- ── 餘額搬回來源 ─────────────────────────────────────────────────────────
  -- 合併是「加進目標」，復原就「從目標扣掉同一筆金額、還給來源」。目標的餘額在合併
  -- 之後可能又被動過，扣下去會變負數的話擋掉 —— 餘額是錢，寧可要求人工處理。
  IF v_mm.points_moved > 0 THEN
    SELECT COALESCE(balance, 0) INTO v_bal FROM member_points_balance
     WHERE tenant_id = v_tenant AND member_id = v_real FOR UPDATE;
    IF COALESCE(v_bal, 0) < v_mm.points_moved THEN
      RAISE EXCEPTION 'unmerge_balance_insufficient: 目標會員目前點數 % 少於當初併入的 %，扣回去會變負數，請先人工調整',
        COALESCE(v_bal, 0), v_mm.points_moved;
    END IF;
    UPDATE member_points_balance
       SET balance = balance - v_mm.points_moved, version = version + 1, updated_at = NOW()
     WHERE tenant_id = v_tenant AND member_id = v_real;
    INSERT INTO member_points_balance (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, v_guest, v_mm.points_moved, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance    = member_points_balance.balance + EXCLUDED.balance,
          version    = member_points_balance.version + 1,
          updated_at = NOW();
  END IF;

  IF v_mm.wallet_moved > 0 THEN
    SELECT COALESCE(balance, 0) INTO v_bal FROM wallet_balances
     WHERE tenant_id = v_tenant AND member_id = v_real FOR UPDATE;
    IF COALESCE(v_bal, 0) < v_mm.wallet_moved THEN
      RAISE EXCEPTION 'unmerge_balance_insufficient: 目標會員目前儲值金 % 少於當初併入的 %，扣回去會變負數，請先人工調整',
        COALESCE(v_bal, 0), v_mm.wallet_moved;
    END IF;
    UPDATE wallet_balances
       SET balance = balance - v_mm.wallet_moved, version = version + 1, updated_at = NOW()
     WHERE tenant_id = v_tenant AND member_id = v_real;
    INSERT INTO wallet_balances (tenant_id, member_id, balance, version, updated_at)
    VALUES (v_tenant, v_guest, v_mm.wallet_moved, 1, NOW())
    ON CONFLICT (tenant_id, member_id) DO UPDATE
      SET balance    = wallet_balances.balance + EXCLUDED.balance,
          version    = wallet_balances.version + 1,
          updated_at = NOW();
  END IF;

  -- ── 來源會員復活 ─────────────────────────────────────────────────────────
  UPDATE members
     SET status                = v_status_to,
         merged_into_member_id = NULL,
         updated_at            = NOW(),
         updated_by            = v_operator
   WHERE id = v_guest AND tenant_id = v_tenant;

  -- B 路徑漏掉的：合併時搬過去、但之後 updated_at 被覆蓋而推不回來的訂單。
  -- 沒辦法精算，至少把「目標身上還有多少張單」給出去讓人核對。
  IF v_recon THEN
    SELECT count(*) INTO v_left FROM customer_orders
     WHERE tenant_id = v_tenant AND member_id = v_real;
  END IF;

  UPDATE member_merges
     SET reverted_at = NOW(), reverted_by = v_operator, reverted_reason = p_reason
   WHERE id = p_merge_id;

  INSERT INTO member_audit_log (
    tenant_id, entity_type, entity_id, action, before_value, after_value, reason, operator_id
  ) VALUES (
    v_tenant, 'merge', p_merge_id, 'unmerge',
    jsonb_build_object('primary_member_id', v_real, 'merged_member_id', v_guest,
                       'points_moved', v_mm.points_moved, 'wallet_moved', v_mm.wallet_moved,
                       'cards_moved', v_mm.cards_moved, 'merged_at', v_mm.created_at),
    jsonb_build_object('reconstructed', v_recon, 'orders', v_n_orders, 'aliases', v_n_alias,
                       'tags', v_n_tags, 'cards', v_n_cards,
                       'points_ledger', v_n_pl, 'wallet_ledger', v_n_wl,
                       'restored_status', v_status_to),
    p_reason, v_operator
  );

  RETURN jsonb_build_object(
    'merge_id',            p_merge_id,
    'source_member_id',    v_guest,
    'target_member_id',    v_real,
    'reconstructed',       v_recon,
    'orders_restored',     v_n_orders,
    -- 清單裡有、但實際沒搬回來的（合併後又被搬去第三個人身上）。
    -- 兩個數字不一樣時 UI 要講出來，不能只報成功。
    'orders_expected',     COALESCE(array_length(v_order_ids, 1), 0),
    'aliases_restored',    v_n_alias,
    'tags_restored',       v_n_tags,
    'cards_restored',      v_n_cards,
    'points_restored',     v_mm.points_moved,
    'wallet_restored',     v_mm.wallet_moved,
    'restored_status',     v_status_to,
    -- 只有 B 路徑給：目標名下剩餘的訂單總數，供人工核對有沒有漏搬
    'target_orders_total', CASE WHEN v_recon THEN v_left ELSE NULL END
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_unmerge_member(BIGINT, UUID, TEXT) IS
  '復原一次會員合併：把當初搬走的訂單／暱稱／標籤／卡片／流水與餘額還給來源會員並讓它復活。'
  'moved 有值時精準復原；舊紀錄（moved 為 NULL）改用 updated_at 時間戳推回，且僅限沒動到點數／儲值／卡片者，'
  '回傳 reconstructed=true 提醒可能有漏。紀錄本身不刪，只標 reverted_at。';

REVOKE ALL ON FUNCTION public.rpc_unmerge_member(BIGINT, UUID, TEXT) FROM anon;
