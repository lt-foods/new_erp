-- ============================================================================
-- 20260924090000_line_note_react_wake_guard.sql
--
-- 笑臉補按的喚醒條件有個洞：某則留言怎麼按都失敗（客人刪了留言）、或社群把笑臉關掉，
-- 那些留言的 reacted_at 永遠是 NULL，_line_note_tick 就每分鐘把 worker 叫醒 7 天、什麼都按不到。
--
-- - line_note_comments.react_fail_count / react_failed_at：worker 每按失敗一次 +1，
--   到 3 次就寫 react_failed_at 放棄（LINE 擋次數那種整批失敗也會算到，頂多少一個笑臉）。
-- - 喚醒條件排除 react_failed_at 有值的，以及 react_on_confirm=false 的社群。
--
-- 基底：_line_note_tick @ 20260924080000（grep 過，最新）。
-- rollback：還原 20260924080000 的 _line_note_tick；兩個欄位留著無害。
-- ============================================================================

ALTER TABLE line_note_comments
  ADD COLUMN IF NOT EXISTS react_fail_count INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS react_failed_at  TIMESTAMPTZ;
COMMENT ON COLUMN line_note_comments.react_failed_at IS '按笑臉連續失敗 3 次後放棄的時間；有值就不再嘗試、也不再喚醒 worker（20260924090000）';

CREATE OR REPLACE FUNCTION public._line_note_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
  v_hhmm   TEXT := to_char(now() AT TIME ZONE 'Asia/Taipei', 'HH24:MI');
BEGIN
  BEGIN
    PERFORM public._line_note_release_scheduled();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'line-note-tick: 排程發文失敗：%', SQLERRM;
  END;
  BEGIN
    PERFORM public._line_note_enqueue_due_closes();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'line-note-tick: 排結單留言失敗：%', SQLERRM;
  END;
  BEGIN
    PERFORM public._line_note_enqueue_due_reminds();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'line-note-tick: 排結單提醒失敗：%', SQLERRM;
  END;

  -- 有事才叫 worker：排隊中的工作、讀取時間到、還有笑臉要補（只算按得到的：
  -- 沒放棄過、而且社群有開笑臉）
  IF NOT EXISTS (SELECT 1 FROM line_note_jobs WHERE status = 'queued')
     AND NOT EXISTS (SELECT 1 FROM line_note_communities
                      WHERE listen_enabled AND v_hhmm = ANY (read_times))
     AND NOT EXISTS (SELECT 1 FROM line_note_comments m
                      JOIN line_note_posts p ON p.id = m.post_id
                      JOIN line_note_communities c ON c.id = p.community_id
                      WHERE m.status = 'resolved'
                        AND m.reacted_at IS NULL AND m.react_failed_at IS NULL
                        AND m.line_comment_id IS NOT NULL
                        AND c.react_on_confirm
                        AND m.resolved_at >= now() - INTERVAL '1 hour')
     AND NOT EXISTS (SELECT 1 FROM line_note_comments m
                      JOIN line_note_posts p ON p.id = m.post_id
                      JOIN line_note_communities c ON c.id = p.community_id
                      WHERE m.status IN ('ordered', 'duplicate')
                        AND m.reacted_at IS NULL AND m.react_failed_at IS NULL
                        AND m.line_comment_id IS NOT NULL
                        AND c.react_on_confirm
                        AND m.commented_at >= now() - INTERVAL '7 days')
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
