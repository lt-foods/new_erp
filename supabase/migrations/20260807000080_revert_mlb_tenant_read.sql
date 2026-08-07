-- ============================================================================
-- 2026-08-07: 撤掉誤加到 member_line_bindings 的 mlb_tenant_read policy
--
-- 事故經過：20260807000060 想建一張「webhook 收 LINE ID」的新表，取名
-- member_line_bindings —— 但**這張表早就存在**（20260425130000_line_bindings.sql，
-- 線上 948 筆真資料、18 家店）。`CREATE TABLE IF NOT EXISTS` 靜默跳過，
-- 後面的 ALTER / CREATE POLICY 卻照樣套到了既有表上。
--
-- 後果：多出一條 mlb_tenant_read（同租戶任何登入者可讀**全部**門市的綁定），
-- 比原設計寬。原設計是刻意三層收窄的：
--   mlb_self_read  顧客只讀自己
--   mlb_store_read 店員只讀自己那家店
--   mlb_hq_all     只有 hq 能全看
-- 這裡把多出來的那條移除，回到原本的三條。
--
-- 順便移除同批加的兩個無用索引：該表 member_id 是 NOT NULL，
-- `WHERE member_id IS NOT NULL` 等於全表、`WHERE member_id IS NULL` 恆空。
--
-- 教訓：建新表前先確認名字沒被用過 ——
--   SELECT to_regclass('public.<table>');
-- ============================================================================

DROP POLICY IF EXISTS mlb_tenant_read ON member_line_bindings;

DROP INDEX IF EXISTS idx_mlb_member;
DROP INDEX IF EXISTS idx_mlb_store_unlinked;

-- 把被覆蓋掉的註解改回描述這張表真正的用途
COMMENT ON TABLE member_line_bindings IS
  '會員 × 門市 的 LINE 綁定（見 20260425130000）。注意：這裡的 line_user_id 來自'
  '會員登入用的 Login channel provider，**不等於**各店 OA 看到的 ID；'
  '要推播用的 per-store ID 在 store_line_followers';
COMMENT ON COLUMN member_line_bindings.member_id IS '所屬會員（NOT NULL）';
