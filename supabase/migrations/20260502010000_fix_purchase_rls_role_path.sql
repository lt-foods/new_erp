-- 修正 RLS：role 應從 app_metadata 讀
--
-- 問題：原 policy 用 `auth.jwt() ->> 'role'` 取 supabase 內建的 PG role
-- （永遠是 'authenticated'），不是業務 role。導致一般 admin 帳號
-- UPDATE purchase_request_items 等被靜默擋下（PostgREST 回 200 + 空陣列）。
--
-- 修法：改讀 `auth.jwt() -> 'app_metadata' ->> 'role'`。
-- 沒設業務 role 的 user → NULL → COALESCE '' → 命中 ARRAY 中的空字串 → 通過。

DROP POLICY IF EXISTS pr_hq_all  ON purchase_requests;
DROP POLICY IF EXISTS pri_hq_all ON purchase_request_items;
DROP POLICY IF EXISTS po_hq_all  ON purchase_orders;
DROP POLICY IF EXISTS poi_hq_all ON purchase_order_items;

CREATE POLICY pr_hq_all ON purchase_requests
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );

CREATE POLICY pri_hq_all ON purchase_request_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM purchase_requests pr
       WHERE pr.id = purchase_request_items.pr_id
         AND pr.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );

CREATE POLICY po_hq_all ON purchase_orders
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );

CREATE POLICY poi_hq_all ON purchase_order_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM purchase_orders po
       WHERE po.id = purchase_order_items.po_id
         AND po.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );
