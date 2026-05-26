-- rpc_upsert_fb_page：UPDATE 時若提供新 token，順便清掉 token_invalid_at / token_last_error
--
-- 基底版本：20260621000030_rpc_upsert_fb_page.sql（首版）
-- 變更內容：
--   * 沿用所有既有邏輯（SECURITY DEFINER、role 驗證、token NULL/'' 保留現值等）
--   * UPDATE 分支新增：v_token 非 NULL（= 使用者重貼了 token）→ 同步清掉
--     token_invalid_at + token_last_error；NULL（= 保留現 token）→ 不動。
-- Rollback：CREATE OR REPLACE 回 20260621000030 的版本。
--
-- 動機：使用者手動更新 token 後 UI 不應繼續顯示「失效」警告。

CREATE OR REPLACE FUNCTION rpc_upsert_fb_page(
  p_id            BIGINT,
  p_page_id       TEXT,
  p_name          TEXT,
  p_access_token  TEXT,
  p_sort_order    INTEGER,
  p_is_active     BOOLEAN
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role   TEXT := COALESCE(
                     NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                     NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                     ''
                   );
  v_id     BIGINT;
  v_token  TEXT := NULLIF(TRIM(COALESCE(p_access_token, '')), '');
  v_name   TEXT := NULLIF(TRIM(COALESCE(p_name, '')), '');
  v_pageid TEXT := NULLIF(TRIM(COALESCE(p_page_id, '')), '');
  v_sort   INTEGER := COALESCE(p_sort_order, 0);
  v_active BOOLEAN := COALESCE(p_is_active, TRUE);
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    RAISE EXCEPTION 'permission denied: only owner/admin/hq_manager can manage fb pages';
  END IF;
  IF v_pageid IS NULL THEN
    RAISE EXCEPTION 'page_id required';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'name required';
  END IF;

  IF p_id IS NULL THEN
    IF v_token IS NULL THEN
      RAISE EXCEPTION 'access_token required when creating a new fb page';
    END IF;
    INSERT INTO fb_pages (tenant_id, page_id, name, access_token, sort_order, is_active)
    VALUES (v_tenant, v_pageid, v_name, v_token, v_sort, v_active)
    RETURNING id INTO v_id;
  ELSE
    UPDATE fb_pages
       SET page_id          = v_pageid,
           name             = v_name,
           access_token     = COALESCE(v_token, access_token),
           sort_order       = v_sort,
           is_active        = v_active,
           token_invalid_at = CASE WHEN v_token IS NOT NULL THEN NULL ELSE token_invalid_at END,
           token_last_error = CASE WHEN v_token IS NOT NULL THEN NULL ELSE token_last_error END,
           updated_at       = NOW()
     WHERE id = p_id
       AND tenant_id = v_tenant
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'fb_page % not found in this tenant', p_id;
    END IF;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION rpc_upsert_fb_page IS
  'Upsert fb_pages 主檔；UPDATE 時 p_access_token NULL/空字串視為保留原值，反之同時清掉失效標記。';
