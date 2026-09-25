-- ============================================================================
-- 20260925070000_line_note_sub_chat_share.sql
--
-- 社群的子群（子聊天室，m…）：不另外發記事本、只把母社群那篇貼文**分享**到子群聊天室，
-- 節奏（開團立刻／時段／區間／間隔）與結單日提醒用子群自己那一列的設定。
-- 老闆 9/25：子群是從母社群分出來的，記事本母社群已經有了，「他要分享到群裡，
-- 所以要多一個設定是這種情境的，然後他也要可以分時段分享」。
--
-- - line_note_communities.share_from_community_id：跟著哪個社群分享（母社群）。有值＝子群：
--   不發文、不讀留言（listen_enabled 強制 false）、不留結單留言；只有分享＋提醒。
-- - 母社群那篇一發到 LINE（line_note_posts status='posted' 且有 line_post_id），trigger
--   `_line_note_fanout_sub_shares` 就替每個子群長一列同 campaign 的 line_note_posts：
--   status='posted'、line_post_id 抄母社群的、share_state='scheduled'。
--   之後 _line_note_release_scheduled 依子群自己的節奏放行 → kind='share' 工作 →
--   worker 用母社群的 home 路由、分享到子群的 mid（worker 看 share_from_community_id 分辨）。
--   子群列的 line_post_id 是母社群的貼文 → worker 的 deletePost / updatePost 對子群列不碰 LINE 貼文。
-- - 開團自動發文、開團彈窗 / 社群列「發文」三支 RPC 都跳過子群（擋下的理由講清楚）。
-- - 結單留言（_line_note_enqueue_due_closes）排除子群，否則母社群那篇會被留言 N 次。
--   結單日提醒**包含**子群（再分享一次到子群，worker 同樣走母社群 home）。
-- - 設定子群當下把母社群「還在開團中」的貼文補進來（share_state='scheduled'，照節奏放）。
--
-- 基底（都 grep 過、也對過線上 pg_get_functiondef）：
--   _line_note_on_campaign_open     @ 20260925040000
--   rpc_line_note_campaign_targets  @ 20260923120000
--   rpc_line_note_queue_posts       @ 20260921020000
--   rpc_line_note_queue_post        @ 20260921020000
--   rpc_line_note_community_upsert  @ 20260921020000（多一個參數 → DROP 再建）
--   _line_note_enqueue_due_closes   @ 20260925030000
-- rollback：還原上面六支到各自基底；
--   DROP TRIGGER trg_line_note_fanout_sub_shares ON line_note_posts;
--   DROP FUNCTION public._line_note_fanout_sub_shares(BIGINT);
--   ALTER TABLE line_note_communities DROP COLUMN share_from_community_id;
-- ============================================================================

ALTER TABLE public.line_note_communities
  ADD COLUMN IF NOT EXISTS share_from_community_id BIGINT REFERENCES public.line_note_communities(id) ON DELETE SET NULL;
DO $$ BEGIN
  ALTER TABLE public.line_note_communities
    ADD CONSTRAINT line_note_communities_share_from_not_self CHECK (share_from_community_id IS DISTINCT FROM id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_line_note_communities_share_from
  ON public.line_note_communities (share_from_community_id) WHERE share_from_community_id IS NOT NULL;
COMMENT ON COLUMN public.line_note_communities.share_from_community_id IS
  '子群：跟著這個母社群分享（不發文、不讀留言，只把母社群那篇分享到本聊天室；節奏用自己的）。20260925070000';

-- ----------------------------------------------------------------------------
-- 1. 母社群那篇發到 LINE 之後，替子群長一列「等分享」的貼文
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_fanout_sub_shares(p_post_id BIGINT)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_p RECORD;
  v_n INT;
BEGIN
  SELECT p.*, c.share_from_community_id AS parent_share_from, g.status AS g_status
    INTO v_p
    FROM line_note_posts p
    JOIN line_note_communities c ON c.id = p.community_id
    JOIN group_buy_campaigns g ON g.id = p.campaign_id
   WHERE p.id = p_post_id;
  IF v_p.id IS NULL OR v_p.status <> 'posted' OR v_p.line_post_id IS NULL THEN RETURN 0; END IF;
  IF v_p.parent_share_from IS NOT NULL THEN RETURN 0; END IF;   -- 子群列自己不再往下長
  IF v_p.g_status <> 'open' THEN RETURN 0; END IF;

  WITH ins AS (
    INSERT INTO line_note_posts
      (tenant_id, community_id, campaign_id, line_post_id, text, status, posted_at, share_state, created_by, updated_by)
    SELECT v_p.tenant_id, s.id, v_p.campaign_id, v_p.line_post_id, v_p.text, 'posted', v_p.posted_at, 'scheduled',
           v_p.created_by, v_p.updated_by
      FROM line_note_communities s
     WHERE s.share_from_community_id = v_p.community_id
       AND s.auto_post_on_open
    ON CONFLICT (community_id, campaign_id) DO UPDATE
       SET line_post_id = EXCLUDED.line_post_id, text = EXCLUDED.text, status = 'posted',
           posted_at = EXCLUDED.posted_at, share_state = 'scheduled', last_error = NULL
     WHERE line_note_posts.status <> 'posted' OR line_note_posts.line_post_id IS NULL
    RETURNING id
  )
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_fanout_sub_shares(BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._line_note_posts_fanout_trg()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  IF NEW.status = 'posted' AND NEW.line_post_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'posted' OR OLD.line_post_id IS DISTINCT FROM NEW.line_post_id) THEN
    PERFORM public._line_note_fanout_sub_shares(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_line_note_fanout_sub_shares ON public.line_note_posts;
CREATE TRIGGER trg_line_note_fanout_sub_shares
  AFTER INSERT OR UPDATE OF status, line_post_id ON public.line_note_posts
  FOR EACH ROW EXECUTE FUNCTION public._line_note_posts_fanout_trg();

-- ----------------------------------------------------------------------------
-- 2. 開團自動發文：子群不發（基底 20260925040000，只加一個條件）
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
       AND c.share_from_community_id IS NULL
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
-- 3. 開團彈窗清單：子群不能勾，理由寫「跟著母社群分享」（基底 20260923120000）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_campaign_targets(p_campaign_id bigint)
 RETURNS TABLE(community_id bigint, home_id text, home_name text, home_kind text, store_id bigint, store_name text, account_id bigint, account_label text, account_status text, auto_post_on_open boolean, listen_enabled boolean, sales_channels text[], in_scope boolean, can_post boolean, blocked_reason text, post_id bigint, post_status text, line_post_id text, post_text text, posted_at timestamp with time zone, last_read_at timestamp with time zone, closed_reason text, post_error text, comment_total integer, comment_ordered integer, comment_duplicate integer, comment_todo integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant   UUID    := public._current_tenant_id();
  -- 發文的角色集合＝rpc_line_note_queue_posts 會放行的那組，不要另外定義
  v_may_post BOOLEAN := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
                        = ANY (ARRAY['owner','admin','hq_manager','assistant','']);
  v_owner    BIGINT;
  v_cstat    TEXT;
  v_chan     TEXT;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'no tenant in token'; END IF;

  SELECT g.owner_store_id, g.status, g.sales_channel INTO v_owner, v_cstat, v_chan
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF v_cstat IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  -- 分店只能看總部的團與自己店開的團
  IF NOT public._line_note_branch_visible_store(v_owner) THEN
    RAISE EXCEPTION 'wrong_store: 這不是你的店開的團';
  END IF;

  RETURN QUERY
  WITH c AS (
    SELECT lc.*,
           a.label  AS a_label,
           a.status AS a_status,
           -- 店家範圍：總部的團發到所有社群，店家自開的團只發到那家店的
           -- （跟 _line_note_on_campaign_open 同一條件，改一邊記得改另一邊）
           (v_owner IS NULL OR lc.store_id = v_owner) AS scoped,
           -- 類別範圍：漂漂館的團只發到有勾漂漂館的社群，反之亦然
           public._line_note_takes_channel(lc.sales_channels, v_chan) AS takes_chan,
           -- 子群：跟著母社群分享，不另外發文
           (SELECT COALESCE(NULLIF(m.home_name, ''), m.home_id) FROM line_note_communities m
             WHERE m.id = lc.share_from_community_id) AS parent_name
      FROM line_note_communities lc
      JOIN line_note_accounts a ON a.id = lc.account_id
     WHERE lc.tenant_id = v_tenant
       -- 分店看不到別家店綁的社群（總部社群 store_id IS NULL，大家都看得到）
       AND public._line_note_branch_visible_store(lc.store_id)
  ), p AS (
    SELECT lp.*,
           COALESCE(s.total, 0)     AS n_total,
           COALESCE(s.ordered, 0)   AS n_ordered,
           COALESCE(s.duplicate, 0) AS n_duplicate,
           COALESCE(s.todo, 0)      AS n_todo
      FROM line_note_posts lp
      LEFT JOIN LATERAL (
        SELECT count(*)::INT AS total,
               count(*) FILTER (WHERE cm.status = 'ordered')::INT   AS ordered,
               count(*) FILTER (WHERE cm.status = 'duplicate')::INT AS duplicate,
               count(*) FILTER (WHERE public._line_note_comment_is_todo(cm.status, cm.member_no_hint, cm.text))::INT AS todo
          FROM line_note_comments cm WHERE cm.post_id = lp.id
      ) s ON TRUE
     WHERE lp.tenant_id = v_tenant AND lp.campaign_id = p_campaign_id
  )
  SELECT c.id, c.home_id, c.home_name, c.home_kind,
         c.store_id, st.name,
         c.account_id, c.a_label, c.a_status,
         c.auto_post_on_open, c.listen_enabled,
         c.sales_channels,
         (c.scoped AND c.takes_chan) AS in_scope,
         -- can_post / blocked_reason 要跟 rpc_line_note_queue_posts 擋的東西**一模一樣**。
         -- 注意「已經發過」的判準是 posted 或 line_post_id 有值，不是「有這一列」——
         -- status='failed'（發文失敗、LINE 上根本沒東西）必須還能再發一次。
         (v_may_post AND c.scoped AND c.takes_chan AND c.a_status = 'active'
            AND c.share_from_community_id IS NULL
            AND v_cstat IN ('open','closed')
            AND NOT (p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL))) AS can_post,
         CASE WHEN c.share_from_community_id IS NOT NULL
                                                    THEN '子群：跟著「' || COALESCE(c.parent_name, '?') || '」分享，不另外發文'
              WHEN p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL)
                                                    THEN '已經發過了'
              WHEN NOT v_may_post                   THEN '發文到社群只有總部能操作'
              WHEN NOT c.scoped                     THEN '這個社群只收該店自開的團'
              WHEN NOT c.takes_chan                 THEN '這個社群沒有開放「' || public._line_note_channel_label(v_chan) || '」的團'
              WHEN c.a_status <> 'active'            THEN 'LINE 帳號沒有登入'
              WHEN v_cstat NOT IN ('open','closed')  THEN '這團不是開團中／已收單'
         END,
         p.id, p.status, p.line_post_id, p.text,
         p.posted_at, p.last_read_at, p.closed_reason, p.last_error,
         p.n_total, p.n_ordered, p.n_duplicate, p.n_todo
    FROM c
    LEFT JOIN p ON p.community_id = c.id
    LEFT JOIN stores st ON st.id = c.store_id
   -- 範圍外（別家店的 / 沒開放這一類團的）不列出來 —— 清單只留真的發得到的。
   -- 唯一例外：已經有貼文的一定要出現，設定是後來才改的，歷史不能憑空消失。
   -- 一個都沒有時由彈窗寫出原因（「只發得到有勾這一類的社群」）。
   WHERE (c.scoped AND c.takes_chan) OR p.id IS NOT NULL
   ORDER BY (p.id IS NOT NULL) DESC, c.home_name NULLS LAST, c.id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_campaign_targets(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. 真的排工作那兩支：子群一律擋（基底 20260921020000）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_queue_posts(
  p_campaign_id   BIGINT,
  p_community_ids BIGINT[]
) RETURNS TABLE (
  out_community_id BIGINT,
  out_post_id      BIGINT,
  out_status       TEXT,
  out_error        TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_owner  BIGINT;
  v_cstat  TEXT;
  v_chan   TEXT;
  v_cid    BIGINT;
  v_c      RECORD;
  v_exist  RECORD;
  v_post   BIGINT;
BEGIN
  SELECT g.owner_store_id, g.status, g.sales_channel INTO v_owner, v_cstat, v_chan
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF v_cstat IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_cstat NOT IN ('open','closed') THEN
    RAISE EXCEPTION '只有開團中／已收單的團可以發到記事本（這團是 %）', v_cstat;
  END IF;

  FOR v_cid IN
    SELECT DISTINCT x FROM unnest(COALESCE(p_community_ids, ARRAY[]::BIGINT[])) AS x
  LOOP
    SELECT lc.id, lc.account_id, lc.store_id, lc.sales_channels, lc.share_from_community_id, a.status AS a_status
      INTO v_c
      FROM line_note_communities lc
      JOIN line_note_accounts a ON a.id = lc.account_id
     WHERE lc.id = v_cid AND lc.tenant_id = v_tenant;
    IF v_c.id IS NULL THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, '找不到這個社群'::TEXT;
      CONTINUE;
    END IF;
    IF v_c.share_from_community_id IS NOT NULL THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, '子群跟著母社群分享，不另外發文'::TEXT;
      CONTINUE;
    END IF;
    IF v_owner IS NOT NULL AND v_c.store_id IS DISTINCT FROM v_owner THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, '這個社群只收該店自開的團'::TEXT;
      CONTINUE;
    END IF;
    IF NOT public._line_note_takes_channel(v_c.sales_channels, v_chan) THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT,
        '這個社群沒有開放「' || public._line_note_channel_label(v_chan) || '」的團';
      CONTINUE;
    END IF;
    IF v_c.a_status <> 'active' THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, 'LINE 帳號沒有登入'::TEXT;
      CONTINUE;
    END IF;

    SELECT lp.id, lp.status, lp.line_post_id INTO v_exist
      FROM line_note_posts lp
     WHERE lp.community_id = v_cid AND lp.campaign_id = p_campaign_id;
    -- 已經貼在 LINE 上了就跳過：重排會多貼一篇，而 line_post_id 被覆蓋 → 舊那篇的留言再也讀不回來
    IF v_exist.id IS NOT NULL AND (v_exist.status = 'posted' OR v_exist.line_post_id IS NOT NULL) THEN
      RETURN QUERY SELECT v_cid, v_exist.id, 'already_posted'::TEXT, NULL::TEXT;
      CONTINUE;
    END IF;

    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, created_by, updated_by)
    VALUES (v_tenant, v_cid, p_campaign_id, 'queued', auth.uid(), auth.uid())
    ON CONFLICT (community_id, campaign_id) DO UPDATE
       SET status = 'queued', last_error = NULL, updated_by = auth.uid()
    RETURNING id INTO v_post;

    -- 手滑點兩下不要排兩次（worker 那邊 jobPost 也會擋已發，但沒必要留一堆廢工作）
    IF NOT EXISTS (
      SELECT 1 FROM line_note_jobs j
       WHERE j.kind = 'post' AND j.post_id = v_post AND j.status IN ('queued','running')
    ) THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (v_tenant, 'post', v_c.account_id, v_cid, v_post, auth.uid());
    END IF;
    RETURN QUERY SELECT v_cid, v_post, 'queued'::TEXT, NULL::TEXT;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_queue_posts(BIGINT, BIGINT[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_line_note_queue_post(
  p_community_id BIGINT,
  p_campaign_id  BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant   UUID := public._line_note_require_admin();
  v_account  BIGINT;
  v_channels TEXT[];
  v_parent   BIGINT;
  v_chan     TEXT;
  v_post     BIGINT;
BEGIN
  SELECT account_id, sales_channels, share_from_community_id INTO v_account, v_channels, v_parent
    FROM line_note_communities
   WHERE id = p_community_id AND tenant_id = v_tenant;
  IF v_account IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_community_id; END IF;
  IF v_parent IS NOT NULL THEN RAISE EXCEPTION '子群跟著母社群分享，不另外發文'; END IF;
  SELECT g.sales_channel INTO v_chan
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF NOT public._line_note_takes_channel(v_channels, v_chan) THEN
    RAISE EXCEPTION '這個社群沒有開放「%」的團', public._line_note_channel_label(v_chan);
  END IF;

  INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, created_by, updated_by)
  VALUES (v_tenant, p_community_id, p_campaign_id, 'queued', auth.uid(), auth.uid())
  ON CONFLICT (community_id, campaign_id) DO UPDATE
     SET status = CASE WHEN line_note_posts.status = 'posted' THEN 'posted' ELSE 'queued' END,
         last_error = NULL, updated_by = auth.uid()
  RETURNING id INTO v_post;

  IF (SELECT status FROM line_note_posts WHERE id = v_post) = 'posted' THEN
    RAISE EXCEPTION '這個團已經發過文了';
  END IF;

  INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
  VALUES (v_tenant, 'post', v_account, p_community_id, v_post, auth.uid());
  RETURN v_post;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_queue_post(BIGINT, BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. 結單留言：子群不留（母社群那篇會被留 N 次）（基底 20260925030000）
-- ----------------------------------------------------------------------------
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
       AND c.share_from_community_id IS NULL
       AND g.status = 'open'
       AND g.customer_end_at IS NOT NULL
       AND g.customer_end_at <= now()
       AND g.customer_end_at >= now() - INTERVAL '10 minutes'
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

-- ----------------------------------------------------------------------------
-- 6. 社群設定存檔：多收 p_share_from_community_id（簽名變了 → DROP 舊的再建）
--    基底 20260921020000。子群：listen_enabled 強制 false、close_comment 清掉；
--    存完把母社群還在開團中的貼文補進來（等分享、照節奏放）。
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT, BOOLEAN, TEXT[]);

CREATE FUNCTION public.rpc_line_note_community_upsert(
  p_id                      BIGINT,
  p_account_id              BIGINT,
  p_home_id                 TEXT,
  p_home_name               TEXT,
  p_home_kind               TEXT,
  p_listen_enabled          BOOLEAN,
  p_read_times              TEXT[],
  p_auto_post_on_open       BOOLEAN,
  p_post_template           TEXT,
  p_read_days               INT DEFAULT 3,
  p_store_id                BIGINT DEFAULT NULL,
  p_react_on_confirm        BOOLEAN DEFAULT TRUE,
  p_sales_channels          TEXT[] DEFAULT NULL,
  p_share_from_community_id BIGINT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_id     BIGINT;
  v_t      TEXT;
  v_home   TEXT := TRIM(p_home_id);
  v_clash  TEXT;
  v_chans  TEXT[] := NULLIF(p_sales_channels, ARRAY[]::TEXT[]);
  v_parent RECORD;
  v_listen BOOLEAN := p_listen_enabled;
  v_post   RECORD;
BEGIN
  PERFORM 1 FROM line_note_accounts WHERE id = p_account_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'account % not in tenant', p_account_id; END IF;
  IF p_store_id IS NOT NULL THEN
    PERFORM 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN RAISE EXCEPTION 'store % not in tenant', p_store_id; END IF;
  END IF;
  IF COALESCE(v_home, '') = '' THEN RAISE EXCEPTION '請選擇社群'; END IF;
  FOREACH v_t IN ARRAY COALESCE(p_read_times, ARRAY[]::TEXT[]) LOOP
    IF v_t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
      RAISE EXCEPTION '讀取時間格式要是 HH:MM（收到「%」）', v_t;
    END IF;
  END LOOP;
  IF p_read_days IS NOT NULL AND (p_read_days < 1 OR p_read_days > 30) THEN
    RAISE EXCEPTION '讀取範圍要在 1～30 天';
  END IF;
  -- 一個都沒勾 = 這個社群什麼團都收不到，等於自己把社群關掉又看不出來，直接擋
  IF v_chans IS NOT NULL THEN
    FOREACH v_t IN ARRAY v_chans LOOP
      IF v_t NOT IN ('main','piaopiao') THEN RAISE EXCEPTION '不認得的團別「%」', v_t; END IF;
    END LOOP;
  ELSIF p_sales_channels IS NOT NULL THEN
    RAISE EXCEPTION '請至少勾一種要發的團（一般商城／漂漂館）';
  END IF;
  -- 子群：母社群要同帳號、自己不能是別人的子群；子群不讀留言
  IF p_share_from_community_id IS NOT NULL THEN
    SELECT id, account_id, share_from_community_id, home_id INTO v_parent
      FROM line_note_communities WHERE id = p_share_from_community_id AND tenant_id = v_tenant;
    IF v_parent.id IS NULL THEN RAISE EXCEPTION '找不到母社群'; END IF;
    IF v_parent.account_id <> p_account_id THEN RAISE EXCEPTION '母社群要用同一個 LINE 帳號'; END IF;
    IF v_parent.share_from_community_id IS NOT NULL THEN RAISE EXCEPTION '母社群自己也是子群，不能再往下掛'; END IF;
    IF v_parent.home_id = v_home THEN RAISE EXCEPTION '母社群不能選自己'; END IF;
    v_listen := FALSE;
  END IF;

  IF p_id IS NULL THEN
    -- 撞號 = 這個社群早就設定過了，把表單的值套到既有那筆（一個社群只有一份設定）
    INSERT INTO line_note_communities
      (tenant_id, account_id, store_id, home_id, home_name, home_kind,
       listen_enabled, read_times, auto_post_on_open, post_template, read_days, react_on_confirm,
       sales_channels, share_from_community_id, created_by, updated_by)
    VALUES
      (v_tenant, p_account_id, p_store_id, v_home, p_home_name,
       COALESCE(p_home_kind, 'square_chat'),
       COALESCE(v_listen, FALSE),
       COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), ARRAY['12:00']),
       COALESCE(p_auto_post_on_open, TRUE),
       NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
       COALESCE(p_read_days, 3),
       COALESCE(p_react_on_confirm, TRUE),
       COALESCE(v_chans, ARRAY['main']::TEXT[]),
       p_share_from_community_id,
       auth.uid(), auth.uid())
    ON CONFLICT (tenant_id, home_id) DO UPDATE
       SET account_id        = EXCLUDED.account_id,
           store_id          = EXCLUDED.store_id,
           home_name         = COALESCE(EXCLUDED.home_name, line_note_communities.home_name),
           home_kind         = COALESCE(EXCLUDED.home_kind, line_note_communities.home_kind),
           listen_enabled    = EXCLUDED.listen_enabled,
           read_times        = EXCLUDED.read_times,
           auto_post_on_open = EXCLUDED.auto_post_on_open,
           post_template     = EXCLUDED.post_template,
           read_days         = EXCLUDED.read_days,
           react_on_confirm  = EXCLUDED.react_on_confirm,
           sales_channels    = EXCLUDED.sales_channels,
           share_from_community_id = EXCLUDED.share_from_community_id,
           close_comment     = CASE WHEN EXCLUDED.share_from_community_id IS NULL THEN line_note_communities.close_comment END,
           updated_by        = auth.uid()
    RETURNING id INTO v_id;
  ELSE
    -- 編輯不能合併：兩筆各自掛著 line_note_posts，硬合會弄丟其中一邊的貼文與留言
    SELECT COALESCE(NULLIF(home_name, ''), home_id) INTO v_clash
      FROM line_note_communities
     WHERE tenant_id = v_tenant AND home_id = v_home AND id <> p_id;
    IF v_clash IS NOT NULL THEN
      RAISE EXCEPTION '社群「%」已經設定過了，請直接編輯那一筆，不要在這裡改成同一個社群', v_clash;
    END IF;
    IF p_share_from_community_id = p_id THEN RAISE EXCEPTION '母社群不能選自己'; END IF;
    IF p_share_from_community_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM line_note_communities WHERE share_from_community_id = p_id) THEN
      RAISE EXCEPTION '這個社群底下已經掛著子群，不能再變成別人的子群';
    END IF;

    UPDATE line_note_communities
       SET account_id        = p_account_id,
           store_id          = p_store_id,
           home_id           = v_home,
           home_name         = p_home_name,
           home_kind         = COALESCE(p_home_kind, home_kind),
           listen_enabled    = COALESCE(v_listen, listen_enabled),
           read_times        = COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), read_times),
           auto_post_on_open = COALESCE(p_auto_post_on_open, auto_post_on_open),
           post_template     = NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
           read_days         = COALESCE(p_read_days, read_days),
           react_on_confirm  = COALESCE(p_react_on_confirm, react_on_confirm),
           sales_channels    = COALESCE(v_chans, sales_channels),
           share_from_community_id = p_share_from_community_id,
           close_comment     = CASE WHEN p_share_from_community_id IS NULL THEN close_comment END,
           updated_by        = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
  END IF;

  -- 子群：母社群還在開團中的貼文補進來（等分享；節奏由 _line_note_release_scheduled 管）
  IF p_share_from_community_id IS NOT NULL AND COALESCE(p_auto_post_on_open, TRUE) THEN
    FOR v_post IN
      SELECT p.id FROM line_note_posts p
        JOIN group_buy_campaigns g ON g.id = p.campaign_id
       WHERE p.community_id = p_share_from_community_id AND p.status = 'posted'
         AND p.line_post_id IS NOT NULL AND g.status = 'open'
    LOOP
      PERFORM public._line_note_fanout_sub_shares(v_post.id);
    END LOOP;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT, BOOLEAN, TEXT[], BIGINT) TO authenticated;
