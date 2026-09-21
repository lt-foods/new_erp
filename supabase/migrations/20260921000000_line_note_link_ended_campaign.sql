-- ============================================================================
-- 20260921000000_line_note_link_ended_campaign.sql
--
-- 「指定團」可以指到**已經結單**的團，而且指下去直接收成「已結束」。
--
-- 起因（Alex 2026-09-21，三峽）：貼文分頁堆了一整排「未認出團」，店家說「這些在
-- 三峽已經結單了」。查下去是同一個原因的兩半：
--   * worker 比對候選只撈 status in (open, closed) —— 團一鎖定（= 結單；線上 3,106 團
--     裡有 2,757 在 locked、只有 327 在 open/closed）就從候選裡消失，手貼的貼文認不出來；
--   * 後台「指定團」的清單也只列 open/closed，所以**連手動指定都指不了**，
--     那些貼文只能一直堆著（三峽 50 則 / 松山 36 則，其中 32 則系統裡有同名的團，
--     例：貼文 #686「蒜味排骨酥600g/包」↔ GRP-20260910-007 已鎖定）。
-- worker 那半在 line-note-worker（第二池比對 + 重認庫裡的舊貼文），這支只管 RPC。
--
-- 這支改什麼：指定的團已經不是 open/closed 時，貼文直接標 status='closed'（已結束），
-- 不要標 'posted'。理由是結單後的團**加不了單**，jobRead 本來就會把這種貼文收掉
-- （`cst not in (open, closed) → status = 'closed'`）—— 但那段只掃 read_days 內的貼文，
-- 舊貼文指定完會一直掛著「已發文」卻永遠不會被讀，畫面上看不出它其實已經結束了。
--
-- 沒動：權限 gate（_line_note_require_post_access + 分店可見範圍）、同社群同團的唯一性守衛。
-- 前端的團清單走既有 RLS，改成「草稿 / 已取消以外都列」。
--
-- 基底：rpc_line_note_post_link ← 20260919000000
--       （grep 過 supabase/migrations/：20260910000000 建、20260919000000 換 gate，此為第三版）
-- Rollback：重跑 20260919000000 的 rpc_line_note_post_link 段。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_line_note_post_link(
  p_id          BIGINT,
  p_campaign_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant    UUID := public._line_note_require_post_access(p_id);
  v_community BIGINT;
  v_clash     BIGINT;
  v_owner     BIGINT;
  v_found     BOOLEAN;
  v_cstatus   TEXT;
BEGIN
  SELECT community_id INTO v_community
    FROM line_note_posts WHERE id = p_id AND tenant_id = v_tenant;
  IF v_community IS NULL THEN RAISE EXCEPTION 'post % not in tenant', p_id; END IF;

  SELECT TRUE, owner_store_id, status INTO v_found, v_owner, v_cstatus
    FROM group_buy_campaigns WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF v_found IS NULL THEN RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id; END IF;
  -- 分店只能指定總部的團或自己店開的團（總部角色這道永遠 true）
  IF NOT public._line_note_branch_visible_store(v_owner) THEN
    RAISE EXCEPTION 'wrong_store: 這不是你的店開的團';
  END IF;

  -- 同一個社群同一團只能有一則貼文（UNIQUE (community_id, campaign_id)）
  SELECT id INTO v_clash FROM line_note_posts
   WHERE community_id = v_community AND campaign_id = p_campaign_id AND id <> p_id;
  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION '這個社群已經有一則貼文對應到這一團了，請先處理掉那一則';
  END IF;

  UPDATE line_note_posts
     SET campaign_id = p_campaign_id,
         -- 團還收得了單 → posted（接著讀留言加單）；已經結單 → 直接收成已結束
         status      = CASE WHEN status <> 'unlinked' THEN status
                            WHEN v_cstatus IN ('open','closed') THEN 'posted'
                            ELSE 'closed' END,
         updated_by  = auth.uid(),
         updated_at  = NOW()
   WHERE id = p_id AND tenant_id = v_tenant;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_post_link(BIGINT, BIGINT) TO authenticated;
