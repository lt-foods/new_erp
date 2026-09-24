-- ============================================================================
-- 20260924080000_line_note_close_day_remind.sql
--
-- 結單當天早上，機器人把「今天要結單」的貼文再分享到聊天室一次提醒大家；
-- 分享前可先發一段文字（社群自訂，例：「好鄰居們早安‼ 再看一眼今日結單商品喔～」），
-- 一天只發一次，接著每篇貼文各一張分享卡片。
--
-- 時間：每個社群自己的 remind_time（台北，預設 08:00）。
-- 母體：status='posted'、有 line_post_id、還沒提醒過（remind_shared_at IS NULL）、
--   客人收單時間（無則店家收單）的台北日期 = 今天、而且收單時間在提醒時間之後
--   （已經結單的不提醒）。只補 10 分鐘內的（同 20260924070000 的教訓，舊團不補）。
-- rollback：還原 20260924070000 的 _line_note_tick；DROP FUNCTION _line_note_enqueue_due_reminds,
--   rpc_line_note_community_set_remind；jobs kind CHECK 拿掉 'remind'；新欄位留著無害。
-- ============================================================================

ALTER TABLE line_note_posts ADD COLUMN IF NOT EXISTS remind_shared_at TIMESTAMPTZ;
ALTER TABLE line_note_communities
  ADD COLUMN IF NOT EXISTS remind_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS remind_time     TEXT NOT NULL DEFAULT '08:00',
  ADD COLUMN IF NOT EXISTS remind_message  TEXT,
  ADD COLUMN IF NOT EXISTS remind_message_sent_on DATE;
COMMENT ON COLUMN line_note_communities.remind_time IS '結單當天幾點把今天結單的貼文再分享到聊天室（台北 HH:MM）';
COMMENT ON COLUMN line_note_communities.remind_message IS '分享前先發的文字（一天一次）；NULL = 用 worker 的預設文字（DEFAULT_REMIND_MESSAGE）';

ALTER TABLE line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind'));

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
       AND (COALESCE(g.customer_end_at, g.end_at) AT TIME ZONE 'Asia/Taipei')::date = v_today
       AND COALESCE(g.customer_end_at, g.end_at) > now()
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

CREATE OR REPLACE FUNCTION public.rpc_line_note_community_set_remind(
  p_id BIGINT, p_enabled BOOLEAN, p_time TEXT, p_message TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  IF NOT (COALESCE(p_time, '') ~ '^([01]?\d|2[0-3]):[0-5]\d$') THEN
    RAISE EXCEPTION '提醒時間要是 HH:MM（收到 %）', p_time;
  END IF;
  UPDATE line_note_communities
     SET remind_enabled = COALESCE(p_enabled, TRUE), remind_time = p_time,
         remind_message = NULLIF(TRIM(p_message), '')
   WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_set_remind(BIGINT, BOOLEAN, TEXT, TEXT) TO authenticated;

-- tick：基底 20260924070000，多排一種工作。
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
  -- 結單當天早上：再分享一次提醒
  BEGIN
    PERFORM public._line_note_enqueue_due_reminds();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'line-note-tick: 排結單提醒失敗：%', SQLERRM;
  END;

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
