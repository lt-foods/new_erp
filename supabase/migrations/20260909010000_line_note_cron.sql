-- ============================================================================
-- 20260909010000_line_note_cron.sql
--
-- LINE 記事本 worker 改成排程：pg_cron 每分鐘打一次 Edge Function `line-note-worker`
-- （action=tick），它會到 read_times 排讀留言、撿 line_note_jobs 裡的工作跑完就結束。
-- 不再需要 tools/line-note-scraper 那支常駐 worker。
--
-- 需要兩個 vault 秘密（不進 migration，套完後另外跑一次）：
--   SELECT vault.create_secret('https://<ref>.functions.supabase.co/line-note-worker', 'line_note_worker_url');
--   SELECT vault.create_secret('<隨機字串>', 'line_note_cron_secret');
--   -- 同一個隨機字串也要設成 Edge Function 的 secret LINE_NOTE_CRON_SECRET
-- 兩個沒設好的話 _line_note_tick() 只 RAISE NOTICE 不做事，cron 不會炸。
--
-- rollback：
--   SELECT cron.unschedule('line-note-tick');
--   DROP FUNCTION public._line_note_tick();
--   （pg_net 留著無妨）
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public._line_note_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO v_url    FROM vault.decrypted_secrets WHERE name = 'line_note_worker_url'  LIMIT 1;
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'line_note_cron_secret' LIMIT 1;
  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'line-note-tick: vault 缺 line_note_worker_url / line_note_cron_secret，略過';
    RETURN;
  END IF;

  -- 只有排隊中的工作、或有社群開監聽時才打，省 Edge Function 呼叫數
  IF NOT EXISTS (SELECT 1 FROM line_note_jobs WHERE status = 'queued')
     AND NOT EXISTS (SELECT 1 FROM line_note_communities WHERE listen_enabled) THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-line-note-secret', v_secret),
    body    := '{"action":"tick"}'::jsonb,
    timeout_milliseconds := 120000
  );
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_tick() FROM PUBLIC, anon, authenticated;

-- cron.schedule 同名 job 為 idempotent，重複 run migration 不會炸
SELECT cron.schedule('line-note-tick', '* * * * *', $cron$ SELECT public._line_note_tick(); $cron$);
