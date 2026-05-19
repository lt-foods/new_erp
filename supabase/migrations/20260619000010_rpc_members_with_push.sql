-- ============================================================================
-- 2026-05-19: rpc_members_with_push — 後台會員列表「已安裝 App 並開啟通知」鈴鐺
-- ----------------------------------------------------------------------------
-- push_subscriptions RLS 只允許 member 自己 / role='hq'；後台 admin JWT role
-- 非 'hq'（owner/admin 等）→ 直接 select 會被 RLS 靜默回 0 列（同
-- reference_admin_jwt_role_null 模式）。故包成 SECURITY DEFINER RPC：
--   * 依呼叫端 tenant（_current_tenant_id(), 與 rpc_upsert_member 一致）過濾
--   * 只回傳「給定 p_member_ids 中有 push 訂閱者」的 member_id
--   * UNIQUE(tenant_id, member_id) 保證每人 ≤1 列；DISTINCT 為保險
-- 純唯讀；不碰寫入路徑（rpc_upsert_push_subscription 不動）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_members_with_push(p_member_ids BIGINT[])
RETURNS TABLE (member_id BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT ps.member_id
    FROM push_subscriptions ps
   WHERE ps.tenant_id = public._current_tenant_id()
     AND ps.member_id = ANY(p_member_ids);
$$;

COMMENT ON FUNCTION public.rpc_members_with_push(BIGINT[]) IS
  '後台用：回傳給定 member_ids 中有 web push 訂閱者（=已安裝 PWA + 開啟通知）。'
  ' SECURITY DEFINER 繞過 push_subscriptions RLS（admin JWT role 非 hq），依呼叫端 tenant 過濾。';

GRANT EXECUTE ON FUNCTION public.rpc_members_with_push(BIGINT[]) TO authenticated;
