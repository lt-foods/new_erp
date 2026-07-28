-- ============================================================================
-- 2026-07-28: rpc_member_purge / rpc_member_purge_bulk — 會員「徹底刪除」（硬刪除）
-- ----------------------------------------------------------------------------
-- 背景：既有「刪除會員」= rpc_member_gdpr_delete（20260618000040）軟刪除：
--       清 PII + status='deleted'，members 資料列與點數/儲值流水都留在 DB。
--       使用者需求「會員要可以徹底刪除」→ 補硬刪除路徑：members 資料列
--       連同所有會員附屬資料一併實體 DELETE，會員完全消失。
--
-- 與 GDPR 軟刪除並存：前端刪除 modal 提供兩種模式（徹底刪除 / 保留紀錄刪除），
-- 本檔不動 rpc_member_gdpr_delete[_bulk]，兩條路徑互不影響。
--
-- 刪除範圍（依 FK 盤點，指向 members 的表全數處理）：
--   實體 DELETE（會員附屬資料，隨會員一起消失）：
--     points_ledger / member_points_balance（暫關 trg_no_delete_points）
--     wallet_ledger / wallet_balances（暫關 trg_no_delete_wallet）
--     member_cards / member_tags
--     member_line_bindings / customer_line_aliases / push_subscriptions
--     member_merges（primary 或 merged 指到被刪會員的紀錄）
--     notifications（FK ON DELETE CASCADE，自動）
--     members 本體（暫關 trg_no_delete_member）
--   解除連結（營運/庫存/稅務紀錄，單據本身保留）：
--     customer_orders.member_id → NULL（訂單掛庫存移動與結算，不可刪）
--     order_waitlist.member_id  → NULL
--     backorders.member_id      → NULL
--     members.merged_into_member_id → NULL（其他會員指向被刪會員的合併殘影）
--     member_imports.resolved_member_id（FK ON DELETE SET NULL，自動）
--
-- 守門：
--   - 只刪自己 tenant（_current_tenant_id，含試用到期守門）
--   - member_type='store_internal'（分店內部會員，補貨/叫貨鏈依賴）一律拒刪：
--     單筆版 RAISE、批次版略過並回報 skipped_internal
--   - 權限沿用會員刪除慣例：SECURITY DEFINER 不自帶 role gate，
--     UI 端以 isAdmin 把關 + 輸入確認（同 rpc_member_gdpr_delete_bulk）
--
-- 觸發器暫關安全性：ALTER TABLE DISABLE TRIGGER 在本函式交易內執行，
-- 對該表取得 ACCESS EXCLUSIVE 鎖直到 commit，期間其他連線無法寫入，
-- 不存在「別人趁 trigger 關閉時偷刪 ledger」的窗口（同 rpc_admin_purge_lele_imports 前例）。
--
-- 稽核：刪除前對每筆會員寫 member_audit_log action='purge'，只記非 PII
-- 中繼資訊（member_no / member_type / prev_status / 有無姓名電話 LINE），
-- 與 gdpr_delete 的隱私原則一致。
--
-- 冪等：已不存在的 id 批次版略過（單筆版 RAISE not found），可安全重跑。
-- 基底版本：首建（無歷史版本）。
-- Rollback：
--   DROP FUNCTION public.rpc_member_purge(BIGINT, TEXT);
--   DROP FUNCTION public.rpc_member_purge_bulk(BIGINT[], TEXT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_member_purge_bulk(
  p_member_ids BIGINT[],
  p_reason     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant           UUID := public._current_tenant_id();
  v_operator         UUID := COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);
  v_ids              BIGINT[];
  v_input            INTEGER := COALESCE(array_length(p_member_ids, 1), 0);
  v_skipped_internal INTEGER := 0;
  v_purged           INTEGER := 0;
  v_orders_unlinked  INTEGER := 0;
  v_points_deleted   INTEGER := 0;
  v_wallet_deleted   INTEGER := 0;
  v_cards_deleted    INTEGER := 0;
BEGIN
  IF v_input = 0 THEN
    RETURN jsonb_build_object('purged', 0, 'skipped_internal', 0, 'skipped_missing', 0);
  END IF;

  -- 同 tenant、排除分店內部會員
  SELECT array_agg(id) INTO v_ids
    FROM members
   WHERE id = ANY(p_member_ids)
     AND tenant_id = v_tenant
     AND member_type IS DISTINCT FROM 'store_internal';

  SELECT COUNT(*) INTO v_skipped_internal
    FROM members
   WHERE id = ANY(p_member_ids)
     AND tenant_id = v_tenant
     AND member_type = 'store_internal';

  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RETURN jsonb_build_object(
      'purged', 0,
      'skipped_internal', v_skipped_internal,
      'skipped_missing',  v_input - v_skipped_internal
    );
  END IF;
  v_purged := array_length(v_ids, 1);

  -- 稽核：刪除前寫入，只記非 PII 中繼資訊
  INSERT INTO member_audit_log (
    tenant_id, entity_type, entity_id, action,
    before_value, after_value, reason, operator_id
  )
  SELECT v_tenant, 'member', m.id, 'purge',
         jsonb_build_object(
           'member_no',   m.member_no,
           'member_type', m.member_type,
           'prev_status', m.status,
           'had_name',    m.name IS NOT NULL,
           'had_phone',   m.phone_hash IS NOT NULL AND m.phone_hash NOT LIKE 'DELETED\_%',
           'had_line',    m.line_user_id IS NOT NULL
         ),
         jsonb_build_object('purged', true),
         p_reason, v_operator
    FROM members m
   WHERE m.id = ANY(v_ids);

  -- 營運單據保留、解除會員連結
  UPDATE customer_orders SET member_id = NULL WHERE member_id = ANY(v_ids);
  GET DIAGNOSTICS v_orders_unlinked = ROW_COUNT;
  UPDATE order_waitlist  SET member_id = NULL WHERE member_id = ANY(v_ids);
  UPDATE backorders      SET member_id = NULL WHERE member_id = ANY(v_ids);
  UPDATE members         SET merged_into_member_id = NULL
   WHERE merged_into_member_id = ANY(v_ids) AND NOT (id = ANY(v_ids));

  -- 會員附屬資料實體刪除
  DELETE FROM member_merges
   WHERE primary_member_id = ANY(v_ids) OR merged_member_id = ANY(v_ids);
  DELETE FROM member_line_bindings  WHERE member_id = ANY(v_ids);
  DELETE FROM customer_line_aliases WHERE member_id = ANY(v_ids);
  DELETE FROM push_subscriptions    WHERE member_id = ANY(v_ids);

  EXECUTE 'ALTER TABLE points_ledger DISABLE TRIGGER trg_no_delete_points';
  EXECUTE 'ALTER TABLE wallet_ledger DISABLE TRIGGER trg_no_delete_wallet';
  EXECUTE 'ALTER TABLE members       DISABLE TRIGGER trg_no_delete_member';

  DELETE FROM points_ledger WHERE member_id = ANY(v_ids);
  GET DIAGNOSTICS v_points_deleted = ROW_COUNT;
  DELETE FROM member_points_balance WHERE member_id = ANY(v_ids);

  DELETE FROM wallet_ledger WHERE member_id = ANY(v_ids);
  GET DIAGNOSTICS v_wallet_deleted = ROW_COUNT;
  DELETE FROM wallet_balances WHERE member_id = ANY(v_ids);

  DELETE FROM member_cards WHERE member_id = ANY(v_ids);
  GET DIAGNOSTICS v_cards_deleted = ROW_COUNT;
  DELETE FROM member_tags WHERE member_id = ANY(v_ids);

  -- notifications 由 FK CASCADE、member_imports.resolved_member_id 由 SET NULL 自動處理
  DELETE FROM members WHERE id = ANY(v_ids);

  EXECUTE 'ALTER TABLE points_ledger ENABLE TRIGGER trg_no_delete_points';
  EXECUTE 'ALTER TABLE wallet_ledger ENABLE TRIGGER trg_no_delete_wallet';
  EXECUTE 'ALTER TABLE members       ENABLE TRIGGER trg_no_delete_member';

  RETURN jsonb_build_object(
    'purged',                v_purged,
    'skipped_internal',      v_skipped_internal,
    'skipped_missing',       v_input - v_skipped_internal - v_purged,
    'orders_unlinked',       v_orders_unlinked,
    'points_ledger_deleted', v_points_deleted,
    'wallet_ledger_deleted', v_wallet_deleted,
    'cards_deleted',         v_cards_deleted
  );
END;
$$;

-- Supabase default privileges 會另外給 anon EXECUTE，須明確 REVOKE（雖然
-- 函式內 _current_tenant_id 會擋無 tenant claim 的呼叫，仍不留 anon 入口）
REVOKE ALL ON FUNCTION public.rpc_member_purge_bulk(BIGINT[], TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_member_purge_bulk(BIGINT[], TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_member_purge_bulk(BIGINT[], TEXT) IS
  '會員徹底刪除（硬刪除，批次）：實體刪除 members 及點數/儲值流水、卡片、標籤、LINE 綁定、'
  '推播訂閱；訂單/候補/欠品僅解除會員連結保留單據。store_internal 會員略過。回傳各項筆數 JSONB。';

-- ----------------------------------------------------------------------------
-- 單筆版：守門用 RAISE（前端可翻譯錯誤），實刪委派批次版
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_member_purge(
  p_member_id BIGINT,
  p_reason    TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_type   TEXT;
BEGIN
  SELECT member_type INTO v_type
    FROM members
   WHERE id = p_member_id AND tenant_id = v_tenant;

  IF v_type IS NULL THEN
    RAISE EXCEPTION 'member % not found', p_member_id;
  END IF;
  IF v_type = 'store_internal' THEN
    RAISE EXCEPTION 'member % is a store-internal member, cannot purge', p_member_id;
  END IF;

  RETURN public.rpc_member_purge_bulk(ARRAY[p_member_id], p_reason);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_member_purge(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_member_purge(BIGINT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_member_purge(BIGINT, TEXT) IS
  '會員徹底刪除（硬刪除，單筆）：委派 rpc_member_purge_bulk。不存在 / store_internal 會 RAISE。';
