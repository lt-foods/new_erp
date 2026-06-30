-- ============================================================
-- 店長「自己店」範圍 helper + 修 stock_balances RLS
--
-- 背景：店員角色 store_manager 的 JWT 只有 app_metadata.role / app_metadata.stores
--   （stores 是「店名陣列」，admin-controlled），但 **沒有 location_id / store_id**。
--   現行 stock_balances 的 store_read_own 政策卻要 jwt.role='clerk' 且
--   location_id = jwt.location_id → 對 store_manager 完全不符 → 店長讀不到任何
--   庫存、一律回 0。
--
-- 修法：用既有的 app_metadata.stores（店名）對應到 stores 表，取出該店長管理的
--   store_id / location_id，包成兩個 SECURITY DEFINER helper，再讓 RLS（及退貨
--   RPC，見 20260707000080）共用。不需改登入流程或帳號資料。
--
-- 安全性：helper 為 SECURITY DEFINER（繞過 stores RLS），但只認 **使用者自己**
--   app_metadata.stores 裡的店名（app_metadata 由 admin 控制、使用者不可改），且
--   tenant 綁定，故不能越權注入別店。
--
-- Rollback：
--   DROP POLICY store_read_own ON stock_balances; 再建回舊版（clerk + jwt.location_id）；
--   DROP FUNCTION public._jwt_store_ids(); DROP FUNCTION public._jwt_store_location_ids();
-- ============================================================

-- ----------------------------------------------------------------
-- 1. helper：店長 JWT(app_metadata.stores 店名) → store_id[] / location_id[]
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._jwt_store_ids()
RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(s.id), '{}')
    FROM stores s
   WHERE s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
     AND s.name = ANY (ARRAY(
       SELECT jsonb_array_elements_text(
         COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb))));
$$;

CREATE OR REPLACE FUNCTION public._jwt_store_location_ids()
RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(s.location_id), '{}')
    FROM stores s
   WHERE s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
     AND s.location_id IS NOT NULL
     AND s.name = ANY (ARRAY(
       SELECT jsonb_array_elements_text(
         COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb))));
$$;

COMMENT ON FUNCTION public._jwt_store_ids() IS
  '回傳當前使用者(app_metadata.stores 店名)對應的 store id 陣列。tenant 綁定、SECURITY DEFINER。';
COMMENT ON FUNCTION public._jwt_store_location_ids() IS
  '回傳當前使用者(app_metadata.stores 店名)對應的 location id 陣列。tenant 綁定、SECURITY DEFINER。';

GRANT EXECUTE ON FUNCTION public._jwt_store_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public._jwt_store_location_ids() TO authenticated;

-- ----------------------------------------------------------------
-- 2. 修 stock_balances 的 store_read_own：店長只看自己店 location
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS store_read_own ON stock_balances;
CREATE POLICY store_read_own ON stock_balances
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('store_manager','store_staff','clerk')
    AND location_id = ANY (public._jwt_store_location_ids())
  );

COMMENT ON POLICY store_read_own ON stock_balances IS
  '門市角色(store_manager/store_staff/clerk)只讀自己店 location 的庫存結存；'
  '自己店 location 由 app_metadata.stores 店名經 _jwt_store_location_ids() 推導。';
