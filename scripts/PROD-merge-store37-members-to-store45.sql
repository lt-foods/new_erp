-- ============================================================
-- PROD 一次性資料操作：四號店(37)併入中和店(45) — 會員複製 + 原會員黑名單
-- 執行日：2026-07-13（已透過 Supabase Management API 執行完畢，此檔為留檔）
--
-- 背景：四號店收店，客群轉往中和店。
--   1. 四號店 798 筆 active 會員複製一份到中和店（新 member_no 接現有流水號）
--      - 追溯標記：external_source='manual'，external_id='store_merge_37_to_45:<原會員id>'
--        （external_source 有 CHECK 只允許 lele/pinduoduo/1688/line_community/manual）
--      - 唯一索引 uniq_members_tenant_extsrc_extid 保證重跑不會重複複製
--      - 原本就黑名單的 4 筆（id 57869/58579/58890/60998），複製後維持黑名單
--      - status='deleted' 的 1 筆（M040120）不複製
--      - 四號會員皆無電話/LINE/錢包/點數/暱稱別名，無唯一鍵衝突、無金額複製問題
--   2. 四號店全部 799 筆會員設 no_new_order=TRUE（禁建單/加單）
--      - 不動 no_notify_pickup：既有訂單到貨通知照發
--      - 取貨(rpc_record_pickup)/到貨(rpc_arrive_and_distribute)不檢查此旗標，
--        四號 1,525 筆未結案訂單照常收貨取貨
--   3. 店家主檔不動（stores.id=37 保留、維持啟用）
--
-- 執行後驗證（2026-07-13）：
--   copies=798、全部在中和(45) active、複製黑名單=4、
--   四號 799/799 已黑名單、中和會員 4661→5459、member_no 無重複
-- ============================================================

BEGIN;

WITH base AS (
  SELECT COALESCE(MAX((SUBSTRING(member_no FROM '^M(\d{1,9})$'))::BIGINT), 0) AS max_no
  FROM members
  WHERE tenant_id = (SELECT tenant_id FROM stores WHERE id = 37)
    AND member_no ~ '^M\d{1,9}$'
),
src AS (
  SELECT m.*, row_number() OVER (ORDER BY m.id) AS rn
  FROM members m
  WHERE m.home_store_id = 37
    AND m.status = 'active'
    AND m.tenant_id = (SELECT tenant_id FROM stores WHERE id = 37)
    AND NOT EXISTS (
      SELECT 1 FROM members c
      WHERE c.tenant_id = m.tenant_id
        AND c.external_source = 'manual'
        AND c.external_id = 'store_merge_37_to_45:' || m.id::text
    )
)
INSERT INTO members (
  tenant_id, member_no, name,
  email_hash, email_enc, email,
  birthday_enc, birth_md, birthday, gender,
  tier_id, home_store_id, status,
  joined_at, last_visit_at, notes,
  member_type, avatar_url, takeout_store_name_hint,
  no_notify_pickup, no_new_order, admin_note,
  external_source, external_id
)
SELECT
  s.tenant_id,
  'M' || lpad((b.max_no + s.rn)::text, 6, '0'),
  s.name,
  s.email_hash, s.email_enc, s.email,
  s.birthday_enc, s.birth_md, s.birthday, s.gender,
  s.tier_id, 45, 'active',
  s.joined_at, s.last_visit_at, s.notes,
  s.member_type, s.avatar_url, s.takeout_store_name_hint,
  s.no_notify_pickup, s.no_new_order, s.admin_note,
  'manual', 'store_merge_37_to_45:' || s.id::text
FROM src s CROSS JOIN base b;

UPDATE members
SET no_new_order = TRUE, updated_at = now()
WHERE home_store_id = 37 AND NOT no_new_order;

COMMIT;

-- ============================================================
-- ROLLBACK（如需還原）
-- ============================================================
-- BEGIN;
-- -- 刪除複製到中和的會員（僅限尚未產生訂單/異動時可安全刪除）
-- DELETE FROM members
--  WHERE external_source = 'manual'
--    AND external_id LIKE 'store_merge_37_to_45:%';
-- -- 解除四號會員黑名單（保留原本就是黑名單的 4 筆）
-- UPDATE members
--    SET no_new_order = FALSE, updated_at = now()
--  WHERE home_store_id = 37
--    AND id NOT IN (57869, 58579, 58890, 60998);
-- COMMIT;
