-- 粉絲團設定 CRUD：rpc_upsert_fb_page
--
-- 設計重點：
--   * SECURITY DEFINER 跳過 RLS，內部自驗 role IN ('owner','admin','hq_manager')
--   * tenant_id 從 JWT 拿（不從參數收），避免 client 偽造跨 tenant
--   * access_token 屬機敏：UPDATE 時 p_access_token NULL/'' 視為「保留現值」，
--     避免前端編輯時需要重新貼整串長 token
--   * INSERT 時 p_access_token 必填，且不可為空白
--   * v1 不提供 rpc_delete_fb_page，使用者只能 is_active=false 停用
--     （fb_pages 被 campaign_fb_posts FK 引用，硬刪會破壞既有發文紀錄）

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
    -- 新增：access_token 必填
    IF v_token IS NULL THEN
      RAISE EXCEPTION 'access_token required when creating a new fb page';
    END IF;
    INSERT INTO fb_pages (tenant_id, page_id, name, access_token, sort_order, is_active)
    VALUES (v_tenant, v_pageid, v_name, v_token, v_sort, v_active)
    RETURNING id INTO v_id;
  ELSE
    -- 更新：access_token NULL/空 → 保留原值，否則覆寫
    UPDATE fb_pages
       SET page_id      = v_pageid,
           name         = v_name,
           access_token = COALESCE(v_token, access_token),
           sort_order   = v_sort,
           is_active    = v_active,
           updated_at   = NOW()
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
  'Upsert fb_pages 主檔；UPDATE 時 p_access_token NULL/空字串視為保留原值。';

REVOKE ALL ON FUNCTION rpc_upsert_fb_page(BIGINT, TEXT, TEXT, TEXT, INTEGER, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_upsert_fb_page(BIGINT, TEXT, TEXT, TEXT, INTEGER, BOOLEAN) TO authenticated;
