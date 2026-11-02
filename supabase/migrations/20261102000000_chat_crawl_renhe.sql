-- ============================================================================
-- 廠商群組聊天室：只開「人和食緣」（20261102000000）
--
-- 20261101000210 把聊天室讀取全部關掉。小幫手99號 11/2 重新登入、存下 E2EE 金鑰後，
-- 試讀了記事本 14 天內沒有新貼文的 5 群，聊天訊息全部解得開：
--   人和食緣    59 則，有新品文案（豆豉小魚豆乾、眷村酸豆角肉燥）← Alex：開這群
--   核果果家倫  46 則，有新品文案，也有很多叫貨／對帳
--   全富 / 中太 / 囍願蛋團：多半是對帳、匯款、問價、叫貨數量
-- 其他群維持只讀記事本。要再開別群：UPDATE ... SET crawl_chat = TRUE WHERE home_id = '…';
-- rollback：UPDATE public.line_note_communities SET crawl_chat = FALSE WHERE home_id = 'c8b6b120c57571354ae574ceedaafe2d0';
-- ============================================================================
UPDATE public.line_note_communities
   SET crawl_chat = TRUE
 WHERE crawl_enabled AND home_id = 'c8b6b120c57571354ae574ceedaafe2d0';  -- 人和食緣x包子媽vi
