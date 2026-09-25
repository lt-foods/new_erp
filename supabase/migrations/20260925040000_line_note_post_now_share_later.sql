-- ============================================================================
-- 20260925040000_line_note_post_now_share_later.sql
--
-- 發文規則改成：開團（時間到）就**立刻**發到記事本，各社群設定的節奏改成管「分享到聊天室」。
-- 老闆 9/25 指示：「開團時間到就發文到記事本，然後再依照設定時間分享到聊天區，
-- 然後標示一下哪些發到記事本，哪些是分享過的」。
--
-- - line_note_posts.share_state：none（不分享/舊資料）→ scheduled（等節奏放行）→ sharing（已排 share 工作）
--   → shared（已分享，shared_at）；failed（分享失敗，錯誤在 last_error）；skipped（團結單/取消，不分享了）
-- - 開團 trigger 一律建 queued 貼文 + post 工作；share_state 依社群 post_mode：immediate → none
--   （worker 發完馬上分享），其他 → scheduled。
-- - _line_note_release_scheduled 改成放行「已發文、等分享」的貼文（status='posted' AND share_state='scheduled'），
--   放行 = 建 kind='share' 工作；節奏算法（slots / interval / spread、一分鐘一篇）不變。
-- - 目前還在 status='scheduled'（等發文）的貼文一律轉成 queued + post 工作、share_state='scheduled'，
--   換句話說馬上發到記事本、分享照原節奏。
--
-- 基底：_line_note_on_campaign_open @ 20260924040000、_line_note_release_scheduled @ 20260924050000、
--       jobs kind CHECK @ 20260924080000。
-- rollback：還原那三段；欄位留著無害。
-- ============================================================================

ALTER TABLE line_note_posts
  ADD COLUMN IF NOT EXISTS share_state TEXT NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS shared_at   TIMESTAMPTZ;
DO $$ BEGIN
  ALTER TABLE line_note_posts ADD CONSTRAINT line_note_posts_share_state_chk
    CHECK (share_state IN ('none', 'scheduled', 'sharing', 'shared', 'failed', 'skipped'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN line_note_posts.share_state IS
  'none=不分享/舊資料 scheduled=等節奏放行 sharing=已排 share 工作 shared=已分享(shared_at) failed=分享失敗 skipped=團不開了（20260925040000）';

-- 舊資料回填：發文當下有分享成功的（job result.sharedTo）、或結單日提醒分享過的
UPDATE line_note_posts p SET share_state = 'shared', shared_at = COALESCE(p.shared_at, x.at)
  FROM (
    SELECT j.post_id, max(j.finished_at) AS at
      FROM line_note_jobs j
     WHERE j.status = 'done'
       AND ((j.kind = 'post' AND j.result->>'sharedTo' IS NOT NULL)
         OR (j.kind = 'remind' AND (j.result->>'reminded') = 'true'))
     GROUP BY j.post_id
  ) x
 WHERE x.post_id = p.id AND p.share_state = 'none';

ALTER TABLE line_note_jobs DROP CONSTRAINT IF EXISTS line_note_jobs_kind_check;
ALTER TABLE line_note_jobs ADD CONSTRAINT line_note_jobs_kind_check
  CHECK (kind IN ('login', 'logout', 'list_homes', 'post', 'read', 'close', 'remind', 'share'));

CREATE INDEX IF NOT EXISTS idx_line_note_posts_share_scheduled
  ON line_note_posts (community_id, posted_at, id) WHERE status = 'posted' AND share_state = 'scheduled';

-- ----------------------------------------------------------------------------
-- 開團 → 一律立刻排發文；分享狀態看社群節奏
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
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, share_state, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id, 'queued',
            CASE WHEN v_c.post_mode = 'immediate' THEN 'none' ELSE 'scheduled' END,
            NEW.updated_by, NEW.updated_by)
    ON CONFLICT (community_id, campaign_id) DO NOTHING
    RETURNING id INTO v_post;
    IF v_post IS NOT NULL THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (NEW.tenant_id, 'post', v_c.account_id, v_c.community_id, v_post, NEW.updated_by);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 節奏放行：對象改成「已發文、等分享」的貼文，放行 = 建 share 工作
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
  -- 團已經不開了（結單／取消）或社群關掉自動發文：還沒分享的就不分享了
  UPDATE line_note_posts p SET share_state = 'skipped'
    FROM group_buy_campaigns g, line_note_communities lc
   WHERE p.share_state = 'scheduled' AND g.id = p.campaign_id AND lc.id = p.community_id
     AND (g.status <> 'open' OR NOT lc.auto_post_on_open);

  FOR c IN
    SELECT lc.id, lc.tenant_id, lc.account_id, lc.post_mode, lc.post_release_budget,
           lc.post_release_target, lc.post_last_slot_at, lc.post_window_until
      FROM line_note_communities lc
     WHERE EXISTS (SELECT 1 FROM line_note_posts p
                    WHERE p.community_id = lc.id AND p.status = 'posted' AND p.share_state = 'scheduled')
     FOR UPDATE OF lc SKIP LOCKED
  LOOP
    v_limit := 1;

    IF c.post_mode = 'immediate' THEN
      c.post_release_budget := 1000000;
      v_limit := NULL;
    ELSE
      IF c.post_release_budget <= 0 OR c.post_mode <> 'spread' THEN
        SELECT * INTO v_slot FROM public._line_note_due_slot(c.id);
        IF v_slot.slot_at IS NOT NULL THEN
          SELECT count(*) INTO v_cnt FROM line_note_posts
           WHERE community_id = c.id AND status = 'posted' AND share_state = 'scheduled';
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

      IF c.post_mode = 'spread' AND c.post_release_budget > 0 AND c.post_window_until IS NOT NULL THEN
        IF now() >= c.post_window_until THEN
          v_should := c.post_release_target;
        ELSE
          v_frac := EXTRACT(EPOCH FROM (now() - c.post_last_slot_at))
                  / NULLIF(EXTRACT(EPOCH FROM (c.post_window_until - c.post_last_slot_at)), 0);
          v_should := ceil(c.post_release_target * LEAST(GREATEST(COALESCE(v_frac, 1), 0), 1))::int;
        END IF;
        IF (c.post_release_target - c.post_release_budget) >= v_should THEN
          CONTINUE;
        END IF;
      END IF;
    END IF;

    IF c.post_release_budget <= 0 THEN CONTINUE; END IF;

    FOR v_post IN
      SELECT p.id FROM line_note_posts p
       WHERE p.community_id = c.id AND p.status = 'posted' AND p.share_state = 'scheduled'
       ORDER BY p.posted_at, p.id
       LIMIT v_limit
    LOOP
      UPDATE line_note_posts SET share_state = 'sharing' WHERE id = v_post.id;
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id)
      VALUES (c.tenant_id, 'share', c.account_id, c.id, v_post.id);
      v_n := v_n + 1;
      c.post_release_budget := c.post_release_budget - 1;
    END LOOP;

    IF c.post_mode <> 'immediate' THEN
      UPDATE line_note_communities
         SET post_release_budget = CASE
               WHEN EXISTS (SELECT 1 FROM line_note_posts
                             WHERE community_id = c.id AND status = 'posted' AND share_state = 'scheduled')
               THEN GREATEST(c.post_release_budget, 0) ELSE 0 END
       WHERE id = c.id;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_release_scheduled() FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 現有「等發文」的排程貼文：馬上發到記事本，分享照節奏
-- ----------------------------------------------------------------------------
WITH conv AS (
  UPDATE line_note_posts p SET status = 'queued', share_state = 'scheduled'
    FROM line_note_communities c
   WHERE p.status = 'scheduled' AND c.id = p.community_id
  RETURNING p.id, p.tenant_id, p.community_id, c.account_id
)
INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id)
SELECT tenant_id, 'post', account_id, community_id, id FROM conv
 WHERE NOT EXISTS (SELECT 1 FROM line_note_jobs j WHERE j.kind = 'post' AND j.post_id = conv.id AND j.status IN ('queued', 'running'));
