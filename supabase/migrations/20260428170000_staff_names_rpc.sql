-- ============================================================
-- staff names lookup：用於 UI timeline 顯示「誰」
-- 從 auth.users 取 email / raw_user_meta_data.display_name
-- 因為 auth.users 受限，用 SECURITY DEFINER function 開口
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_get_staff_names(p_uids UUID[])
RETURNS TABLE(id UUID, display_name TEXT, email TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    u.id,
    COALESCE(
      NULLIF(u.raw_user_meta_data ->> 'display_name', ''),
      NULLIF(u.raw_user_meta_data ->> 'name', ''),
      split_part(u.email, '@', 1),
      substring(u.id::text, 1, 8)
    ) AS display_name,
    u.email
  FROM auth.users u
  WHERE u.id = ANY(p_uids);
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_staff_names TO authenticated;

COMMENT ON FUNCTION public.rpc_get_staff_names IS
  '批次查 staff 顯示名稱：取 raw_user_meta_data.display_name 或 email 前綴';
