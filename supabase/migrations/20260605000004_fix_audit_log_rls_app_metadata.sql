-- ============================================================
-- customer_order_audit_log RLS：同 SECURITY DEFINER 修法
--   admin user JWT 的 role 是 'authenticated'，自定義 role 在 app_metadata.role
--   修 SELECT policy 讓 HQ 與店家都能正確判斷
-- ============================================================

DROP POLICY IF EXISTS coa_hq_read    ON customer_order_audit_log;
DROP POLICY IF EXISTS coa_store_read ON customer_order_audit_log;

-- HQ：app_metadata.role IN HQ tier，或無自定義 role 視為 HQ tier
CREATE POLICY coa_hq_read ON customer_order_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(
          NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
          NULLIF(auth.jwt() ->> 'role', 'authenticated'),
          ''
        ) IN ('owner','admin','hq_manager','hq_accountant','')
  );

-- 店家：app_metadata.store_id 或 top-level store_id 對到自己 pickup_store
CREATE POLICY coa_store_read ON customer_order_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND order_id IN (
      SELECT id FROM customer_orders
       WHERE pickup_store_id = COALESCE(
         NULLIF(auth.jwt() -> 'app_metadata' ->> 'store_id', '')::bigint,
         NULLIF(auth.jwt() ->> 'store_id','')::bigint
       )
    )
  );
