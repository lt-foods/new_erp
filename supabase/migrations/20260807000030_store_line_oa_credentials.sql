-- ============================================================================
-- 2026-08-07: 每分店自己的 LINE Messaging API 憑證
--
-- 背景：這個租戶是「每加盟店各自申請 LINE OA」的架構（21 家活躍店裡已有 14 家
-- 填了 stores.line_oa_basic_id，各自不同）。所以推播憑證天生是 per-store 的，
-- 不可能用單一組全域 token —— 對 A 店的好友，只有 A 店的 channel 推得到。
-- 對齊 docs/PRD-通知模組.md §6.10「LINE OA 憑證管理」。
--
-- ⚠ 為什麼另開一張表，而不是加欄位在 stores：
--   channel_secret 是密鑰。RLS 是 **row-level 不是 column-level**，只要它在
--   stores 上，任何能讀 stores 的店員都能用 PostgREST 直接 `select=*` 撈走。
--   所以放獨立表 + 不給任何 policy（= 前端一律讀不到），只有 service_role
--   （edge function）bypass RLS 讀得到。
--
-- 寫入走 rpc_set_store_line_oa（SECURITY DEFINER + owner/admin gate），
-- 讀狀態走 rpc_get_store_line_oa_status（**只回 channel_id，永不回 secret**）。
-- ============================================================================

CREATE TABLE IF NOT EXISTS store_line_oa_credentials (
  store_id                BIGINT      PRIMARY KEY REFERENCES stores(id) ON DELETE CASCADE,
  tenant_id               UUID        NOT NULL,
  channel_id              TEXT        NOT NULL,
  channel_secret          TEXT        NOT NULL,
  -- 用 channel_id + secret 跟 LINE 換來的 token（client_credentials，約 30 天）。
  -- 快取在這裡，避免每次發訊息都多打一次 LINE 的 oauth 端點。
  access_token            TEXT,
  access_token_expires_at TIMESTAMPTZ,
  updated_by              UUID,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  store_line_oa_credentials IS
  '每分店的 LINE Messaging API 憑證。含密鑰，前端一律讀不到（無 RLS policy），只有 service_role 讀得到';
COMMENT ON COLUMN store_line_oa_credentials.channel_secret IS
  '密鑰 —— 不可經任何 RPC / view 回傳給前端';
COMMENT ON COLUMN store_line_oa_credentials.access_token IS
  'client_credentials 換來的 channel access token 快取；改憑證時會清空強制重換';

-- ── RLS：故意「一條 policy 都不給」= authenticated / anon 讀寫都是零列 ─────
-- service_role 走 bypass，不受影響。
ALTER TABLE store_line_oa_credentials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON store_line_oa_credentials FROM anon, authenticated;

-- ── 寫入：owner / admin 才可以設定分店憑證 ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_set_store_line_oa(
  p_store_id       BIGINT,
  p_channel_id     TEXT,
  p_channel_secret TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() ->> 'role', '');
  v_cid    TEXT := NULLIF(btrim(COALESCE(p_channel_id, '')), '');
  v_sec    TEXT := NULLIF(btrim(COALESCE(p_channel_secret, '')), '');
BEGIN
  -- '' = 沒有顯式 role 的 legacy/dev admin，對齊 apps/admin/src/lib/role.ts 的 ADMIN_ROLES
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有負責人 / 管理員可以設定 LINE 憑證';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM stores WHERE id = p_store_id AND tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'store_not_found';
  END IF;

  -- 兩個都給空 = 清除設定（該店改回沒有自己的推播憑證）
  IF v_cid IS NULL AND v_sec IS NULL THEN
    DELETE FROM store_line_oa_credentials WHERE store_id = p_store_id;
    RETURN;
  END IF;

  IF v_cid IS NULL OR v_sec IS NULL THEN
    RAISE EXCEPTION 'channel_id 與 channel_secret 必須一起提供';
  END IF;

  INSERT INTO store_line_oa_credentials AS c
    (store_id, tenant_id, channel_id, channel_secret, updated_by, updated_at)
  VALUES (p_store_id, v_tenant, v_cid, v_sec, auth.uid(), NOW())
  ON CONFLICT (store_id) DO UPDATE SET
    channel_id     = EXCLUDED.channel_id,
    channel_secret = EXCLUDED.channel_secret,
    -- 憑證換了，舊 token 一定要作廢，否則會繼續拿舊 OA 的 token 發訊息
    access_token            = NULL,
    access_token_expires_at = NULL,
    updated_by     = EXCLUDED.updated_by,
    updated_at     = NOW();
END;
$$;

COMMENT ON FUNCTION public.rpc_set_store_line_oa(BIGINT, TEXT, TEXT) IS
  '設定分店 LINE Messaging API 憑證（owner/admin）。兩個參數都傳空字串 = 清除';

-- ── 讀狀態：只回「有沒有設定 + channel_id」，永遠不回 secret ────────────────
-- channel_id 等同 OAuth 的 client_id，不是密鑰，回給前端可以讓管理員確認接對帳號。
CREATE OR REPLACE FUNCTION public.rpc_get_store_line_oa_status()
RETURNS TABLE (
  store_id   BIGINT,
  channel_id TEXT,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() ->> 'role', '');
BEGIN
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  RETURN QUERY
    SELECT c.store_id, c.channel_id, c.updated_at
      FROM store_line_oa_credentials c
     WHERE c.tenant_id = v_tenant;
END;
$$;

COMMENT ON FUNCTION public.rpc_get_store_line_oa_status() IS
  '列出本租戶已設定 LINE 憑證的分店（只回 channel_id，不回 secret）';

REVOKE ALL ON FUNCTION public.rpc_set_store_line_oa(BIGINT, TEXT, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_get_store_line_oa_status() FROM anon;
