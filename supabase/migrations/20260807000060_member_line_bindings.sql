-- ============================================================================
-- 2026-08-07: 每分店的 LINE 綁定（webhook 收 ID）
--
-- 背景：LINE 的 user ID 綁 Provider。14 家店的 OA 各在自己的 Provider，
-- members.line_user_id（來自單一支 Login channel）對任何一家店的 OA 都查不到
-- —— 2026-08-07 實測：松山店 12 位活躍會員的 ID，查該店 OA profile 全數 404。
--
-- 改走 Messaging API 的 account link（官方機制，**不需要 LINE Login channel**）：
--   1. 顧客加該店 OA 好友 / 傳訊息 → webhook 收到該店 provider 的 line_user_id
--   2. 要配對時發 linkToken 連結，顧客登入後 LINE 回 accountLink 事件
--   3. 用 nonce 把 member_id 跟該店 line_user_id 綁起來
--
-- 對齊 docs/PRD-通知模組.md §6.8「同一會員在不同店有不同 line_user_id」。
-- ============================================================================

CREATE TABLE IF NOT EXISTS member_line_bindings (
  id           BIGSERIAL   PRIMARY KEY,
  tenant_id    UUID        NOT NULL,
  store_id     BIGINT      NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  -- 該店 Provider 底下的 ID。**不要**跟 members.line_user_id 混用，那是另一個
  -- provider 的東西，兩者對同一個人是不同字串。
  line_user_id TEXT        NOT NULL,
  -- 還沒配對到會員時是 NULL：webhook 只知道「有這個 LINE 使用者」，
  -- 不知道他是誰，要等 account link 完成才填得上。
  member_id    BIGINT      REFERENCES members(id) ON DELETE SET NULL,
  display_name TEXT,
  picture_url  TEXT,
  followed     BOOLEAN     NOT NULL DEFAULT TRUE,
  linked_at    TIMESTAMPTZ,
  last_event_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (store_id, line_user_id)
);

CREATE INDEX IF NOT EXISTS idx_mlb_member ON member_line_bindings (member_id)
  WHERE member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mlb_store_unlinked ON member_line_bindings (store_id)
  WHERE member_id IS NULL;

COMMENT ON TABLE  member_line_bindings IS
  '每分店 OA 的 LINE 使用者名冊 + 與會員的對應。line_user_id 是「該店 provider」的 ID，與 members.line_user_id 不同源、不可互換';
COMMENT ON COLUMN member_line_bindings.member_id IS
  'NULL = webhook 收到這個 LINE 使用者但還沒配對到會員';

ALTER TABLE member_line_bindings ENABLE ROW LEVEL SECURITY;

-- 讀：自家 tenant 的 staff 可看（用來在 admin 顯示「這位會員在這家店綁了沒」）
DROP POLICY IF EXISTS mlb_tenant_read ON member_line_bindings;
CREATE POLICY mlb_tenant_read ON member_line_bindings
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);
-- 寫：只有 service_role（webhook），不開給前端

-- ── account link 用的一次性 nonce ───────────────────────────────────────────
-- 流程：發 linkToken 前先建一筆（記住這是哪位會員、哪家店），
-- LINE 回 accountLink 事件時帶著同一個 nonce，才知道要綁給誰。
CREATE TABLE IF NOT EXISTS line_account_link_nonces (
  nonce      TEXT        PRIMARY KEY,
  tenant_id  UUID        NOT NULL,
  store_id   BIGINT      NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  member_id  BIGINT      NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  used_at    TIMESTAMPTZ
);

COMMENT ON TABLE line_account_link_nonces IS
  'account link 的一次性 nonce。LINE 的 linkToken 只有 10 分鐘效期，這裡的紀錄同樣是短命的';

ALTER TABLE line_account_link_nonces ENABLE ROW LEVEL SECURITY;
-- 前端完全不需要讀寫；service_role bypass
REVOKE ALL ON line_account_link_nonces FROM anon, authenticated;

-- 過期清理（nonce 只有 10 分鐘有效，留 1 天足夠除錯）
CREATE OR REPLACE FUNCTION purge_line_account_link_nonces(p_days INT DEFAULT 1)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_deleted BIGINT;
BEGIN
  DELETE FROM line_account_link_nonces
   WHERE created_at < NOW() - (p_days || ' days')::INTERVAL;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;
