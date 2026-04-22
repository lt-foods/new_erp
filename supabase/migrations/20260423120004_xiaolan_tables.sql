-- ============================================================
-- 供應商整合 (Supplier Integration) v0.2: xiaolan_* tables
-- PRD: docs/PRD-供應商整合-v0.2.md
-- ============================================================

-- ============================================================
-- 1. TABLES (5 staging + 1 settings)
-- ============================================================

-- 小蘭採購流水
CREATE TABLE xiaolan_purchases (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  source_ref_id     TEXT NOT NULL,
  sheet_tab         TEXT NOT NULL,
  purchase_date     DATE,
  supplier_code     TEXT,
  item_description  TEXT,
  qty               NUMERIC(18,3),
  unit_cost         NUMERIC(18,4),
  amount            NUMERIC(18,4),
  resolved_po_id    BIGINT REFERENCES purchase_orders(id),
  resolved_sku_id   BIGINT REFERENCES skus(id),
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','resolved','skipped','error')),
  raw_row           JSONB,
  created_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);

CREATE INDEX idx_xiaolan_pur_status ON xiaolan_purchases (tenant_id, status);
CREATE INDEX idx_xiaolan_pur_date ON xiaolan_purchases (tenant_id, purchase_date DESC);

-- 漂漂館進貨 staging
CREATE TABLE xiaolan_piaopiao (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  source_ref_id       TEXT NOT NULL,
  sheet_tab           TEXT,
  purchase_date       DATE,
  item_description    TEXT,
  qty                 NUMERIC(18,3),
  unit_cost           NUMERIC(18,4),
  resolved_sku_id     BIGINT REFERENCES skus(id),
  resolved_brand_id   BIGINT REFERENCES brands(id),
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','resolved','skipped','error')),
  raw_row             JSONB,
  created_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);

CREATE INDEX idx_xiaolan_pp_status ON xiaolan_piaopiao (tenant_id, status);

-- 訂單追蹤流水
CREATE TABLE xiaolan_order_tracking (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  source_ref_id     TEXT NOT NULL,
  external_order_no TEXT NOT NULL,
  tracking_no       TEXT,
  carrier           TEXT,
  status_text       TEXT,
  status_code       TEXT
                      CHECK (status_code IN ('created','shipped','in_transit','arrived','returned','unknown')),
  last_event_at     TIMESTAMPTZ,
  resolved_po_id    BIGINT REFERENCES purchase_orders(id),
  resolved_gr_id    BIGINT REFERENCES goods_receipts(id),
  raw_row           JSONB,
  created_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);

CREATE INDEX idx_xiaolan_track_external ON xiaolan_order_tracking (tenant_id, external_order_no);

-- 到貨紀錄
CREATE TABLE xiaolan_arrivals (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  source_ref_id     TEXT NOT NULL,
  arrival_date      DATE NOT NULL,
  external_order_no TEXT,
  item_description  TEXT,
  qty_arrived       NUMERIC(18,3),
  condition_note    TEXT,
  resolved_gr_id    BIGINT REFERENCES goods_receipts(id),
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','resolved','skipped','error')),
  raw_row           JSONB,
  created_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);

CREATE INDEX idx_xiaolan_arr_status ON xiaolan_arrivals (tenant_id, status);
CREATE INDEX idx_xiaolan_arr_date ON xiaolan_arrivals (tenant_id, arrival_date DESC);

-- 退貨紀錄
CREATE TABLE xiaolan_returns (
  id                              BIGSERIAL PRIMARY KEY,
  tenant_id                       UUID NOT NULL,
  source_ref_id                   TEXT NOT NULL,
  return_date                     DATE NOT NULL,
  external_order_no               TEXT,
  reason                          TEXT,
  qty_returned                    NUMERIC(18,3),
  refund_amount                   NUMERIC(18,4),
  resolved_purchase_return_id     BIGINT REFERENCES purchase_returns(id),
  status                          TEXT NOT NULL DEFAULT 'pending'
                                    CHECK (status IN ('pending','resolved','skipped','error')),
  raw_row                         JSONB,
  created_by                      UUID,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source_ref_id)
);

CREATE INDEX idx_xiaolan_ret_status ON xiaolan_returns (tenant_id, status);

-- 設定主檔
CREATE TABLE xiaolan_settings (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL,
  sheet_id                 TEXT NOT NULL,
  sheet_tabs               JSONB NOT NULL,
  supplier_code_mapping    JSONB,
  sku_match_rules          JSONB,
  sync_enabled             BOOLEAN NOT NULL DEFAULT TRUE,
  last_synced_at           TIMESTAMPTZ,
  last_sync_status         TEXT,
  last_sync_error          TEXT,
  created_by               UUID,
  updated_by               UUID,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, sheet_id)
);

CREATE TRIGGER trg_touch_xiaolan_settings BEFORE UPDATE ON xiaolan_settings
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- 2. RPC FUNCTIONS
-- ============================================================

-- 解決一筆 xiaolan_purchases (建 PO item / 標 resolved)
CREATE OR REPLACE FUNCTION rpc_resolve_xiaolan_purchase(
  p_xiaolan_id BIGINT,
  p_po_id      BIGINT,
  p_sku_id     BIGINT,
  p_operator   UUID
) RETURNS VOID AS $$
DECLARE
  v_x  RECORD;
  v_po RECORD;
BEGIN
  SELECT * INTO v_x FROM xiaolan_purchases
   WHERE id = p_xiaolan_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'xiaolan_purchase % not found or not pending', p_xiaolan_id;
  END IF;

  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PO % not found', p_po_id;
  END IF;

  -- optionally append a PO item
  IF v_x.qty IS NOT NULL AND v_x.unit_cost IS NOT NULL THEN
    INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost,
                                      created_by, updated_by)
    VALUES (p_po_id, p_sku_id, v_x.qty, v_x.unit_cost, p_operator, p_operator);
  END IF;

  UPDATE xiaolan_purchases
     SET resolved_po_id = p_po_id, resolved_sku_id = p_sku_id, status = 'resolved'
   WHERE id = p_xiaolan_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 解決 xiaolan_arrivals (連到 GR)
CREATE OR REPLACE FUNCTION rpc_resolve_xiaolan_arrival(
  p_xiaolan_id BIGINT,
  p_gr_id      BIGINT,
  p_operator   UUID
) RETURNS VOID AS $$
BEGIN
  UPDATE xiaolan_arrivals
     SET resolved_gr_id = p_gr_id, status = 'resolved'
   WHERE id = p_xiaolan_id AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'xiaolan_arrival % not found or not pending', p_xiaolan_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 解決 xiaolan_returns (連到 purchase_return)
CREATE OR REPLACE FUNCTION rpc_resolve_xiaolan_return(
  p_xiaolan_id BIGINT,
  p_return_id  BIGINT,
  p_operator   UUID
) RETURNS VOID AS $$
BEGIN
  UPDATE xiaolan_returns
     SET resolved_purchase_return_id = p_return_id, status = 'resolved'
   WHERE id = p_xiaolan_id AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'xiaolan_return % not found or not pending', p_xiaolan_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 解決 xiaolan_order_tracking (連到 PO + GR + status sync)
CREATE OR REPLACE FUNCTION rpc_resolve_xiaolan_tracking(
  p_xiaolan_id BIGINT,
  p_po_id      BIGINT,
  p_gr_id      BIGINT,
  p_operator   UUID
) RETURNS VOID AS $$
DECLARE
  v_x RECORD;
BEGIN
  SELECT * INTO v_x FROM xiaolan_order_tracking
   WHERE id = p_xiaolan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'xiaolan_order_tracking % not found', p_xiaolan_id;
  END IF;

  UPDATE xiaolan_order_tracking
     SET resolved_po_id = p_po_id, resolved_gr_id = p_gr_id
   WHERE id = p_xiaolan_id;

  -- sync goods_receipts.arrival_status if applicable
  IF p_gr_id IS NOT NULL AND v_x.status_code IN ('arrived','in_transit','shipped') THEN
    UPDATE goods_receipts
       SET arrival_status = CASE
                              WHEN v_x.status_code = 'arrived' THEN 'arrived'
                              WHEN v_x.status_code IN ('in_transit','shipped') THEN 'pending'
                              ELSE arrival_status
                            END,
           updated_by = p_operator
     WHERE id = p_gr_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 批次解決 (auto-match 走 sku_match_rules in xiaolan_settings)
CREATE OR REPLACE FUNCTION rpc_bulk_resolve_xiaolan(
  p_table    TEXT,
  p_ids      BIGINT[],
  p_operator UUID
) RETURNS JSONB AS $$
DECLARE
  v_resolved INTEGER := 0;
  v_skipped  INTEGER := 0;
  v_errors   INTEGER := 0;
BEGIN
  IF p_table NOT IN ('purchases','piaopiao','arrivals','returns','tracking') THEN
    RAISE EXCEPTION 'invalid table: %', p_table;
  END IF;

  -- 為避免 dynamic SQL 複雜度, 此 RPC 僅做 status='skipped' 標記;
  -- admin UI 應逐筆呼叫對應的 rpc_resolve_xiaolan_<table>
  IF p_table = 'purchases' THEN
    UPDATE xiaolan_purchases SET status = 'skipped'
     WHERE id = ANY(p_ids) AND status = 'pending';
    GET DIAGNOSTICS v_skipped = ROW_COUNT;
  ELSIF p_table = 'piaopiao' THEN
    UPDATE xiaolan_piaopiao SET status = 'skipped'
     WHERE id = ANY(p_ids) AND status = 'pending';
    GET DIAGNOSTICS v_skipped = ROW_COUNT;
  ELSIF p_table = 'arrivals' THEN
    UPDATE xiaolan_arrivals SET status = 'skipped'
     WHERE id = ANY(p_ids) AND status = 'pending';
    GET DIAGNOSTICS v_skipped = ROW_COUNT;
  ELSIF p_table = 'returns' THEN
    UPDATE xiaolan_returns SET status = 'skipped'
     WHERE id = ANY(p_ids) AND status = 'pending';
    GET DIAGNOSTICS v_skipped = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('resolved', v_resolved, 'skipped', v_skipped, 'errors', v_errors);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 3. RLS
-- ============================================================

ALTER TABLE xiaolan_purchases       ENABLE ROW LEVEL SECURITY;
ALTER TABLE xiaolan_piaopiao        ENABLE ROW LEVEL SECURITY;
ALTER TABLE xiaolan_order_tracking  ENABLE ROW LEVEL SECURITY;
ALTER TABLE xiaolan_arrivals        ENABLE ROW LEVEL SECURITY;
ALTER TABLE xiaolan_returns         ENABLE ROW LEVEL SECURITY;
ALTER TABLE xiaolan_settings        ENABLE ROW LEVEL SECURITY;

-- service_role bypass: PostgREST 用 service_role key 連線時自動 bypass RLS, 不用寫 policy
-- admin: ALL on all tables
-- 其他 role: 看不到

CREATE POLICY xp_admin_all ON xiaolan_purchases
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY xpp_admin_all ON xiaolan_piaopiao
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY xt_admin_all ON xiaolan_order_tracking
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY xa_admin_all ON xiaolan_arrivals
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY xr_admin_all ON xiaolan_returns
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
CREATE POLICY xs_admin_all ON xiaolan_settings
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
