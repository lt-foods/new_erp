-- ============================================================================
-- 2026-05-19: rpc_member_gdpr_delete — 會員「刪除」= 軟刪除 + PII 清空
-- ----------------------------------------------------------------------------
-- 背景：members 有 trg_no_delete_member 觸發器，硬 DELETE 一律 RAISE，
--       指示「Use rpc_member_gdpr_delete instead」。但該 RPC 先前只寫在
--       PRD（docs/PRD-會員模組.md Q13，2026-04-20 拍板），從未實作。
--       本 migration 依 PRD 規格補上。
--
-- 規格（PRD Q13「刪除 vs 封存」→ 軟刪除 + PII 清空、歷史流水保留）：
--   members:
--     name=NULL, phone_enc=NULL, phone_hash='DELETED_'||id（保 unique、釋放原手機號）,
--     email_enc=NULL, email_hash=NULL, birthday_enc=NULL, birth_md=NULL,
--     status='deleted', notes='[GDPR deleted at {ts} by {operator}]'
--   member_cards: 全部 → status='retired'
--   member_tags:  全部刪除
--   points_ledger / wallet_ledger / sales: 不動（稅捐稽徵法 7 年留存）
--   member_audit_log: 記一筆 action='gdpr_delete'
--
-- 相對 PRD 的補充（PRD 2026-04-20 撰寫時這些欄位/表還不存在，但同屬 PII，
-- 依規格「PII 清空」精神一併處理，非擅自擴張範圍）：
--   members.line_user_id → NULL（LINE User ID 屬個資；同時釋放 uniq_members_line_user_id）
--   members.avatar_url   → NULL（大頭照屬個資）
--
-- 刻意「不」處理（留待日後若有需求再單獨確認，避免本次過度設計）：
--   customer_line_aliases（LINE 暱稱對應）、push_subscriptions（裝置 token）、
--   customer_orders（訂單個別保留，與 merge 政策一致、稅務留存）。
--
-- 隱私正確性：member_audit_log.before_value 只存「非 PII 的中繼資訊」
--   （清掉前的 status / 是否有姓名電郵），不把要刪的 PII 原文寫進稽核表，
--   否則 GDPR 刪除形同虛設。
--
-- 冪等：已是 'deleted' 的會員 → 直接 RETURN（NOTICE），可安全重跑。
-- 權限：SECURITY DEFINER（與 rpc_merge_member 一致，由後台呼叫；
--   PRD 要求「僅總部老闆/行銷可操作 + UI 二次確認」於呼叫端把關）。
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_member_gdpr_delete(
  p_member_id BIGINT,
  p_reason    TEXT DEFAULT NULL,
  p_operator  UUID DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant     UUID;
  v_operator   UUID;
  v_status     TEXT;
  v_had_name   BOOLEAN;
  v_had_email  BOOLEAN;
  v_had_phone  BOOLEAN;
  v_had_line   BOOLEAN;
  v_cards      INTEGER := 0;
  v_tags       INTEGER := 0;
BEGIN
  v_operator := COALESCE(p_operator, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  SELECT tenant_id, status,
         (name IS NOT NULL), (email_hash IS NOT NULL),
         (phone_hash IS NOT NULL AND phone_hash NOT LIKE 'DELETED\_%'),
         (line_user_id IS NOT NULL)
    INTO v_tenant, v_status, v_had_name, v_had_email, v_had_phone, v_had_line
    FROM members WHERE id = p_member_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'member % not found', p_member_id;
  END IF;

  -- 冪等：已刪除 → 不重複動作（可安全重跑）
  IF v_status = 'deleted' THEN
    RAISE NOTICE 'member % already gdpr-deleted, no-op', p_member_id;
    RETURN;
  END IF;

  -- 1) members 主檔：清 PII + status='deleted'
  UPDATE members
     SET name         = NULL,
         phone_enc    = NULL,
         phone_hash   = 'DELETED_' || id,
         email_enc    = NULL,
         email_hash   = NULL,
         birthday_enc = NULL,
         birth_md     = NULL,
         line_user_id = NULL,
         avatar_url   = NULL,
         status       = 'deleted',
         notes        = '[GDPR deleted at ' || NOW()::text || ' by ' || v_operator::text || ']',
         updated_at   = NOW(),
         updated_by   = v_operator
   WHERE id = p_member_id;

  -- 2) 會員卡：全部退卡
  UPDATE member_cards
     SET status     = 'retired',
         retired_at = COALESCE(retired_at, NOW()),
         updated_at = NOW(),
         updated_by = v_operator
   WHERE member_id = p_member_id AND status <> 'retired';
  GET DIAGNOSTICS v_cards = ROW_COUNT;

  -- 3) 會員標籤：全部刪除
  DELETE FROM member_tags WHERE member_id = p_member_id;
  GET DIAGNOSTICS v_tags = ROW_COUNT;

  -- 4) points_ledger / wallet_ledger / sales：刻意不動（稅務 7 年留存）

  -- 5) 稽核：只記非 PII 中繼資訊
  INSERT INTO member_audit_log (
    tenant_id, entity_type, entity_id, action,
    before_value, after_value, reason, operator_id
  ) VALUES (
    v_tenant, 'member', p_member_id, 'gdpr_delete',
    jsonb_build_object(
      'prev_status', v_status,
      'had_name',  v_had_name,
      'had_email', v_had_email,
      'had_phone', v_had_phone,
      'had_line',  v_had_line
    ),
    jsonb_build_object(
      'status',         'deleted',
      'cards_retired',  v_cards,
      'tags_removed',   v_tags
    ),
    p_reason, v_operator
  );
END;
$$;

COMMENT ON FUNCTION rpc_member_gdpr_delete(BIGINT, TEXT, UUID) IS
  '會員 GDPR 刪除：軟刪除（status=deleted）+ 清 PII（姓名/電話/email/生日/LINE/大頭照），'
  '卡片退卡、標籤刪除，流水/訂單/sales 保留（稅務）。冪等、稽核只記非 PII 中繼。';
