-- ============================================================================
-- 20260910020000_line_note_campaign_publish.sql
--
-- 記事本的貼文整合進「開團」：開團列表每一團自己有一顆 LINE 記事本按鈕，
-- 在那邊勾要發到哪幾個群組、一次發出去，同一個彈窗也看得到這團爬回來的
-- 貼文與留言。原本要先跑到「LINE 記事本 → 社群設定 → 逐個社群按發文」，
-- 一團發三個群組就要開三次彈窗、還得自己記得哪個發過了。
--
-- 兩支新函式（沒有覆蓋既有 function）：
--
--  1. rpc_line_note_campaign_targets(campaign)
--     這團「可以發到哪些群組 + 已經發成什麼樣」。母體 = 開團自動發文那支
--     trigger（_line_note_on_campaign_open @ 20260909020000）認得的範圍
--     ∪ 已經有貼文的群組（範圍後來改了也要看得到歷史）。
--     ⚠ can_post 這一欄的判定要跟 rpc_line_note_queue_posts 一模一樣 ——
--       彈窗的預設勾選（預設全選＝全部 can_post）、按鈕能不能按都吃它，
--       兩邊各算一套就會出現「畫面說可以發、按下去說不行」，或反過來
--       「畫面說不能發，其實那是一篇發失敗的貼文、本來就該能重發」。
--
--  2. rpc_line_note_queue_posts(campaign, community_ids[])
--     一次排好幾個群組的發文工作，**逐群組回結果**，不用例外中斷整批。
--     既有的 rpc_line_note_queue_post（單一社群、已發過就 RAISE）原封不動 ——
--     「LINE 記事本 → 社群設定 → 發文」還在用它，它靠那個例外顯示錯誤。
--
-- 「已經發過」的判準是 status='posted' **或 line_post_id IS NOT NULL**：
-- 光看 status 會漏掉「發成功了但後來被推成 closed」的貼文，重排一次
-- 就是在 LINE 上多貼一篇、而 line_post_id 被覆蓋掉 → 舊那篇沒人管得到
-- （留言也再也讀不回來）。記事本貼文只能刪掉重發，客人已經看到了。
--
-- rollback：
--   DROP FUNCTION public.rpc_line_note_campaign_targets(BIGINT);
--   DROP FUNCTION public.rpc_line_note_queue_posts(BIGINT, BIGINT[]);
--   DROP FUNCTION public._line_note_comment_is_todo(TEXT, TEXT);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 「這則留言還要人看」的判定，收成一支
--    前端同一套在 apps/admin/src/lib/lineNoteStatus.ts（isTodoComment），
--    改一邊記得改另一邊 —— 貼文頁的待處理徽章與這裡的統計要對得上。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_comment_is_todo(
  p_status TEXT, p_member_no_hint TEXT
) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE
AS $$
  SELECT p_status IN ('pending','unmatched','error')
      OR (p_status = 'no_order' AND COALESCE(p_member_no_hint, '') <> '');
$$;

-- ----------------------------------------------------------------------------
-- 1. 這團可以發到哪些群組 / 已經發成什麼樣
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_campaign_targets(p_campaign_id BIGINT)
RETURNS TABLE (
  community_id       BIGINT,
  home_id            TEXT,
  home_name          TEXT,
  home_kind          TEXT,
  store_id           BIGINT,
  store_name         TEXT,
  account_id         BIGINT,
  account_label      TEXT,
  account_status     TEXT,
  auto_post_on_open  BOOLEAN,
  listen_enabled     BOOLEAN,
  in_scope           BOOLEAN,
  can_post           BOOLEAN,
  blocked_reason     TEXT,
  post_id            BIGINT,
  post_status        TEXT,
  line_post_id       TEXT,
  post_text          TEXT,
  posted_at          TIMESTAMPTZ,
  last_read_at       TIMESTAMPTZ,
  closed_reason      TEXT,
  post_error         TEXT,
  comment_total      INT,
  comment_ordered    INT,
  comment_duplicate  INT,
  comment_todo       INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_owner  BIGINT;
  v_cstat  TEXT;
BEGIN
  SELECT g.owner_store_id, g.status INTO v_owner, v_cstat
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF v_cstat IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;

  RETURN QUERY
  WITH c AS (
    SELECT lc.*,
           a.label  AS a_label,
           a.status AS a_status,
           -- 開團自動發文的範圍：總部的團發到所有社群，店家自開的團只發到那家店的
           -- （跟 _line_note_on_campaign_open 同一條件，改一邊記得改另一邊）
           (v_owner IS NULL OR lc.store_id = v_owner) AS scoped
      FROM line_note_communities lc
      JOIN line_note_accounts a ON a.id = lc.account_id
     WHERE lc.tenant_id = v_tenant
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
               count(*) FILTER (WHERE public._line_note_comment_is_todo(cm.status, cm.member_no_hint))::INT AS todo
          FROM line_note_comments cm WHERE cm.post_id = lp.id
      ) s ON TRUE
     WHERE lp.tenant_id = v_tenant AND lp.campaign_id = p_campaign_id
  )
  SELECT c.id, c.home_id, c.home_name, c.home_kind,
         c.store_id, st.name,
         c.account_id, c.a_label, c.a_status,
         c.auto_post_on_open, c.listen_enabled,
         c.scoped,
         -- can_post / blocked_reason 要跟 rpc_line_note_queue_posts 擋的東西**一模一樣**。
         -- 注意「已經發過」的判準是 posted 或 line_post_id 有值，不是「有這一列」——
         -- status='failed'（發文失敗、LINE 上根本沒東西）必須還能再發一次，
         -- 不然一次失敗就只能跑去記事本頁繞，而那頁也只有「已發過就 RAISE」那條路。
         (c.scoped AND c.a_status = 'active'
            AND v_cstat IN ('open','closed')
            AND NOT (p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL))) AS can_post,
         CASE WHEN p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL)
                                                    THEN '已經發過了'
              WHEN NOT c.scoped                     THEN '這個社群只收該店自開的團'
              WHEN c.a_status <> 'active'            THEN 'LINE 帳號沒有登入'
              WHEN v_cstat NOT IN ('open','closed')  THEN '這團不是開團中／已收單'
         END,
         p.id, p.status, p.line_post_id, p.text,
         p.posted_at, p.last_read_at, p.closed_reason, p.last_error,
         p.n_total, p.n_ordered, p.n_duplicate, p.n_todo
    FROM c
    LEFT JOIN p ON p.community_id = c.id
    LEFT JOIN stores st ON st.id = c.store_id
   -- 範圍外但已經發過的也要列出來（範圍是後來才改的，歷史不能憑空消失）
   WHERE c.scoped OR p.id IS NOT NULL
   ORDER BY (p.id IS NOT NULL) DESC, c.home_name NULLS LAST, c.id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_campaign_targets(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 一次發到好幾個群組
--    out_status：queued（已排隊）/ already_posted（跳過）/ error（這個群組不行）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_queue_posts(
  p_campaign_id   BIGINT,
  p_community_ids BIGINT[]
) RETURNS TABLE (out_community_id BIGINT, out_post_id BIGINT, out_status TEXT, out_error TEXT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_admin();
  v_owner  BIGINT;
  v_cstat  TEXT;
  v_cid    BIGINT;
  v_c      RECORD;
  v_exist  RECORD;
  v_post   BIGINT;
BEGIN
  SELECT g.owner_store_id, g.status INTO v_owner, v_cstat
    FROM group_buy_campaigns g WHERE g.id = p_campaign_id AND g.tenant_id = v_tenant;
  IF v_cstat IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  IF v_cstat NOT IN ('open','closed') THEN
    RAISE EXCEPTION '只有開團中／已收單的團可以發到記事本（這團是 %）', v_cstat;
  END IF;

  FOR v_cid IN
    SELECT DISTINCT x FROM unnest(COALESCE(p_community_ids, ARRAY[]::BIGINT[])) AS x
  LOOP
    SELECT lc.id, lc.account_id, lc.store_id, a.status AS a_status
      INTO v_c
      FROM line_note_communities lc
      JOIN line_note_accounts a ON a.id = lc.account_id
     WHERE lc.id = v_cid AND lc.tenant_id = v_tenant;
    IF v_c.id IS NULL THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, '找不到這個社群'::TEXT;
      CONTINUE;
    END IF;
    IF v_owner IS NOT NULL AND v_c.store_id IS DISTINCT FROM v_owner THEN
      RETURN QUERY SELECT v_cid, NULL::BIGINT, 'error'::TEXT, '這個社群只收該店自開的團'::TEXT;
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

COMMENT ON FUNCTION public.rpc_line_note_queue_posts(BIGINT, BIGINT[]) IS
  '一次把一個團發到多個記事本社群，逐社群回結果（queued/already_posted/error）。'
  '單一社群版是 rpc_line_note_queue_post（已發過會 RAISE）。';
