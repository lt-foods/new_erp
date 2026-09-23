-- ============================================================================
-- 20260923120000_line_note_tick_wake_for_ordered_react.sql
--
-- 機器人加單成功的笑臉原本只在 read job（一天 read_times 那幾輪）讀完留言時順手按，
-- LINE 一輪最多讓按 30 則 → 平鎮社群一週積欠 634 則沒按（2026-09-23 回報
-- GRP-20260922-010-0058「機器人加單怎麼沒有按笑臉」）。
-- worker 加了每分鐘補按（reactOrdered，每 tick 最多 10 則），但 worker 要被叫醒才會跑：
-- 這裡加第四個喚醒條件「7 天內 ordered/duplicate 還沒按笑臉」，窗與 worker 的
-- PENDING_WINDOW_MS 一致。
--
-- 已知：某則怎麼按都失敗（留言被刪之類）會讓 worker 每分鐘醒來直到它掉出 7 天窗；
-- 一次 tick 無事可做約 1 秒，可以接受。
--
-- 基底：_line_note_tick @ 20260922010000（已 grep 確認最新，且與線上 pg_get_functiondef 相同）。
-- rollback：還原 20260922010000 的 _line_note_tick()，並
--           DROP INDEX IF EXISTS idx_line_note_comments_ordered_unreacted;
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_line_note_comments_ordered_unreacted
  ON line_note_comments (commented_at DESC)
  WHERE reacted_at IS NULL AND status IN ('ordered', 'duplicate') AND line_comment_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public._line_note_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
  v_hhmm   TEXT := to_char(now() AT TIME ZONE 'Asia/Taipei', 'HH24:MI');
BEGIN
  -- 有事才做：排隊中的工作、現在正好是某個社群設定的讀取時間，
  -- 或是剛剛有人按「已解決」而那則留言還沒按過笑臉、或 7 天內加單成功的留言還沒按過笑臉
  IF NOT EXISTS (SELECT 1 FROM line_note_jobs WHERE status = 'queued')
     AND NOT EXISTS (SELECT 1 FROM line_note_communities
                      WHERE listen_enabled AND v_hhmm = ANY (read_times))
     AND NOT EXISTS (SELECT 1 FROM line_note_comments
                      WHERE status = 'resolved'
                        AND reacted_at IS NULL
                        AND line_comment_id IS NOT NULL
                        AND resolved_at >= now() - INTERVAL '1 hour')
     AND NOT EXISTS (SELECT 1 FROM line_note_comments
                      WHERE status IN ('ordered', 'duplicate')
                        AND reacted_at IS NULL
                        AND line_comment_id IS NOT NULL
                        AND commented_at >= now() - INTERVAL '7 days')
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
