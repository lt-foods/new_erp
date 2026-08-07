-- ============================================================================
-- 2026-08-07: store_line_followers —— 各店 OA 的 LINE 好友名冊（webhook 寫入）
--
-- 為什麼不塞進既有的 member_line_bindings：
--   那張表裡的 line_user_id 來自**會員登入用的 Login channel provider**
--   （線上 948 筆中有 944 筆與 members.line_user_id 完全相同），
--   而這裡要存的是**各店 OA provider** 的 ID。兩者對同一個人是不同字串、
--   不可互換。混在同一張表 = 之後沒人分得出哪一筆推得動、哪一筆推不動，
--   而「分不出來」正是今天繞一整圈的根源。所以刻意分開存。
--
-- 另外 member_line_bindings.member_id 是 NOT NULL，裝不下「webhook 收到某個
-- LINE 使用者但還不知道他是誰」這個中間狀態 —— 那正是本表的主要用途。
-- ============================================================================

CREATE TABLE IF NOT EXISTS store_line_followers (
  id            BIGSERIAL   PRIMARY KEY,
  tenant_id     UUID        NOT NULL,
  store_id      BIGINT      NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  -- 該店 OA provider 的 ID。**不要**跟 members.line_user_id 或
  -- member_line_bindings.line_user_id 混用或比對，那是另一個 provider 的東西。
  line_user_id  TEXT        NOT NULL,
  -- NULL = 收到這個 LINE 使用者，但還沒配對到會員（等 account link 完成）
  member_id     BIGINT      REFERENCES members(id) ON DELETE SET NULL,
  display_name  TEXT,
  picture_url   TEXT,
  followed      BOOLEAN     NOT NULL DEFAULT TRUE,
  linked_at     TIMESTAMPTZ,
  last_event_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (store_id, line_user_id)
);

CREATE INDEX IF NOT EXISTS idx_slf_member
  ON store_line_followers (member_id) WHERE member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_slf_unlinked
  ON store_line_followers (store_id) WHERE member_id IS NULL;

COMMENT ON TABLE store_line_followers IS
  '各分店 OA 的 LINE 好友名冊（line-webhook 寫入）。line_user_id 是該店 OA provider 的 ID，可直接用於 push';
COMMENT ON COLUMN store_line_followers.member_id IS
  'NULL = 還沒配對到會員；配對走 Messaging API 的 account link（linkToken + nonce）';

ALTER TABLE store_line_followers ENABLE ROW LEVEL SECURITY;

-- 讀取權限對齊既有 member_line_bindings 的三層設計，不要放寬：
--   hq 全看、店員只看自己那家店。顧客端不需要讀這張表。
DROP POLICY IF EXISTS slf_hq_all ON store_line_followers;
CREATE POLICY slf_hq_all ON store_line_followers
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') IN ('owner','admin','hq','hq_manager','')
  );

DROP POLICY IF EXISTS slf_store_read ON store_line_followers;
CREATE POLICY slf_store_read ON store_line_followers
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND store_id = NULLIF(auth.jwt() -> 'app_metadata' ->> 'store_id', '')::BIGINT
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') IN ('store_manager','store_staff')
  );
-- 寫入只有 service_role（line-webhook），不開給前端
