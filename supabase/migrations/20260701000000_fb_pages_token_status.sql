-- fb_pages 加 token 失效追蹤欄位
--
-- 基底版本：20260620000030_fb_pages_and_campaign_fb_posts.sql（建表）
-- Rollback：ALTER TABLE fb_pages DROP COLUMN token_invalid_at, DROP COLUMN token_last_error;
--           （不影響既有 access_token 資料）
--
-- 用途：
--   * campaign-publish-facebook 偵測到 FB 回 error code 190（token expired/invalid）
--     時寫入 token_invalid_at + token_last_error，下次發文前 UI 會顯示警告 banner。
--   * fb-exchange-token edge function 換到新永久 page token 後清回 NULL。
--   * rpc_upsert_fb_page 手動貼新 token 時也會清掉（20260701000010）。

ALTER TABLE fb_pages
  ADD COLUMN token_invalid_at  TIMESTAMPTZ,
  ADD COLUMN token_last_error  TEXT;

COMMENT ON COLUMN fb_pages.token_invalid_at IS
  '偵測到 token 失效的時間（FB error code 190 等）；換新 token 後清為 NULL';
COMMENT ON COLUMN fb_pages.token_last_error IS
  '最近一次 token 相關錯誤訊息（給 UI 顯示用）';
