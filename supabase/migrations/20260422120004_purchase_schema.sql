-- ============================================================
-- Purchase / Inbound Module Schema v0.1
-- PostgreSQL 15+ / Supabase
-- 依賴：inventory_schema.sql（locations, stock_movements, rpc_inbound, rpc_outbound）
-- See docs/DB-進貨模組.md for full design rationale.
-- ============================================================

-- ============================================================
-- TABLES
-- ============================================================

-- 1. 供應商
CREATE TABLE suppliers (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  code            TEXT NOT NULL,
  name            TEXT NOT NULL,
  tax_id          TEXT,
  contact_name    TEXT,
  phone           TEXT,
  email           TEXT,
  address         TEXT,
  payment_terms   TEXT,
  lead_time_days  INTEGER,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  notes           TEXT,
  created_by      UUID,
  updated_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE suppliers IS '供應商主檔';

-- 2. 供應商 ↔ SKU 對應
CREATE TABLE supplier_skus (
  tenant_id          UUID NOT NULL,
  supplier_id        BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  sku_id             BIGINT NOT NULL,
  supplier_sku_code  TEXT,
  default_unit_cost  NUMERIC(18,4),
  pack_qty           NUMERIC(18,3) NOT NULL DEFAULT 1,
  is_preferred       BOOLEAN NOT NULL DEFAULT FALSE,
  last_purchased_at  TIMESTAMPTZ,
  notes              TEXT,
  created_by         UUID,
  updated_by         UUID,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, supplier_id, sku_id)
);

-- 3. 商品別名（LINE 解析用）
CREATE TABLE sku_aliases (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  sku_id      BIGINT NOT NULL,
  alias       TEXT NOT NULL,
  source      TEXT NOT NULL CHECK (source IN ('line_parsing','manual','supplier_name','historical')),
  created_by  UUID,
  updated_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, alias)
);
COMMENT ON TABLE sku_aliases IS 'LINE 文字解析用：一個別名對應一個 SKU';

-- 4. 採購單（PR 引用 PO items，故先建）
CREATE TABLE purchase_orders (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  po_no             TEXT NOT NULL,
  supplier_id       BIGINT NOT NULL REFERENCES suppliers(id),
  dest_location_id  BIGINT NOT NULL REFERENCES locations(id),
  status            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                      'draft','sent','partially_received','fully_received','closed','cancelled'
                    )),
  order_date        DATE NOT NULL DEFAULT CURRENT_DATE,
  expected_date     DATE,
  subtotal          NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax               NUMERIC(18,2) NOT NULL DEFAULT 0,
  total             NUMERIC(18,2) NOT NULL DEFAULT 0,
  payment_terms     TEXT,
  created_by        UUID NOT NULL,
  updated_by        UUID,
  sent_at           TIMESTAMPTZ,
  sent_by           UUID,
  sent_channel      TEXT,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, po_no)
);

CREATE TABLE purchase_order_items (
  id             BIGSERIAL PRIMARY KEY,
  po_id          BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
  sku_id         BIGINT NOT NULL,
  qty_ordered    NUMERIC(18,3) NOT NULL CHECK (qty_ordered > 0),
  qty_received   NUMERIC(18,3) NOT NULL DEFAULT 0,
  qty_returned   NUMERIC(18,3) NOT NULL DEFAULT 0,
  unit_cost      NUMERIC(18,4) NOT NULL,
  tax_rate       NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  line_subtotal  NUMERIC(18,2) GENERATED ALWAYS AS (qty_ordered * unit_cost) STORED,
  notes          TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. 請購單（LINE 叫貨）
CREATE TABLE purchase_requests (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL,
  pr_no                TEXT NOT NULL,
  source_location_id   BIGINT REFERENCES locations(id),
  raw_line_text        TEXT,
  status               TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                         'draft','submitted','partially_ordered','fully_ordered','cancelled'
                       )),
  created_by           UUID NOT NULL,
  updated_by           UUID,
  submitted_at         TIMESTAMPTZ,
  notes                TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, pr_no)
);

CREATE TABLE purchase_request_items (
  id                     BIGSERIAL PRIMARY KEY,
  pr_id                  BIGINT NOT NULL REFERENCES purchase_requests(id) ON DELETE CASCADE,
  sku_id                 BIGINT NOT NULL,
  qty_requested          NUMERIC(18,3) NOT NULL CHECK (qty_requested > 0),
  suggested_supplier_id  BIGINT REFERENCES suppliers(id),
  raw_line               TEXT,
  parse_confidence       NUMERIC(4,3),
  po_item_id             BIGINT REFERENCES purchase_order_items(id),
  notes                  TEXT,
  created_by             UUID,
  updated_by             UUID,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. 收貨單
CREATE TABLE goods_receipts (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  gr_no                 TEXT NOT NULL,
  po_id                 BIGINT NOT NULL REFERENCES purchase_orders(id),
  supplier_id           BIGINT NOT NULL REFERENCES suppliers(id),
  dest_location_id      BIGINT NOT NULL REFERENCES locations(id),
  status                TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed','cancelled')),
  receive_date          DATE NOT NULL DEFAULT CURRENT_DATE,
  supplier_invoice_no   TEXT,
  received_by           UUID NOT NULL,
  confirmed_at          TIMESTAMPTZ,
  confirmed_by          UUID,
  notes                 TEXT,
  created_by            UUID,
  updated_by            UUID,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, gr_no)
);

CREATE TABLE goods_receipt_items (
  id                BIGSERIAL PRIMARY KEY,
  gr_id             BIGINT NOT NULL REFERENCES goods_receipts(id) ON DELETE CASCADE,
  po_item_id        BIGINT REFERENCES purchase_order_items(id),
  sku_id            BIGINT NOT NULL,
  qty_expected      NUMERIC(18,3),
  qty_received      NUMERIC(18,3) NOT NULL CHECK (qty_received > 0),
  qty_damaged       NUMERIC(18,3) NOT NULL DEFAULT 0,
  unit_cost         NUMERIC(18,4) NOT NULL,
  batch_no          TEXT,
  expiry_date       DATE,
  variance_reason   TEXT,
  movement_id       BIGINT REFERENCES stock_movements(id),
  notes             TEXT,
  created_by        UUID,
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. 退供單
CREATE TABLE purchase_returns (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL,
  return_no            TEXT NOT NULL,
  supplier_id          BIGINT NOT NULL REFERENCES suppliers(id),
  source_location_id   BIGINT NOT NULL REFERENCES locations(id),
  source_gr_id         BIGINT REFERENCES goods_receipts(id),
  status               TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                         'draft','confirmed','shipped','completed','cancelled'
                       )),
  return_date          DATE NOT NULL DEFAULT CURRENT_DATE,
  reason               TEXT NOT NULL,
  created_by           UUID NOT NULL,
  updated_by           UUID,
  confirmed_at         TIMESTAMPTZ,
  confirmed_by         UUID,
  notes                TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, return_no)
);

CREATE TABLE purchase_return_items (
  id            BIGSERIAL PRIMARY KEY,
  return_id     BIGINT NOT NULL REFERENCES purchase_returns(id) ON DELETE CASCADE,
  gr_item_id    BIGINT REFERENCES goods_receipt_items(id),
  sku_id        BIGINT NOT NULL,
  qty           NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  unit_cost     NUMERIC(18,4) NOT NULL,
  reason        TEXT,
  movement_id   BIGINT REFERENCES stock_movements(id),
  notes         TEXT,
  created_by    UUID,
  updated_by    UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_pr_status         ON purchase_requests (tenant_id, status, created_at DESC);
CREATE INDEX idx_pri_pending       ON purchase_request_items (pr_id) WHERE po_item_id IS NULL;
CREATE INDEX idx_po_supplier       ON purchase_orders (tenant_id, supplier_id, status, order_date DESC);
CREATE INDEX idx_po_status         ON purchase_orders (tenant_id, status);
CREATE INDEX idx_gr_po             ON goods_receipts (po_id, status);
CREATE INDEX idx_gr_recent         ON goods_receipts (tenant_id, receive_date DESC);
CREATE INDEX idx_supplier_skus_sku ON supplier_skus (tenant_id, sku_id) WHERE is_preferred = TRUE;
CREATE INDEX idx_alias_lookup      ON sku_aliases (tenant_id, alias);
CREATE INDEX idx_return_supplier   ON purchase_returns (tenant_id, supplier_id, return_date DESC);

-- ============================================================
-- TRIGGERS (touch updated_at)
-- ============================================================
-- 註：touch_updated_at 函式由 inventory_schema.sql 定義；此處僅建 TRIGGER

CREATE TRIGGER trg_touch_suppliers              BEFORE UPDATE ON suppliers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_supplier_skus          BEFORE UPDATE ON supplier_skus
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sku_aliases            BEFORE UPDATE ON sku_aliases
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_purchase_orders        BEFORE UPDATE ON purchase_orders
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_purchase_order_items   BEFORE UPDATE ON purchase_order_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_purchase_requests      BEFORE UPDATE ON purchase_requests
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_purchase_request_items BEFORE UPDATE ON purchase_request_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_goods_receipts         BEFORE UPDATE ON goods_receipts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_goods_receipt_items    BEFORE UPDATE ON goods_receipt_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_purchase_returns       BEFORE UPDATE ON purchase_returns
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_purchase_return_items  BEFORE UPDATE ON purchase_return_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- RPC FUNCTIONS
-- ============================================================

-- PO 狀態自動維護（內部用）
CREATE OR REPLACE FUNCTION _refresh_po_status(p_po_id BIGINT)
RETURNS VOID AS $$
DECLARE
  v_total_ordered NUMERIC;
  v_total_received NUMERIC;
  v_new_status TEXT;
BEGIN
  SELECT SUM(qty_ordered), SUM(qty_received)
    INTO v_total_ordered, v_total_received
    FROM purchase_order_items WHERE po_id = p_po_id;

  IF v_total_received >= v_total_ordered THEN
    v_new_status := 'fully_received';
  ELSIF v_total_received > 0 THEN
    v_new_status := 'partially_received';
  ELSE
    RETURN;
  END IF;

  UPDATE purchase_orders
     SET status = v_new_status, updated_at = NOW()
   WHERE id = p_po_id AND status IN ('sent','partially_received');
END;
$$ LANGUAGE plpgsql;

-- GR 確認 → 入庫
CREATE OR REPLACE FUNCTION rpc_confirm_gr(p_gr_id BIGINT, p_operator UUID)
RETURNS VOID AS $$
DECLARE
  v_gr RECORD;
  v_item RECORD;
  v_mov_id BIGINT;
BEGIN
  SELECT * INTO v_gr FROM goods_receipts WHERE id = p_gr_id FOR UPDATE;
  IF v_gr.status <> 'draft' THEN
    RAISE EXCEPTION 'GR % is not in draft (current: %)', p_gr_id, v_gr.status;
  END IF;

  FOR v_item IN SELECT * FROM goods_receipt_items WHERE gr_id = p_gr_id LOOP
    v_mov_id := rpc_inbound(
      p_tenant_id       => v_gr.tenant_id,
      p_location_id     => v_gr.dest_location_id,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_item.qty_received,
      p_unit_cost       => v_item.unit_cost,
      p_movement_type   => 'purchase_receipt',
      p_source_doc_type => 'goods_receipt',
      p_source_doc_id   => p_gr_id,
      p_operator        => p_operator
    );

    UPDATE goods_receipt_items SET movement_id = v_mov_id WHERE id = v_item.id;

    IF v_item.po_item_id IS NOT NULL THEN
      UPDATE purchase_order_items
         SET qty_received = qty_received + v_item.qty_received
       WHERE id = v_item.po_item_id;
    END IF;
  END LOOP;

  UPDATE goods_receipts
     SET status = 'confirmed', confirmed_at = NOW(), confirmed_by = p_operator, updated_at = NOW()
   WHERE id = p_gr_id;

  PERFORM _refresh_po_status(v_gr.po_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 退供確認 → 出庫
CREATE OR REPLACE FUNCTION rpc_confirm_return(p_return_id BIGINT, p_operator UUID)
RETURNS VOID AS $$
DECLARE
  v_ret RECORD;
  v_item RECORD;
  v_mov_id BIGINT;
BEGIN
  SELECT * INTO v_ret FROM purchase_returns WHERE id = p_return_id FOR UPDATE;
  IF v_ret.status <> 'draft' THEN
    RAISE EXCEPTION 'Return % is not in draft (current: %)', p_return_id, v_ret.status;
  END IF;

  FOR v_item IN SELECT * FROM purchase_return_items WHERE return_id = p_return_id LOOP
    v_mov_id := rpc_outbound(
      p_tenant_id       => v_ret.tenant_id,
      p_location_id     => v_ret.source_location_id,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_item.qty,
      p_movement_type   => 'return_to_supplier',
      p_source_doc_type => 'purchase_return',
      p_source_doc_id   => p_return_id,
      p_operator        => p_operator,
      p_allow_negative  => FALSE
    );
    UPDATE purchase_return_items SET movement_id = v_mov_id WHERE id = v_item.id;

    IF v_item.gr_item_id IS NOT NULL THEN
      UPDATE purchase_order_items poi
         SET qty_returned = qty_returned + v_item.qty
        FROM goods_receipt_items gri
       WHERE gri.id = v_item.gr_item_id
         AND poi.id = gri.po_item_id;
    END IF;
  END LOOP;

  UPDATE purchase_returns
     SET status = 'confirmed', confirmed_at = NOW(), confirmed_by = p_operator, updated_at = NOW()
   WHERE id = p_return_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PR 合併成 PO
CREATE OR REPLACE FUNCTION rpc_merge_prs_to_po(
  p_tenant_id     UUID,
  p_pr_item_ids   BIGINT[],
  p_supplier_id   BIGINT,
  p_dest_location BIGINT,
  p_po_no         TEXT,
  p_operator      UUID
) RETURNS BIGINT AS $$
DECLARE
  v_po_id BIGINT;
BEGIN
  INSERT INTO purchase_orders (tenant_id, po_no, supplier_id, dest_location_id, created_by)
  VALUES (p_tenant_id, p_po_no, p_supplier_id, p_dest_location, p_operator)
  RETURNING id INTO v_po_id;

  WITH grouped AS (
    SELECT pri.sku_id, SUM(pri.qty_requested) AS qty,
           COALESCE(MAX(ss.default_unit_cost), 0) AS unit_cost
      FROM purchase_request_items pri
      LEFT JOIN supplier_skus ss
             ON ss.tenant_id = p_tenant_id
            AND ss.supplier_id = p_supplier_id
            AND ss.sku_id = pri.sku_id
     WHERE pri.id = ANY(p_pr_item_ids)
     GROUP BY pri.sku_id
  ), inserted AS (
    INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost)
    SELECT v_po_id, sku_id, qty, unit_cost FROM grouped
    RETURNING id, sku_id
  )
  UPDATE purchase_request_items pri
     SET po_item_id = i.id
    FROM inserted i
   WHERE pri.id = ANY(p_pr_item_ids) AND pri.sku_id = i.sku_id;

  UPDATE purchase_requests pr
     SET status = CASE
       WHEN NOT EXISTS (
         SELECT 1 FROM purchase_request_items pri
          WHERE pri.pr_id = pr.id AND pri.po_item_id IS NULL
       ) THEN 'fully_ordered' ELSE 'partially_ordered'
     END
   WHERE pr.id IN (SELECT pr_id FROM purchase_request_items WHERE id = ANY(p_pr_item_ids));

  RETURN v_po_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RLS
-- ============================================================

ALTER TABLE suppliers              ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_skus          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sku_aliases            ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_requests      ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_request_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_orders        ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_order_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE goods_receipts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE goods_receipt_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_returns       ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_return_items  ENABLE ROW LEVEL SECURITY;

CREATE POLICY purchase_full ON purchase_orders
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','purchaser','accountant')
  );

CREATE POLICY gr_warehouse ON goods_receipts
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') = 'warehouse'
    AND dest_location_id = (auth.jwt() ->> 'location_id')::bigint
  );

CREATE POLICY pr_helper ON purchase_requests
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') = 'helper'
    AND created_by = auth.uid()
  );

CREATE POLICY pr_store_manager ON purchase_requests
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') = 'store_manager'
    AND source_location_id = (auth.jwt() ->> 'location_id')::bigint
  );
