-- ============================================================================
-- 20260919000000_line_notes_view_perm_link_post.sql
--
-- `line_notes_view` 功能權限：貼文分頁的「指定團」（把「未認出團」的貼文綁到某一團）
-- 也開給 perm 持有者（Alex 2026-09-19：LINE 記事本底下的貼文，裡面的綁定團，
-- 一般店長也要可以看到）。發文 / 立即讀取 / 刪貼文 / 帳號 / 社群設定仍只有總部。
--
-- 為什麼要開：認不出團的貼文「指定團之後才會開始讀留言加單」，分店店長在留言加單
-- 分頁處理留言（20260918020000）時，碰到未認出團的貼文只能等總部來指定。
--
-- 走什麼：
--   指定團   rpc_line_note_post_link 原本 _line_note_require_admin()；改成
--            _line_note_require_post_access(p_id)：總部角色照舊放行，perm 持有者要那則
--            貼文在自己看得到的範圍內（_line_note_post_visible）才放行。
--            另外多一道：指定的那一團也要在自己看得到的範圍（總部的團或自己店開的團，
--            _line_note_branch_visible_store(owner_store_id)），總部角色這道永遠 true。
--   團的清單 前端直接讀 group_buy_campaigns，走既有 RLS（分店看得到總部團與自己店的團）。
--
-- 基底：rpc_line_note_post_link ← 20260910000000（唯一前版，已 grep 確認），
--       只換 gate 那一行 + 加團的可見範圍檢查。
-- Rollback：
--   重跑 20260910000000 的 rpc_line_note_post_link 段；
--   DROP FUNCTION public._line_note_require_post_access(BIGINT);
-- ============================================================================

-- 1. 「這個人可以動這則貼文嗎」：總部角色，或有 perm 且貼文在可見範圍
--    （比照 20260918020000 的 _line_note_require_comment_access）
CREATE OR REPLACE FUNCTION public._line_note_require_post_access(p_post_id BIGINT)
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  IF v_role IN ('owner','admin','hq_manager','assistant','') THEN
    RETURN v_tenant;
  END IF;
  IF public._jwt_has_perm('line_notes_view')
     AND EXISTS (SELECT 1 FROM line_note_posts p
                  WHERE p.id = p_post_id AND p.tenant_id = v_tenant
                    AND public._line_note_post_visible(p.id)) THEN
    RETURN v_tenant;
  END IF;
  RAISE EXCEPTION 'insufficient_role';
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_require_post_access(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._line_note_require_post_access(BIGINT) TO authenticated;

-- 2. rpc_line_note_post_link — 基底 20260910000000，換 gate + 團的可見範圍
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
BEGIN
  SELECT community_id INTO v_community
    FROM line_note_posts WHERE id = p_id AND tenant_id = v_tenant;
  IF v_community IS NULL THEN RAISE EXCEPTION 'post % not in tenant', p_id; END IF;

  SELECT TRUE, owner_store_id INTO v_found, v_owner
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
         status      = CASE WHEN status = 'unlinked' THEN 'posted' ELSE status END,
         updated_by  = auth.uid(),
         updated_at  = NOW()
   WHERE id = p_id AND tenant_id = v_tenant;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_post_link(BIGINT, BIGINT) TO authenticated;
