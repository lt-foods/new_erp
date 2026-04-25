-- ============================================================
-- Purchase 模組 RLS 補強：admin / 一般 authenticated tenant 內讀寫
-- 既有 pr_helper / pr_store_manager 過於嚴格，admin 用戶看不到 PR/PO
-- 沿用 group_buy_campaigns 的 auth_read_* + *_hq_all 模式
-- ============================================================

-- purchase_requests
DROP POLICY IF EXISTS auth_read_purchase_requests ON purchase_requests;
DROP POLICY IF EXISTS pr_hq_all ON purchase_requests;

CREATE POLICY auth_read_purchase_requests ON purchase_requests
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
  );

CREATE POLICY pr_hq_all ON purchase_requests
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );

-- purchase_request_items（沒有 tenant_id 欄位，依 pr_id 透過 EXISTS 檢查）
ALTER TABLE purchase_request_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_read_purchase_request_items ON purchase_request_items;
DROP POLICY IF EXISTS pri_hq_all ON purchase_request_items;

CREATE POLICY auth_read_purchase_request_items ON purchase_request_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM purchase_requests pr
       WHERE pr.id = purchase_request_items.pr_id
         AND pr.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
  );

CREATE POLICY pri_hq_all ON purchase_request_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM purchase_requests pr
       WHERE pr.id = purchase_request_items.pr_id
         AND pr.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
    AND COALESCE(auth.jwt() ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );

-- purchase_orders
DROP POLICY IF EXISTS auth_read_purchase_orders ON purchase_orders;
DROP POLICY IF EXISTS po_hq_all ON purchase_orders;

CREATE POLICY auth_read_purchase_orders ON purchase_orders
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
  );

CREATE POLICY po_hq_all ON purchase_orders
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );

-- purchase_order_items
ALTER TABLE purchase_order_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_read_purchase_order_items ON purchase_order_items;
DROP POLICY IF EXISTS poi_hq_all ON purchase_order_items;

CREATE POLICY auth_read_purchase_order_items ON purchase_order_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM purchase_orders po
       WHERE po.id = purchase_order_items.po_id
         AND po.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
  );

CREATE POLICY poi_hq_all ON purchase_order_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM purchase_orders po
       WHERE po.id = purchase_order_items.po_id
         AND po.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    )
    AND COALESCE(auth.jwt() ->> 'role', '') = ANY (ARRAY['owner','admin','hq_manager','purchaser',''])
  );
