-- ============================================================================
-- 20260924050000_line_note_spread_posting.sql
--
-- 發文節奏第四種：spread「時間區間平均發」
--   post_slots = [{"from":"09:00","to":"15:00","pct":50},{"from":"15:00","to":"20:00","pct":50}]
--   每個區間開始時決定這個區間要發幾篇，然後在區間內平均分散發（最快一分鐘一篇）。
--
-- pct 的意思跟 slots 模式不同：這裡是「佔今天總量的比例」，寫 50 / 50 就是各發一半。
-- 實作：區間開始時 target = 排程中篇數 × 本區間 pct ÷（本區間 + 今天後面所有區間的 pct 合計）。
--   50/50 → 第一段 50/100 = 一半，第二段 50/50 = 剩下全部。合計不到 100 會留一些不發（照設定）。
-- 區間中途才排進來的貼文（例：11:00 開的團）等下一個區間；沒有下一個區間就等明天。
-- 進度存在社群列上：post_last_slot_at = 區間開始、post_window_until = 區間結束、
--   post_release_target = 本區間目標篇數、post_release_budget = 還沒發的目標篇數。
--   每分鐘應該已發 = ceil(target × 已過時間比例)，不夠就補 1 篇（一分鐘最多 1 篇，
--   cron 停過一陣子就慢慢追、寧可拖過區間尾也不要一口氣連發）。
--
-- 基底：_line_note_due_slot / _line_note_release_scheduled /
--       rpc_line_note_community_set_schedule @ 20260924040000（同一天、只有那一支動過）。
-- rollback：還原 20260924040000 那三支 + post_mode CHECK；兩個新欄位留著無害。
-- ============================================================================

ALTER TABLE line_note_communities
  ADD COLUMN IF NOT EXISTS post_window_until    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS post_release_target  INT NOT NULL DEFAULT 0;

ALTER TABLE line_note_communities DROP CONSTRAINT IF EXISTS line_note_communities_post_mode_chk;
ALTER TABLE line_note_communities ADD CONSTRAINT line_note_communities_post_mode_chk
  CHECK (post_mode IN ('immediate', 'slots', 'interval', 'spread'));
COMMENT ON COLUMN line_note_communities.post_mode IS
  'immediate=開團當下全發 / slots=post_slots 各時段發剩餘 pct% / interval=視窗內每 N 小時發剩餘 pct% / spread=post_slots 各區間平均分散發（pct 佔總量）（20260924050000）';

-- ----------------------------------------------------------------------------
-- 現在該觸發的時段。回傳型別多了 slot_end（spread 才有值），DROP 再建。
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public._line_note_due_slot(BIGINT);
CREATE FUNCTION public._line_note_due_slot(p_community_id BIGINT)
RETURNS TABLE (slot_at TIMESTAMPTZ, slot_end TIMESTAMPTZ, pct NUMERIC)
LANGUAGE sql STABLE
AS $$
  WITH c AS (
    SELECT * FROM line_note_communities WHERE id = p_community_id
  ), today AS (
    SELECT (now() AT TIME ZONE 'Asia/Taipei')::date AS d
  ), slots AS (
    -- slots：單點時段，pct = 剩餘的比例
    SELECT (x->>'at')::time AS t, NULL::time AS t_end,
           LEAST(GREATEST((x->>'pct')::int, 1), 100)::numeric AS pct
      FROM c, jsonb_array_elements(c.post_slots) x
     WHERE c.post_mode = 'slots'
       AND (x->>'at') ~ '^\d{1,2}:\d{2}$' AND (x->>'pct') ~ '^\d+$'
    UNION ALL
    -- interval：展開成單點時段
    SELECT g::time, NULL::time, c.post_every_pct::numeric
      FROM c, today,
           generate_series(today.d + c.post_window_start::time,
                           today.d + c.post_window_end::time,
                           make_interval(hours => c.post_every_hours)) g
     WHERE c.post_mode = 'interval'
       AND c.post_window_start ~ '^\d{1,2}:\d{2}$' AND c.post_window_end ~ '^\d{1,2}:\d{2}$'
    UNION ALL
    -- spread：區間，pct 換算成「佔剩餘的比例」= 本區間 ÷（本區間 + 之後區間）
    SELECT w.t_from, w.t_to,
           100.0 * w.pct / NULLIF(SUM(w.pct) OVER (ORDER BY w.t_from ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING), 0)
      FROM (
        SELECT (x->>'from')::time AS t_from, (x->>'to')::time AS t_to, GREATEST((x->>'pct')::int, 0) AS pct
          FROM c, jsonb_array_elements(c.post_slots) x
         WHERE c.post_mode = 'spread'
           AND (x->>'from') ~ '^\d{1,2}:\d{2}$' AND (x->>'to') ~ '^\d{1,2}:\d{2}$' AND (x->>'pct') ~ '^\d+$'
      ) w
  ), abs_slots AS (
    SELECT ((today.d + s.t) AT TIME ZONE 'Asia/Taipei') AS slot_at,
           CASE WHEN s.t_end IS NULL THEN NULL ELSE ((today.d + s.t_end) AT TIME ZONE 'Asia/Taipei') END AS slot_end,
           s.pct
      FROM slots s, today
  )
  SELECT a.slot_at, a.slot_end, a.pct
    FROM abs_slots a, c
   WHERE a.slot_at <= now()
     AND a.slot_at > COALESCE(c.post_last_slot_at, '-infinity')
     AND a.pct IS NOT NULL AND a.pct > 0
     -- 單點時段：只補 30 分鐘內錯過的；區間：還在區間裡就算
     AND CASE WHEN a.slot_end IS NULL THEN a.slot_at > now() - INTERVAL '30 minutes'
              ELSE now() < a.slot_end END
   ORDER BY a.slot_at DESC
   LIMIT 1;
$$;

-- ----------------------------------------------------------------------------
-- 放行。基底 20260924040000，多 spread 的分支。
-- ----------------------------------------------------------------------------
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
  v_limit  INT;
  v_frac   NUMERIC;
  v_should INT;
BEGIN
  -- 團已經不開了（結單／取消）或社群關掉自動發文：還沒發的排程就不發了
  DELETE FROM line_note_posts p
   USING group_buy_campaigns g, line_note_communities lc
   WHERE p.status = 'scheduled' AND g.id = p.campaign_id AND lc.id = p.community_id
     AND (g.status <> 'open' OR NOT lc.auto_post_on_open);

  FOR c IN
    SELECT lc.id, lc.tenant_id, lc.account_id, lc.post_mode, lc.post_release_budget,
           lc.post_release_target, lc.post_last_slot_at, lc.post_window_until
      FROM line_note_communities lc
     WHERE EXISTS (SELECT 1 FROM line_note_posts p WHERE p.community_id = lc.id AND p.status = 'scheduled')
     FOR UPDATE OF lc SKIP LOCKED
  LOOP
    v_limit := 1;

    IF c.post_mode = 'immediate' THEN
      -- 改回「開團立刻發」的社群：手上的排程全部放行
      c.post_release_budget := 1000000;
      v_limit := NULL;
    ELSE
      -- 上一個區間／時段的額度發完了，或 spread 的區間已經結束又沒額度 → 看有沒有新時段到了
      IF c.post_release_budget <= 0 OR c.post_mode <> 'spread' THEN
        SELECT * INTO v_slot FROM public._line_note_due_slot(c.id);
        IF v_slot.slot_at IS NOT NULL THEN
          SELECT count(*) INTO v_cnt FROM line_note_posts WHERE community_id = c.id AND status = 'scheduled';
          c.post_release_budget := LEAST(v_cnt, GREATEST(1, round(v_cnt * v_slot.pct / 100.0)::int));
          c.post_release_target := c.post_release_budget;
          c.post_last_slot_at   := v_slot.slot_at;
          c.post_window_until   := v_slot.slot_end;
          UPDATE line_note_communities
             SET post_last_slot_at = c.post_last_slot_at, post_window_until = c.post_window_until,
                 post_release_target = c.post_release_target, post_release_budget = c.post_release_budget
           WHERE id = c.id;
        END IF;
      END IF;

      -- spread：照時間比例決定這一分鐘該不該放
      IF c.post_mode = 'spread' AND c.post_release_budget > 0 AND c.post_window_until IS NOT NULL THEN
        IF now() >= c.post_window_until THEN
          v_should := c.post_release_target;
        ELSE
          v_frac := EXTRACT(EPOCH FROM (now() - c.post_last_slot_at))
                  / NULLIF(EXTRACT(EPOCH FROM (c.post_window_until - c.post_last_slot_at)), 0);
          v_should := ceil(c.post_release_target * LEAST(GREATEST(COALESCE(v_frac, 1), 0), 1))::int;
        END IF;
        -- 已發 = target − budget；還不到該發的量就這一分鐘先不發
        IF (c.post_release_target - c.post_release_budget) >= v_should THEN
          CONTINUE;
        END IF;
      END IF;
    END IF;

    IF c.post_release_budget <= 0 THEN CONTINUE; END IF;

    FOR v_post IN
      SELECT p.id FROM line_note_posts p
       WHERE p.community_id = c.id AND p.status = 'scheduled'
       ORDER BY p.created_at, p.id
       LIMIT v_limit
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
-- 存設定：多 spread 的驗證。基底 20260924040000。
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
  v_prev   TIME;
BEGIN
  IF p_post_mode NOT IN ('immediate', 'slots', 'interval', 'spread') THEN
    RAISE EXCEPTION '發文方式不正確：%', p_post_mode;
  END IF;
  IF p_post_mode IN ('slots', 'spread') THEN
    IF jsonb_typeof(p_post_slots) <> 'array' OR jsonb_array_length(p_post_slots) = 0 THEN
      RAISE EXCEPTION '請至少設定一個發文時段';
    END IF;
  END IF;
  IF p_post_mode = 'slots' THEN
    FOR v_slot IN SELECT * FROM jsonb_array_elements(p_post_slots) LOOP
      IF NOT ((v_slot->>'at') ~ '^([01]?\d|2[0-3]):[0-5]\d$') THEN
        RAISE EXCEPTION '時段格式要是 HH:MM（收到 %）', v_slot->>'at';
      END IF;
      IF NOT ((v_slot->>'pct') ~ '^\d+$') OR (v_slot->>'pct')::int NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION '每個時段的比例要是 1～100（收到 %）', v_slot->>'pct';
      END IF;
    END LOOP;
  END IF;
  IF p_post_mode = 'spread' THEN
    v_prev := NULL;
    FOR v_slot IN
      SELECT x FROM jsonb_array_elements(p_post_slots) x ORDER BY (x->>'from')
    LOOP
      IF NOT ((v_slot->>'from') ~ '^([01]?\d|2[0-3]):[0-5]\d$' AND (v_slot->>'to') ~ '^([01]?\d|2[0-3]):[0-5]\d$') THEN
        RAISE EXCEPTION '區間格式要是 HH:MM（收到 % ～ %）', v_slot->>'from', v_slot->>'to';
      END IF;
      IF (v_slot->>'to')::time <= (v_slot->>'from')::time THEN
        RAISE EXCEPTION '區間的結束要晚於開始（% ～ %）', v_slot->>'from', v_slot->>'to';
      END IF;
      IF v_prev IS NOT NULL AND (v_slot->>'from')::time < v_prev THEN
        RAISE EXCEPTION '區間不能重疊（% 開始時上一段還沒結束）', v_slot->>'from';
      END IF;
      v_prev := (v_slot->>'to')::time;
      IF NOT ((v_slot->>'pct') ~ '^\d+$') OR (v_slot->>'pct')::int NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION '每個區間的比例要是 1～100（收到 %）', v_slot->>'pct';
      END IF;
    END LOOP;
    IF (SELECT SUM((x->>'pct')::int) FROM jsonb_array_elements(p_post_slots) x) > 100 THEN
      RAISE EXCEPTION '各區間的比例加起來不能超過 100';
    END IF;
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

  -- 只有節奏真的改了才重設進度；改了的話當下已經過的時段不補發（post_last_slot_at = now()）。
  UPDATE line_note_communities SET
    post_mode         = p_post_mode,
    post_slots        = CASE WHEN p_post_mode IN ('slots', 'spread') THEN p_post_slots ELSE post_slots END,
    post_every_hours  = COALESCE(p_post_every_hours, post_every_hours),
    post_every_pct    = COALESCE(p_post_every_pct, post_every_pct),
    post_window_start = COALESCE(p_post_window_start, post_window_start),
    post_window_end   = COALESCE(p_post_window_end, post_window_end),
    post_last_slot_at = now(),
    post_window_until = NULL,
    post_release_target = 0,
    post_release_budget = 0
  WHERE id = p_id
    AND (post_mode IS DISTINCT FROM p_post_mode
      OR (p_post_mode IN ('slots', 'spread') AND post_slots IS DISTINCT FROM p_post_slots)
      OR (p_post_mode = 'interval' AND (
            post_every_hours  IS DISTINCT FROM COALESCE(p_post_every_hours, post_every_hours)
         OR post_every_pct    IS DISTINCT FROM COALESCE(p_post_every_pct, post_every_pct)
         OR post_window_start IS DISTINCT FROM COALESCE(p_post_window_start, post_window_start)
         OR post_window_end   IS DISTINCT FROM COALESCE(p_post_window_end, post_window_end))));
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_set_schedule(BIGINT, TEXT, JSONB, INT, INT, TEXT, TEXT) TO authenticated;
