-- ============================================================================
-- 2026-07-07: tenants 主檔 — SaaS 化 Phase 0（試用租戶註冊的地基）
-- ----------------------------------------------------------------------------
-- 背景（docs/PLAN-試用租戶註冊.md）：
--   全部業務表都有 tenant_id UUID + RLS 隔離，但「租戶」本身沒有主檔，
--   只是散落各表的一個 UUID。要做試用租戶（自助註冊、試用期、一鍵刪除），
--   第一步是給租戶一個身分：tenants 表。
--
-- 本支做三件事：
--   1. tenants 表 + RLS（authenticated 只能讀自己 JWT tenant 那一列；
--      寫入不開 policy = 全擋，之後統一走 service_role / edge function）
--   2. backfill：把現有正式租戶（auth.users.raw_app_meta_data.tenant_id
--      撈 DISTINCT）寫進來，status='active'、is_protected=TRUE。
--      is_protected 是未來 rpc_purge_tenant（一鍵刪除）的硬保險：
--      protected 租戶在任何路徑下都不可 purge。
--      名稱用「包子媽生鮮小舖」= apps/admin/src/lib/tenant.ts 的
--      DEFAULT_TENANT_NAME；local/e2e 環境 auth.users 為空 → backfill 無事發生。
--   3. rpc_get_my_tenant()：前端拿租戶名稱/狀態/試用期的唯一入口。
--      apps/admin 的 getTenantName() 從 env 改為「DB 為主、env fallback」。
--
-- status 值域：
--   trial     試用中（trial_expires_at 有值）
--   active    正式
--   suspended 試用到期（保留資料、擋操作；Phase 2 起作用）
--   deleted   已 purge（墓碑，Phase 3 起作用）
--
-- 基底：全新物件，無既有版本。
-- rollback：DROP FUNCTION public.rpc_get_my_tenant(); DROP TABLE public.tenants;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. tenants 表
-- ----------------------------------------------------------------------------

CREATE TABLE tenants (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name             TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'trial'
                   CHECK (status IN ('trial','active','suspended','deleted')),
  is_protected     BOOLEAN NOT NULL DEFAULT FALSE,
  trial_started_at TIMESTAMPTZ,
  trial_expires_at TIMESTAMPTZ,
  contact_email    TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  purged_at        TIMESTAMPTZ
);

COMMENT ON TABLE tenants IS '租戶主檔（SaaS 化 Phase 0）。寫入一律走 service_role，client 只讀自己。';
COMMENT ON COLUMN tenants.is_protected IS 'TRUE = 永遠不可被 rpc_purge_tenant 刪除（正式租戶保險）';

ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

-- authenticated 只能讀自己 JWT 的 tenant；無 INSERT/UPDATE/DELETE policy = 全擋
CREATE POLICY tenants_self_read ON tenants
  FOR SELECT USING (id = (auth.jwt() ->> 'tenant_id')::uuid);

-- ----------------------------------------------------------------------------
-- 2. backfill 現有租戶
-- ----------------------------------------------------------------------------

INSERT INTO tenants (id, name, status, is_protected)
SELECT DISTINCT
  (u.raw_app_meta_data ->> 'tenant_id')::uuid,
  '包子媽生鮮小舖',   -- 對齊 apps/admin/src/lib/tenant.ts DEFAULT_TENANT_NAME
  'active',
  TRUE
FROM auth.users u
WHERE u.raw_app_meta_data ->> 'tenant_id' IS NOT NULL
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. rpc_get_my_tenant — 前端取得自己租戶的名稱/狀態/試用期
-- ----------------------------------------------------------------------------
-- SECURITY DEFINER + 固定 WHERE id = JWT tenant_id（不收參數，無越權面）。
-- 回傳 0 列 = tenants 尚未 backfill 或 JWT 無 tenant claim，前端 fallback env 名稱。

CREATE OR REPLACE FUNCTION public.rpc_get_my_tenant()
RETURNS TABLE (
  id               UUID,
  name             TEXT,
  status           TEXT,
  trial_expires_at TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT t.id, t.name, t.status, t.trial_expires_at
    FROM public.tenants t
   WHERE t.id = (auth.jwt() ->> 'tenant_id')::uuid;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_my_tenant TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_get_my_tenant FROM anon, public;
