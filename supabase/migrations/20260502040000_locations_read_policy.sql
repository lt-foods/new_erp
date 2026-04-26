-- locations 表 RLS enabled 但沒 policy → PostgreSQL deny all。
-- 一般前端 query「找總倉 location」回空陣列 → 「找不到總倉 location」錯誤。
--
-- 補上 tenant 內 SELECT policy，採跟其他模組一致的「app_metadata.role 為空也通過」設計。

CREATE POLICY auth_read_locations ON locations
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
  );
