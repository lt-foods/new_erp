-- ============================================================================
-- 2026-06-06: push_subscriptions 支援原生推播（APNs / FCM）
-- ----------------------------------------------------------------------------
-- 基底版本：rpc_upsert_push_subscription 以
--   20260603000000_push_subs_unique_per_member.sql 為基底（時間最新版，
--   含 (tenant_id, member_id) 衝突鍵 + service_role 帶 member/tenant 參數）。
--
-- 變更：
--   1. endpoint / p256dh / auth 改為 nullable（原生用 device_token，
--      不需要 web push 三件組）
--   2. 新增 provider / device_token / platform / app_version 欄
--   3. 唯一性從「每 member 一筆」放寬為「每 member × 每投遞目標一筆」
--      （web 以 endpoint、原生以 device_token 為投遞目標）
--      → 支援同一會員多裝置同時訂閱（web + iOS + Android）
--   4. rpc_upsert_push_subscription 擴參數，依投遞目標 upsert
--
-- Rollback：指回 20260603000000_push_subs_unique_per_member.sql
--   （DROP push_subs_target_uq、DROP 新欄位、還原 endpoint/p256dh/auth NOT NULL
--    與 (tenant_id, member_id) UNIQUE，並還原該檔的 6 參數 RPC）
-- ============================================================================

-- ── 1. 欄位 ─────────────────────────────────────────────────────────────────
ALTER TABLE push_subscriptions
  ADD COLUMN IF NOT EXISTS provider     TEXT NOT NULL DEFAULT 'webpush',
  ADD COLUMN IF NOT EXISTS device_token TEXT,
  ADD COLUMN IF NOT EXISTS platform     TEXT,
  ADD COLUMN IF NOT EXISTS app_version  TEXT;

-- web push 三件組對原生訂閱為 NULL → 放寬 NOT NULL
ALTER TABLE push_subscriptions ALTER COLUMN endpoint DROP NOT NULL;
ALTER TABLE push_subscriptions ALTER COLUMN p256dh   DROP NOT NULL;
ALTER TABLE push_subscriptions ALTER COLUMN auth     DROP NOT NULL;

COMMENT ON COLUMN push_subscriptions.provider     IS '投遞通道：webpush | fcm | apns';
COMMENT ON COLUMN push_subscriptions.device_token IS '原生裝置 token（FCM/APNs）；web 為 NULL';
COMMENT ON COLUMN push_subscriptions.platform     IS 'ios | android | web';
COMMENT ON COLUMN push_subscriptions.app_version  IS '回報時的 App 版本（debug 用）';

-- ── 2. 唯一性：每 member × 每投遞目標一筆 ────────────────────────────────────
-- 放寬舊的 (tenant_id, member_id) 單筆限制，改以「投遞目標」為唯一鍵：
-- 同會員可同時擁有 web + iOS + Android 多筆訂閱；同目標重訂則覆蓋。
ALTER TABLE push_subscriptions
  DROP CONSTRAINT IF EXISTS push_subscriptions_tenant_member_unique;

-- 投遞目標 = COALESCE(device_token, endpoint)，用 expression unique index。
CREATE UNIQUE INDEX IF NOT EXISTS push_subs_target_uq
  ON push_subscriptions (tenant_id, member_id, provider, COALESCE(device_token, endpoint));

-- ── 3. RPC：依投遞目標 upsert ───────────────────────────────────────────────
-- 清掉所有歷史簽名，避免 PostgREST 以具名參數呼叫時 overload 撞車。
DROP FUNCTION IF EXISTS rpc_upsert_push_subscription(TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS rpc_upsert_push_subscription(TEXT, TEXT, TEXT, TEXT, BIGINT, UUID);

CREATE OR REPLACE FUNCTION rpc_upsert_push_subscription(
  p_endpoint     TEXT   DEFAULT NULL,
  p_p256dh       TEXT   DEFAULT NULL,
  p_auth         TEXT   DEFAULT NULL,
  p_user_agent   TEXT   DEFAULT NULL,
  p_member_id    BIGINT DEFAULT NULL,
  p_tenant_id    UUID   DEFAULT NULL,
  p_provider     TEXT   DEFAULT 'webpush',
  p_device_token TEXT   DEFAULT NULL,
  p_platform     TEXT   DEFAULT NULL,
  p_app_version  TEXT   DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant    UUID   := COALESCE(p_tenant_id, (auth.jwt() ->> 'tenant_id')::UUID);
  v_member_id BIGINT := COALESCE(p_member_id, (auth.jwt() ->> 'member_id')::BIGINT);
  v_target    TEXT   := COALESCE(p_device_token, p_endpoint);
  v_id        BIGINT;
BEGIN
  IF v_tenant IS NULL OR v_member_id IS NULL THEN
    RAISE EXCEPTION 'missing tenant_id or member_id (v_tenant=%, v_member_id=%)',
                    v_tenant, v_member_id;
  END IF;
  IF v_target IS NULL THEN
    RAISE EXCEPTION 'need endpoint (webpush) or device_token (native)';
  END IF;

  INSERT INTO push_subscriptions (
    tenant_id, member_id, provider, endpoint, p256dh, auth,
    device_token, platform, app_version, user_agent
  ) VALUES (
    v_tenant, v_member_id, COALESCE(p_provider, 'webpush'), p_endpoint, p_p256dh, p_auth,
    p_device_token, p_platform, p_app_version, p_user_agent
  )
  ON CONFLICT (tenant_id, member_id, provider, COALESCE(device_token, endpoint)) DO UPDATE
  SET endpoint     = EXCLUDED.endpoint,
      p256dh       = EXCLUDED.p256dh,
      auth         = EXCLUDED.auth,
      device_token = EXCLUDED.device_token,
      platform     = EXCLUDED.platform,
      app_version  = EXCLUDED.app_version,
      user_agent   = EXCLUDED.user_agent,
      updated_at   = NOW()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_upsert_push_subscription(
  TEXT, TEXT, TEXT, TEXT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT
) TO authenticated;
