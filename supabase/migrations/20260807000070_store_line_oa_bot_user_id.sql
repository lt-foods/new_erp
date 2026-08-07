-- ============================================================================
-- 2026-08-07: store_line_oa_credentials 記下 OA 自己的 userId
--
-- 用途：line-webhook 在「Webhook URL 沒帶 ?store=」時，要靠 body 的
-- `destination`（= 該 OA 的 userId）反查是哪一家店。主要路徑仍是 ?store=，
-- 這是備援 —— 14 家店手動貼 URL，難免有人漏了 query。
--
-- 值從 /v2/bot/info 的 userId 來，admin-line-push 的 verify_store 會順手寫入
-- （那支本來就在打 /v2/bot/info）。
-- ============================================================================

ALTER TABLE store_line_oa_credentials ADD COLUMN IF NOT EXISTS bot_user_id TEXT;

CREATE INDEX IF NOT EXISTS idx_store_line_oa_bot_user
  ON store_line_oa_credentials (bot_user_id) WHERE bot_user_id IS NOT NULL;

COMMENT ON COLUMN store_line_oa_credentials.bot_user_id IS
  '該 OA 自己的 LINE userId（/v2/bot/info 的 userId）。webhook 沒帶 ?store= 時用 destination 反查用';
