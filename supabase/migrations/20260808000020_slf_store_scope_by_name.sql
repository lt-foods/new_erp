-- ============================================================================
-- 2026-08-08: 店長讀 LINE 名冊 / 配對，改用 app_metadata.stores（店名陣列）
--
-- Bug：20260807000090 的 slf_store_read 讀 `app_metadata.store_id`，但線上
-- 33 個 staff 帳號**沒有任何一個**有 store_id — 分店身分實際上是
-- `app_metadata.stores`（店名陣列，例 ['林口店']，見 layout.tsx isBranchUser）。
-- 結果店長開發送視窗，配對選單永遠是空的（RLS 靜默回 0 列，不報錯）。
--
-- 順帶收緊 rpc_bind_store_line_follower：原本店長可以幫**任何店**的會員配對，
-- 改成分店角色只能配對「自己店」的會員（hq 層級不變）。
--
-- 基底：20260807000090（slf_store_read）、20260807000100（bind RPC，唯一版本）。
-- Rollback：重跑上述兩支的對應段落。
-- ============================================================================

DROP POLICY IF EXISTS slf_store_read ON store_line_followers;
CREATE POLICY slf_store_read ON store_line_followers
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') IN ('store_manager','store_staff')
    AND EXISTS (
      SELECT 1 FROM stores s
      WHERE s.id = store_line_followers.store_id
        AND s.tenant_id = store_line_followers.tenant_id
        AND s.name IN (
          SELECT jsonb_array_elements_text(auth.jwt() -> 'app_metadata' -> 'stores')
        )
    )
  );

CREATE OR REPLACE FUNCTION public.rpc_bind_store_line_follower(
  p_member_id    BIGINT,
  p_line_user_id TEXT
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
  IF v_store IS NULL THEN RAISE EXCEPTION 'member_has_no_store: 此會員沒有取貨店，無法決定要綁哪一家店的官方帳號'; END IF;

  -- 分店角色只能動自己店的會員（身分 = app_metadata.stores 店名陣列）
  IF v_role IN ('store_manager','store_staff') AND NOT EXISTS (
    SELECT 1 FROM stores s
    WHERE s.id = v_store AND s.tenant_id = v_tenant
      AND s.name IN (SELECT jsonb_array_elements_text(auth.jwt() -> 'app_metadata' -> 'stores'))
  ) THEN
    RAISE EXCEPTION 'wrong_store: 只能配對自己店的會員';
  END IF;

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
