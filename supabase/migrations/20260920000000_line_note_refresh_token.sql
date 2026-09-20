-- ─────────────────────────────────────────────────────────────────────────────
-- LINE 記事本：把 refresh token 一起存下來（不存＝每 7 天就要人重新掃一次 QR）
--
-- 症狀：小幫手帳號每隔 7 天整組停擺，last_error 是
--   Request internal failed, getProfile(/S4) ->
--   {"code":"MUST_REFRESH_V3_TOKEN","reason":"Access token refresh required"}
-- 線上那把 token 的 claims：iat 2026-09-12 14:09、exp 2026-09-19 14:09（＝**整整 7 天**）、
-- rexp 2027-09-12（refresh token 一年）。最後一筆成功的 read 是 9/19 14:00，
-- 也就是 access token 過期前 9 分鐘 —— 不是壞掉，是到期。
--
-- 原因：linejs 自己就會處理 MUST_REFRESH_V3_TOKEN（request/mod.ts 攔下來 →
-- auth.tryRefreshToken() → 原請求重送），但**前提是 storage 裡有 refreshToken**。
-- Edge Function 版用的是 MemoryStorage，而 DB 只存了 access token，
-- 掃 QR 當下拿到的 refresh token 隨著那次 invocation 一起蒸發 → 永遠 refresh 不了，
-- 只能靠人重新掃 QR。（tools/line-note-scraper 那支用 FileStorage，所以沒這個問題。）
--
-- 這支只加欄位；寫入與使用在 supabase/functions/{_shared/lineNote.ts,line-note-worker}。
-- 兩個欄位都是秘密，跟 auth_token 一樣不進 v_line_note_accounts。
--
-- rollback:
--   ALTER TABLE line_note_accounts DROP COLUMN refresh_token, DROP COLUMN token_expire;
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE line_note_accounts
  ADD COLUMN IF NOT EXISTS refresh_token TEXT,   -- 秘密：linejs storage 的 refreshToken（LINE 會輪替，換了要寫回來）
  ADD COLUMN IF NOT EXISTS token_expire  BIGINT; -- access token 到期的 epoch 秒（linejs storage 的 expire，純參考）

COMMENT ON COLUMN line_note_accounts.refresh_token IS
  'linejs storage 的 refreshToken。access token 7 天到期時靠它換新的；沒有它就只能重新掃 QR。LINE 會輪替，refresh 後要寫回來。';
COMMENT ON COLUMN line_note_accounts.token_expire IS
  'access token 到期時間（epoch 秒）。只做觀察用，linejs 是等 MUST_REFRESH_V3_TOKEN 才換。';
