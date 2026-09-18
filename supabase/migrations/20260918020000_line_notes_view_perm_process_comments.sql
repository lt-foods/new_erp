-- ============================================================================
-- 20260918020000_line_notes_view_perm_process_comments.sql
--
-- `line_notes_view` 功能權限：除了看，也要能**處理留言**（Alex 2026-09-18 看到分店店長
-- 的留言加單分頁沒有任何處理鈕）。發文 / 讀留言 / 帳號 / 社群設定仍只有總部。
--
-- 留言加單那四顆鈕各走什麼：
--   重試        rpc_line_note_apply_comment —— 本來就沒有角色 gate（只驗 tenant），不用動。
--   已解決/忽略/退回未處理  前端直接 UPDATE line_note_comments —— 被 lncm_hq_all（FOR ALL、
--               總部角色）擋成 0 rows、**不報錯**。本檔加一條 UPDATE policy 給 perm 持有者，
--               範圍同 SELECT（_line_note_post_visible：社群沒綁店或綁自己店、團是總部或自己店）。
--   指定會員    rpc_line_note_assign_member 原本 _line_note_require_admin()；改成
--               _line_note_require_comment_access(p_comment_id)：總部角色照舊放行，
--               perm 持有者要那則留言在自己看得到的範圍內才放行。
--
-- 基底：rpc_line_note_assign_member ← 20260918010000（唯一前版），只換 gate 那一行。
-- Rollback：
--   DROP POLICY IF EXISTS lncm_perm_update ON public.line_note_comments;
--   重跑 20260918010000 的 rpc_line_note_assign_member 段；
--   DROP FUNCTION public._line_note_require_comment_access(BIGINT);
-- ============================================================================

-- 1. perm 持有者可以改自己看得到的留言（狀態 / 已解決備註）
DROP POLICY IF EXISTS lncm_perm_update ON public.line_note_comments;
CREATE POLICY lncm_perm_update ON public.line_note_comments FOR UPDATE
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND public._line_note_post_visible(post_id)
  )
  WITH CHECK (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND public._line_note_post_visible(post_id)
  );

-- 2. 「這個人可以處理這則留言嗎」：總部角色，或有 perm 且留言在可見範圍
CREATE OR REPLACE FUNCTION public._line_note_require_comment_access(p_comment_id BIGINT)
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
     AND EXISTS (SELECT 1 FROM line_note_comments c
                  WHERE c.id = p_comment_id AND c.tenant_id = v_tenant
                    AND public._line_note_post_visible(c.post_id)) THEN
    RETURN v_tenant;
  END IF;
  RAISE EXCEPTION 'insufficient_role';
END;
$$;
REVOKE ALL ON FUNCTION public._line_note_require_comment_access(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._line_note_require_comment_access(BIGINT) TO authenticated;

-- 3. rpc_line_note_assign_member — 基底 20260918010000，只換 gate
CREATE OR REPLACE FUNCTION public.rpc_line_note_assign_member(
  p_comment_id BIGINT,
  p_member_id  BIGINT
)
RETURNS TABLE (out_status TEXT, out_error TEXT, out_order_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._line_note_require_comment_access(p_comment_id);
  v_c      line_note_comments%ROWTYPE;
  v_mstat  TEXT;
BEGIN
  SELECT * INTO v_c FROM line_note_comments WHERE id = p_comment_id AND tenant_id = v_tenant;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'comment % not in tenant', p_comment_id; END IF;
  IF v_c.commenter_id IS NULL THEN RAISE EXCEPTION 'no_commenter_id: 這則留言沒有留言者 id，無法記住'; END IF;
  IF v_c.status = 'ordered' THEN RAISE EXCEPTION 'already_ordered: 這則已經加成單了'; END IF;

  SELECT m.status INTO v_mstat FROM members m WHERE m.id = p_member_id AND m.tenant_id = v_tenant;
  IF v_mstat IS NULL THEN RAISE EXCEPTION 'member % not in tenant', p_member_id; END IF;
  IF v_mstat IN ('merged','deleted') THEN RAISE EXCEPTION 'member_inactive: 這位會員已被合併／刪除'; END IF;

  PERFORM public._line_note_remember_commenter(v_tenant, v_c.commenter_id, v_c.commenter_name, p_member_id, 'manual');

  RETURN QUERY SELECT r.out_status, r.out_error, r.out_order_id
                 FROM public.rpc_line_note_apply_comment(p_comment_id, TRUE) r;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_line_note_assign_member(BIGINT, BIGINT) TO authenticated;
