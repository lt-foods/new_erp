-- ============================================================
-- rpc_list_staff — 改回 JSONB 單列 (AUDIT #15)
--
-- 原 RPC RETURNS TABLE,受 PostgREST max_rows=1000 限制,
-- tenant >1000 員工時管理頁顯示不完整。改為 RETURNS jsonb,
-- 包成單列 jsonb_agg array,繞過列數限制。
--
-- PG 不能用 CREATE OR REPLACE 改 return type → DROP + CREATE。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_list_staff();

CREATE OR REPLACE FUNCTION public.rpc_list_staff()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_result jsonb;
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'user_id',         u.id,
      'email',           u.email::text,
      'display_name',    COALESCE(u.raw_user_meta_data ->> 'display_name', u.raw_user_meta_data ->> 'name'),
      'role',            COALESCE(u.raw_app_meta_data ->> 'role', ''),
      'stores',          COALESCE(u.raw_app_meta_data -> 'stores', '[]'::jsonb),
      'disabled',        (COALESCE(u.raw_app_meta_data ->> 'role', '') = 'disabled'),
      'created_at',      u.created_at,
      'last_sign_in_at', u.last_sign_in_at
    )
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
      u.email
  ), '[]'::jsonb)
  INTO v_result
  FROM auth.users u
  WHERE (u.raw_app_meta_data ->> 'tenant_id')::uuid = v_tenant;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_staff() TO authenticated;

COMMENT ON FUNCTION public.rpc_list_staff() IS
  'RETURNS jsonb 單列,避免 PostgREST max_rows=1000 截斷。詳見 docs/STANDARD-資料分頁與筆數限制.md';
