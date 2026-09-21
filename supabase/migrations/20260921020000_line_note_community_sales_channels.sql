-- ============================================================================
-- 20260921020000_line_note_community_sales_channels.sql
--
-- 社群設定新增「這個社群收哪一類的團」（line_note_communities.sales_channels）：
-- 開團有 sales_channel = 'main'（一般商城）／'piaopiao'（漂漂館），
-- 以後**漂漂館的團只發得到有勾漂漂館的社群**，一般商城的團也只發到有勾一般商城的社群。
--
-- 為什麼是陣列不是一顆 boolean：老闆要的是「這個社群能發漂漂館」，但反向那半
-- （專門開給漂漂館的群組不該被日常的團洗版）同一個設定就要能表達，
-- 不然過兩天又要再加一欄。勾選＝這個社群收哪幾種團，至少要勾一種。
--
-- 既有社群一律 '{main}'（預設值）：線上兩個包子媽群組過去是連漂漂館的團也收的
-- （松山 17 篇、三峽 3 篇），這次收斂就是老闆要的「只發到相關的社群」——
-- 要繼續收漂漂館的話到社群設定把「漂漂館」勾回來就好，一個開關的事。
--
-- ⚠ 範圍規則散在四個地方，這次一起改，而且新規則只寫一次（_line_note_takes_channel）：
--   1. _line_note_on_campaign_open()      開團自動發文
--   2. rpc_line_note_campaign_targets()   開團列表「LINE 記事本」彈窗的清單 / can_post
--   3. rpc_line_note_queue_posts()        那顆彈窗按下去真正排工作的（擋的理由要跟 2 一模一樣）
--   4. rpc_line_note_queue_post()         社群設定每一列的「發文」（單一社群）
--   不收這一類的社群**照樣列出來**、只是不能勾（can_post=false + 理由），
--   不要從清單裡消失 —— 「漂漂館的團打開彈窗空空如也」跟壞掉分不出來。
--
-- 基底（都 grep 過全 migrations，並跟正式庫 pg_get_functiondef 對過）：
--   _line_note_on_campaign_open     @ 20260909020000
--   rpc_line_note_campaign_targets  @ 20260910030000（RETURNS TABLE 多一欄 → 必須 DROP 再建）
--   rpc_line_note_queue_posts       @ 20260910020000
--   rpc_line_note_queue_post        @ 20260908010000
--   rpc_line_note_community_upsert  @ 20260909090000（多一個參數 → 必須 DROP 再建）
--
-- rollback：
--   把上面五支還原到各自基底版本，然後
--   DROP FUNCTION public._line_note_takes_channel(TEXT[], TEXT);
--   DROP FUNCTION public._line_note_channel_label(TEXT);
--   ALTER TABLE line_note_communities DROP COLUMN sales_channels;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 欄位：這個社群收哪幾種團
-- ----------------------------------------------------------------------------
ALTER TABLE public.line_note_communities
  ADD COLUMN IF NOT EXISTS sales_channels TEXT[] NOT NULL DEFAULT ARRAY['main']::TEXT[];

ALTER TABLE public.line_note_communities
  DROP CONSTRAINT IF EXISTS line_note_communities_sales_channels_check;
ALTER TABLE public.line_note_communities
  ADD CONSTRAINT line_note_communities_sales_channels_check CHECK (
    COALESCE(array_length(sales_channels, 1), 0) >= 1
    AND array_position(sales_channels, NULL) IS NULL
    AND sales_channels <@ ARRAY['main','piaopiao']::TEXT[]
  );

COMMENT ON COLUMN public.line_note_communities.sales_channels IS
  '這個社群收哪幾類的團（對應 group_buy_campaigns.sales_channel）：main=一般商城、piaopiao=漂漂館。'
  '至少一種。發文範圍＝店家範圍（store_id）AND 這一欄，四支函式共用 _line_note_takes_channel()。';

-- ----------------------------------------------------------------------------
-- 2. 規則本體：只寫這一次
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_takes_channel(
  p_channels TEXT[], p_sales_channel TEXT
) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE
AS $$
  SELECT COALESCE(p_sales_channel, 'main')
         = ANY (COALESCE(NULLIF(p_channels, ARRAY[]::TEXT[]), ARRAY['main']::TEXT[]));
$$;
COMMENT ON FUNCTION public._line_note_takes_channel(TEXT[], TEXT) IS
  '這個社群收不收這一類的團。發文範圍的另一半是店家範圍（總部團發全部／店家團只發標了那家店的）。';

CREATE OR REPLACE FUNCTION public._line_note_channel_label(p_sales_channel TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN p_sales_channel = 'piaopiao' THEN '漂漂館' ELSE '一般商城' END; $$;

-- ----------------------------------------------------------------------------
-- 3. 開團自動發文：多一道「這個社群收不收這一類」
--    基底 20260909020000，只加最後那一個條件。
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
    SELECT c.id AS community_id, c.account_id
      FROM line_note_communities c
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
     WHERE c.tenant_id = NEW.tenant_id
       AND c.auto_post_on_open
       AND (NEW.owner_store_id IS NULL OR c.store_id = NEW.owner_store_id)
       AND public._line_note_takes_channel(c.sales_channels, NEW.sales_channel)
  LOOP
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id, 'queued', NEW.updated_by, NEW.updated_by)
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
-- 4. 彈窗的清單：多回一欄 sales_channels，in_scope 併入類別，擋下的理由講清楚是哪一條
--    RETURNS TABLE 變了 → 一定要先 DROP（CREATE OR REPLACE 會報 cannot change return type）。
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_line_note_campaign_targets(BIGINT);

CREATE FUNCTION public.rpc_line_note_campaign_targets(p_campaign_id BIGINT)
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
  sales_channels     TEXT[],
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
           public._line_note_takes_channel(lc.sales_channels, v_chan) AS takes_chan
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
               count(*) FILTER (WHERE public._line_note_comment_is_todo(cm.status, cm.member_no_hint))::INT AS todo
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
            AND v_cstat IN ('open','closed')
            AND NOT (p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL))) AS can_post,
         CASE WHEN p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL)
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
   -- 範圍外但已經發過的也要列出來（範圍是後來才改的，歷史不能憑空消失）。
   -- 不收這一類的社群也留在清單上（只是不能勾）—— 不然漂漂館的團打開來整片空白，
   -- 跟「社群設定壞了」分不出來。
   WHERE c.scoped OR p.id IS NOT NULL
   ORDER BY (p.id IS NOT NULL) DESC, c.home_name NULLS LAST, c.id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_campaign_targets(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. 真的排工作那支：擋的條件與訊息跟上面逐字一致
--    基底 20260910020000，只加類別那一段。
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
    SELECT lc.id, lc.account_id, lc.store_id, lc.sales_channels, a.status AS a_status
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

-- ----------------------------------------------------------------------------
-- 6. 社群設定每一列的「發文」（單一社群）：同一道守衛，不然它就是後門
--    基底 20260908010000。
-- ----------------------------------------------------------------------------
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
  v_chan     TEXT;
  v_post     BIGINT;
BEGIN
  SELECT account_id, sales_channels INTO v_account, v_channels FROM line_note_communities
   WHERE id = p_community_id AND tenant_id = v_tenant;
  IF v_account IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_community_id; END IF;
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
-- 7. 社群設定存檔：多收一個 p_sales_channels（簽名變了 → DROP 舊的再建）
--    基底 20260909090000。
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT, BOOLEAN);

CREATE FUNCTION public.rpc_line_note_community_upsert(
  p_id                BIGINT,
  p_account_id        BIGINT,
  p_home_id           TEXT,
  p_home_name         TEXT,
  p_home_kind         TEXT,
  p_listen_enabled    BOOLEAN,
  p_read_times        TEXT[],
  p_auto_post_on_open BOOLEAN,
  p_post_template     TEXT,
  p_read_days         INT DEFAULT 3,
  p_store_id          BIGINT DEFAULT NULL,
  p_react_on_confirm  BOOLEAN DEFAULT TRUE,
  p_sales_channels    TEXT[] DEFAULT NULL
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

  IF p_id IS NULL THEN
    -- 撞號 = 這個社群早就設定過了，把表單的值套到既有那筆（一個社群只有一份設定）
    INSERT INTO line_note_communities
      (tenant_id, account_id, store_id, home_id, home_name, home_kind,
       listen_enabled, read_times, auto_post_on_open, post_template, read_days, react_on_confirm,
       sales_channels, created_by, updated_by)
    VALUES
      (v_tenant, p_account_id, p_store_id, v_home, p_home_name,
       COALESCE(p_home_kind, 'square_chat'),
       COALESCE(p_listen_enabled, FALSE),
       COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), ARRAY['12:00']),
       COALESCE(p_auto_post_on_open, TRUE),
       NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
       COALESCE(p_read_days, 3),
       COALESCE(p_react_on_confirm, TRUE),
       COALESCE(v_chans, ARRAY['main']::TEXT[]),
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

    UPDATE line_note_communities
       SET account_id        = p_account_id,
           store_id          = p_store_id,
           home_id           = v_home,
           home_name         = p_home_name,
           home_kind         = COALESCE(p_home_kind, home_kind),
           listen_enabled    = COALESCE(p_listen_enabled, listen_enabled),
           read_times        = COALESCE(NULLIF(p_read_times, ARRAY[]::TEXT[]), read_times),
           auto_post_on_open = COALESCE(p_auto_post_on_open, auto_post_on_open),
           post_template     = NULLIF(TRIM(COALESCE(p_post_template, '')), ''),
           read_days         = COALESCE(p_read_days, read_days),
           react_on_confirm  = COALESCE(p_react_on_confirm, react_on_confirm),
           sales_channels    = COALESCE(v_chans, sales_channels),
           updated_by        = auth.uid()
     WHERE id = p_id AND tenant_id = v_tenant
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'community % not in tenant', p_id; END IF;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_community_upsert(
  BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, TEXT[], BOOLEAN, TEXT, INT, BIGINT, BOOLEAN, TEXT[]) TO authenticated;
