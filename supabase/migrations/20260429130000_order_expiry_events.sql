-- ============================================================================
-- Issue #72: order_expiry_events — 取貨逾期處理紀錄 (PRD §Q10)
-- append-only log；無 RPC（由上層業務邏輯直接 INSERT）
-- ============================================================================

CREATE TABLE order_expiry_events (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  order_id      BIGINT NOT NULL REFERENCES customer_orders(id),
  order_item_id BIGINT,                    -- NULL = 整筆訂單
  action        TEXT NOT NULL CHECK (action IN ('damaged','returned_to_stock','refunded')),
  storage_type  TEXT,
  qty           NUMERIC(18,3) NOT NULL,
  movement_id   BIGINT REFERENCES stock_movements(id),
  operator_id   UUID,                      -- NULL = 系統自動
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_oee_order    ON order_expiry_events (tenant_id, order_id);
CREATE INDEX idx_oee_created  ON order_expiry_events (tenant_id, created_at DESC);

-- append-only guard
CREATE OR REPLACE FUNCTION forbid_expiry_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'order_expiry_events is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_update_expiry
  BEFORE UPDATE ON order_expiry_events FOR EACH ROW EXECUTE FUNCTION forbid_expiry_mutation();
CREATE TRIGGER trg_no_delete_expiry
  BEFORE DELETE ON order_expiry_events FOR EACH ROW EXECUTE FUNCTION forbid_expiry_mutation();

-- RLS
ALTER TABLE order_expiry_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY oee_hq_all ON order_expiry_events
  AS PERMISSIVE FOR ALL TO authenticated
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'hq');

CREATE POLICY oee_store_read ON order_expiry_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
    AND order_id IN (
      SELECT id FROM customer_orders
       WHERE pickup_store_id = (auth.jwt() -> 'app_metadata' ->> 'store_id')::bigint
    )
  );
