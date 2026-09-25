-- ============================================================================
-- 20260925020000_line_note_interval_minutes.sql
--
-- 「每 n 小時發 n%」改成以分鐘為單位（老闆要「每半小時 2%」）。
-- - line_note_communities.post_every_minutes（預設 120，從 post_every_hours × 60 回填；hours 欄留著不用）
-- - _line_note_due_slot 的 interval 分支改用分鐘
-- - rpc_line_note_community_set_schedule 多收 p_post_every_minutes（舊簽名 DROP，避免 PostgREST 撞多載）
--
-- 基底：_line_note_due_slot / rpc_line_note_community_set_schedule @ 20260924050000。
-- rollback：還原 20260924050000 的兩支；欄位留著無害。
-- ============================================================================
ALTER TABLE line_note_communities ADD COLUMN IF NOT EXISTS post_every_minutes INT NOT NULL DEFAULT 120;
UPDATE line_note_communities SET post_every_minutes = post_every_hours * 60 WHERE post_every_minutes = 120 AND post_every_hours * 60 <> 120;
DO $$ BEGIN
  ALTER TABLE line_note_communities ADD CONSTRAINT line_note_communities_post_every_minutes_chk
    CHECK (post_every_minutes BETWEEN 5 AND 1440);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

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
    SELECT (x->>'at')::time AS t, NULL::time AS t_end,
           LEAST(GREATEST((x->>'pct')::int, 1), 100)::numeric AS pct
      FROM c, jsonb_array_elements(c.post_slots) x
     WHERE c.post_mode = 'slots'
       AND (x->>'at') ~ '^\d{1,2}:\d{2}$' AND (x->>'pct') ~ '^\d+$'
    UNION ALL
    SELECT g::time, NULL::time, c.post_every_pct::numeric
      FROM c, today,
           generate_series(today.d + c.post_window_start::time,
                           today.d + c.post_window_end::time,
                           make_interval(mins => c.post_every_minutes)) g
     WHERE c.post_mode = 'interval'
       AND c.post_window_start ~ '^\d{1,2}:\d{2}$' AND c.post_window_end ~ '^\d{1,2}:\d{2}$'
    UNION ALL
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
     AND CASE WHEN a.slot_end IS NULL THEN a.slot_at > now() - INTERVAL '30 minutes'
              ELSE now() < a.slot_end END
   ORDER BY a.slot_at DESC
   LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.rpc_line_note_community_set_schedule(BIGINT, TEXT, JSONB, INT, INT, TEXT, TEXT);
CREATE FUNCTION public.rpc_line_note_community_set_schedule(
  p_id                 BIGINT,
  p_post_mode          TEXT,
  p_post_slots         JSONB,
  p_post_every_minutes INT,
  p_post_every_pct     INT,
  p_post_window_start  TEXT,
  p_post_window_end    TEXT
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
    IF COALESCE(p_post_every_minutes, 0) NOT BETWEEN 5 AND 1440 THEN
      RAISE EXCEPTION '間隔要在 5～1440 分鐘之間（收到 %）', p_post_every_minutes;
    END IF;
  END IF;

  PERFORM 1 FROM line_note_communities WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;

  UPDATE line_note_communities SET
    post_mode          = p_post_mode,
    post_slots         = CASE WHEN p_post_mode IN ('slots', 'spread') THEN p_post_slots ELSE post_slots END,
    post_every_minutes = COALESCE(p_post_every_minutes, post_every_minutes),
    post_every_hours   = GREATEST(1, COALESCE(p_post_every_minutes, post_every_minutes) / 60),
    post_every_pct     = COALESCE(p_post_every_pct, post_every_pct),
    post_window_start  = COALESCE(p_post_window_start, post_window_start),
    post_window_end    = COALESCE(p_post_window_end, post_window_end),
    post_last_slot_at  = now(),
    post_window_until  = NULL,
    post_release_target = 0,
    post_release_budget = 0
  WHERE id = p_id
    AND (post_mode IS DISTINCT FROM p_post_mode
      OR (p_post_mode IN ('slots', 'spread') AND post_slots IS DISTINCT FROM p_post_slots)
      OR (p_post_mode = 'interval' AND (
            post_every_minutes IS DISTINCT FROM COALESCE(p_post_every_minutes, post_every_minutes)
         OR post_every_pct     IS DISTINCT FROM COALESCE(p_post_every_pct, post_every_pct)
         OR post_window_start  IS DISTINCT FROM COALESCE(p_post_window_start, post_window_start)
         OR post_window_end    IS DISTINCT FROM COALESCE(p_post_window_end, post_window_end))));
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_set_schedule(BIGINT, TEXT, JSONB, INT, INT, TEXT, TEXT) TO authenticated;
