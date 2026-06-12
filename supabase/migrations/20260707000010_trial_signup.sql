-- ============================================================================
-- 2026-07-07: 試用租戶自助註冊 — SaaS 化 Phase 1 後端
-- ----------------------------------------------------------------------------
-- 配合 edge function `trial-signup`（公開端點，見 supabase/functions/trial-signup/）：
--   1. trial_signup_attempts — 註冊嘗試紀錄（rate limit 用）。
--      RLS 開、不開任何 policy = client 全擋，只有 service_role（edge fn）可讀寫。
--   2. rpc_seed_trial_tenant — 新試用租戶的最低可動資料集：
--      總倉 location（多數模組假設存在）+ 一家示範門市 + 預設會員等級。
--      內容對齊 scripts/e2e/01-master.sql 的 code 慣例（WH-HQ / S001 / T-*），
--      但刻意只給最小集合，試用者自己的主檔自己建。
--      冪等：該 tenant 已有任何 location 就直接 return（edge fn retry 安全）。
--
-- 基底：tenants 表 = 20260707000000（Phase 0）。全新物件，無既有版本。
-- rollback：DROP FUNCTION public.rpc_seed_trial_tenant(UUID);
--           DROP TABLE public.trial_signup_attempts;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. trial_signup_attempts（append-only、service_role only）
-- ----------------------------------------------------------------------------

CREATE TABLE trial_signup_attempts (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      TEXT NOT NULL,
  ip         INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE trial_signup_attempts IS '試用註冊嘗試（rate limit）。無 tenant_id：平台層資料，不隨租戶 purge。';

CREATE INDEX idx_tsa_email_created ON trial_signup_attempts (email, created_at);
CREATE INDEX idx_tsa_ip_created    ON trial_signup_attempts (ip, created_at);

ALTER TABLE trial_signup_attempts ENABLE ROW LEVEL SECURITY;
-- 不開 policy：authenticated / anon 全擋，service_role bypass RLS

-- ----------------------------------------------------------------------------
-- 2. rpc_seed_trial_tenant
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_seed_trial_tenant(p_tenant_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM public.tenants WHERE id = p_tenant_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'rpc_seed_trial_tenant: tenant not found: %', p_tenant_id;
  END IF;
  IF v_status <> 'trial' THEN
    RAISE EXCEPTION 'rpc_seed_trial_tenant: tenant status must be trial, got %', v_status;
  END IF;

  -- 冪等守門：已 seed 過（有任何 location）就跳過
  IF EXISTS (SELECT 1 FROM public.locations WHERE tenant_id = p_tenant_id) THEN
    RETURN;
  END IF;

  -- 倉別：總倉 + 示範店倉（code 慣例對齊 scripts/e2e/01-master.sql）
  INSERT INTO public.locations (tenant_id, code, name, type) VALUES
    (p_tenant_id, 'WH-HQ',   '總倉',     'central_warehouse'),
    (p_tenant_id, 'WH-S001', '示範店倉', 'store');

  -- 示範門市（supplier_id 留空：試用者自己的供應商自己建）
  INSERT INTO public.stores
    (tenant_id, code, name, location_id, notification_mode, pickup_window_days, allowed_payment_methods)
  SELECT p_tenant_id, 'S001', '示範門市', l.id, 'simple', 5, '["cash"]'::jsonb
    FROM public.locations l
   WHERE l.tenant_id = p_tenant_id AND l.code = 'WH-S001';

  -- 預設會員等級（對齊 e2e seed 的三級制）
  INSERT INTO public.member_tiers (tenant_id, code, name, sort_order, benefits) VALUES
    (p_tenant_id, 'T-NORMAL', '一般會員', 1, '{"points_multiplier":1.0,"member_price_eligible":false}'::jsonb),
    (p_tenant_id, 'T-SILVER', '銀卡會員', 2, '{"points_multiplier":1.2,"member_price_eligible":true}'::jsonb),
    (p_tenant_id, 'T-GOLD',   '金卡會員', 3, '{"points_multiplier":1.5,"member_price_eligible":true}'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.rpc_seed_trial_tenant IS
  '試用租戶基礎資料 seed（trial-signup edge fn 專用）。只允許 service_role 呼叫。';

REVOKE EXECUTE ON FUNCTION public.rpc_seed_trial_tenant FROM authenticated, anon, public;
GRANT EXECUTE ON FUNCTION public.rpc_seed_trial_tenant TO service_role;
