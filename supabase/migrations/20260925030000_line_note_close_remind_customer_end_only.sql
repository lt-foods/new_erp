-- ============================================================================
-- 20260925030000_line_note_close_remind_customer_end_only.sql
--
-- 結單留言 / 結單日提醒改成只看「客人收單」（customer_end_at）。
-- 之前用 COALESCE(customer_end_at, end_at)，客人收單沒填的團就拿店家收單當結單時間 ——
-- 9/25 早上提醒了鱸魚片、紅龍米漢堡，老闆說那是店家結單不是客人結單。
-- 客人收單沒填的團：不留言、不提醒（要的話到開團把客人收單填上）。
-- 提醒另外只認「開團中」的團（worker 執行當下也再確認一次，排進去之後被改成草稿就不發）。
--
-- 基底：_line_note_enqueue_due_closes @ 20260924070000、_line_note_enqueue_due_reminds @ 20260924080000。
-- rollback：還原那兩支。
-- ============================================================================
CREATE OR REPLACE FUNCTION public._line_note_enqueue_due_closes()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_n INT;
BEGIN
  WITH due AS (
    SELECT p.id AS post_id, p.tenant_id, p.community_id, c.account_id
      FROM line_note_posts p
      JOIN group_buy_campaigns g ON g.id = p.campaign_id
      JOIN line_note_communities c ON c.id = p.community_id
     WHERE p.status = 'posted' AND p.close_notified_at IS NULL AND p.line_post_id IS NOT NULL
       AND g.status = 'open'
       AND g.customer_end_at IS NOT NULL
       AND g.customer_end_at <= now()
       AND g.customer_end_at >= now() - INTERVAL '10 minutes'
       AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                        WHERE j.kind = 'close' AND j.post_id = p.id AND j.status IN ('queued', 'running'))
  ), ins AS (
    INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id)
    SELECT tenant_id, 'close', account_id, community_id, post_id FROM due
    RETURNING id
  )
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_enqueue_due_closes() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._line_note_enqueue_due_reminds()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_n     INT;
  v_today DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  WITH due AS (
    SELECT p.id AS post_id, p.tenant_id, p.community_id, c.account_id
      FROM line_note_posts p
      JOIN group_buy_campaigns g ON g.id = p.campaign_id
      JOIN line_note_communities c ON c.id = p.community_id
     WHERE p.status = 'posted' AND p.remind_shared_at IS NULL AND p.line_post_id IS NOT NULL
       AND c.remind_enabled AND c.remind_time ~ '^\d{1,2}:\d{2}$'
       AND g.status = 'open'
       AND g.customer_end_at IS NOT NULL
       AND (g.customer_end_at AT TIME ZONE 'Asia/Taipei')::date = v_today
       AND g.customer_end_at > now()
       AND ((v_today + c.remind_time::time) AT TIME ZONE 'Asia/Taipei') <= now()
       AND ((v_today + c.remind_time::time) AT TIME ZONE 'Asia/Taipei') >  now() - INTERVAL '10 minutes'
       AND NOT EXISTS (SELECT 1 FROM line_note_jobs j
                        WHERE j.kind = 'remind' AND j.post_id = p.id AND j.status IN ('queued', 'running'))
  ), ins AS (
    INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id)
    SELECT tenant_id, 'remind', account_id, community_id, post_id FROM due
    RETURNING id
  )
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_enqueue_due_reminds() FROM PUBLIC, anon, authenticated;
