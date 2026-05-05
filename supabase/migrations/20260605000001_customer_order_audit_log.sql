-- ============================================================
-- customer_order_audit_log: 訂單售價 / 備註變更歷史 (append-only)
--   涵蓋 entity_type IN ('order','item')
--   涵蓋 field IN ('unit_price','item_notes','discount_amount','order_notes')
--   edit_reason 為 optional（與 campaign_audit_log 不同），UI 不強制填
-- ============================================================

CREATE TABLE customer_order_audit_log (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID   NOT NULL,
  order_id     BIGINT NOT NULL REFERENCES customer_orders(id) ON DELETE CASCADE,
  entity_type  TEXT   NOT NULL CHECK (entity_type IN ('order','item')),
  entity_id    BIGINT,
  field        TEXT   NOT NULL CHECK (field IN
                  ('unit_price','item_notes','discount_amount','order_notes')),
  before_value JSONB,
  after_value  JSONB,
  edit_reason  TEXT,
  operator_id  UUID   NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- append-only：無 updated_*
);

CREATE INDEX idx_coa_order  ON customer_order_audit_log (tenant_id, order_id, created_at DESC);
CREATE INDEX idx_coa_entity ON customer_order_audit_log (order_id, entity_type, entity_id);

CREATE TRIGGER trg_no_mut_coa BEFORE UPDATE OR DELETE ON customer_order_audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();

ALTER TABLE customer_order_audit_log ENABLE ROW LEVEL SECURITY;

-- HQ 可看本 tenant 全部
CREATE POLICY coa_hq_read ON customer_order_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() ->> 'role', '') IN
      ('owner','admin','hq_manager','hq_accountant','')
  );

-- 店家只看自己 pickup_store 的訂單
CREATE POLICY coa_store_read ON customer_order_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND order_id IN (
      SELECT id FROM customer_orders
       WHERE pickup_store_id = NULLIF(auth.jwt() ->> 'store_id','')::bigint
    )
  );

-- 不開 INSERT/UPDATE/DELETE policy → 只允 SECURITY DEFINER RPC 寫
