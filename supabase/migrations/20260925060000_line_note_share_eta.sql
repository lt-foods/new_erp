-- ============================================================================
-- 20260925060000_line_note_share_eta.sql
--
-- 「等分享（依節奏）」要直接寫上預計幾點分享。rpc_line_note_share_eta(post_ids) 依每個社群的節奏
-- 把排隊中的貼文（share_state IN ('scheduled','sharing')）逐篇推算預計分享時間：
--   - immediate：現在
--   - 正在進行中的時段（post_release_budget > 0）：剩下的額度接著放（單點時段一分鐘一篇；
--     區間平均發＝在剩下的區間裡平均）
--   - 之後的時段：照 _line_note_due_slot 同一套規則往後推（今天沒放完就推到明天），最多推 3 天
-- 只是估算：節奏改了、有人手動插隊、worker 停擺都會偏。
-- rollback：DROP FUNCTION rpc_line_note_share_eta(BIGINT[]);
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_line_note_share_eta(p_post_ids BIGINT[])
RETURNS TABLE (post_id BIGINT, eta TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  c        RECORD;
  v_posts  BIGINT[];
  v_n      INT;
  v_i      INT;          -- 下一個還沒排到時間的貼文（0-based）
  v_k      INT;
  v_take   INT;
  v_slot   RECORD;
  v_today  DATE := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_len    INTERVAL;
  v_budget INT;
  v_state  TEXT;
BEGIN
  FOR c IN
    SELECT lc.*
      FROM line_note_communities lc
     WHERE lc.tenant_id = v_tenant
       AND EXISTS (SELECT 1 FROM line_note_posts p
                    WHERE p.community_id = lc.id AND p.id = ANY (p_post_ids)
                      AND p.share_state IN ('scheduled', 'sharing'))
  LOOP
    -- 這個社群排隊中的全部貼文（不只被問的那幾篇，順位才算得對）
    SELECT array_agg(p.id ORDER BY p.share_state = 'sharing' DESC, p.posted_at, p.id)
      INTO v_posts
      FROM line_note_posts p
     WHERE p.community_id = c.id AND p.status = 'posted' AND p.share_state IN ('scheduled', 'sharing');
    v_n := COALESCE(array_length(v_posts, 1), 0);
    v_i := 0;
    IF v_n = 0 THEN CONTINUE; END IF;

    -- 已經排了 share 工作的：馬上
    FOR v_k IN 1..v_n LOOP
      SELECT share_state INTO v_state FROM line_note_posts WHERE id = v_posts[v_k];
      EXIT WHEN v_state <> 'sharing';
      post_id := v_posts[v_k]; eta := now(); RETURN NEXT;
      v_i := v_i + 1;
    END LOOP;

    IF c.post_mode = 'immediate' THEN
      WHILE v_i < v_n LOOP
        post_id := v_posts[v_i + 1]; eta := now(); RETURN NEXT; v_i := v_i + 1;
      END LOOP;
      CONTINUE;
    END IF;

    -- 進行中的時段：剩下的額度
    v_budget := LEAST(COALESCE(c.post_release_budget, 0), v_n - v_i);
    IF v_budget > 0 THEN
      IF c.post_mode = 'spread' AND c.post_window_until IS NOT NULL AND c.post_window_until > now() THEN
        v_len := c.post_window_until - now();
        FOR v_k IN 1..v_budget LOOP
          post_id := v_posts[v_i + 1]; eta := now() + v_len * (v_k - 1) / v_budget; RETURN NEXT; v_i := v_i + 1;
        END LOOP;
      ELSE
        FOR v_k IN 1..v_budget LOOP
          post_id := v_posts[v_i + 1]; eta := now() + make_interval(mins => v_k - 1); RETURN NEXT; v_i := v_i + 1;
        END LOOP;
      END IF;
    END IF;

    -- 之後的時段（今天剩下的 + 明後天），照 _line_note_due_slot 的規則
    FOR v_slot IN
      WITH days AS (SELECT v_today + g AS d FROM generate_series(0, 3) g),
      raw AS (
        SELECT d.d, (x->>'at')::time AS t, NULL::time AS t_end,
               LEAST(GREATEST((x->>'pct')::int, 1), 100)::numeric AS pct
          FROM days d, jsonb_array_elements(c.post_slots) x
         WHERE c.post_mode = 'slots' AND (x->>'at') ~ '^\d{1,2}:\d{2}$' AND (x->>'pct') ~ '^\d+$'
        UNION ALL
        SELECT d.d, g::time, NULL::time, c.post_every_pct::numeric
          FROM days d,
               generate_series(d.d + c.post_window_start::time, d.d + c.post_window_end::time,
                               make_interval(mins => GREATEST(COALESCE(c.post_every_minutes, 60), 5))) g
         WHERE c.post_mode = 'interval'
           AND c.post_window_start ~ '^\d{1,2}:\d{2}$' AND c.post_window_end ~ '^\d{1,2}:\d{2}$'
        UNION ALL
        SELECT w.d, w.t_from, w.t_to,
               100.0 * w.pct / NULLIF(SUM(w.pct) OVER (PARTITION BY w.d ORDER BY w.t_from
                                       ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING), 0)
          FROM (
            SELECT d.d, (x->>'from')::time AS t_from, (x->>'to')::time AS t_to, GREATEST((x->>'pct')::int, 0) AS pct
              FROM days d, jsonb_array_elements(c.post_slots) x
             WHERE c.post_mode = 'spread'
               AND (x->>'from') ~ '^\d{1,2}:\d{2}$' AND (x->>'to') ~ '^\d{1,2}:\d{2}$' AND (x->>'pct') ~ '^\d+$'
          ) w
      )
      SELECT ((r.d + r.t) AT TIME ZONE 'Asia/Taipei') AS slot_at,
             CASE WHEN r.t_end IS NULL THEN NULL ELSE ((r.d + r.t_end) AT TIME ZONE 'Asia/Taipei') END AS slot_end,
             r.pct
        FROM raw r
       WHERE r.pct > 0
         AND ((r.d + r.t) AT TIME ZONE 'Asia/Taipei') > COALESCE(c.post_last_slot_at, '-infinity')
         AND (CASE WHEN r.t_end IS NULL THEN ((r.d + r.t) AT TIME ZONE 'Asia/Taipei') > now() - INTERVAL '30 minutes'
                   ELSE ((r.d + r.t_end) AT TIME ZONE 'Asia/Taipei') > now() END)
       ORDER BY 1
    LOOP
      EXIT WHEN v_i >= v_n;
      v_take := LEAST(v_n - v_i, GREATEST(1, round((v_n - v_i) * v_slot.pct / 100.0)::int));
      IF v_slot.slot_end IS NULL THEN
        FOR v_k IN 1..v_take LOOP
          post_id := v_posts[v_i + 1]; eta := GREATEST(v_slot.slot_at, now()) + make_interval(mins => v_k - 1);
          RETURN NEXT; v_i := v_i + 1;
        END LOOP;
      ELSE
        v_len := v_slot.slot_end - GREATEST(v_slot.slot_at, now());
        FOR v_k IN 1..v_take LOOP
          post_id := v_posts[v_i + 1]; eta := GREATEST(v_slot.slot_at, now()) + v_len * (v_k - 1) / v_take;
          RETURN NEXT; v_i := v_i + 1;
        END LOOP;
      END IF;
    END LOOP;
    -- 三天內都排不到的（節奏設得很慢）：不回，前端就照舊顯示「依節奏」
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_share_eta(BIGINT[]) TO authenticated;
