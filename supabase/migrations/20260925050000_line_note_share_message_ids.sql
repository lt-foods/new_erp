-- ============================================================================
-- 20260925050000_line_note_share_message_ids.sql
--
-- 分享到聊天室的那則訊息要記下來，刪貼文時一併收回（老闆 9/25：「刪除貼文也要加上回收分享」）。
-- sendPostToTalk 的回應沒有訊息 id，worker 分享完馬上 getSquareChat 讀 lastMessage
-- （POSTNOTIFICATION、postEndUrl 帶 postId 對得上才算），記進 share_message_ids。
-- rollback：ALTER TABLE line_note_posts DROP COLUMN share_message_ids; DROP FUNCTION _line_note_append_share_msg;
-- ============================================================================
ALTER TABLE line_note_posts ADD COLUMN IF NOT EXISTS share_message_ids JSONB NOT NULL DEFAULT '[]'::jsonb;
COMMENT ON COLUMN line_note_posts.share_message_ids IS
  '分享到聊天室的訊息 [{chat, id, at}]，刪貼文時逐一收回（unsendMessage）。分享前的舊資料是空的、收不回。';

CREATE OR REPLACE FUNCTION public._line_note_append_share_msg(p_post_id BIGINT, p_chat TEXT, p_msg TEXT)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER
AS $$
  UPDATE line_note_posts
     SET share_message_ids = share_message_ids
       || jsonb_build_array(jsonb_build_object('chat', p_chat, 'id', p_msg, 'at', now()))
   WHERE id = p_post_id AND p_msg IS NOT NULL
     AND NOT (share_message_ids @> jsonb_build_array(jsonb_build_object('id', p_msg)));
$$;
REVOKE ALL ON FUNCTION public._line_note_append_share_msg(BIGINT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
