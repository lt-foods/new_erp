-- ============================================================
-- Order v0.2 addendum: picking waves + matrix view + stalled items
-- PRD: docs/PRD-訂單取貨模組-v0.2-addendum.md
-- ============================================================

-- ============================================================
-- 1. 既有表欄位補充：group_buy_campaigns
-- ============================================================

ALTER TABLE group_buy_campaigns
  ADD COLUMN cutoff_date            DATE,
  ADD COLUMN expected_arrival_date  DATE,
  ADD COLUMN matrix_row_order       INTEGER NOT NULL DEFAULT 0;

CREATE INDEX idx_gbc_cutoff_date ON group_buy_campaigns (tenant_id, cutoff_date)
  WHERE status IN ('open', 'closed');

-- ============================================================
-- 2. TABLES
-- ============================================================

-- 揀貨波次單頭
CREATE TABLE picking_waves (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  wave_code    TEXT NOT NULL,
  wave_date    DATE NOT NULL,
  status       TEXT NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','picking','picked','shipped','cancelled')),
  store_count  INTEGER NOT NULL DEFAULT 0,
  item_count   INTEGER NOT NULL DEFAULT 0,
  total_qty    NUMERIC(18,3) NOT NULL DEFAULT 0,
  note         TEXT,
  created_by   UUID,
  updated_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, wave_code)
);
COMMENT ON TABLE picking_waves IS '揀貨波次主檔';

CREATE INDEX idx_waves_date ON picking_waves (tenant_id, wave_date DESC);
CREATE INDEX idx_waves_status ON picking_waves (tenant_id, status);

-- 揀貨波次明細
CREATE TABLE picking_wave_items (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL,
  wave_id              BIGINT NOT NULL REFERENCES picking_waves(id) ON DELETE CASCADE,
  sku_id               BIGINT NOT NULL REFERENCES skus(id),
  store_id             BIGINT NOT NULL REFERENCES stores(id),
  qty                  NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  picked_qty           NUMERIC(18,3),
  campaign_id          BIGINT REFERENCES group_buy_campaigns(id),
  generated_transfer_id BIGINT REFERENCES transfers(id),
  note                 TEXT,
  created_by           UUID,
  updated_by           UUID,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (wave_id, sku_id, store_id)
);

CREATE INDEX idx_wave_items_wave ON picking_wave_items (wave_id);
CREATE INDEX idx_wave_items_store ON picking_wave_items (tenant_id, store_id, wave_id);

-- 揀貨波次稽核（append-only）
CREATE TABLE picking_wave_audit_log (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL,
  wave_id      BIGINT NOT NULL REFERENCES picking_waves(id) ON DELETE CASCADE,
  wave_item_id BIGINT REFERENCES picking_wave_items(id) ON DELETE SET NULL,
  action       TEXT NOT NULL CHECK (action IN (
                 'wave_created','wave_status_changed','item_added','item_removed',
                 'picked_qty_changed','so_generated','wave_cancelled'
               )),
  before_value JSONB,
  after_value  JSONB,
  note         TEXT,
  created_by   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_wave_audit_wave ON picking_wave_audit_log (tenant_id, wave_id, created_at DESC);
CREATE INDEX idx_wave_audit_item ON picking_wave_audit_log (wave_item_id) WHERE wave_item_id IS NOT NULL;

-- 外部訂單匯入 staging（樂樂 CSV 等）
CREATE TABLE external_order_imports (
  id                          BIGSERIAL PRIMARY KEY,
  tenant_id                   UUID NOT NULL,
  source                      TEXT NOT NULL CHECK (source IN ('lele','shopee','other')),
  batch_id                    TEXT NOT NULL,
  raw_row                     JSONB NOT NULL,
  parsed_sku_id               BIGINT REFERENCES skus(id),
  parsed_customer_identifier  TEXT,
  parsed_qty                  NUMERIC(18,3),
  parsed_amount               NUMERIC(18,4),
  resolved_order_id           BIGINT REFERENCES customer_orders(id),
  status                      TEXT NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','resolved','skipped','error')),
  error_message               TEXT,
  created_by                  UUID,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ext_imports_batch ON external_order_imports (tenant_id, batch_id);
CREATE INDEX idx_ext_imports_status ON external_order_imports (tenant_id, status);

-- ============================================================
-- 3. VIEWS
-- ============================================================

-- 開團總表 matrix dataset
CREATE OR REPLACE VIEW v_open_group_matrix AS
SELECT
  gbc.id                AS campaign_id,
  gbc.tenant_id,
  gbc.cutoff_date,
  gbc.matrix_row_order,
  ci.sku_id,
  s.id                  AS store_id,
  s.name                AS store_name,
  COALESCE(SUM(coi.qty), 0)        AS total_qty,
  COUNT(DISTINCT co.member_id)     AS customer_count,
  COUNT(DISTINCT co.id)            AS order_count
FROM group_buy_campaigns gbc
JOIN campaign_items ci ON ci.campaign_id = gbc.id
LEFT JOIN customer_order_items coi ON coi.campaign_item_id = ci.id
                                  AND coi.status NOT IN ('cancelled','expired')
LEFT JOIN customer_orders co ON co.id = coi.order_id
LEFT JOIN stores s ON s.id = co.pickup_store_id
WHERE gbc.status IN ('open','closed')
GROUP BY gbc.id, gbc.tenant_id, gbc.cutoff_date, gbc.matrix_row_order,
         ci.sku_id, s.id, s.name;

-- 未到貨積壓
CREATE OR REPLACE VIEW v_stalled_items AS
SELECT
  coi.id                AS order_item_id,
  coi.tenant_id,
  gbc.id                AS campaign_id,
  gbc.cutoff_date,
  gbc.expected_arrival_date,
  coi.sku_id,
  coi.qty,
  co.channel_id,
  co.member_id,
  co.pickup_store_id,
  EXTRACT(DAY FROM NOW() - gbc.expected_arrival_date)::INT AS days_overdue
FROM customer_order_items coi
JOIN customer_orders co ON co.id = coi.order_id
JOIN campaign_items ci ON ci.id = coi.campaign_item_id
JOIN group_buy_campaigns gbc ON gbc.id = ci.campaign_id
WHERE coi.status IN ('pending','reserved')
  AND gbc.expected_arrival_date IS NOT NULL
  AND gbc.expected_arrival_date < CURRENT_DATE;

-- ============================================================
-- 4. TRIGGERS
-- ============================================================

CREATE TRIGGER trg_touch_picking_waves      BEFORE UPDATE ON picking_waves
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_picking_wave_items BEFORE UPDATE ON picking_wave_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_no_mut_wave_audit BEFORE UPDATE OR DELETE ON picking_wave_audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
-- Note: external_order_imports 允許 UPDATE (status / resolved_order_id 轉移), 不裝 forbid trigger

-- ============================================================
-- 5. RPC FUNCTIONS (SECURITY DEFINER)
-- ============================================================

-- 建立揀貨波次（aggregate sku × store from campaigns）
CREATE OR REPLACE FUNCTION rpc_create_picking_wave(
  p_tenant_id   UUID,
  p_campaign_ids BIGINT[],
  p_wave_date   DATE,
  p_wave_code   TEXT,
  p_operator    UUID
) RETURNS BIGINT AS $$
DECLARE
  v_wave_id     BIGINT;
  v_item_count  INTEGER;
  v_store_count INTEGER;
  v_total_qty   NUMERIC(18,3);
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('picking_wave:create:' || p_tenant_id::text));

  INSERT INTO picking_waves (tenant_id, wave_code, wave_date, status, created_by, updated_by)
  VALUES (p_tenant_id, p_wave_code, p_wave_date, 'draft', p_operator, p_operator)
  RETURNING id INTO v_wave_id;

  INSERT INTO picking_wave_items (
    tenant_id, wave_id, sku_id, store_id, qty, campaign_id, created_by, updated_by
  )
  SELECT p_tenant_id, v_wave_id, coi.sku_id, co.pickup_store_id,
         SUM(coi.qty), ci.campaign_id, p_operator, p_operator
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    JOIN campaign_items ci ON ci.id = coi.campaign_item_id
   WHERE ci.campaign_id = ANY(p_campaign_ids)
     AND coi.tenant_id = p_tenant_id
     AND coi.status IN ('pending','reserved')
   GROUP BY coi.sku_id, co.pickup_store_id, ci.campaign_id
  HAVING SUM(coi.qty) > 0;

  SELECT COUNT(*),
         COUNT(DISTINCT store_id),
         COALESCE(SUM(qty), 0)
    INTO v_item_count, v_store_count, v_total_qty
    FROM picking_wave_items
   WHERE wave_id = v_wave_id;

  UPDATE picking_waves
     SET item_count = v_item_count,
         store_count = v_store_count,
         total_qty = v_total_qty
   WHERE id = v_wave_id;

  INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
  VALUES (p_tenant_id, v_wave_id, 'wave_created',
          jsonb_build_object('wave_code', p_wave_code, 'campaign_ids', p_campaign_ids,
                             'item_count', v_item_count, 'store_count', v_store_count),
          p_operator);

  RETURN v_wave_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 更新單列 picked_qty（現場揀貨用）
CREATE OR REPLACE FUNCTION rpc_update_picked_qty(
  p_wave_item_id BIGINT,
  p_new_qty      NUMERIC,
  p_operator     UUID,
  p_note         TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_tenant_id   UUID;
  v_wave_id     BIGINT;
  v_wave_status TEXT;
  v_old_qty     NUMERIC(18,3);
BEGIN
  SELECT pwi.tenant_id, pwi.wave_id, pw.status, pwi.picked_qty
    INTO v_tenant_id, v_wave_id, v_wave_status, v_old_qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
   WHERE pwi.id = p_wave_item_id
   FOR UPDATE OF pwi, pw;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'picking_wave_item % not found', p_wave_item_id;
  END IF;

  IF v_wave_status NOT IN ('draft','picking') THEN
    RAISE EXCEPTION 'wave % is in status %, cannot update picked_qty', v_wave_id, v_wave_status;
  END IF;

  UPDATE picking_wave_items
     SET picked_qty = p_new_qty,
         updated_by = p_operator
   WHERE id = p_wave_item_id;

  INSERT INTO picking_wave_audit_log (
    tenant_id, wave_id, wave_item_id, action, before_value, after_value, note, created_by
  ) VALUES (
    v_tenant_id, v_wave_id, p_wave_item_id, 'picked_qty_changed',
    jsonb_build_object('picked_qty', v_old_qty),
    jsonb_build_object('picked_qty', p_new_qty),
    p_note, p_operator
  );

  IF v_wave_status = 'draft' THEN
    UPDATE picking_waves SET status = 'picking', updated_by = p_operator WHERE id = v_wave_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 從揀貨波次生成 transfers (transfer_type='hq_to_store', 每店一張) + post-commit count 驗證
-- 註: PRD #1 §4.2 原寫 sales_orders, 但 sales_orders 需 customer_id NOT NULL (B2B 用),
--     語意應為 HQ→store 內部出貨 → 用 transfers 更合理。
-- 注意: 本 RPC 引用 transfers.transfer_type, 該欄位由 PRD #2 庫存 v0.2 migration 加;
--     需在 inventory v0.2 migration 套用後才能正常使用。
CREATE OR REPLACE FUNCTION generate_transfer_from_wave(
  p_wave_id  BIGINT,
  p_hq_location_id BIGINT,
  p_operator UUID
) RETURNS JSONB AS $$
DECLARE
  v_tenant_id            UUID;
  v_wave_status          TEXT;
  v_expected_store_count INTEGER;
  v_expected_item_count  INTEGER;
  v_actual_xfer_count    INTEGER;
  v_actual_item_count    INTEGER;
  v_store_rec            RECORD;
  v_dest_location_id     BIGINT;
  v_new_xfer_id          BIGINT;
  v_inserted_items       INTEGER;
  v_xfer_ids             BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  PERFORM pg_advisory_xact_lock(p_wave_id);

  SELECT tenant_id, status INTO v_tenant_id, v_wave_status
    FROM picking_waves WHERE id = p_wave_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;
  IF v_wave_status <> 'picked' THEN
    RAISE EXCEPTION 'wave % is in status %, expected picked', p_wave_id, v_wave_status;
  END IF;

  SELECT COUNT(DISTINCT store_id), COUNT(*)
    INTO v_expected_store_count, v_expected_item_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0;

  IF v_expected_item_count = 0 THEN
    RAISE EXCEPTION 'wave % has no picked items, cannot generate transfer', p_wave_id;
  END IF;

  FOR v_store_rec IN
    SELECT DISTINCT pwi.store_id, s.location_id
      FROM picking_wave_items pwi
      JOIN stores s ON s.id = pwi.store_id
     WHERE pwi.wave_id = p_wave_id AND pwi.picked_qty > 0
  LOOP
    v_dest_location_id := v_store_rec.location_id;
    IF v_dest_location_id IS NULL THEN
      RAISE EXCEPTION 'store % has no location_id mapped', v_store_rec.store_id;
    END IF;

    INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                           status, transfer_type, requested_by, created_by, updated_by)
    VALUES (v_tenant_id,
            'WAVE-' || p_wave_id || '-S' || v_store_rec.store_id,
            p_hq_location_id, v_dest_location_id,
            'confirmed', 'hq_to_store', p_operator, p_operator, p_operator)
    RETURNING id INTO v_new_xfer_id;

    INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                                created_by, updated_by)
    SELECT v_new_xfer_id, pwi.sku_id, pwi.picked_qty, pwi.picked_qty,
           p_operator, p_operator
      FROM picking_wave_items pwi
     WHERE pwi.wave_id = p_wave_id
       AND pwi.store_id = v_store_rec.store_id
       AND pwi.picked_qty > 0;

    GET DIAGNOSTICS v_inserted_items = ROW_COUNT;
    IF v_inserted_items = 0 THEN
      RAISE EXCEPTION 'empty transfer generated for store %', v_store_rec.store_id;
    END IF;

    UPDATE picking_wave_items
       SET generated_transfer_id = v_new_xfer_id, updated_by = p_operator
     WHERE wave_id = p_wave_id AND store_id = v_store_rec.store_id AND picked_qty > 0;

    INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
    VALUES (v_tenant_id, p_wave_id, 'so_generated',
            jsonb_build_object('transfer_id', v_new_xfer_id,
                               'store_id', v_store_rec.store_id,
                               'items_count', v_inserted_items),
            p_operator);

    v_xfer_ids := v_xfer_ids || v_new_xfer_id;
  END LOOP;

  UPDATE picking_waves SET status = 'shipped', updated_by = p_operator WHERE id = p_wave_id;

  -- Post-execution count 驗證（Flag 4）
  SELECT COUNT(DISTINCT generated_transfer_id)
    INTO v_actual_xfer_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND generated_transfer_id IS NOT NULL;

  SELECT COUNT(*)
    INTO v_actual_item_count
    FROM transfer_items ti
    JOIN picking_wave_items pwi ON pwi.generated_transfer_id = ti.transfer_id
   WHERE pwi.wave_id = p_wave_id;

  IF v_actual_xfer_count <> v_expected_store_count THEN
    RAISE EXCEPTION 'transfer count mismatch: expected %, got %', v_expected_store_count, v_actual_xfer_count;
  END IF;
  IF v_actual_item_count <> v_expected_item_count THEN
    RAISE EXCEPTION 'item count mismatch: expected %, got %', v_expected_item_count, v_actual_item_count;
  END IF;

  RETURN jsonb_build_object(
    'transfer_count', v_actual_xfer_count,
    'item_count', v_actual_item_count,
    'transfer_ids', v_xfer_ids
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 樂樂 / 外部訂單匯入 resolve
CREATE OR REPLACE FUNCTION rpc_import_external_orders(
  p_tenant_id   UUID,
  p_batch_id    TEXT,
  p_campaign_id BIGINT,
  p_operator    UUID
) RETURNS JSONB AS $$
DECLARE
  v_row              RECORD;
  v_campaign_status  TEXT;
  v_resolved INTEGER := 0;
  v_skipped  INTEGER := 0;
  v_errors   INTEGER := 0;
BEGIN
  SELECT status INTO v_campaign_status
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = p_tenant_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_campaign_id;
  END IF;
  IF v_campaign_status NOT IN ('open','closed') THEN
    RAISE EXCEPTION 'campaign % is in status %, cannot import', p_campaign_id, v_campaign_status;
  END IF;

  FOR v_row IN
    SELECT * FROM external_order_imports
     WHERE tenant_id = p_tenant_id AND batch_id = p_batch_id AND status = 'pending'
  LOOP
    IF v_row.parsed_sku_id IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
    -- Note: full customer/order resolution 留給 admin UI；此處只做 staging → skipped
    -- (actual matching logic 依實際 CSV 格式決定；先保守標 resolved=0)
    v_skipped := v_skipped + 1;
  END LOOP;

  RETURN jsonb_build_object('resolved', v_resolved, 'skipped', v_skipped, 'errors', v_errors);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 6. RLS
-- ============================================================

ALTER TABLE picking_waves           ENABLE ROW LEVEL SECURITY;
ALTER TABLE picking_wave_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE picking_wave_audit_log  ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_order_imports  ENABLE ROW LEVEL SECURITY;

-- 總倉 / admin：ALL
CREATE POLICY pw_hq_all ON picking_waves
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','warehouse')
  );

-- 加盟店：只讀 wave_items where store = 自己
CREATE POLICY pw_store_read ON picking_waves
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND id IN (
      SELECT wave_id FROM picking_wave_items
       WHERE store_id = (auth.jwt() ->> 'store_id')::bigint
    )
  );

CREATE POLICY pwi_hq_all ON picking_wave_items
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','warehouse')
  );
CREATE POLICY pwi_store_read ON picking_wave_items
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND store_id = (auth.jwt() ->> 'store_id')::bigint
  );

CREATE POLICY pwal_hq_read ON picking_wave_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

CREATE POLICY eoi_hq_all ON external_order_imports
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
