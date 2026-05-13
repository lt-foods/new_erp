-- ============================================================
-- Staff permissions v1 fixes:
-- 1. stores 是 TEXT[] (store name) 不是 BIGINT[] — 對齊既有 app_metadata 設計
-- 2. self-change role 一律擋 (不只 owner)，避免 admin 也鎖死自己
-- ============================================================

-- Drop 舊 BIGINT[] 版避免 overload
DROP FUNCTION IF EXISTS public.rpc_update_staff_stores(UUID, BIGINT[]);

-- ============================================================
-- rpc_update_staff_role 加 self-change 防線
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

  SELECT (raw_app_meta_data ->> 'tenant_id')::uuid,
         COALESCE(raw_app_meta_data ->> 'role', '')
    INTO v_target_tenant, v_target_role
    FROM auth.users
   WHERE id = p_user_id;

  IF NOT FOUND OR v_target_tenant IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'user % not in tenant', p_user_id;
  END IF;

  -- 任何 caller 都不能改自己 role（防鎖死、強制讓另一位 owner/admin 操作）
  IF p_user_id = v_caller_id THEN
    RAISE EXCEPTION 'cannot change own role; ask another owner/admin to do it';
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

  -- 保留至少 1 個 owner
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
-- rpc_update_staff_stores: 用 TEXT[] (store name)
-- 驗證 name 存在 stores 表 + 'HQ'/'總倉' magic value 也允許
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_update_staff_stores(
  p_user_id     UUID,
  p_store_names TEXT[]
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_target_tenant  UUID;
  v_invalid_name   TEXT;
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  SELECT (raw_app_meta_data ->> 'tenant_id')::uuid INTO v_target_tenant
    FROM auth.users WHERE id = p_user_id;
  IF NOT FOUND OR v_target_tenant IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'user % not in tenant', p_user_id;
  END IF;

  -- 驗證每個 name 是 '總倉' magic value 或實際 store name
  IF p_store_names IS NOT NULL AND array_length(p_store_names, 1) > 0 THEN
    SELECT n INTO v_invalid_name
      FROM unnest(p_store_names) AS n
     WHERE n <> '總倉'
       AND NOT EXISTS (
         SELECT 1 FROM stores
          WHERE name = n AND tenant_id = v_tenant
       )
     LIMIT 1;
    IF v_invalid_name IS NOT NULL THEN
      RAISE EXCEPTION 'store "%" not in tenant', v_invalid_name;
    END IF;
  END IF;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
       || jsonb_build_object('stores', COALESCE(to_jsonb(p_store_names), '[]'::jsonb))
   WHERE id = p_user_id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_staff_stores(UUID, TEXT[]) TO authenticated;
