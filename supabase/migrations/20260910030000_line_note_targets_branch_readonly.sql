-- ============================================================================
-- 20260910030000_line_note_targets_branch_readonly.sql
--
-- 開團的「LINE 記事本」彈窗：分店帳號看得到歷史，但發文只有總部能按。
--
-- 原本 rpc_line_note_campaign_targets 開頭就是 _line_note_require_admin()，
-- 分店帳號一問就 insufficient_role → 彈窗整個打不開，所以那顆按鈕乾脆只給
-- admin 看。結果是店家完全不知道自家的團有沒有發到社群、客人在底下留了什麼，
-- 只能回頭問總部。
--
-- 改成：**讀**放給同 tenant 的所有角色，**發文**維持原本那組角色。
--
-- ⚠ can_post 用的角色集合要跟 rpc_line_note_queue_posts 擋的那組**完全一樣**
--   （= _line_note_require_admin 的 owner/admin/hq_manager/assistant/''），
--   不是前端的 isAdmin(owner/admin/'')。兩邊各寫一套就會變成
--   「畫面說可以發、按下去說 insufficient_role」——20260910020000 的檔頭就在講這件事。
--   前端只負責「分店 → 整個發文區塊不畫出來」，寬嚴由這支決定。
--
-- 分店看得到的範圍（兩層都要，不然會看到別家店的客人留言）：
--   團：總部的團，或自己店開的團（不是自己的 → wrong_store）
--   社群：沒綁店的（總部社群，大家的團都發那裡），或綁到自己店的
-- 目前線上兩個社群都是總部社群 → 分店照樣看得到歷史，不會開了是空的。
--
-- 另外新增 rpc_line_note_post_comments：彈窗原本直接 SELECT line_note_comments，
-- 那張表的 RLS 只放總部角色，分店讀回來會是空的（不會報錯，就是空的 —— 比報錯更難查）。
--
-- 基底：rpc_line_note_campaign_targets @ 20260910020000（唯一前版，已 grep 確認）。
--       欄位、母體、排序全部原樣，只動授權與 can_post/blocked_reason。
-- rollback：還原 20260910020000 的 rpc_line_note_campaign_targets；
--           DROP FUNCTION public.rpc_line_note_post_comments(BIGINT);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 「這個帳號看得到這篇貼文嗎」——targets 與 comments 共用同一套判斷
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_branch_visible_store(p_store_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  -- 沒綁店 = 總部社群／總部團，誰都看得到；綁了店就要是自己的店
  SELECT NOT public._is_branch_scoped_user()
      OR p_store_id IS NULL
      OR EXISTS (
           SELECT 1 FROM stores s
            WHERE s.id = p_store_id
              AND s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
              AND COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb) ? s.name);
$$;
GRANT EXECUTE ON FUNCTION public._line_note_branch_visible_store(BIGINT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 1. 這團可以發到哪些群組 / 已經發成什麼樣（讀：全角色；發文：只有總部）
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
  v_tenant   UUID    := public._current_tenant_id();
  -- 發文的角色集合＝rpc_line_note_queue_posts 會放行的那組，不要另外定義
  v_may_post BOOLEAN := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
                        = ANY (ARRAY['owner','admin','hq_manager','assistant','']);
  v_owner    BIGINT;
  v_cstat    TEXT;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'no tenant in token'; END IF;

  SELECT g.owner_store_id, g.status INTO v_owner, v_cstat
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
           -- 開團自動發文的範圍：總部的團發到所有社群，店家自開的團只發到那家店的
           -- （跟 _line_note_on_campaign_open 同一條件，改一邊記得改另一邊）
           (v_owner IS NULL OR lc.store_id = v_owner) AS scoped
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
         c.scoped,
         -- can_post / blocked_reason 要跟 rpc_line_note_queue_posts 擋的東西**一模一樣**。
         -- 注意「已經發過」的判準是 posted 或 line_post_id 有值，不是「有這一列」——
         -- status='failed'（發文失敗、LINE 上根本沒東西）必須還能再發一次。
         (v_may_post AND c.scoped AND c.a_status = 'active'
            AND v_cstat IN ('open','closed')
            AND NOT (p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL))) AS can_post,
         CASE WHEN p.id IS NOT NULL AND (p.status = 'posted' OR p.line_post_id IS NOT NULL)
                                                    THEN '已經發過了'
              WHEN NOT v_may_post                   THEN '發文到社群只有總部能操作'
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
-- 2. 一篇貼文爬回來的留言（讀：全角色，範圍同上）
--    彈窗原本直接 SELECT line_note_comments，那張表的 RLS 只放總部角色 ——
--    分店讀回來是**空的、不報錯**，畫面會變成「有 12 則留言」但展開什麼都沒有。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_line_note_post_comments(p_post_id BIGINT)
RETURNS TABLE (
  id                BIGINT,
  line_comment_id   TEXT,
  commenter_name    TEXT,
  text              TEXT,
  commented_at      TIMESTAMPTZ,
  member_no_hint    TEXT,
  status            TEXT,
  customer_order_id BIGINT,
  error             TEXT,
  reacted_at        TIMESTAMPTZ,
  resolution_note   TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_cstore BIGINT;   -- 貼文所在社群綁的店
  v_ostore BIGINT;   -- 這篇貼文那個團的主辦店
  v_found  BOOLEAN;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'no tenant in token'; END IF;

  SELECT TRUE, lc.store_id, g.owner_store_id
    INTO v_found, v_cstore, v_ostore
    FROM line_note_posts lp
    JOIN line_note_communities lc ON lc.id = lp.community_id
    LEFT JOIN group_buy_campaigns g ON g.id = lp.campaign_id
   WHERE lp.id = p_post_id AND lp.tenant_id = v_tenant;
  IF NOT COALESCE(v_found, FALSE) THEN RAISE EXCEPTION 'post % not in tenant', p_post_id; END IF;

  IF NOT (public._line_note_branch_visible_store(v_cstore)
          AND public._line_note_branch_visible_store(v_ostore)) THEN
    RAISE EXCEPTION 'wrong_store: 這不是你的店看得到的貼文';
  END IF;

  RETURN QUERY
  SELECT cm.id, cm.line_comment_id, cm.commenter_name, cm.text, cm.commented_at,
         cm.member_no_hint, cm.status, cm.customer_order_id, cm.error,
         cm.reacted_at, cm.resolution_note
    FROM line_note_comments cm
   WHERE cm.post_id = p_post_id AND cm.tenant_id = v_tenant
   ORDER BY cm.commented_at NULLS LAST, cm.id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_post_comments(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_line_note_post_comments(BIGINT) IS
  '一篇記事本貼文爬回來的留言。分店帳號也讀得到（line_note_comments 的 RLS 只放總部角色），'
  '範圍限「總部社群或自己店的社群」×「總部團或自己店開的團」。';
