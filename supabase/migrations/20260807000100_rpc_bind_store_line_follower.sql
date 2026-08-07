-- ============================================================================
-- 2026-08-07: 手動把「該店 OA 好友名冊」裡的一筆配對到會員
--
-- 背景：webhook 只知道「有這個 LINE 使用者」，不知道他是哪位會員
-- （store_line_followers.member_id 為 NULL）。官方的 account link（linkToken）
-- 是自動化的正解，但那條路要碰顧客端體驗、得先設計；在那之前先讓店員能手動配對
-- —— 店員本來就認得顧客的 LINE 名稱 / 頭像，這是他們最直覺的做法。
--
-- 安全性：只能配對「自己 tenant」且「該會員所屬分店」的名冊列，
-- 避免把 A 店的 LINE 使用者綁到 B 店的會員身上（那會導致訊息推錯人）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bind_store_line_follower(
  p_member_id    BIGINT,
  p_line_user_id TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  -- ⚠ 應用角色走 app_metadata（見 CLAUDE.md / 20260807000040）
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_store  BIGINT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT home_store_id INTO v_store
    FROM members WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_store IS NULL THEN RAISE EXCEPTION 'member_has_no_store: 此會員沒有取貨店，無法決定要綁哪一家店的官方帳號'; END IF;

  -- 一個會員在同一家店只會有一組 LINE 身分：先解除舊的，再綁新的
  UPDATE store_line_followers
     SET member_id = NULL, linked_at = NULL
   WHERE tenant_id = v_tenant AND store_id = v_store
     AND member_id = p_member_id AND line_user_id <> p_line_user_id;

  UPDATE store_line_followers
     SET member_id = p_member_id, linked_at = NOW()
   WHERE tenant_id = v_tenant AND store_id = v_store
     AND line_user_id = p_line_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'follower_not_found: 這個 LINE 使用者不在該會員所屬分店的名冊裡';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.rpc_bind_store_line_follower(BIGINT, TEXT) IS
  '把該店 OA 好友名冊的一筆配對到會員（同 tenant + 該會員所屬分店才可）';

REVOKE ALL ON FUNCTION public.rpc_bind_store_line_follower(BIGINT, TEXT) FROM anon;
