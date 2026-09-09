-- ============================================================================
-- 20260909060000_line_note_comment_reaction.sql
--
-- 機器人處理完的留言，回頭在 LINE 記事本那則留言上按一個「笑臉」，
-- 讓客人知道「你的 +1 我收到了」。
--
-- likeType 1003 = 笑（LINE 的表情：1001 讚 / 1002 愛心 / 1003 笑 / 1004 驚 / 1005 哭 / 1006 怒），
-- 走 POST /<prefix>/api/v57/like/create.json（prefix 群組 /mh、社群 /sn，跟讀留言同一套探測）。
--
-- 只對「確定收到單」的留言按：ordered（加成單）、duplicate（本來就有單）、
-- resolved（小幫手自己處理掉）。unmatched / error 不按 —— 那些還沒處理完，
-- 按了等於跟客人說收到了，客人就不會再來問。
--
-- reacted_at 記已經按過的，避免每次讀留言都重按一次。
-- react_on_confirm 是社群層級的開關（預設開），要關掉不用改程式。
--
-- 全部是新欄位，沒有覆蓋既有 function。
-- rollback：
--   ALTER TABLE line_note_comments DROP COLUMN reacted_at;
--   ALTER TABLE line_note_communities DROP COLUMN react_on_confirm;
-- ============================================================================

ALTER TABLE line_note_comments
  ADD COLUMN IF NOT EXISTS reacted_at TIMESTAMPTZ;
COMMENT ON COLUMN line_note_comments.reacted_at IS
  '已經在 LINE 記事本那則留言上按過表情的時間。NULL = 還沒按。';

CREATE INDEX IF NOT EXISTS idx_line_note_comments_to_react
  ON line_note_comments (post_id)
  WHERE reacted_at IS NULL AND status IN ('ordered','duplicate','resolved');

ALTER TABLE line_note_communities
  ADD COLUMN IF NOT EXISTS react_on_confirm BOOLEAN NOT NULL DEFAULT TRUE;
COMMENT ON COLUMN line_note_communities.react_on_confirm IS
  '處理完的留言要不要在 LINE 上按笑臉回覆客人（預設開）。';
