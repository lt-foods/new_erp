-- ============================================================================
-- 20260909080000_line_note_close_on_comment.sql
--
-- 小幫手在記事本留言區宣布「結單」之後，這篇貼文就不再自動爬、不再自動加單。
--
-- 判定放在 worker（正則），結果落在 line_note_comments.is_closing_notice：
--   NULL  = 還沒判定（worker 讀到就判一次）
--   TRUE  = 是結單宣告
--   FALSE = 人工否決過（後台按「恢復讀取」）→ 永遠不會再被判成結單
-- 沒有這個三態的話，恢復讀取之後下一次讀留言會立刻再撞到同一則、又關掉。
--
-- 誤判的代價是「整團安靜地停止爬」，所以只認宣告句、問句不算，
-- 而且一定要留得下痕跡（closed_reason / closed_comment_id）+ 一鍵恢復
-- （rpc_line_note_post_reopen），不要讓店家只看到「已結束」三個字查不出原因。
--
-- ⚠ closed_comment_id 刻意**不加 FK** —— line_note_comments 已經有一條 FK 指向
--    line_note_posts，再加一條反向的會讓 PostgREST 的 embed 全部變 PGRST201
--    （見 CLAUDE.md「對已經被前端 embed 的表加第二支 FK」）。
--
-- 新欄位 + 一支新 RPC，沒有覆蓋既有 function。
-- rollback：
--   DROP FUNCTION public.rpc_line_note_post_reopen(BIGINT);
--   ALTER TABLE line_note_posts DROP COLUMN closed_at, DROP COLUMN closed_reason,
--                               DROP COLUMN closed_comment_id;
--   ALTER TABLE line_note_comments DROP COLUMN is_closing_notice;
-- ============================================================================

ALTER TABLE line_note_comments
  ADD COLUMN IF NOT EXISTS is_closing_notice BOOLEAN;
COMMENT ON COLUMN line_note_comments.is_closing_notice IS
  '這則是不是「結單」宣告。NULL=還沒判定，TRUE=是，FALSE=人工否決（不再重判）。';

ALTER TABLE line_note_posts
  ADD COLUMN IF NOT EXISTS closed_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS closed_reason     TEXT,
  ADD COLUMN IF NOT EXISTS closed_comment_id BIGINT;
COMMENT ON COLUMN line_note_posts.closed_reason IS
  '停止自動讀取的原因（結單那則留言的原文）。';
COMMENT ON COLUMN line_note_posts.closed_comment_id IS
  '判定為結單宣告的那則 line_note_comments.id（刻意不加 FK，避免 PostgREST embed 歧義）。';

-- ----------------------------------------------------------------------------
-- 恢復讀取：誤判時一鍵還原，並把那則留言標成「不是結單」，下次不會再關掉
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_post_reopen(p_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant  UUID := public._line_note_require_admin();
  v_comment BIGINT;
BEGIN
  SELECT closed_comment_id INTO v_comment
    FROM line_note_posts WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'post % not in tenant', p_id; END IF;

  -- 否決那則宣告：worker 只判 is_closing_notice IS NULL 的留言，FALSE 之後不再重判
  IF v_comment IS NOT NULL THEN
    UPDATE line_note_comments
       SET is_closing_notice = FALSE,
           status     = CASE WHEN status = 'ignored' THEN 'pending' ELSE status END,
           updated_at = NOW()
     WHERE id = v_comment AND tenant_id = v_tenant;
  END IF;

  UPDATE line_note_posts
     SET status = 'posted', closed_at = NULL, closed_reason = NULL, closed_comment_id = NULL,
         updated_at = NOW()
   WHERE id = p_id AND tenant_id = v_tenant AND status = 'closed';
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_post_reopen(BIGINT) TO authenticated;
