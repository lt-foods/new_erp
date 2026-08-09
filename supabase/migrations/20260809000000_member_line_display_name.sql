-- ============================================================================
-- 2026-08-09: 會員「顯示名稱」與「後台名稱」分家
-- ----------------------------------------------------------------------------
-- 背景：members.name 一欄同時扛兩個互相打架的用途 ——
--   (a) 會員端 /me 顯示給客人自己看的名字
--   (b) 後台列表 / 搜尋 / 揀貨單上店員辨識這個人的名字
-- 會員在 /me 把姓名改成「小美」，店員就再也搜不到「陳小美(松山)」；
-- 反過來店員為了好認把 name 改成「陳小美-常客-不收袋」，客人開 App 就看到
-- 這串內部備註。
--
-- 修法：新增 members.line_display_name
--   - line_display_name：LINE 端的顯示名稱。**只由 LINE 登入時同步**，
--     會員與後台都不可編輯（要改請客人去改自己的 LINE 名稱）。
--     會員端 App 一律顯示這個（fallback → name）。
--   - name：後台自己編的名字，只有後台能改，列表 / 搜尋 / 單據都用它。
--     會員端不再顯示、也不再能改（liff-api 的 update_me 已拿掉 name）。
--
-- 本檔動的東西：
--   1. members 加欄位 + backfill + trgm index
--   2. v_admin_member_list 重建（view 的 m.* 在建立當下就展開成欄位清單，
--      不重建的話新欄位不會出現 —— 後台 select line_display_name 會 400）
--   3. rpc_search_members：搜尋條件多吃 line_display_name、回傳多一欄
--      （店員看到客人 LINE 名稱來問，要搜得到）
--   4. rpc_member_gdpr_delete：line_display_name 屬 PII，一起清掉
--
-- 基底版本：
--   v_admin_member_list        ← 20260804000010_v_admin_member_list_ready_only.sql
--   rpc_search_members         ← 20260628000000_search_members_resolve_merged.sql
--   rpc_member_gdpr_delete     ← 20260618000040_rpc_member_gdpr_delete.sql
--
-- Rollback：
--   - v_admin_member_list / rpc_search_members / rpc_member_gdpr_delete
--     重跑上列各自的基底 migration
--   - DROP INDEX IF EXISTS public.idx_members_line_display_name_trgm;
--   - ALTER TABLE public.members DROP COLUMN IF EXISTS line_display_name;
-- ============================================================================

-- ── 1) 欄位 ────────────────────────────────────────────────────────────────
ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS line_display_name TEXT;

COMMENT ON COLUMN public.members.line_display_name IS
  'LINE 顯示名稱（每次 LINE 登入由 liff-session / line-oauth-callback 同步）。會員端 App 顯示這個；會員與後台皆不可編輯';
COMMENT ON COLUMN public.members.name IS
  '後台名稱：後台自己編、供列表/搜尋/單據辨識用。會員端不顯示也不可改（顯示用 line_display_name）';

-- backfill：已綁 LINE 的會員，現有 name 幾乎都是 auto-register 從 LINE 帶進來的，
-- 拿它當起始值最接近事實；之後任何一次 LINE 登入都會覆寫成當下的真值。
-- 沒綁 LINE 的（後台建檔 / 樂樂匯入）留 NULL，前端 fallback 回 name。
UPDATE public.members
   SET line_display_name = name
 WHERE line_user_id IS NOT NULL
   AND line_display_name IS NULL
   AND name IS NOT NULL;

-- 與 idx_members_name_trgm（20260704000000）同理由：搜尋是 ILIKE '%term%'，
-- 沒有 trigram index 會整張表 Seq Scan。
CREATE INDEX IF NOT EXISTS idx_members_line_display_name_trgm
  ON public.members USING gin (line_display_name gin_trgm_ops);

-- ── 2) v_admin_member_list 重建（口徑不變，只為了帶到新欄位） ──────────────
DROP VIEW IF EXISTS public.v_admin_member_list;

CREATE VIEW public.v_admin_member_list
WITH (security_invoker = true) AS
SELECT
  m.*,
  COALESCE(uo.unpicked_order_count, 0)::int AS unpicked_order_count
FROM public.members m
LEFT JOIN (
  SELECT member_id, COUNT(*) AS unpicked_order_count
  FROM public.customer_orders
  WHERE status IN ('ready','partially_completed')
  GROUP BY member_id
) uo ON uo.member_id = m.id;

GRANT SELECT ON public.v_admin_member_list TO authenticated, anon;

-- ── 3) rpc_search_members：多搜 / 多回 line_display_name ───────────────────
-- 只改 rpc_search_members；同檔的 rpc_search_aliases（搜 nickname）維持
-- 20260628000000 的版本不動。
DROP FUNCTION IF EXISTS public.rpc_search_members(TEXT, INT);

CREATE OR REPLACE FUNCTION public.rpc_search_members(
  p_term  TEXT,
  p_limit INT DEFAULT 20
) RETURNS TABLE (
  id                BIGINT,
  member_no         TEXT,
  name              TEXT,
  line_display_name TEXT,
  phone             TEXT,
  avatar_url        TEXT,
  home_store_id     BIGINT,
  home_store_name   TEXT,
  no_new_order      BOOLEAN,
  no_notify_pickup  BOOLEAN,
  admin_note        TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID   := public._current_tenant_id();
  v_tokens TEXT[] := ARRAY(
    SELECT t
      FROM regexp_split_to_table(COALESCE(p_term, ''), '[\s+]+') AS t
     WHERE t <> ''
  );
  v_lim    INT    := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  RETURN QUERY
  WITH RECURSIVE matches AS (
    SELECT m.id, m.status, m.merged_into_member_id, m.created_at
      FROM members m
     WHERE m.tenant_id = v_tenant
       AND m.status <> 'deleted'
       AND (
         COALESCE(array_length(v_tokens, 1), 0) = 0
         OR NOT EXISTS (
           SELECT 1
             FROM unnest(v_tokens) AS tok
            WHERE NOT (
              m.name      ILIKE '%' || tok || '%'
              OR m.line_display_name ILIKE '%' || tok || '%'
              OR m.member_no ILIKE '%' || tok || '%'
              OR m.phone     ILIKE '%' || tok || '%'
            )
         )
       )
  ),
  resolved AS (
    SELECT id AS source_id, id AS target_id, status, merged_into_member_id, 0 AS hop, created_at
      FROM matches
    UNION ALL
    SELECT r.source_id, m.id, m.status, m.merged_into_member_id, r.hop + 1, m.created_at
      FROM resolved r
      JOIN members m ON m.id = r.merged_into_member_id
     WHERE r.status = 'merged'
       AND r.merged_into_member_id IS NOT NULL
       AND r.hop < 5
  ),
  finals AS (
    SELECT DISTINCT ON (source_id) source_id, target_id, status, created_at
      FROM resolved
     ORDER BY source_id, hop DESC
  )
  SELECT m.id, m.member_no, m.name, m.line_display_name, m.phone, m.avatar_url,
         m.home_store_id, s.name,
         m.no_new_order, m.no_notify_pickup, m.admin_note
    FROM (
      SELECT DISTINCT ON (target_id) target_id, created_at
        FROM finals
       WHERE status NOT IN ('merged', 'deleted')
       ORDER BY target_id, created_at DESC
    ) f
    JOIN members m ON m.id = f.target_id
    LEFT JOIN stores s ON s.id = m.home_store_id
   ORDER BY f.created_at DESC
   LIMIT v_lim;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_search_members TO authenticated;

-- ── 4) GDPR 刪除：line_display_name 也是 PII ───────────────────────────────
-- 基底 20260618000040，只在 UPDATE members 那段多清一欄，其餘原封不動。
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
         line_display_name = NULL,
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
