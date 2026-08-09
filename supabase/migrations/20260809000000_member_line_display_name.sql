-- ============================================================================
-- 2026-08-09: 會員端「顯示名稱」與後台名稱分家
-- ----------------------------------------------------------------------------
-- 背景：members.name 一欄同時扛兩個互相打架的用途 ——
--   (a) 會員端 /me 顯示給客人自己看的名字
--   (b) 後台列表 / 搜尋 / 揀貨單上店員辨識這個人的名字
-- 會員在 /me 把姓名改成「小美」，店員就再也搜不到「陳小美(松山)」。
--
-- 修法：新增 members.line_display_name
--   - line_display_name：LINE 端的顯示名稱。**只由 LINE 登入時同步**，
--     會員與後台都不可編輯（要改請客人去改自己的 LINE 名稱）。
--     會員端 App 一律顯示這個（fallback → name）。
--   - name：維持現狀，後台照舊用（列表 / 搜尋 / 單據）。
--     差別只在會員端不再顯示、也不再能改（liff-api 的 update_me 已拿掉 name）。
--
-- **後台看得到的東西刻意一個都不動。**
--   v_admin_member_list、rpc_search_members、rpc_upsert_member 全部原封不動；
--   後台的行為與這次改動前完全一致（新欄位對後台是不存在的）。
--   註：view 的 m.* 在建立當下就展開成欄位清單，所以 v_admin_member_list
--   不會、也不該自己冒出 line_display_name —— 後台若哪天要顯示 / 搜尋
--   LINE 名稱，再另開 migration 重建 view 與 rpc_search_members。
--   唯一的例外是下面的 rpc_member_gdpr_delete，只多清一個後台讀不到的新欄位，
--   簽章與所有既有行為完全不變。
--
-- 基底版本：rpc_member_gdpr_delete ← 20260618000040_rpc_member_gdpr_delete.sql
--   （2026-08-09 已用 pg_get_functiondef 撈線上實際定義逐行比對過，
--     與該 migration 完全一致、無手改漂移，故直接基於它擴寫。）
--
-- Rollback：
--   - 重跑 20260618000040_rpc_member_gdpr_delete.sql
--   - ALTER TABLE public.members DROP COLUMN IF EXISTS line_display_name;
-- ============================================================================

ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS line_display_name TEXT;

COMMENT ON COLUMN public.members.line_display_name IS
  'LINE 顯示名稱（每次 LINE 登入由 liff-session / line-oauth-callback 同步）。會員端 App 顯示這個；會員與後台皆不可編輯。後台的名字仍是 members.name';

-- backfill：已綁 LINE 的會員，現有 name 幾乎都是 auto-register 從 LINE 帶進來的，
-- 拿它當起始值最接近事實；之後任何一次 LINE 登入都會覆寫成當下的真值。
-- 沒綁 LINE 的（後台建檔 / 樂樂匯入）留 NULL，會員端 fallback 回 name。
-- 只寫新欄位，members.name 一個字都沒動。
--
-- set_config：members 有 touch_updated_at trigger，這支 backfill 會掃過所有
-- 已綁 LINE 的會員（線上約兩萬筆），不擋掉的話每一筆的 updated_at 都會被
-- 蓋成 migration 執行時間 —— 後台會員列表預設就是照「更新」排序，整個列表
-- 會變成一坨同一時間、店員再也看不出誰最近有動。GUC 是 20260611000010 為了
-- 同一個理由加進 touch_updated_at() 的。
SELECT set_config('app.skip_updated_at', '1', false);

UPDATE public.members
   SET line_display_name = name
 WHERE line_user_id IS NOT NULL
   AND line_display_name IS NULL
   AND name IS NOT NULL;

SELECT set_config('app.skip_updated_at', '', false);

-- ── GDPR 刪除：line_display_name 也是 PII ─────────────────────────────────
-- 基底 20260618000040（＝線上實際定義），只在 UPDATE members 那段多清一欄，
-- 其餘一字不改：簽章、稽核內容、卡片退卡、標籤刪除、冪等守衛全部照舊。
-- 後台完全感覺不到差別 —— 它本來就讀不到 line_display_name。
CREATE OR REPLACE FUNCTION public.rpc_member_gdpr_delete(
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
     SET name              = NULL,
         line_display_name = NULL,   -- ← 本次唯一新增
         phone_enc         = NULL,
         phone_hash        = 'DELETED_' || id,
         email_enc         = NULL,
         email_hash        = NULL,
         birthday_enc      = NULL,
         birth_md          = NULL,
         line_user_id      = NULL,
         avatar_url        = NULL,
         status            = 'deleted',
         notes             = '[GDPR deleted at ' || NOW()::text || ' by ' || v_operator::text || ']',
         updated_at        = NOW(),
         updated_by        = v_operator
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
  '會員 GDPR 刪除：軟刪除（status=deleted）+ 清 PII（姓名/LINE 顯示名稱/電話/email/生日/LINE/大頭照），'
  '卡片退卡、標籤刪除，流水/訂單/sales 保留（稅務）。冪等、稽核只記非 PII 中繼。';
