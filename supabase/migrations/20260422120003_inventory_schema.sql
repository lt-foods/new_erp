-- ============================================================
-- Inventory Module Schema v0.1
-- PostgreSQL 15+ / Supabase
-- See docs/DB-庫存模組.md for full design rationale.
-- ============================================================

-- ============================================================
-- TABLES
-- ============================================================

-- 1. 倉別
CREATE TABLE locations (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  code        TEXT NOT NULL,
  name        TEXT NOT NULL,
  type        TEXT NOT NULL CHECK (type IN ('central_warehouse','store')),
  address     TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_by  UUID,
  updated_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE locations IS '倉別：總倉 + 門市';

-- 2. 庫存結存（物化視圖）
CREATE TABLE stock_balances (
  tenant_id         UUID NOT NULL,
  location_id       BIGINT NOT NULL REFERENCES locations(id),
  sku_id            BIGINT NOT NULL,
  on_hand           NUMERIC(18,3) NOT NULL DEFAULT 0,
  reserved          NUMERIC(18,3) NOT NULL DEFAULT 0,
  in_transit_in     NUMERIC(18,3) NOT NULL DEFAULT 0,
  avg_cost          NUMERIC(18,4) NOT NULL DEFAULT 0,
  version           BIGINT NOT NULL DEFAULT 0,
  last_movement_at  TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, location_id, sku_id)
);
COMMENT ON TABLE stock_balances IS '庫存結存，由 stock_movements trigger 維護';
COMMENT ON COLUMN stock_balances.version IS '樂觀鎖版本';
COMMENT ON COLUMN stock_balances.in_transit_in IS '本倉已發貨未收貨的在途入量';

-- 3. 庫存異動（append-only）
CREATE TABLE stock_movements (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  location_id           BIGINT NOT NULL REFERENCES locations(id),
  sku_id                BIGINT NOT NULL,
  quantity              NUMERIC(18,3) NOT NULL CHECK (quantity <> 0),
  unit_cost             NUMERIC(18,4),
  movement_type         TEXT NOT NULL CHECK (movement_type IN (
                          'purchase_receipt',
                          'return_to_supplier',
                          'sale',
                          'customer_return',
                          'transfer_out',
                          'transfer_in',
                          'stocktake_gain',
                          'stocktake_loss',
                          'damage',
                          'manual_adjust',
                          'reversal'
                        )),
  source_doc_type       TEXT,
  source_doc_id         BIGINT,
  source_doc_line_id    BIGINT,
  reverses              BIGINT REFERENCES stock_movements(id),
  reversed_by           BIGINT REFERENCES stock_movements(id),
  batch_no              TEXT,
  expiry_date           DATE,
  reason                TEXT,
  operator_id           UUID NOT NULL,
  operator_ip           INET,
  notes                 TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE stock_movements IS '庫存異動紀錄：append-only';
COMMENT ON COLUMN stock_movements.quantity IS '有號：+入 / -出';

-- 4. 調撥單
CREATE TABLE transfers (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  transfer_no       TEXT NOT NULL,
  source_location   BIGINT NOT NULL REFERENCES locations(id),
  dest_location     BIGINT NOT NULL REFERENCES locations(id),
  status            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                      'draft','confirmed','shipped','received','cancelled','closed'
                    )),
  requested_by      UUID,
  shipped_by        UUID,
  shipped_at        TIMESTAMPTZ,
  received_by       UUID,
  received_at       TIMESTAMPTZ,
  notes             TEXT,
  created_by        UUID,
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, transfer_no),
  CHECK (source_location <> dest_location)
);

CREATE TABLE transfer_items (
  id               BIGSERIAL PRIMARY KEY,
  transfer_id      BIGINT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
  sku_id           BIGINT NOT NULL,
  qty_requested    NUMERIC(18,3) NOT NULL CHECK (qty_requested > 0),
  qty_shipped      NUMERIC(18,3) NOT NULL DEFAULT 0,
  qty_received     NUMERIC(18,3) NOT NULL DEFAULT 0,
  qty_variance     NUMERIC(18,3) GENERATED ALWAYS AS (qty_received - qty_shipped) STORED,
  out_movement_id  BIGINT REFERENCES stock_movements(id),
  in_movement_id   BIGINT REFERENCES stock_movements(id),
  notes            TEXT,
  created_by       UUID,
  updated_by       UUID,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. 盤點單
CREATE TABLE stocktakes (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  stocktake_no  TEXT NOT NULL,
  location_id   BIGINT NOT NULL REFERENCES locations(id),
  type          TEXT NOT NULL CHECK (type IN ('full','partial','cycle')),
  status        TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                  'draft','counting','review','adjusted','cancelled'
                )),
  freeze_trx    BOOLEAN NOT NULL DEFAULT FALSE,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  created_by    UUID NOT NULL,
  updated_by    UUID,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, stocktake_no)
);

CREATE TABLE stocktake_items (
  id                      BIGSERIAL PRIMARY KEY,
  stocktake_id            BIGINT NOT NULL REFERENCES stocktakes(id) ON DELETE CASCADE,
  sku_id                  BIGINT NOT NULL,
  system_qty              NUMERIC(18,3) NOT NULL,
  counted_qty             NUMERIC(18,3),
  diff_qty                NUMERIC(18,3) GENERATED ALWAYS AS (counted_qty - system_qty) STORED,
  adjustment_movement_id  BIGINT REFERENCES stock_movements(id),
  counted_by              UUID,
  counted_at              TIMESTAMPTZ,
  notes                   TEXT,
  created_by              UUID,
  updated_by              UUID,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. 補貨規則
CREATE TABLE reorder_rules (
  tenant_id       UUID NOT NULL,
  location_id     BIGINT NOT NULL REFERENCES locations(id),
  sku_id          BIGINT NOT NULL,
  safety_stock    NUMERIC(18,3) NOT NULL DEFAULT 0,
  reorder_point   NUMERIC(18,3) NOT NULL DEFAULT 0,
  max_stock       NUMERIC(18,3),
  lead_time_days  INTEGER,
  created_by      UUID,
  updated_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, location_id, sku_id),
  CHECK (reorder_point >= safety_stock),
  CHECK (max_stock IS NULL OR max_stock >= reorder_point)
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_mov_tloc_sku_time
  ON stock_movements (tenant_id, location_id, sku_id, created_at DESC);

CREATE INDEX idx_mov_source
  ON stock_movements (source_doc_type, source_doc_id)
  WHERE source_doc_id IS NOT NULL;

CREATE INDEX idx_mov_time
  ON stock_movements (tenant_id, created_at DESC);

CREATE INDEX idx_bal_tloc
  ON stock_balances (tenant_id, location_id)
  WHERE on_hand <> 0;

CREATE INDEX idx_transfers_status
  ON transfers (tenant_id, status, created_at DESC);

CREATE INDEX idx_transfers_dest_status
  ON transfers (dest_location, status);

CREATE INDEX idx_stocktakes_loc_status
  ON stocktakes (tenant_id, location_id, status);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Movement → Balance 自動維護
CREATE OR REPLACE FUNCTION apply_movement_to_balance()
RETURNS TRIGGER AS $$
DECLARE
  v_cur RECORD;
  v_new_on_hand NUMERIC(18,3);
  v_new_avg_cost NUMERIC(18,4);
BEGIN
  INSERT INTO stock_balances (tenant_id, location_id, sku_id)
  VALUES (NEW.tenant_id, NEW.location_id, NEW.sku_id)
  ON CONFLICT DO NOTHING;

  SELECT * INTO v_cur
    FROM stock_balances
   WHERE tenant_id = NEW.tenant_id
     AND location_id = NEW.location_id
     AND sku_id = NEW.sku_id
   FOR UPDATE;

  v_new_on_hand := v_cur.on_hand + NEW.quantity;

  IF NEW.quantity > 0 AND NEW.unit_cost IS NOT NULL AND NEW.unit_cost > 0
     AND (v_cur.on_hand + NEW.quantity) > 0 THEN
    v_new_avg_cost := (v_cur.on_hand * v_cur.avg_cost + NEW.quantity * NEW.unit_cost)
                    / (v_cur.on_hand + NEW.quantity);
  ELSE
    v_new_avg_cost := v_cur.avg_cost;
  END IF;

  UPDATE stock_balances
     SET on_hand = v_new_on_hand,
         avg_cost = v_new_avg_cost,
         version = v_cur.version + 1,
         last_movement_at = NEW.created_at,
         updated_at = NOW()
   WHERE tenant_id = NEW.tenant_id
     AND location_id = NEW.location_id
     AND sku_id = NEW.sku_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_movement
AFTER INSERT ON stock_movements
FOR EACH ROW EXECUTE FUNCTION apply_movement_to_balance();

-- 禁止更新 / 刪除 movements
CREATE OR REPLACE FUNCTION forbid_movement_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'stock_movements is append-only. Use a reversing entry instead.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_update_mov BEFORE UPDATE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION forbid_movement_mutation();
CREATE TRIGGER trg_no_delete_mov BEFORE DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION forbid_movement_mutation();

-- updated_at 自動更新
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_locations       BEFORE UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_transfers       BEFORE UPDATE ON transfers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_transfer_items  BEFORE UPDATE ON transfer_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_stocktakes      BEFORE UPDATE ON stocktakes
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_stocktake_items BEFORE UPDATE ON stocktake_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_reorder_rules   BEFORE UPDATE ON reorder_rules
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- RPC FUNCTIONS (SECURITY DEFINER)
-- ============================================================

-- 入庫
CREATE OR REPLACE FUNCTION rpc_inbound(
  p_tenant_id UUID,
  p_location_id BIGINT,
  p_sku_id BIGINT,
  p_quantity NUMERIC,
  p_unit_cost NUMERIC,
  p_movement_type TEXT,
  p_source_doc_type TEXT,
  p_source_doc_id BIGINT,
  p_operator UUID
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Inbound quantity must be positive';
  END IF;

  INSERT INTO stock_movements
    (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
     source_doc_type, source_doc_id, operator_id)
  VALUES
    (p_tenant_id, p_location_id, p_sku_id, p_quantity, p_unit_cost, p_movement_type,
     p_source_doc_type, p_source_doc_id, p_operator)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 出庫（含可用庫存檢查）
CREATE OR REPLACE FUNCTION rpc_outbound(
  p_tenant_id UUID,
  p_location_id BIGINT,
  p_sku_id BIGINT,
  p_quantity NUMERIC,
  p_movement_type TEXT,
  p_source_doc_type TEXT,
  p_source_doc_id BIGINT,
  p_operator UUID,
  p_allow_negative BOOLEAN DEFAULT FALSE
) RETURNS BIGINT AS $$
DECLARE
  v_available NUMERIC;
  v_cost NUMERIC;
  v_id BIGINT;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Outbound quantity must be positive';
  END IF;

  SELECT on_hand - reserved, avg_cost
    INTO v_available, v_cost
    FROM stock_balances
   WHERE tenant_id = p_tenant_id
     AND location_id = p_location_id
     AND sku_id = p_sku_id
   FOR UPDATE;

  IF NOT FOUND THEN
    v_available := 0; v_cost := 0;
  END IF;

  IF v_available < p_quantity AND NOT p_allow_negative THEN
    RAISE EXCEPTION 'Insufficient stock: available=%, required=%', v_available, p_quantity;
  END IF;

  INSERT INTO stock_movements
    (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
     source_doc_type, source_doc_id, operator_id)
  VALUES
    (p_tenant_id, p_location_id, p_sku_id, -p_quantity, v_cost, p_movement_type,
     p_source_doc_type, p_source_doc_id, p_operator)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RLS (Row-Level Security) - 範例；實際欄位與 JWT claim 依 auth 設計
-- ============================================================

ALTER TABLE locations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_balances    ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements   ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfers         ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfer_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE stocktakes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE stocktake_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE reorder_rules     ENABLE ROW LEVEL SECURITY;

-- 總部 / 採購 / 倉管：本 tenant 全讀
CREATE POLICY hq_full_read ON stock_balances
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','purchaser','warehouse','reporter')
  );

-- 門市：只看自己 location
CREATE POLICY store_read_own ON stock_balances
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('store_manager','clerk')
    AND location_id = (auth.jwt() ->> 'location_id')::bigint
  );
