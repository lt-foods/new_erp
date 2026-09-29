-- ============================================================================
-- 20260929000000_line_note_no_bot_for_store_campaign.sql
--
-- 門市自開團（owner_store_id IS NOT NULL）不讓機器人發 LINE 記事本（老闆 9/29）。
--
-- 四個入口一起關：
--   1. _line_note_on_campaign_open（開團自動發文）→ 自開團直接 RETURN
--   2. rpc_line_note_queue_posts（開團彈窗勾社群發）→ 擋
--   3. rpc_line_note_queue_post（/line-notes 單一社群發文／回收後重發）→ 擋
--   4. rpc_line_note_campaign_targets → can_post = false、blocked_reason 寫原因
-- 已經貼上去的舊貼文不動（留言照讀、結單留言照留）；套用當下線上沒有排隊中的自開團貼文。
--
-- 基底：
--   _line_note_on_campaign_open       @ 20260927050000
--   rpc_line_note_queue_posts / _post @ 20260925070000
--   rpc_line_note_campaign_targets    @ 20260927020000
-- rollback：四支函式各自還原到上述基底版本。
-- ============================================================================

-- 1. 開團自動發文
CREATE OR REPLACE FUNCTION public._line_note_on_campaign_open()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c RECORD;
  v_post BIGINT;
BEGIN
  -- 只在「剛變成 open」時跑：INSERT 直接看 NEW，UPDATE 要 OLD 不是 open
  IF NEW.status <> 'open' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'open' THEN RETURN NEW; END IF;
  -- 補貨申請的 sentinel 團（20260612000020）建立時就是 open，不是要發的團
  IF NEW.campaign_no = '__INTERNAL_RESTOCK__' THEN RETURN NEW; END IF;
  -- 這團開團時不發記事本（開團表單的開關）
  IF NOT COALESCE(NEW.line_note_enabled, TRUE) THEN RETURN NEW; END IF;
  -- 門市自開團一律不讓機器人發記事本（老闆 9/29）
  IF NEW.owner_store_id IS NOT NULL THEN RETURN NEW; END IF;
  -- 收單時間已過的團（多半是已收單的團被改回開團中）不發：客人看到也下不了單
  IF (NEW.customer_end_at IS NOT NULL AND NEW.customer_end_at <= NOW())
     OR (NEW.end_at IS NOT NULL AND NEW.end_at <= NOW()) THEN
    RETURN NEW;
  END IF;

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

-- 2. 開團彈窗發文
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
  IF v_owner IS NOT NULL THEN
    RAISE EXCEPTION '門市自開團不發 LINE 記事本';
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

-- 3. 單一社群發文
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
  v_owner    BIGINT;
  v_post     BIGINT;
BEGIN
  SELECT account_id, sales_channels, share_from_community_id INTO v_account, v_channels, v_parent
    FROM line_note_communities
   WHERE id = p_community_id AND tenant_id = v_tenant;
  IF v_account IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_community_id; END IF;
  IF v_parent IS NOT NULL THEN RAISE EXCEPTION '子群跟著母社群分享，不另外發文'; END IF;
  SELECT g.sales_channel, g.owner_store_id INTO v_chan, v_owner
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_owner IS NOT NULL THEN RAISE EXCEPTION '門市自開團不發 LINE 記事本'; END IF;
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

-- 4. 開團彈窗的群組清單
CREATE OR REPLACE FUNCTION public.rpc_line_note_campaign_targets(p_campaign_id bigint)
 RETURNS TABLE(community_id bigint, home_id text, home_name text, home_kind text, store_id bigint, store_name text, account_id bigint, account_label text, account_status text, auto_post_on_open boolean, listen_enabled boolean, sales_channels text[], in_scope boolean, can_post boolean, blocked_reason text, post_id bigint, post_status text, line_post_id text, post_text text, posted_at timestamp with time zone, last_read_at timestamp with time zone, closed_reason text, post_error text, share_state text, shared_at timestamp with time zone, comment_total integer, comment_ordered integer, comment_duplicate integer, comment_todo integer)
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
         (v_may_post AND v_owner IS NULL AND c.scoped AND c.takes_chan AND c.a_status = 'active'
            AND c.share_from_community_id IS NULL
            AND v_cstat IN ('open','closed')
            AND NOT (p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL))) AS can_post,
         CASE WHEN c.share_from_community_id IS NOT NULL
                                                    THEN '子群：跟著「' || COALESCE(c.parent_name, '?') || '」分享，不另外發文'
              WHEN p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL)
                                                    THEN '已經發過了'
              WHEN v_owner IS NOT NULL              THEN '門市自開團不發 LINE 記事本'
              WHEN NOT v_may_post                   THEN '發文到社群只有總部能操作'
              WHEN NOT c.scoped                     THEN '這個社群只收該店自開的團'
              WHEN NOT c.takes_chan                 THEN '這個社群沒有開放「' || public._line_note_channel_label(v_chan) || '」的團'
              WHEN c.a_status <> 'active'            THEN 'LINE 帳號沒有登入'
              WHEN v_cstat NOT IN ('open','closed')  THEN '這團不是開團中／已收單'
         END,
         p.id, p.status, p.line_post_id, p.text,
         p.posted_at, p.last_read_at, p.closed_reason, p.last_error,
         p.share_state, p.shared_at,
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
