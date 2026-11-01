-- ============================================================================
-- 廠商群組：除了記事本，也讀聊天室（20261101000150）
--
-- 全富、中太、核果果這幾家不發記事本，新品直接丟在群組聊天室（圖＋文字）。
-- crawl job（line-note-worker jobCrawl）看到 crawl_chat = TRUE 就順便讀近 crawl_days 天的
-- 聊天訊息：同一個人連續發的圖＋文字（間隔 10 分鐘內）併成一篇，
-- line_post_id = 'chat:<第一則訊息 id>'，跟記事本貼文一樣走 rpc_line_note_market_ingest →
-- market-ai 拆品項 → 候選池。圖存 products 儲存桶 supplier-notes/<群組>/<貼文>/<n>.<副檔名>。
--
-- LINE 群組訊息預設端對端加密（Letter Sealing）。解密要用機器人登入時 LINE 交給它的
-- E2EE 私鑰 —— 以前登入用的是記憶體 storage，這把鑰匙跟著那次 invocation 一起蒸發。
-- 所以 line_note_accounts 加 e2ee_keys 存起來（只有 service_role 讀得到，表本來就沒開給
-- authenticated），之後每次建 client 先塞回 storage。**既有帳號要重新掃一次 QR 才拿得到鑰匙。**
--
-- 新欄位，沒有改既有函式本體。
-- rollback：
--   ALTER TABLE public.line_note_communities DROP COLUMN crawl_chat;
--   ALTER TABLE public.line_note_accounts DROP COLUMN e2ee_keys;
--   DELETE FROM community_product_candidates WHERE source_external_id LIKE 'ln:chat:%' AND owner_action = 'none';
--   DELETE FROM line_note_market_posts WHERE line_post_id LIKE 'chat:%';
-- ============================================================================

ALTER TABLE public.line_note_accounts
  ADD COLUMN IF NOT EXISTS e2ee_keys JSONB;
COMMENT ON COLUMN public.line_note_accounts.e2ee_keys IS
  'LINE 端對端加密金鑰（linejs storage 的 e2eeKeys:* 原樣存，{"e2eeKeys:<id>": "<json>"}）。讀加密的群組聊天用；只有 service_role 可讀';

ALTER TABLE public.line_note_communities
  ADD COLUMN IF NOT EXISTS crawl_chat BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN public.line_note_communities.crawl_chat IS
  '爬選品時也讀這個群組的聊天室訊息（廠商不發記事本、新品直接貼在聊天裡的群組）';

-- 先開這三家試讀（Alex 2026-11-01）：全富、中太、核果果
UPDATE public.line_note_communities
   SET crawl_chat = TRUE
 WHERE crawl_enabled
   AND home_id IN ('c860f458c94f2810136917739d8934323',   -- (團)全富＆包子媽
                   'cf6c9930ddfa62dbf538ceac2d883a25f',   -- 中太日本零食V.s包子媽
                   'c14250a30a83a264a34f9c540e2ce0d0a');  -- 包子媽/核果果家倫
