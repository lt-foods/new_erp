-- ============================================================================
-- 20260909040000_line_note_tick_only_when_needed.sql
--
-- cron 還是每分鐘醒來（pg_cron 最小粒度就是分鐘，而且「立即讀取／發文」要能在
-- 一分鐘內被撿走），但**不要每分鐘都去打 Edge Function**。
--
-- 20260909010000 的守門只問「有沒有開監聽的社群」，只要有一個社群開著監聽就每分鐘
-- 打一次 —— 一天 1,440 次呼叫，其中絕大多數進去什麼都沒做就回來。
--
-- 改成兩個條件，符合其一才打：
--   1. line_note_jobs 有 queued（後台按了立即讀取／發文／載入社群，要馬上跑）
--   2. 現在這一分鐘（台北時間 HH:MM）正好是某個開監聽社群的 read_times
-- 松山社群設 08:00 / 12:00 / 18:00 / 23:59 → 一天 4 次，其餘時間只有按鈕才會打。
--
-- 基底：_line_note_tick @ 20260909010000（唯一前版，已 grep 確認）。cron job 不動。
-- rollback：還原 20260909010000 的 _line_note_tick()。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
  v_hhmm   TEXT := to_char(now() AT TIME ZONE 'Asia/Taipei', 'HH24:MI');
BEGIN
  -- 有事才做：排隊中的工作，或現在正好是某個社群設定的讀取時間
  IF NOT EXISTS (SELECT 1 FROM line_note_jobs WHERE status = 'queued')
     AND NOT EXISTS (SELECT 1 FROM line_note_communities
                      WHERE listen_enabled AND v_hhmm = ANY (read_times))
  THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_url    FROM vault.decrypted_secrets WHERE name = 'line_note_worker_url'  LIMIT 1;
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'line_note_cron_secret' LIMIT 1;
  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'line-note-tick: vault 缺 line_note_worker_url / line_note_cron_secret，略過';
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
