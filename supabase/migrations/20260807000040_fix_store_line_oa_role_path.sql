-- ============================================================================
-- 2026-08-07: 修正 store_line_oa RPC 的 role 讀取路徑
--
-- Bug：20260807000030 用 `auth.jwt() ->> 'role'` 判斷角色。那個 claim 是
-- **Postgres 角色**（永遠是 'authenticated'），不是應用角色 —— 結果真正的
-- owner / admin 也被擋，畫面上出現：
--   insufficient_role: 只有負責人 / 管理員可以設定 LINE 憑證
--
-- 應用角色在 `auth.jwt() -> 'app_metadata' ->> 'role'`
-- （custom_access_token_hook 只把 tenant_id 拉到頂層，role 沒有拉）。
-- 這個坑本 repo 已經踩過一次，見 20260502010000_fix_purchase_rls_role_path.sql。
--
-- 基底版本：20260807000030_store_line_oa_credentials.sql
--           （已 grep supabase/migrations/ 確認：那是唯一動過這兩支函式的
--             migration，本檔只改 role 判斷，其餘邏輯一字未改）
--
-- Rollback：重跑 20260807000030 的兩支 CREATE OR REPLACE FUNCTION。
-- ============================================================================

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
  -- ⚠ 一定要走 app_metadata；頂層 'role' 是 Postgres 角色，不是應用角色
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
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
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
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
