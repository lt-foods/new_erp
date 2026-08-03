-- ============================================================
-- 員工「功能權限」(per-feature toggle) v1
--
-- 需求：訂單樞紐表 (/orders/pivot) 原本只有 HQ 帳號（app_metadata.stores
--   含「總倉」或未綁店）看得到全部門市欄位；分店帳號一律被鎖在自己那間店。
--   實務上會有「某位分店同仁需要看全部店的樞紐」的例外，但又不想把他升成
--   HQ 帳號（那會連帶開放商品/採購/總倉收件匣等一堆頁面）。
--   → 改成 role 之外再掛一層「個別授予」的功能權限旗標。
--
-- 做法：沿用既有 auth.users.raw_app_meta_data 設計（同 role / stores），
--   新增 key `perms`（TEXT[] → jsonb array of perm key）。v1 只有一個 key：
--     - orders_pivot_all_stores：訂單樞紐表可檢視所有門市
--   之後要加新的細粒度權限，只要在 _is_valid_staff_perm 補 key + 前端
--   ALL_STAFF_PERMS 補一筆即可，不用再動 schema。
--
-- 基底版本：
--   - rpc_list_staff 以 20260613000150_staff_permissions.sql 的版本擴寫
--     （20260613000160_staff_permissions_fix.sql 只改了 rpc_update_staff_role
--       / rpc_update_staff_stores，沒有動 rpc_list_staff）。
--     這裡只多回傳一個 perms 欄位，其餘 SELECT / 排序 / tenant gate 原樣保留。
--     回傳 shape 改變 → 必須先 DROP 再 CREATE。
--
-- Rollback：
--   DROP FUNCTION public.rpc_update_staff_perms(UUID, TEXT[]);
--   DROP FUNCTION public._is_valid_staff_perm(TEXT);
--   DROP FUNCTION public._jwt_has_perm(TEXT);
--   DROP FUNCTION public.rpc_list_staff();
--   再把 rpc_list_staff 重建回 20260613000150_staff_permissions.sql 的版本。
--   （app_metadata.perms 留著不影響任何既有邏輯）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 合法 perm key 白名單
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_valid_staff_perm(p_perm TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT p_perm IN (
    'orders_pivot_all_stores'   -- 訂單樞紐表：檢視所有門市欄位
  );
$$;

COMMENT ON FUNCTION public._is_valid_staff_perm(TEXT) IS
  '功能權限 key 白名單。新增細粒度權限時在這裡加 key（同時更新前端 ALL_STAFF_PERMS）。';

-- ------------------------------------------------------------
-- 2. 目前登入者是否被授予某個功能權限
--    （v1 前端自己讀 JWT 判斷即可；這支留給之後要在 RPC / RLS 加 gate 時共用）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._jwt_has_perm(p_perm TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    jsonb_typeof(auth.jwt() -> 'app_metadata' -> 'perms') = 'array'
      AND (auth.jwt() -> 'app_metadata' -> 'perms') ? p_perm,
    FALSE
  );
$$;

COMMENT ON FUNCTION public._jwt_has_perm(TEXT) IS
  '當前 JWT 的 app_metadata.perms 是否包含指定功能權限 key。perms 由 owner/admin 經 rpc_update_staff_perms 設定，使用者不可自改。';

GRANT EXECUTE ON FUNCTION public._is_valid_staff_perm(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public._jwt_has_perm(TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 3. rpc_update_staff_perms — owner/admin 個別授予功能權限
--    gate 與 tenant 檢查對齊 rpc_update_staff_stores
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_update_staff_perms(
  p_user_id UUID,
  p_perms   TEXT[]
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant        UUID := public._current_tenant_id();
  v_target_tenant UUID;
  v_target_role   TEXT;
  v_invalid_perm  TEXT;
  v_clean         TEXT[];
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  SELECT (raw_app_meta_data ->> 'tenant_id')::uuid,
         COALESCE(raw_app_meta_data ->> 'role', '')
    INTO v_target_tenant, v_target_role
    FROM auth.users
   WHERE id = p_user_id;

  IF NOT FOUND OR v_target_tenant IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'user % not in tenant', p_user_id;
  END IF;

  -- admin 不能動 owner（對齊 rpc_update_staff_role）
  IF NOT public._caller_is_owner() AND v_target_role = 'owner' THEN
    RAISE EXCEPTION 'admin cannot modify owner';
  END IF;

  -- 去重 + 去空白，並驗證每個 key 都在白名單
  SELECT COALESCE(array_agg(DISTINCT p ORDER BY p), '{}')
    INTO v_clean
    FROM unnest(COALESCE(p_perms, '{}')) AS p
   WHERE COALESCE(btrim(p), '') <> '';

  SELECT p INTO v_invalid_perm
    FROM unnest(v_clean) AS p
   WHERE NOT public._is_valid_staff_perm(p)
   LIMIT 1;
  IF v_invalid_perm IS NOT NULL THEN
    RAISE EXCEPTION 'invalid perm: %', v_invalid_perm;
  END IF;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
       || jsonb_build_object('perms', to_jsonb(v_clean))
   WHERE id = p_user_id;

  RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION public.rpc_update_staff_perms(UUID, TEXT[]) IS
  '設定某員工的功能權限清單（app_metadata.perms）。owner/admin 限定、tenant 綁定、admin 不能改 owner。傳空陣列＝收回全部功能權限。改完該員工需重新登入 / token refresh 才生效。';

GRANT EXECUTE ON FUNCTION public.rpc_update_staff_perms(UUID, TEXT[]) TO authenticated;

-- ------------------------------------------------------------
-- 4. rpc_list_staff — 多回一個 perms 欄位
--    （其餘與 20260613000150 版本相同）
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_list_staff();

CREATE OR REPLACE FUNCTION public.rpc_list_staff()
RETURNS TABLE (
  user_id         UUID,
  email           TEXT,
  display_name    TEXT,
  role            TEXT,
  stores          JSONB,
  perms           JSONB,
  disabled        BOOLEAN,
  created_at      TIMESTAMPTZ,
  last_sign_in_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
BEGIN
  IF NOT public._caller_can_manage_staff() THEN
    RAISE EXCEPTION 'permission denied: requires owner/admin role';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.email::TEXT,
    COALESCE(u.raw_user_meta_data ->> 'display_name', u.raw_user_meta_data ->> 'name')::TEXT,
    COALESCE(u.raw_app_meta_data ->> 'role', '')::TEXT,
    COALESCE(u.raw_app_meta_data -> 'stores', '[]'::jsonb),
    CASE
      WHEN jsonb_typeof(u.raw_app_meta_data -> 'perms') = 'array'
        THEN u.raw_app_meta_data -> 'perms'
      ELSE '[]'::jsonb
    END,
    (COALESCE(u.raw_app_meta_data ->> 'role', '') = 'disabled')::BOOLEAN,
    u.created_at,
    u.last_sign_in_at
  FROM auth.users u
  WHERE (u.raw_app_meta_data ->> 'tenant_id')::uuid = v_tenant
  ORDER BY
    CASE COALESCE(u.raw_app_meta_data ->> 'role', '')
      WHEN 'owner' THEN 1
      WHEN 'admin' THEN 2
      WHEN 'hq_manager' THEN 3
      WHEN 'hq_accountant' THEN 4
      WHEN 'purchaser' THEN 5
      WHEN 'assistant' THEN 6
      WHEN 'store_manager' THEN 7
      WHEN 'store_staff' THEN 8
      WHEN 'disabled' THEN 99
      ELSE 50
    END,
    u.email;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_staff() TO authenticated;
