-- ============================================================================
-- 2026-08-09: 手動配對可以「返回」—— rpc_unbind_store_line_follower
--
-- 背景：rpc_bind_store_line_follower 是店員**用眼睛認**頭像 / LINE 暱稱挑的，
-- 挑錯是常態（同名、換頭像、兩個都像本人）。但綁完之後名冊那一列的
-- member_id 就不是 NULL 了，發送視窗的配對選單（`.is("member_id", null)`）
-- 再也撈不到它 —— 店員按錯一下就沒有回頭路，只能找工程師改 DB。
--
-- 綁錯的後果不是「少一個功能」而是**訊息推給別的顧客**（含可取貨訂單圖，
-- 上面有姓名與品項），所以解除配對這條路一定要留在店員手上。
--
-- 守衛完全對齊 bind（基底：20260808000020，該支是 bind 的最新版本）：
--   同 tenant、分店角色只能動「自己店」的會員。差別只在方向。
-- Rollback：DROP FUNCTION public.rpc_unbind_store_line_follower(BIGINT, TEXT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_unbind_store_line_follower(
  p_member_id    BIGINT,
  p_line_user_id TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  -- ⚠ 應用角色走 app_metadata（見 CLAUDE.md / 20260807000040）
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_store  BIGINT;
  v_hit    INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  SELECT home_store_id INTO v_store
    FROM members WHERE id = p_member_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'member_not_found'; END IF;
  IF v_store IS NULL THEN RAISE EXCEPTION 'member_has_no_store: 此會員沒有取貨店，無法決定要解除哪一家店的配對'; END IF;

  -- 分店角色只能動自己店的會員（身分 = app_metadata.stores 店名陣列）
  IF v_role IN ('store_manager','store_staff') AND NOT EXISTS (
    SELECT 1 FROM stores s
    WHERE s.id = v_store AND s.tenant_id = v_tenant
      AND s.name IN (SELECT jsonb_array_elements_text(auth.jwt() -> 'app_metadata' -> 'stores'))
  ) THEN
    RAISE EXCEPTION 'wrong_store: 只能解除自己店的會員配對';
  END IF;

  -- p_line_user_id 為 NULL = 解除這位會員在該店的所有配對。
  -- 有帶值時只解除那一筆：兩個店員同時開視窗、別人已經改綁成別人時，
  -- 這個條件會讓「返回」自然落空（0 列 → 下面報錯），而不是把新的綁定也拆掉。
  UPDATE store_line_followers
     SET member_id = NULL, linked_at = NULL
   WHERE tenant_id = v_tenant AND store_id = v_store
     AND member_id = p_member_id
     AND (p_line_user_id IS NULL OR line_user_id = p_line_user_id);

  GET DIAGNOSTICS v_hit = ROW_COUNT;
  IF v_hit = 0 THEN
    RAISE EXCEPTION 'binding_not_found: 這位會員目前沒有這筆配對（可能已被其他人解除或改綁）';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.rpc_unbind_store_line_follower(BIGINT, TEXT) IS
  '解除該店 OA 好友名冊與會員的配對（同 tenant + 該會員所屬分店才可）；p_line_user_id 為 NULL 表示解除該會員在該店的所有配對';

REVOKE ALL ON FUNCTION public.rpc_unbind_store_line_follower(BIGINT, TEXT) FROM anon;
