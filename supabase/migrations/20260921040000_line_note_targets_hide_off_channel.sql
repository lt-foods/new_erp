-- ============================================================================
-- 20260921040000_line_note_targets_hide_off_channel.sql
--
-- 開團列表「LINE 記事本」彈窗：**不收這一類團的社群直接不要出現在清單裡**
-- （老闆 9/21：「這個社群沒有開放『一般商城』的團 —— 是這個狀態的社群就不要出現，
--   不會看起來雜亂」）。20260921020000 當時刻意留著它們、只是不給勾＋寫理由，
-- 改成照老闆要的隱藏。
--
-- 唯一的例外照舊：**已經有貼文的一律列出來**（`p.id IS NOT NULL`）。
-- 社群設定是後來才改的，歷史貼文與它的留言不能因為改設定就從畫面上消失。
--
-- 「為什麼整片空白」由彈窗自己解釋：沒有半個可發社群時會寫出
-- 「這是『漂漂館』的團，只發得到有勾這一類的社群 → 去社群設定改」。
--
-- 只動最後那一行 WHERE，其餘與基底逐字相同：
--   基底 rpc_line_note_campaign_targets @ 20260921020000（已與正式庫 pg_get_functiondef 對過）
--   -   WHERE c.scoped OR p.id IS NOT NULL
--   +   WHERE (c.scoped AND c.takes_chan) OR p.id IS NOT NULL
-- 回傳欄位沒變 → CREATE OR REPLACE 就夠，不用 DROP。
-- can_post / blocked_reason 一個字都沒動（跟 rpc_line_note_queue_posts 擋的東西
-- 還是一模一樣；那支照樣會擋，直接打 RPC 也發不到沒開放的社群）。
--
-- rollback：把 WHERE 改回 `c.scoped OR p.id IS NOT NULL`（＝ 20260921020000 那版）。
-- ============================================================================

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
   -- 範圍外（別家店的 / 沒開放這一類團的）不列出來 —— 清單只留真的發得到的。
   -- 唯一例外：已經有貼文的一定要出現，設定是後來才改的，歷史不能憑空消失。
   -- 一個都沒有時由彈窗寫出原因（「只發得到有勾這一類的社群」）。
   WHERE (c.scoped AND c.takes_chan) OR p.id IS NOT NULL
   ORDER BY (p.id IS NOT NULL) DESC, c.home_name NULLS LAST, c.id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_campaign_targets(BIGINT) TO authenticated;
