-- ============================================================
-- Purchase v0.2 addendum: PR pending review + arrival tracking + sub-brand + marketplace import
-- PRD: docs/PRD-採購模組-v0.2-addendum.md
-- ============================================================

-- ============================================================
-- 1. 既有表欄位補充
-- ============================================================

-- purchase_requests: 內部審核 (review_status orthogonal to lifecycle status)
ALTER TABLE purchase_requests
  ADD COLUMN review_status            TEXT NOT NULL DEFAULT 'approved'
                                        CHECK (review_status IN ('pending_review','approved','rejected')),
  ADD COLUMN review_note              TEXT,
  ADD COLUMN reviewed_by              UUID,
  ADD COLUMN reviewed_at              TIMESTAMPTZ,
  ADD COLUMN review_threshold_amount  NUMERIC(18,4);

CREATE INDEX idx_pr_review_status ON purchase_requests (tenant_id, review_status)
  WHERE review_status = 'pending_review';

-- suppliers: 海外旗標 (Flag 11 A)
ALTER TABLE suppliers
  ADD COLUMN is_overseas BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_suppliers_overseas ON suppliers (tenant_id, is_overseas)
  WHERE is_overseas = TRUE;

-- goods_receipts: 陸貨多月到貨追蹤
ALTER TABLE goods_receipts
  ADD COLUMN expected_arrival_date  DATE,
  ADD COLUMN arrival_status         TEXT NOT NULL DEFAULT 'pending'
                                      CHECK (arrival_status IN ('pending','arrived','delayed','partial','cancelled')),
  ADD COLUMN arrival_note           TEXT,
  ADD COLUMN is_land_goods          BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_gr_arrival ON goods_receipts (tenant_id, arrival_status, expected_arrival_date)
  WHERE arrival_status IN ('pending','delayed');

-- brands: 子品牌 (漂漂館)
ALTER TABLE brands
  ADD COLUMN is_sub_brand    BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN parent_brand_id BIGINT REFERENCES brands(id);

CREATE INDEX idx_brands_sub ON brands (tenant_id, parent_brand_id)
  WHERE is_sub_brand = TRUE;

-- ============================================================
-- 2. 新增表
-- ============================================================

-- 採購審核門檻
CREATE TABLE purchase_approval_thresholds (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  scope             TEXT NOT NULL CHECK (scope IN ('global','category','supplier','store')),
  scope_id          BIGINT,
  threshold_amount  NUMERIC(18,4) NOT NULL CHECK (threshold_amount >= 0),
  approver_role     TEXT NOT NULL DEFAULT 'admin'
                      CHECK (approver_role IN ('admin','hq_manager','owner')),
  active            BOOLEAN NOT NULL DEFAULT TRUE,
  created_by        UUID,
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_pat_scope ON purchase_approval_thresholds (tenant_id, scope, COALESCE(scope_id, 0))
  WHERE active = TRUE;

-- 1688 / 拼多多 訂單 staging
CREATE TABLE external_purchase_imports (
  id                              BIGSERIAL PRIMARY KEY,
  tenant_id                       UUID NOT NULL,
  source                          TEXT NOT NULL CHECK (source IN ('1688','pinduoduo','taobao','other')),
  batch_id                        TEXT NOT NULL,
  raw_row                         JSONB NOT NULL,
  parsed_sku_id                   BIGINT REFERENCES skus(id),
  parsed_supplier_id              BIGINT REFERENCES suppliers(id),
  parsed_qty                      NUMERIC(18,3),
  parsed_unit_cost                NUMERIC(18,4),
  parsed_amount                   NUMERIC(18,4),
  parsed_expected_arrival_date    DATE,
  resolved_po_id                  BIGINT REFERENCES purchase_orders(id),
  status                          TEXT NOT NULL DEFAULT 'pending'
                                    CHECK (status IN ('pending','resolved','skipped','error')),
  error_message                   TEXT,
  created_by                      UUID,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ext_pur_batch ON external_purchase_imports (tenant_id, batch_id);
CREATE INDEX idx_ext_pur_status ON external_purchase_imports (tenant_id, status);

-- ============================================================
-- 3. VIEW: 陸貨到貨追蹤
-- ============================================================

CREATE OR REPLACE VIEW v_pending_arrivals AS
SELECT
  gr.id                AS gr_id,
  gr.tenant_id,
  gr.gr_no,
  gr.po_id,
  po.po_no,
  po.supplier_id,
  sup.name             AS supplier_name,
  gr.expected_arrival_date,
  gr.arrival_status,
  gr.arrival_note,
  EXTRACT(DAY FROM NOW() - gr.expected_arrival_date)::INT AS days_overdue,
  (SELECT SUM(gri.qty_expected * gri.unit_cost)
     FROM goods_receipt_items gri
    WHERE gri.gr_id = gr.id) AS expected_value
FROM goods_receipts gr
JOIN purchase_orders po ON po.id = gr.po_id
JOIN suppliers sup ON sup.id = po.supplier_id
WHERE gr.is_land_goods = TRUE
  AND gr.arrival_status IN ('pending','delayed');

-- ============================================================
-- 4. TRIGGERS
-- ============================================================

CREATE TRIGGER trg_touch_pat BEFORE UPDATE ON purchase_approval_thresholds
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Note: external_purchase_imports 允許 UPDATE (status 轉移), 不裝 forbid trigger

-- 自動標 is_land_goods 依 supplier.is_overseas
CREATE OR REPLACE FUNCTION mark_gr_land_goods()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_land_goods = FALSE THEN
    SELECT COALESCE(s.is_overseas, FALSE) INTO NEW.is_land_goods
      FROM purchase_orders po
      JOIN suppliers s ON s.id = po.supplier_id
     WHERE po.id = NEW.po_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_gr_mark_land BEFORE INSERT ON goods_receipts
  FOR EACH ROW EXECUTE FUNCTION mark_gr_land_goods();

-- ============================================================
-- 5. RPC FUNCTIONS
-- ============================================================

-- 審核通過
CREATE OR REPLACE FUNCTION rpc_approve_purchase_request(
  p_pr_id    BIGINT,
  p_note     TEXT,
  p_operator UUID
) RETURNS VOID AS $$
DECLARE
  v_pr RECORD;
BEGIN
  SELECT * INTO v_pr FROM purchase_requests
   WHERE id = p_pr_id AND review_status = 'pending_review' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found or not pending_review', p_pr_id;
  END IF;

  UPDATE purchase_requests
     SET review_status = 'approved',
         review_note = p_note,
         reviewed_by = p_operator,
         reviewed_at = NOW(),
         updated_by = p_operator,
         status = CASE WHEN status = 'draft' THEN 'submitted' ELSE status END,
         submitted_at = CASE WHEN status = 'draft' THEN NOW() ELSE submitted_at END
   WHERE id = p_pr_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 審核退回
CREATE OR REPLACE FUNCTION rpc_reject_purchase_request(
  p_pr_id    BIGINT,
  p_reason   TEXT,
  p_operator UUID
) RETURNS VOID AS $$
BEGIN
  IF p_reason IS NULL OR length(p_reason) = 0 THEN
    RAISE EXCEPTION 'rejection reason is required';
  END IF;

  UPDATE purchase_requests
     SET review_status = 'rejected',
         review_note = p_reason,
         reviewed_by = p_operator,
         reviewed_at = NOW(),
         updated_by = p_operator
   WHERE id = p_pr_id AND review_status = 'pending_review';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PR % not found or not pending_review', p_pr_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 更新 GR ETA + 自動標 delayed
CREATE OR REPLACE FUNCTION rpc_update_arrival_eta(
  p_gr_id    BIGINT,
  p_new_eta  DATE,
  p_note     TEXT,
  p_operator UUID
) RETURNS VOID AS $$
DECLARE
  v_old_eta DATE;
  v_status  TEXT;
BEGIN
  SELECT expected_arrival_date, arrival_status INTO v_old_eta, v_status
    FROM goods_receipts
   WHERE id = p_gr_id AND arrival_status IN ('pending','delayed') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GR % not found or not in trackable status', p_gr_id;
  END IF;

  UPDATE goods_receipts
     SET expected_arrival_date = p_new_eta,
         arrival_note = COALESCE(arrival_note || E'\n', '')
                        || NOW()::date::text || ': ' || p_note,
         arrival_status = CASE
                           WHEN v_old_eta IS NOT NULL AND p_new_eta > v_old_eta + INTERVAL '7 days'
                           THEN 'delayed'
                           ELSE 'pending'
                         END,
         updated_by = p_operator
   WHERE id = p_gr_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- marketplace import resolve
CREATE OR REPLACE FUNCTION rpc_resolve_external_purchase(
  p_tenant_id        UUID,
  p_batch_id         TEXT,
  p_dest_location_id BIGINT,
  p_operator         UUID
) RETURNS JSONB AS $$
DECLARE
  v_supplier_rec  RECORD;
  v_row           RECORD;
  v_new_po_id     BIGINT;
  v_pos_created   INTEGER := 0;
  v_items_created INTEGER := 0;
  v_errors        INTEGER := 0;
BEGIN
  FOR v_supplier_rec IN
    SELECT DISTINCT parsed_supplier_id
      FROM external_purchase_imports
     WHERE tenant_id = p_tenant_id AND batch_id = p_batch_id
       AND status = 'pending' AND parsed_supplier_id IS NOT NULL
  LOOP
    INSERT INTO purchase_orders (tenant_id, po_no, supplier_id, dest_location_id,
                                 status, order_date, notes, created_by, updated_by)
    VALUES (p_tenant_id,
            'MKT-' || p_batch_id || '-' || v_supplier_rec.parsed_supplier_id,
            v_supplier_rec.parsed_supplier_id, p_dest_location_id,
            'sent', CURRENT_DATE,
            'source: marketplace_import / batch ' || p_batch_id,
            p_operator, p_operator)
    RETURNING id INTO v_new_po_id;
    v_pos_created := v_pos_created + 1;

    FOR v_row IN
      SELECT * FROM external_purchase_imports
       WHERE tenant_id = p_tenant_id AND batch_id = p_batch_id
         AND status = 'pending'
         AND parsed_supplier_id = v_supplier_rec.parsed_supplier_id
    LOOP
      IF v_row.parsed_sku_id IS NULL OR v_row.parsed_qty IS NULL OR v_row.parsed_unit_cost IS NULL THEN
        UPDATE external_purchase_imports
           SET status = 'error', error_message = 'missing parsed fields'
         WHERE id = v_row.id;
        v_errors := v_errors + 1;
        CONTINUE;
      END IF;

      INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, unit_cost,
                                        created_by, updated_by)
      VALUES (v_new_po_id, v_row.parsed_sku_id, v_row.parsed_qty,
              v_row.parsed_unit_cost, p_operator, p_operator);
      v_items_created := v_items_created + 1;

      UPDATE external_purchase_imports
         SET resolved_po_id = v_new_po_id, status = 'resolved'
       WHERE id = v_row.id;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'pos_created', v_pos_created,
    'items_created', v_items_created,
    'errors', v_errors
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 6. RLS
-- ============================================================

ALTER TABLE purchase_approval_thresholds  ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_purchase_imports     ENABLE ROW LEVEL SECURITY;

CREATE POLICY pat_admin_all ON purchase_approval_thresholds
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY pat_others_read ON purchase_approval_thresholds
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

CREATE POLICY epi_admin_all ON external_purchase_imports
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','purchaser')
  );
