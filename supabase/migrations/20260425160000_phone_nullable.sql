-- ============================================================================
-- 讓 phone / phone_hash 可為 NULL
-- LIFF auto-register 的會員沒手機、之前用 "line:<uid>" placeholder 很醜；
-- 改成 NULL、UI 顯示「未填」更乾淨。
-- ============================================================================

-- 1) phone_hash 改為可 NULL
ALTER TABLE members ALTER COLUMN phone_hash DROP NOT NULL;

-- 2) 把舊的 table-level UNIQUE(tenant_id, phone_hash) 換成 partial index
--    （允許多筆 phone_hash=NULL 並存、有值時才 unique）
ALTER TABLE members DROP CONSTRAINT IF EXISTS members_tenant_id_phone_hash_key;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_members_tenant_phone_hash_partial
  ON members (tenant_id, phone_hash)
  WHERE phone_hash IS NOT NULL;

-- 3) Backfill：清掉現有 "line:<uid>" placeholder 資料
--    這些會員的 line_user_id 已經在上一個 migration 寫進獨立欄位了，
--    phone 可以放心清空。
UPDATE members
   SET phone = NULL,
       phone_hash = NULL
 WHERE phone LIKE 'line:%';
