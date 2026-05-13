-- ============================================================
-- 員工權限管理 v1
-- PRD:  docs/decisions/2026-04-23-系統立場-混合型.md
-- TEST: docs/TEST-staff-permissions.md
--
-- v1 範圍：list / update_role / update_stores / 停用(role='disabled')
-- v1 不做：邀請新員工（需 Edge Function + service_role）
-- 沿用 auth.users + raw_app_meta_data，無自建員工表
-- ============================================================

-- ============================================================
-- 1. ROLE CONSTANT helper：合法 role 清單
-- ============================================================
CREATE OR REPLACE FUNCTION public._is_valid_staff_role(p_role TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT p_role IN (
    'owner','admin','hq_manager','hq_accountant',
    'purchaser','assistant',
    'store_manager','store_staff',
    'disabled'
  );
$$;

-- caller 是否 owner/admin（操作員工權限的最低門檻）
CREATE OR REPLACE FUNCTION public._caller_can_manage_staff()
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'role') IN ('owner','admin');
$$;

CREATE OR REPLACE FUNCTION public._caller_is_owner()
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'role') = 'owner';
$$;

-- ============================================================
-- 2. rpc_list_staff
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_list_staff()
RETURNS TABLE (
  user_id         UUID,
  email           TEXT,
  display_name    TEXT,
  role            TEXT,
  stores          JSONB,
  disabled        BOOLEAN,
  created_at      TIMESTAMPTZ,
  last_sign_in_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.email::TEXT,
    COALESCE(u.raw_user_meta_data ->> 'display_name', u.raw_user_meta_data ->> 'name')::TEXT,
    COALESCE(u.raw_app_meta_data ->> 'role', '')::TEXT,
    COALESCE(u.raw_app_meta_data -> 'stores', '[]'::jsonb),
    (COALESCE(u.raw_app_meta_data ->> 'role', '') = 'disabled')::BOOLEAN,
    u.created_at,
    u.last_sign_in_at
  FROM auth.users u
  WHERE (u.raw_app_meta_data ->> 'tenant_id')::uuid = v_tenant
  ORDER BY
    CASE COALESCE(u.raw_app_meta_data ->> 'role', '')
      WHEN 'owner' THEN 1
      WHEN 'admin' THEN 2
      WHEN 'hq_manager' THEN 3
      WHEN 'hq_accountant' THEN 4
      WHEN 'purchaser' THEN 5
      WHEN 'assistant' THEN 6
      WHEN 'store_manager' THEN 7
      WHEN 'store_staff' THEN 8
      WHEN 'disabled' THEN 99
      ELSE 50
    END,
    u.email;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_staff() TO authenticated;

-- ============================================================
-- 3. rpc_update_staff_role
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_update_staff_role(
  p_user_id UUID,
  p_role    TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_caller_id    UUID := auth.uid();
  v_target_role  TEXT;
  v_target_tenant UUID;
  v_owner_count  INT;
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  IF NOT public._is_valid_staff_role(p_role) THEN
    RAISE EXCEPTION 'invalid role: %', p_role;
  END IF;

  -- 取目標 user 現況 + tenant 驗證
  SELECT (raw_app_meta_data ->> 'tenant_id')::uuid,
         COALESCE(raw_app_meta_data ->> 'role', '')
    INTO v_target_tenant, v_target_role
    FROM auth.users
   WHERE id = p_user_id;

  IF NOT FOUND OR v_target_tenant IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'user % not in tenant', p_user_id;
  END IF;

  -- 防鎖死：owner 不能 demote 自己 / 不能 disable 自己
  IF p_user_id = v_caller_id AND public._caller_is_owner() THEN
    IF p_role <> 'owner' THEN
      RAISE EXCEPTION 'owner cannot change own role (would lock out)';
    END IF;
  END IF;

  -- admin 不能 promote 任何人為 owner、不能改 owner
  IF NOT public._caller_is_owner() THEN
    IF p_role = 'owner' THEN
      RAISE EXCEPTION 'admin cannot grant owner role';
    END IF;
    IF v_target_role = 'owner' THEN
      RAISE EXCEPTION 'admin cannot modify owner';
    END IF;
  END IF;

  -- 保留至少 1 個 owner：若 target 是 owner 且要改成非 owner，檢查 owner 數
  IF v_target_role = 'owner' AND p_role <> 'owner' THEN
    SELECT COUNT(*) INTO v_owner_count
      FROM auth.users
     WHERE (raw_app_meta_data ->> 'tenant_id')::uuid = v_tenant
       AND COALESCE(raw_app_meta_data ->> 'role', '') = 'owner';
    IF v_owner_count <= 1 THEN
      RAISE EXCEPTION 'cannot remove last owner of tenant';
    END IF;
  END IF;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('role', p_role)
   WHERE id = p_user_id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_staff_role(UUID, TEXT) TO authenticated;

-- ============================================================
-- 4. rpc_update_staff_stores
-- 設定該 user 可存取的 store_id 陣列；HQ role 仍全見、但仍可設 stores 作為「主要管理店」
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_update_staff_stores(
  p_user_id   UUID,
  p_store_ids BIGINT[]
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_target_tenant  UUID;
  v_invalid_count  INT;
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  SELECT (raw_app_meta_data ->> 'tenant_id')::uuid INTO v_target_tenant
    FROM auth.users WHERE id = p_user_id;
  IF NOT FOUND OR v_target_tenant IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'user % not in tenant', p_user_id;
  END IF;

  -- 驗證所有 store_id 都在 tenant
  IF p_store_ids IS NOT NULL AND array_length(p_store_ids, 1) > 0 THEN
    SELECT COUNT(*) INTO v_invalid_count
      FROM unnest(p_store_ids) AS sid
     WHERE NOT EXISTS (
       SELECT 1 FROM stores
        WHERE id = sid AND tenant_id = v_tenant
     );
    IF v_invalid_count > 0 THEN
      RAISE EXCEPTION 'some store_ids not in tenant';
    END IF;
  END IF;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
       || jsonb_build_object('stores', COALESCE(to_jsonb(p_store_ids), '[]'::jsonb))
   WHERE id = p_user_id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_staff_stores(UUID, BIGINT[]) TO authenticated;
