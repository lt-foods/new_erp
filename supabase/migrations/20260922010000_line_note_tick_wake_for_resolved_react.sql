-- ============================================================================
-- 20260922010000_line_note_tick_wake_for_resolved_react.sql
--
-- 小幫手在後台按「已解決」之後，客人那則留言要收到笑臉（worker 的 reactResolved）。
-- 問題是 worker 根本不會醒來：_line_note_tick 的守門是「有 queued 的工作」或
-- 「現在正好是某個社群的 read_times」，而按「已解決」兩者都不成立 —— 2026-09-22
-- 部署 worker 之後實測，線上 33 則待補的笑臉連續好幾分鐘一則都沒按，就是卡在這裡
-- （cron.job_run_details 每分鐘都 succeeded，但 _line_note_tick 自己 RETURN 了，
--  根本沒打 Edge Function）。
--
-- 所以加第三個喚醒條件：最近一小時有人按「已解決」而那則還沒按過笑臉。
--
-- 為什麼喚醒窗（1 小時）比 worker 的補按窗（24 小時）窄：
--   - 喚醒條件問的是「剛剛有沒有人動作」，醒來之後 worker 自己會把 24 小時內
--     所有待補的一起清掉，所以窄窗不會讓舊的補不到。
--   - 萬一某則怎麼按都失敗（客人把留言刪了之類），寬窗會讓 worker 為了它每分鐘
--     醒來整整一天。窄窗把這種空轉壓在一小時內。
--
-- 前端按「已解決」時也會順手 kickWorker()（走使用者 JWT），那條路只對總部角色有效
-- （Edge Function 對分店帳號回 401），cron 這條是所有人都適用的那一半。
--
-- 基底：_line_note_tick @ 20260909040000（已 grep supabase/migrations/ 確認是最新的一支，
--       且與線上 pg_get_functiondef 逐字相同）。cron job 本身不動。
-- rollback：還原 20260909040000 的 _line_note_tick()，並
--           DROP INDEX IF EXISTS idx_line_note_comments_resolved_unreacted;
-- ============================================================================

-- 每分鐘要問一次的條件，給它自己的部分索引（母體＝還沒按笑臉的已解決留言，線上個位數～數十筆）。
-- worker 裡 reactResolved 的那句 SELECT（同樣的條件 + ORDER BY resolved_at DESC）也吃這支。
CREATE INDEX IF NOT EXISTS idx_line_note_comments_resolved_unreacted
  ON line_note_comments (resolved_at DESC)
  WHERE reacted_at IS NULL AND status = 'resolved' AND line_comment_id IS NOT NULL;

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
  -- 或是剛剛有人按「已解決」而那則留言還沒按過笑臉
  IF NOT EXISTS (SELECT 1 FROM line_note_jobs WHERE status = 'queued')
     AND NOT EXISTS (SELECT 1 FROM line_note_communities
                      WHERE listen_enabled AND v_hhmm = ANY (read_times))
     AND NOT EXISTS (SELECT 1 FROM line_note_comments
                      WHERE status = 'resolved'
                        AND reacted_at IS NULL
                        AND line_comment_id IS NOT NULL
                        AND resolved_at >= now() - INTERVAL '1 hour')
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
