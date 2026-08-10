-- ============================================================================
-- 2026-08-10: 解除會員的 LINE 名冊綁定
--
-- 背景：配對是人工從名冊挑的，會點錯（2026-08-10 平鎮店實際發生兩筆，
-- 相隔一分鐘 —— 錯的綁定 = 訊息發給錯的顧客）。錯了之後畫面上原本沒有
-- 任何解法，只能進資料庫改。這支讓店員自己解。
--
-- 角色與範圍完全對齊 rpc_bind_store_line_follower（20260808000020 版）：
-- 分店角色只能動自己店的會員。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_unbind_store_line_follower(
  p_member_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_store  BIGINT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT home_store_id INTO v_store
    FROM members WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_store IS NULL THEN RAISE EXCEPTION 'member_has_no_store'; END IF;

  IF v_role IN ('store_manager','store_staff') AND NOT EXISTS (
    SELECT 1 FROM stores s
    WHERE s.id = v_store AND s.tenant_id = v_tenant
      AND s.name IN (SELECT jsonb_array_elements_text(auth.jwt() -> 'app_metadata' -> 'stores'))
  ) THEN
    RAISE EXCEPTION 'wrong_store: 只能解除自己店的會員';
  END IF;

  UPDATE store_line_followers
     SET member_id = NULL, linked_at = NULL
   WHERE tenant_id = v_tenant AND store_id = v_store AND member_id = p_member_id;

  IF NOT FOUND THEN
    -- 沒有名冊綁定 → 「可發送」是來自舊登入資料（members.line_user_id），
    -- 那不是這支能解的，讓前端把話說清楚
    RAISE EXCEPTION 'no_binding: 此會員沒有名冊綁定，顯示的 LINE 身分來自舊登入資料';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.rpc_unbind_store_line_follower(BIGINT) IS
  '解除會員在其所屬分店的 LINE 名冊綁定（配對錯了用；分店角色限自己店）';

REVOKE ALL ON FUNCTION public.rpc_unbind_store_line_follower(BIGINT) FROM anon;
