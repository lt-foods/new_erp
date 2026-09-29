-- ============================================================================
-- 20260929030000_line_note_reopen_on_campaign_reopen.sql
--
-- 團「關掉又打開」之後，LINE 記事本那篇就再也不動了。
--
-- 9/29 GRP-20260929-027（9/30 一碗家常瓜仔古早雞湯）：22:35 開團自動發 8 篇 →
-- 22:38 被手動關團 → trg_line_note_on_campaign_close（20260927040000）排 close，
-- 8 篇都留了「⏰ 本團已結單」、line_note_posts 標 closed → 22:39 又改回開團中。
-- 但沒有任何東西會把貼文救回來：
--   - _line_note_on_campaign_open 的 INSERT 撞 UNIQUE (community_id, campaign_id) → 不重發
--   - worker 只讀 status='posted' 的貼文 → 之後客人留的 +1 一則都不會變成訂單
--   - LINE 上掛著「本團已結單」，客人也不會再留
--
-- 做法：團從任何非 open 狀態變回 open 時（含 draft → open），
--   1. 被系統結單留言關掉的貼文（closed_reason = 那兩句系統字串）退回 posted、
--      清 close_notified_at / closed_at / closed_reason，蓋 reopened_at
--      → 之後照常讀留言；再次關團 / 客人收單時間到會再留一次結單。
--      小幫手自己留言宣布結單（closed_reason = 留言內容）、貼文被刪的 **不動**。
--   2. 排 kind='reopen' 工作：worker 先把貼文內容更新成最新（文字、圖片），再留言
--      「本團重新開放」，客人才知道可以繼續 +1。
-- worker 的 detectClosing 同批改成：reopened_at 之前的留言不再當結單宣告，
-- 否則系統自己那則「本團已結單」下次讀取就會被認成結單，又關回去。
--
-- 收單時間已過的團不救（同 _line_note_on_campaign_open 的時間守衛）。
--
-- 基底：line_note_jobs_kind_check @ 20260925040000（只多 'reopen'）。新 trigger，不改既有函式。
-- rollback：
--   DROP TRIGGER trg_line_note_on_campaign_reopen ON group_buy_campaigns;
--   DROP FUNCTION _line_note_on_campaign_reopen();
--   kind CHECK 還原 20260925040000；ALTER TABLE line_note_posts DROP COLUMN reopened_at;
-- ============================================================================

ALTER TABLE public.line_note_posts ADD COLUMN IF NOT EXISTS reopened_at TIMESTAMPTZ;
COMMENT ON COLUMN public.line_note_posts.reopened_at IS
  '團關掉又重新開團、系統把這篇退回 posted 的時間。之前的留言不再判成結單宣告（20260929030000）。';

ALTER TABLE public.line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE public.line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind', 'share', 'reopen'));

CREATE OR REPLACE FUNCTION public._line_note_on_campaign_reopen()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  IF NEW.status <> 'open' OR OLD.status = 'open' THEN RETURN NEW; END IF;
  IF (NEW.customer_end_at IS NOT NULL AND NEW.customer_end_at <= NOW())
     OR (NEW.end_at IS NOT NULL AND NEW.end_at <= NOW()) THEN
    RETURN NEW;
  END IF;

  WITH revived AS (
    UPDATE line_note_posts p
       SET status = 'posted', close_notified_at = NULL, closed_at = NULL, closed_reason = NULL,
           reopened_at = NOW(), updated_at = NOW()
     WHERE p.campaign_id = NEW.id
       AND p.status = 'closed'
       AND p.line_post_id IS NOT NULL
       AND p.closed_reason IN ('團已手動關閉，系統已留言結單', '客人收單時間到，系統已留言結單')
    RETURNING p.id, p.tenant_id, p.community_id
  )
  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
  SELECT r.tenant_id, 'reopen', c.account_id, r.community_id, r.id, NEW.updated_by
    FROM revived r
    JOIN line_note_communities c ON c.id = r.community_id;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_on_campaign_reopen() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_line_note_on_campaign_reopen ON public.group_buy_campaigns;
CREATE TRIGGER trg_line_note_on_campaign_reopen
  AFTER UPDATE OF status ON public.group_buy_campaigns
  FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_reopen();
