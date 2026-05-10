-- ============================================================================
-- Issue #73: order_shortage_events — FIFO 分配不足紀錄 (PRD §Q16)
-- append-only log；shortage_qty 為 generated column
-- ============================================================================

CREATE TABLE order_shortage_events (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  campaign_id   BIGINT NOT NULL,
  order_id      BIGINT NOT NULL REFERENCES customer_orders(id),
  sku_id        BIGINT NOT NULL,
  requested_qty NUMERIC(18,3),
  fulfilled_qty NUMERIC(18,3),
  shortage_qty  NUMERIC(18,3) GENERATED ALWAYS AS (requested_qty - fulfilled_qty) STORED,
  reason        TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ose_campaign  ON order_shortage_events (tenant_id, campaign_id);
CREATE INDEX idx_ose_order     ON order_shortage_events (tenant_id, order_id);
CREATE INDEX idx_ose_sku       ON order_shortage_events (tenant_id, sku_id);

-- append-only guard
CREATE OR REPLACE FUNCTION forbid_shortage_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'order_shortage_events is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_update_shortage
  BEFORE UPDATE ON order_shortage_events FOR EACH ROW EXECUTE FUNCTION forbid_shortage_mutation();
CREATE TRIGGER trg_no_delete_shortage
  BEFORE DELETE ON order_shortage_events FOR EACH ROW EXECUTE FUNCTION forbid_shortage_mutation();

-- RLS
ALTER TABLE order_shortage_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY ose_hq_all ON order_shortage_events
  AS PERMISSIVE FOR ALL TO authenticated
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'hq');

CREATE POLICY ose_store_read ON order_shortage_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
    AND order_id IN (
      SELECT id FROM customer_orders
       WHERE pickup_store_id = (auth.jwt() -> 'app_metadata' ->> 'store_id')::bigint
    )
  );
