-- ============================================================================
-- 2026-08-14: Restrict quick-control / guarded-order RPC execute grants
-- ----------------------------------------------------------------------------
-- 20260813000000_quick_campaign_control / 20260813001000_quick_mobile_create_campaign
-- 只 REVOKE FROM PUBLIC，但 Supabase 的 default privileges 會直接把 EXECUTE 發給
-- anon / authenticated（同 20260812021000 的前例），所以線上三支函式 anon 都叫得動。
-- rpc_place_member_order_guarded 是 SECURITY DEFINER 且 p_tenant 走參數、函式內
-- 不驗 caller —— 必須只留 service_role（liff-api 用 service key 呼叫）。
-- 另外兩支函式內有驗 app_metadata role，但照慣例一樣收掉 anon。
-- ============================================================================

REVOKE ALL ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_place_member_order_guarded(UUID, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, TEXT, TEXT) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_quick_update_campaign_control(BIGINT, TEXT, TIMESTAMPTZ, NUMERIC) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_quick_create_campaign_from_product(BIGINT, TEXT, TEXT, TIMESTAMPTZ, TEXT, DATE, NUMERIC, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_quick_create_campaign_from_product(BIGINT, TEXT, TEXT, TIMESTAMPTZ, TEXT, DATE, NUMERIC, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_quick_create_campaign_from_product(BIGINT, TEXT, TEXT, TIMESTAMPTZ, TEXT, DATE, NUMERIC, JSONB) TO authenticated;
