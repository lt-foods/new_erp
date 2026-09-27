-- ============================================================================
-- 20260927030000_line_note_post_recalled_status.sql
--
-- line_note_posts.status 多一個 'recalled'：「回收貼文」＝ LINE 上那篇刪掉、分享卡片收回，
-- 但後台紀錄留著（留言、已加的單都在），line_post_id 清空 → 這個社群可以直接再發一次
-- （rpc_line_note_campaign_targets 的 can_post 看「不是 posted 且沒有 line_post_id」，
-- rpc_line_note_queue_post(s) 的 ON CONFLICT 會把同一列覆寫成 queued，都不用改）。
-- 老闆 9/27：「發出也要可以回收」。跟「刪除貼文」的差別只在不清紀錄。
--
-- 其他地方一律只認 status='posted'（讀留言、節奏分享、結單留言、提醒），recalled 自然被排除；
-- worker discoverPosts 補認貼文 id 只認 posted/closed/failed，recalled 不會被舊列表接回去。
--
-- 基底：CHECK @ 20260924040000。
-- rollback：UPDATE line_note_posts SET status='failed' WHERE status='recalled'; 還原 CHECK。
-- ============================================================================
ALTER TABLE line_note_posts DROP CONSTRAINT IF EXISTS line_note_posts_status_check;
ALTER TABLE line_note_posts ADD CONSTRAINT line_note_posts_status_check
  CHECK (status IN ('scheduled', 'queued', 'posted', 'failed', 'closed', 'unlinked', 'recalled'));
COMMENT ON COLUMN line_note_posts.status IS
  'scheduled=等節奏 queued=排隊 posted=已發 failed=發文失敗 closed=已結束（不讀留言） unlinked=未認出團 recalled=已回收（LINE 上刪了、紀錄留著、可再發，20260927030000）';
