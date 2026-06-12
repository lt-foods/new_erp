-- ============================================================================
-- 2026-07-07: 試用期到期控管 — SaaS 化 Phase 2
-- ----------------------------------------------------------------------------
-- 兩道防線（docs/PLAN-試用租戶註冊.md §4）：
--   1. pg_cron 每小時掃 trial_expires_at 過期的 trial → status='suspended'
--      （資料保留，只擋操作；之後 purge 或轉正式由人決定）
--   2. _current_tenant_id() 加 status 守門：suspended / deleted 租戶
--      呼叫任何用到它的 RPC（含全部寫入 RPC）直接 raise。
--      前端另有整頁「試用已到期」擋畫面（讀取走 RLS 不在此擋，
--      到期後回來「看」資料仍可以，動不了而已）。
--
-- _current_tenant_id 改寫基底：20260424120000（唯一版本，已 grep 全 migrations
-- 確認無其他 CREATE OR REPLACE）。原行為（無 claim → raise）完整保留。
-- rollback：還原 20260424120000 的 _current_tenant_id；
--           SELECT cron.unschedule('suspend-expired-trials');
--           DROP FUNCTION public.rpc_suspend_expired_trials();
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. _current_tenant_id：加 tenants.status 守門
-- ----------------------------------------------------------------------------
-- 查無 tenants row（舊環境尚未 backfill / e2e 直灌帳號）視同 active 放行，
-- 不破壞既有環境；只有「明確被標 suspended/deleted」才擋。

CREATE OR REPLACE FUNCTION public._current_tenant_id()
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant_text TEXT;
  v_tenant      UUID;
  v_status      TEXT;
BEGIN
  v_tenant_text := auth.jwt() ->> 'tenant_id';
  IF v_tenant_text IS NULL OR v_tenant_text = '' THEN
    RAISE EXCEPTION 'JWT missing tenant_id claim; ensure custom_access_token_hook is enabled and user has app_metadata.tenant_id set';
  END IF;
  v_tenant := v_tenant_text::UUID;

  SELECT status INTO v_status FROM public.tenants WHERE id = v_tenant;
  IF v_status = 'suspended' THEN
    RAISE EXCEPTION '試用已到期，帳號已暫停操作。如需繼續使用或刪除資料，請聯絡我們。'
      USING ERRCODE = 'P0001';
  ELSIF v_status = 'deleted' THEN
    RAISE EXCEPTION 'tenant has been deleted' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_tenant;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. 到期自動 suspend（pg_cron 每小時）
-- ----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA cron TO postgres;

CREATE OR REPLACE FUNCTION public.rpc_suspend_expired_trials()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count INT;
BEGIN
  UPDATE public.tenants
     SET status = 'suspended'
   WHERE status = 'trial'
     AND trial_expires_at IS NOT NULL
     AND trial_expires_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.rpc_suspend_expired_trials IS
  'pg_cron 每小時：到期 trial → suspended（資料保留、擋操作）';

REVOKE EXECUTE ON FUNCTION public.rpc_suspend_expired_trials FROM authenticated, anon, public;
GRANT EXECUTE ON FUNCTION public.rpc_suspend_expired_trials TO service_role;

-- cron.schedule 同名 job 為 idempotent，重複 run migration 不會炸
SELECT cron.schedule(
  'suspend-expired-trials',
  '7 * * * *',
  $cron$ SELECT public.rpc_suspend_expired_trials(); $cron$
);
