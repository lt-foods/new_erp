-- ============================================================================
-- 20260929040000_line_note_refresh_on_deadline_change.sql
--
-- 手機團控改了結單時間，LINE 記事本那篇還寫著舊的時間。
--
-- 9/29 GRP-20260929-036（東興 Q 梅）：23:26 開團自動發文「⏰ 9/30 08:00 結單」，
-- 23:32 小幫手在手機團控（rpc_quick_update_campaign_control）把 end_at 延兩次到 10/2 08:00，
-- 8 篇貼文一個字都沒變 —— 更新貼文只有後台「更新貼文」按鈕（worker action=update_post），
-- 團控那條路從來不會碰記事本。
--
-- 做法：開團中的團，貼文上印的結單時間（LEAST(customer_end_at, end_at)，同 lineNoteRender
-- 的 closeAt）變了 → 替每篇已發的貼文排 kind='refresh'，worker 呼叫同一支 updatePost
-- （文字重算、圖片重傳，line_post_id 不變、留言與已加的單不受影響）。
-- 子群的分享列（share_from_community_id）不排：貼文本體在母社群那列。
-- 同一篇已經有排隊中的 refresh 就不再排（團控連按兩次只更新一次）。
-- 關團 / 重開不在這裡處理（20260927040000 / 20260929030000）。
--
-- 基底：line_note_jobs_kind_check @ 20260929030000（只多 'refresh'）。新 trigger，不改既有函式。
-- rollback：
--   DROP TRIGGER trg_line_note_on_campaign_deadline ON group_buy_campaigns;
--   DROP FUNCTION _line_note_on_campaign_deadline();
--   kind CHECK 還原 20260929030000。
-- ============================================================================

ALTER TABLE public.line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE public.line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind', 'share', 'reopen', 'refresh'));

CREATE OR REPLACE FUNCTION public._line_note_on_campaign_deadline()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  IF NEW.status <> 'open' OR OLD.status <> 'open' THEN RETURN NEW; END IF;
  IF LEAST(NEW.customer_end_at, NEW.end_at) IS NOT DISTINCT FROM LEAST(OLD.customer_end_at, OLD.end_at) THEN
    RETURN NEW;
  END IF;

  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
  SELECT p.tenant_id, 'refresh', c.account_id, p.community_id, p.id, NEW.updated_by
    FROM line_note_posts p
    JOIN line_note_communities c ON c.id = p.community_id
   WHERE p.campaign_id = NEW.id
     AND p.status = 'posted' AND p.line_post_id IS NOT NULL
     AND c.share_from_community_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                      WHERE j.kind = 'refresh' AND j.post_id = p.id AND j.status = 'queued');
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_on_campaign_deadline() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_line_note_on_campaign_deadline ON public.group_buy_campaigns;
CREATE TRIGGER trg_line_note_on_campaign_deadline
  AFTER UPDATE OF end_at, customer_end_at ON public.group_buy_campaigns
  FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_deadline();
