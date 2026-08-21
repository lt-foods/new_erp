-- 漂漂館圖片上傳：移除每日 25 張上限。
-- 保留函式名稱與參數，讓已部署的 piaopiao-api 不必同時更新也能立刻解除限制。
CREATE OR REPLACE FUNCTION public.rpc_piaopiao_reserve_upload_slot(
  p_tenant_id UUID,
  p_publisher_id BIGINT,
  p_operator_id UUID
) RETURNS DATE
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_upload_date DATE := (NOW() AT TIME ZONE 'Asia/Taipei')::DATE;
  v_is_active BOOLEAN;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'piaopiao upload reserve is service-only';
  END IF;

  SELECT TRUE INTO v_is_active
    FROM public.piaopiao_publishers
   WHERE id = p_publisher_id
     AND tenant_id = p_tenant_id
     AND auth_user_id = p_operator_id
     AND is_active = TRUE;

  IF COALESCE(v_is_active, FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'piaopiao publisher is not active';
  END IF;

  RETURN v_upload_date;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_piaopiao_reserve_upload_slot(UUID, BIGINT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_piaopiao_reserve_upload_slot(UUID, BIGINT, UUID) TO service_role;

COMMENT ON FUNCTION public.rpc_piaopiao_reserve_upload_slot(UUID, BIGINT, UUID)
IS '漂漂館圖片上傳日期保留；2026-08-21 起不再限制每日張數，只保留 service_role 與上架帳號有效性檢查。';
