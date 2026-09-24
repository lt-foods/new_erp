-- ============================================================================
-- 20260924040000_line_note_scheduled_posting.sql
--
-- 開團時間到自動開團 + 每個社群依自己的時段分批發記事本文
--
-- 1. 排定開團（group_buy_campaigns.auto_open）
--    草稿團勾「到開團時間自動開團」→ pg_cron 每分鐘 rpc_auto_open_scheduled_campaigns()
--    把 start_at 已到的草稿切成 open。開團的副作用（鎖價、LINE 自動發文）本來就掛在
--    status 的 AFTER UPDATE trigger 上，所以純 UPDATE 就夠，不用另外呼叫什麼。
--    驗證比照 CampaignForm 手動開團那兩條（至少一個品項、商品都已上架），不過就不開、
--    把原因寫進 auto_open_error，勾選保留（店家補好商品下一分鐘就會開）。
--    美食列車不自動開：它的「開團推播」在前端（broadcastFoodTrainOpen），cron 打不到。
--
-- 2. 社群發文排程（line_note_communities.post_mode）
--    immediate  開團當下全部排隊（= 原本的行為，預設值）
--    slots      post_slots = [{"at":"10:00","pct":50},{"at":"15:00","pct":100}]
--               每個時段到了，發「排隊中還沒發的」的 pct%（四捨五入、至少 1 篇）
--               「一次全發」= 只設一個 100% 的時段
--    interval   從 post_window_start 起每 post_every_hours 小時（到 post_window_end 為止）
--               發 post_every_pct%。實作上就是把它展開成 slots，走同一套。
--    開團時 trigger 對非 immediate 的社群只建 status='scheduled' 的貼文、不建工作；
--    _line_note_tick 每分鐘先跑 _line_note_release_scheduled()：
--      a. 到了時段 → post_release_budget = 本時段要發的篇數
--      b. 有額度的社群一分鐘放一篇（→ queued + post 工作），所以篇與篇之間隔 1 分鐘
--    團已經不是 open（結單／取消）的排程貼文直接刪掉；社群關掉自動發文也刪掉排程。
--    後台手動「發文」遇到 scheduled 列會照常覆寫成 queued（rpc_line_note_queue_post(s)
--    的 ON CONFLICT DO UPDATE），等於插隊，不用改那兩支。
--
--    錯過的時段只補 30 分鐘內的（cron 停了一陣子、或剛存設定時不要把早上的時段補發）。
--
-- 基底：
--   _line_note_on_campaign_open @ 20260921020000（grep 過，最新）
--   _line_note_tick @ 線上 pg_get_functiondef（比 repo 最新的 20260922010000 多一個
--     「7 天內加單成功還沒按笑臉」的喚醒條件 —— 那段直接套上線、沒回寫 repo；這裡照線上抄）
--   line_note_posts.status CHECK @ 20260908010000
-- rollback：
--   還原 20260921020000 的 _line_note_on_campaign_open、線上版 _line_note_tick；
--   SELECT cron.unschedule('auto-open-scheduled-campaigns');
--   DELETE FROM line_note_posts WHERE status='scheduled'; 還原 status CHECK；
--   DROP FUNCTION _line_note_release_scheduled, _line_note_due_slot_pct,
--     rpc_line_note_community_set_schedule, rpc_set_campaign_auto_open,
--     rpc_auto_open_scheduled_campaigns；新增欄位留著無害。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 欄位
-- ----------------------------------------------------------------------------
ALTER TABLE group_buy_campaigns
  ADD COLUMN IF NOT EXISTS auto_open       BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS auto_open_error TEXT;
COMMENT ON COLUMN group_buy_campaigns.auto_open IS
  '草稿團：start_at 到了由 cron 自動切成 open（rpc_auto_open_scheduled_campaigns）。開成功後清掉。';

ALTER TABLE line_note_communities
  ADD COLUMN IF NOT EXISTS post_mode           TEXT NOT NULL DEFAULT 'immediate',
  ADD COLUMN IF NOT EXISTS post_slots          JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS post_every_hours    INT NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS post_every_pct      INT NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS post_window_start   TEXT NOT NULL DEFAULT '09:00',
  ADD COLUMN IF NOT EXISTS post_window_end     TEXT NOT NULL DEFAULT '21:00',
  ADD COLUMN IF NOT EXISTS post_last_slot_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS post_release_budget INT NOT NULL DEFAULT 0;

DO $$ BEGIN
  ALTER TABLE line_note_communities ADD CONSTRAINT line_note_communities_post_mode_chk
    CHECK (post_mode IN ('immediate', 'slots', 'interval'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE line_note_communities ADD CONSTRAINT line_note_communities_post_every_chk
    CHECK (post_every_hours BETWEEN 1 AND 24 AND post_every_pct BETWEEN 1 AND 100);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON COLUMN line_note_communities.post_mode IS
  'immediate=開團當下全發 / slots=post_slots 各時段發 pct% / interval=視窗內每 N 小時發 pct%（20260924040000）';

ALTER TABLE line_note_posts DROP CONSTRAINT IF EXISTS line_note_posts_status_check;
ALTER TABLE line_note_posts ADD CONSTRAINT line_note_posts_status_check
  CHECK (status IN ('scheduled', 'queued', 'posted', 'failed', 'closed', 'unlinked'));

CREATE INDEX IF NOT EXISTS idx_line_note_posts_scheduled
  ON line_note_posts (community_id, created_at, id) WHERE status = 'scheduled';

-- ----------------------------------------------------------------------------
-- 2. 排定開團
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_campaign_auto_open(p_id BIGINT, p_auto_open BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_owner  BIGINT;
  v_status TEXT;
BEGIN
  SELECT owner_store_id, status INTO v_owner, v_status
    FROM group_buy_campaigns WHERE id = p_id AND tenant_id = v_tenant;
  IF v_status IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_id; END IF;
  -- 同 rpc_upsert_campaign：自開團只能改自己店的
  IF v_owner IS NOT NULL THEN PERFORM public._assert_own_store(v_owner); END IF;

  UPDATE group_buy_campaigns
     SET auto_open = COALESCE(p_auto_open, FALSE) AND v_status = 'draft',
         auto_open_error = NULL
   WHERE id = p_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_set_campaign_auto_open(BIGINT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_auto_open_scheduled_campaigns()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r        RECORD;
  v_err    TEXT;
  v_opened INT := 0;
BEGIN
  FOR r IN
    SELECT id, close_type FROM group_buy_campaigns
     WHERE status = 'draft' AND auto_open AND start_at IS NOT NULL AND start_at <= NOW()
     ORDER BY start_at, id
  LOOP
    v_err := NULL;
    IF r.close_type = 'food_train' THEN
      v_err := '美食列車要手動開團（開團時要推播給客人）';
    ELSIF NOT EXISTS (SELECT 1 FROM campaign_items WHERE campaign_id = r.id) THEN
      v_err := '沒有任何商品，無法自動開團';
    ELSE
      SELECT '下列商品尚未上架，無法自動開團：'
             || string_agg(DISTINCT p.product_code || ' ' || p.name, '、')
        INTO v_err
        FROM campaign_items ci
        JOIN skus s     ON s.id = ci.sku_id
        JOIN products p ON p.id = s.product_id
       WHERE ci.campaign_id = r.id AND p.status <> 'active'
      HAVING count(*) > 0;
    END IF;

    IF v_err IS NOT NULL THEN
      UPDATE group_buy_campaigns SET auto_open_error = v_err
       WHERE id = r.id AND auto_open_error IS DISTINCT FROM v_err;
      CONTINUE;
    END IF;

    BEGIN
      UPDATE group_buy_campaigns
         SET status = 'open', auto_open = FALSE, auto_open_error = NULL
       WHERE id = r.id AND status = 'draft';
      v_opened := v_opened + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE group_buy_campaigns SET auto_open_error = left('自動開團失敗：' || SQLERRM, 500)
       WHERE id = r.id;
    END;
  END LOOP;
  RETURN v_opened;
END;
$$;
REVOKE ALL ON FUNCTION public.rpc_auto_open_scheduled_campaigns() FROM PUBLIC, anon, authenticated;

DO $$ BEGIN
  PERFORM cron.unschedule('auto-open-scheduled-campaigns');
EXCEPTION WHEN OTHERS THEN NULL; END $$;
SELECT cron.schedule('auto-open-scheduled-campaigns', '* * * * *',
  $cron$ SELECT public.rpc_auto_open_scheduled_campaigns(); $cron$);

-- ----------------------------------------------------------------------------
-- 3. 開團自動發文：非 immediate 的社群只排程、不建工作
--    基底 20260921020000，只多 post_mode 分支。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_on_campaign_open()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c RECORD;
  v_post BIGINT;
BEGIN
  IF NEW.status <> 'open' OR OLD.status = 'open' THEN RETURN NEW; END IF;
  FOR v_c IN
    SELECT c.id AS community_id, c.account_id, c.post_mode
      FROM line_note_communities c
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
     WHERE c.tenant_id = NEW.tenant_id
       AND c.auto_post_on_open
       AND (NEW.owner_store_id IS NULL OR c.store_id = NEW.owner_store_id)
       AND public._line_note_takes_channel(c.sales_channels, NEW.sales_channel)
  LOOP
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id,
            CASE WHEN v_c.post_mode = 'immediate' THEN 'queued' ELSE 'scheduled' END,
            NEW.updated_by, NEW.updated_by)
    ON CONFLICT (community_id, campaign_id) DO NOTHING
    RETURNING id INTO v_post;
    IF v_post IS NOT NULL AND v_c.post_mode = 'immediate' THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (NEW.tenant_id, 'post', v_c.account_id, v_c.community_id, v_post, NEW.updated_by);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. 排程
-- ----------------------------------------------------------------------------
-- 這個社群「現在」該觸發的時段：回 (時段時間, pct)，沒有就回 0 列。
-- 只認今天（台北）已經到了、比上次觸發晚、而且 30 分鐘內的時段，取最晚那個。
CREATE OR REPLACE FUNCTION public._line_note_due_slot(p_community_id BIGINT)
RETURNS TABLE (slot_at TIMESTAMPTZ, pct INT)
LANGUAGE sql STABLE
AS $$
  WITH c AS (
    SELECT * FROM line_note_communities WHERE id = p_community_id
  ), today AS (
    SELECT (now() AT TIME ZONE 'Asia/Taipei')::date AS d
  ), slots AS (
    SELECT (x->>'at')::time AS t, LEAST(GREATEST((x->>'pct')::int, 1), 100) AS pct
      FROM c, jsonb_array_elements(c.post_slots) x
     WHERE c.post_mode = 'slots'
       AND (x->>'at') ~ '^\d{1,2}:\d{2}$' AND (x->>'pct') ~ '^\d+$'
    UNION ALL
    SELECT g::time, c.post_every_pct
      FROM c, today,
           generate_series(today.d + c.post_window_start::time,
                           today.d + c.post_window_end::time,
                           make_interval(hours => c.post_every_hours)) g
     WHERE c.post_mode = 'interval'
       AND c.post_window_start ~ '^\d{1,2}:\d{2}$' AND c.post_window_end ~ '^\d{1,2}:\d{2}$'
  )
  SELECT ((today.d + s.t) AT TIME ZONE 'Asia/Taipei') AS slot_at, s.pct
    FROM slots s, today, c
   WHERE ((today.d + s.t) AT TIME ZONE 'Asia/Taipei') <= now()
     AND ((today.d + s.t) AT TIME ZONE 'Asia/Taipei') >  now() - INTERVAL '30 minutes'
     AND ((today.d + s.t) AT TIME ZONE 'Asia/Taipei') >  COALESCE(c.post_last_slot_at, '-infinity')
   ORDER BY 1 DESC
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public._line_note_release_scheduled()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  c        RECORD;
  v_slot   RECORD;
  v_cnt    INT;
  v_post   RECORD;
  v_n      INT := 0;
BEGIN
  -- 團已經不開了（結單／取消）或社群關掉自動發文：還沒發的排程就不發了
  DELETE FROM line_note_posts p
   USING group_buy_campaigns g, line_note_communities lc
   WHERE p.status = 'scheduled' AND g.id = p.campaign_id AND lc.id = p.community_id
     AND (g.status <> 'open' OR NOT lc.auto_post_on_open);

  FOR c IN
    SELECT lc.id, lc.tenant_id, lc.account_id, lc.post_mode, lc.post_release_budget
      FROM line_note_communities lc
     WHERE EXISTS (SELECT 1 FROM line_note_posts p WHERE p.community_id = lc.id AND p.status = 'scheduled')
     FOR UPDATE OF lc SKIP LOCKED
  LOOP
    -- 改回「開團立刻發」的社群：手上的排程全部放行（跟原本行為一樣，一次排隊）
    IF c.post_mode = 'immediate' THEN
      c.post_release_budget := 1000000;
    ELSE
      SELECT * INTO v_slot FROM public._line_note_due_slot(c.id);
      IF v_slot.slot_at IS NOT NULL THEN
        SELECT count(*) INTO v_cnt FROM line_note_posts WHERE community_id = c.id AND status = 'scheduled';
        c.post_release_budget := LEAST(v_cnt, GREATEST(1, round(v_cnt * v_slot.pct / 100.0)::int));
        UPDATE line_note_communities
           SET post_last_slot_at = v_slot.slot_at, post_release_budget = c.post_release_budget
         WHERE id = c.id;
      END IF;
    END IF;

    IF c.post_release_budget <= 0 THEN CONTINUE; END IF;

    -- 一分鐘放一篇（immediate 例外：全部放）
    FOR v_post IN
      SELECT p.id FROM line_note_posts p
       WHERE p.community_id = c.id AND p.status = 'scheduled'
       ORDER BY p.created_at, p.id
       LIMIT CASE WHEN c.post_mode = 'immediate' THEN NULL ELSE 1 END
    LOOP
      UPDATE line_note_posts SET status = 'queued', last_error = NULL WHERE id = v_post.id;
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id)
      VALUES (c.tenant_id, 'post', c.account_id, c.id, v_post.id);
      v_n := v_n + 1;
      c.post_release_budget := c.post_release_budget - 1;
    END LOOP;

    IF c.post_mode <> 'immediate' THEN
      UPDATE line_note_communities
         SET post_release_budget = CASE
               WHEN EXISTS (SELECT 1 FROM line_note_posts WHERE community_id = c.id AND status = 'scheduled')
               THEN GREATEST(c.post_release_budget, 0) ELSE 0 END
       WHERE id = c.id;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_release_scheduled() FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. 後台存排程設定
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_community_set_schedule(
  p_id                BIGINT,
  p_post_mode         TEXT,
  p_post_slots        JSONB,
  p_post_every_hours  INT,
  p_post_every_pct    INT,
  p_post_window_start TEXT,
  p_post_window_end   TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_slot   JSONB;
BEGIN
  IF p_post_mode NOT IN ('immediate', 'slots', 'interval') THEN
    RAISE EXCEPTION '發文方式不正確：%', p_post_mode;
  END IF;
  IF p_post_mode = 'slots' THEN
    IF jsonb_typeof(p_post_slots) <> 'array' OR jsonb_array_length(p_post_slots) = 0 THEN
      RAISE EXCEPTION '請至少設定一個發文時段';
    END IF;
    FOR v_slot IN SELECT * FROM jsonb_array_elements(p_post_slots) LOOP
      IF NOT ((v_slot->>'at') ~ '^([01]?\d|2[0-3]):[0-5]\d$') THEN
        RAISE EXCEPTION '時段格式要是 HH:MM（收到 %）', v_slot->>'at';
      END IF;
      IF NOT ((v_slot->>'pct') ~ '^\d+$') OR (v_slot->>'pct')::int NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION '每個時段的比例要是 1～100（收到 %）', v_slot->>'pct';
      END IF;
    END LOOP;
  END IF;
  IF p_post_mode = 'interval' THEN
    IF NOT (p_post_window_start ~ '^([01]?\d|2[0-3]):[0-5]\d$' AND p_post_window_end ~ '^([01]?\d|2[0-3]):[0-5]\d$') THEN
      RAISE EXCEPTION '發文時間範圍要是 HH:MM';
    END IF;
    IF p_post_window_end::time <= p_post_window_start::time THEN
      RAISE EXCEPTION '發文時間範圍的結束要晚於開始';
    END IF;
  END IF;

  PERFORM 1 FROM line_note_communities WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;

  -- 只有節奏真的改了才重設進度：存社群的其他欄位（讀取時間之類）不要把發到一半的時段砍掉。
  -- 改了節奏的話，當下已經過的時段不補發（post_last_slot_at = now()）。
  UPDATE line_note_communities SET
    post_mode         = p_post_mode,
    post_slots        = CASE WHEN p_post_mode = 'slots' THEN p_post_slots ELSE post_slots END,
    post_every_hours  = COALESCE(p_post_every_hours, post_every_hours),
    post_every_pct    = COALESCE(p_post_every_pct, post_every_pct),
    post_window_start = COALESCE(p_post_window_start, post_window_start),
    post_window_end   = COALESCE(p_post_window_end, post_window_end),
    post_last_slot_at = now(),
    post_release_budget = 0
  WHERE id = p_id
    AND (post_mode IS DISTINCT FROM p_post_mode
      OR (p_post_mode = 'slots' AND post_slots IS DISTINCT FROM p_post_slots)
      OR (p_post_mode = 'interval' AND (
            post_every_hours  IS DISTINCT FROM COALESCE(p_post_every_hours, post_every_hours)
         OR post_every_pct    IS DISTINCT FROM COALESCE(p_post_every_pct, post_every_pct)
         OR post_window_start IS DISTINCT FROM COALESCE(p_post_window_start, post_window_start)
         OR post_window_end   IS DISTINCT FROM COALESCE(p_post_window_end, post_window_end))));
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_set_schedule(BIGINT, TEXT, JSONB, INT, INT, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. tick：先放排程，再照原本的條件決定要不要叫 worker
--    基底：線上 pg_get_functiondef（見檔頭）。
-- ----------------------------------------------------------------------------
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
