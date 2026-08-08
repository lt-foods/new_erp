-- ============================================================================
-- 2026-08-08: account link 邀請的冷卻欄位
--
-- 顧客傳訊息給店家 OA 而我們還不知道他是誰時，自動回一則「查看我的訂單」，
-- 那條連結會帶著 linkToken 走完 account link，把該店 provider 的 ID 跟會員綁起來。
--
-- 為什麼要冷卻：不擋的話顧客每傳一句話就收到一則機器訊息，會蓋掉正常對話。
-- 記下上次邀請時間，同一個人一段時間內只邀一次。
--
-- 註：回覆訊息（replyToken）不吃推播額度，所以這個機制本身零成本。
-- ============================================================================

ALTER TABLE store_line_followers
  ADD COLUMN IF NOT EXISTS link_invited_at TIMESTAMPTZ;

COMMENT ON COLUMN store_line_followers.link_invited_at IS
  '上次自動發出 account link 邀請的時間；用來做冷卻，避免每則訊息都回一次';
