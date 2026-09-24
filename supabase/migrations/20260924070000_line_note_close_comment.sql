-- ============================================================================
-- 20260924070000_line_note_close_comment.sql
--
-- 客人收單時間到，機器人到記事本貼文底下留言「結單」，並把那篇標成已結束（停止自動加單）。
--
-- 時間：group_buy_campaigns.customer_end_at（客人收單），NULL 就用 end_at（店家收單）。
-- 流程：_line_note_tick 每分鐘跑 _line_note_enqueue_due_closes()：
--   status='posted'、有 line_post_id、還沒留過結單留言（close_notified_at IS NULL）、
--   客人收單時間已到（只補 10 分鐘內的；舊團不補 —— 9/24 上線時窗開 2 天，把 80 篇舊貼文全留了一次）→ 排一個 kind='close' 的工作。
--   worker 的 jobClose：先讀最後一輪留言（截止前的 +1 都收進來）→ 留言 → 標 closed。
-- 留言內容：line_note_communities.close_comment，留空用 worker 的預設。
--
-- rollback：還原 20260924050000 的 _line_note_tick；DROP FUNCTION _line_note_enqueue_due_closes；
--   line_note_jobs kind CHECK 拿掉 'close'；兩個新欄位留著無害。
-- ============================================================================

ALTER TABLE line_note_posts ADD COLUMN IF NOT EXISTS close_notified_at TIMESTAMPTZ;
COMMENT ON COLUMN line_note_posts.close_notified_at IS '機器人已在這篇底下留「結單」留言的時間（20260924070000）';

ALTER TABLE line_note_communities ADD COLUMN IF NOT EXISTS close_comment TEXT;
COMMENT ON COLUMN line_note_communities.close_comment IS '客人收單時間到時機器人留的結單留言；NULL = 用預設文字';

ALTER TABLE line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close'));

CREATE INDEX IF NOT EXISTS idx_line_note_posts_close_due
  ON line_note_posts (campaign_id) WHERE status = 'posted' AND close_notified_at IS NULL;

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
       AND COALESCE(g.customer_end_at, g.end_at) <= now()
       AND COALESCE(g.customer_end_at, g.end_at) >= now() - INTERVAL '10 minutes'
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

CREATE OR REPLACE FUNCTION public.rpc_line_note_community_set_close_comment(p_id BIGINT, p_text TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
BEGIN
  UPDATE line_note_communities SET close_comment = NULLIF(TRIM(p_text), '')
   WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_set_close_comment(BIGINT, TEXT) TO authenticated;

-- tick：基底 20260924040000（同一天、只有那一支動過），多一行排結單工作。
CREATE OR REPLACE FUNCTION public._line_note_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
  v_hhmm   TEXT := to_char(now() AT TIME ZONE 'Asia/Taipei', 'HH24:MI');
BEGIN
  -- 排程發文：到了時段就把該發的轉成 queued 工作（一分鐘一篇），下面的守門就會看到
  BEGIN
    PERFORM public._line_note_release_scheduled();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'line-note-tick: 排程發文失敗：%', SQLERRM;
  END;
  -- 客人收單時間到：排「結單留言」工作
  BEGIN
    PERFORM public._line_note_enqueue_due_closes();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'line-note-tick: 排結單留言失敗：%', SQLERRM;
  END;

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
