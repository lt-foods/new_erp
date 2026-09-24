-- ============================================================================
-- 20260924060000_line_note_share_chat_mid.sql
--
-- 「分享貼文到聊天」要知道社群（s…）的主聊天室（m…）。LINE 把 getJoinedSquareChats 下架、
-- getJoinableSquareChats 又不列已加入的，現在只能從事件流撿 mid 再逐一 getSquareChat
-- （一次幾十個請求）。找到一次就記在社群列上，之後直接用；換了聊天室（分享回 code≠0）
-- 由 worker 清掉重找。
-- rollback：ALTER TABLE line_note_communities DROP COLUMN share_chat_mid;
-- ============================================================================
ALTER TABLE line_note_communities ADD COLUMN IF NOT EXISTS share_chat_mid TEXT;
COMMENT ON COLUMN line_note_communities.share_chat_mid IS
  '分享貼文用的聊天室 mid（社群的主聊天室）。worker 第一次找到就寫進來；NULL = 下次分享時再找。';
