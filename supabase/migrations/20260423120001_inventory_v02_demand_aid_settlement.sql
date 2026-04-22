-- ============================================================
-- Inventory v0.2 addendum: demand / backorder / mutual aid / clearance / transfer settlement
-- PRD: docs/PRD-庫存模組-v0.2-addendum.md
-- ============================================================

-- ============================================================
-- 1. 既有表欄位補充：transfers.transfer_type (Q5)
-- ============================================================

ALTER TABLE transfers
  ADD COLUMN transfer_type TEXT NOT NULL DEFAULT 'store_to_store'
    CHECK (transfer_type IN ('store_to_store','return_to_hq','hq_to_store'));

CREATE INDEX idx_transfers_type ON transfers (tenant_id, transfer_type, status);

-- ============================================================
-- 2. TABLES
-- ============================================================

-- 需求單
CREATE TABLE demand_requests (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL,
  requester_store_id       BIGINT NOT NULL REFERENCES stores(id),
  sku_id                   BIGINT NOT NULL REFERENCES skus(id),
  qty                      NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  urgency                  TEXT NOT NULL DEFAULT 'normal'
                             CHECK (urgency IN ('normal','urgent','critical')),
  reason                   TEXT,
  status                   TEXT NOT NULL DEFAULT 'open'
                             CHECK (status IN ('open','fulfilled_by_transfer',
                                               'fulfilled_by_po','cancelled','expired')),
  target_date              DATE,
  fulfilled_transfer_id    BIGINT REFERENCES transfers(id),
  fulfilled_po_id          BIGINT REFERENCES purchase_orders(id),
  notes                    TEXT,
  created_by               UUID,
  updated_by               UUID,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dr_store_status ON demand_requests (tenant_id, requester_store_id, status);
CREATE INDEX idx_dr_sku_open ON demand_requests (tenant_id, sku_id) WHERE status = 'open';

-- 欠品 roll-over
CREATE TABLE backorders (
  id                                BIGSERIAL PRIMARY KEY,
  tenant_id                         UUID NOT NULL,
  original_customer_order_item_id   BIGINT NOT NULL REFERENCES customer_order_items(id),
  sku_id                            BIGINT NOT NULL REFERENCES skus(id),
  store_id                          BIGINT NOT NULL REFERENCES stores(id),
  member_id                         BIGINT REFERENCES members(id),
  qty_pending                       NUMERIC(18,3) NOT NULL CHECK (qty_pending > 0),
  rollover_to_campaign_id           BIGINT REFERENCES group_buy_campaigns(id),
  rollover_customer_order_item_id   BIGINT REFERENCES customer_order_items(id),
  status                            TEXT NOT NULL DEFAULT 'pending'
                                      CHECK (status IN ('pending','rolled_over','resolved','cancelled')),
  notes                             TEXT,
  created_by                        UUID,
  updated_by                        UUID,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_backorders_sku_status ON backorders (tenant_id, sku_id, status);
CREATE INDEX idx_backorders_member_pending ON backorders (member_id, status) WHERE status = 'pending';

-- 互助交流板
CREATE TABLE mutual_aid_board (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  offering_store_id   BIGINT NOT NULL REFERENCES stores(id),
  sku_id              BIGINT NOT NULL REFERENCES skus(id),
  qty_available       NUMERIC(18,3) NOT NULL CHECK (qty_available > 0),
  qty_remaining       NUMERIC(18,3) NOT NULL,
  expires_at          TIMESTAMPTZ NOT NULL,
  note                TEXT,
  status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','exhausted','expired','cancelled')),
  created_by          UUID,
  updated_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_active ON mutual_aid_board (tenant_id, status, expires_at)
  WHERE status = 'active';

-- 互助板認領（append-only）
CREATE TABLE mutual_aid_claims (
  id                      BIGSERIAL PRIMARY KEY,
  tenant_id               UUID NOT NULL,
  board_id                BIGINT NOT NULL REFERENCES mutual_aid_board(id),
  claiming_store_id       BIGINT NOT NULL REFERENCES stores(id),
  qty                     NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  resulting_transfer_id   BIGINT REFERENCES transfers(id),
  created_by              UUID,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_claims_board ON mutual_aid_claims (board_id, created_at DESC);

-- 88 折出清
CREATE TABLE aid_clearance_offers (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  offering_store_id     BIGINT NOT NULL REFERENCES stores(id),
  sku_id                BIGINT NOT NULL REFERENCES skus(id),
  qty_available         NUMERIC(18,3) NOT NULL CHECK (qty_available > 0),
  qty_remaining         NUMERIC(18,3) NOT NULL,
  discount_rate         NUMERIC(5,3) NOT NULL DEFAULT 0.88
                          CHECK (discount_rate IN (0.88, 0.85, 0.80)),
  expires_at            TIMESTAMPTZ NOT NULL,
  reason                TEXT,
  status                TEXT NOT NULL DEFAULT 'offered'
                          CHECK (status IN ('offered','claimed_by_store',
                                            'backfilled_by_hq','expired','cancelled')),
  converted_demand_id   BIGINT REFERENCES demand_requests(id),
  created_by            UUID,
  updated_by            UUID,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_aid_clearance_active ON aid_clearance_offers (tenant_id, status)
  WHERE status = 'offered';

-- 店轉店月結算
CREATE TABLE transfer_settlements (
  id                            BIGSERIAL PRIMARY KEY,
  tenant_id                     UUID NOT NULL,
  settlement_month              DATE NOT NULL,
  store_a_id                    BIGINT NOT NULL REFERENCES stores(id),
  store_b_id                    BIGINT NOT NULL REFERENCES stores(id),
  a_to_b_amount                 NUMERIC(18,4) NOT NULL DEFAULT 0,
  b_to_a_amount                 NUMERIC(18,4) NOT NULL DEFAULT 0,
  net_amount                    NUMERIC(18,4) NOT NULL,
  transfer_count                INTEGER NOT NULL DEFAULT 0,
  status                        TEXT NOT NULL DEFAULT 'draft'
                                  CHECK (status IN ('draft','confirmed','settled','disputed')),
  settled_at                    TIMESTAMPTZ,
  settled_by                    UUID,
  -- FK to vendor_bills 在 PRD #5 (AP) migration 後補
  generated_vendor_bill_id      BIGINT,
  notes                         TEXT,
  created_by                    UUID,
  updated_by                    UUID,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, settlement_month, store_a_id, store_b_id),
  CHECK (store_a_id < store_b_id)
);

CREATE INDEX idx_settlements_month ON transfer_settlements (tenant_id, settlement_month DESC);

-- 月結算明細（append-only）
CREATE TABLE transfer_settlement_items (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  settlement_id   BIGINT NOT NULL REFERENCES transfer_settlements(id) ON DELETE CASCADE,
  transfer_id     BIGINT NOT NULL REFERENCES transfers(id),
  direction       TEXT NOT NULL CHECK (direction IN ('a_to_b','b_to_a')),
  amount          NUMERIC(18,4) NOT NULL,
  transfer_date   DATE NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_settlement_items_settlement ON transfer_settlement_items (settlement_id);

-- ============================================================
-- 3. TRIGGERS
-- ============================================================

CREATE TRIGGER trg_touch_demand_requests       BEFORE UPDATE ON demand_requests
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_backorders            BEFORE UPDATE ON backorders
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_aid_board             BEFORE UPDATE ON mutual_aid_board
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_aid_clearance         BEFORE UPDATE ON aid_clearance_offers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_settlements           BEFORE UPDATE ON transfer_settlements
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_no_mut_aid_claims          BEFORE UPDATE OR DELETE ON mutual_aid_claims
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
CREATE TRIGGER trg_no_mut_settle_items        BEFORE UPDATE OR DELETE ON transfer_settlement_items
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();

-- ============================================================
-- 4. RPC FUNCTIONS
-- ============================================================

-- 以 transfer 滿足需求單
CREATE OR REPLACE FUNCTION rpc_fulfill_demand_by_transfer(
  p_demand_id        BIGINT,
  p_source_store_id  BIGINT,
  p_operator         UUID
) RETURNS BIGINT AS $$
DECLARE
  v_demand           RECORD;
  v_src_location_id  BIGINT;
  v_dst_location_id  BIGINT;
  v_new_xfer_id      BIGINT;
BEGIN
  SELECT * INTO v_demand FROM demand_requests
   WHERE id = p_demand_id AND status = 'open' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'demand % not found or not open', p_demand_id;
  END IF;

  SELECT location_id INTO v_src_location_id FROM stores WHERE id = p_source_store_id;
  SELECT location_id INTO v_dst_location_id FROM stores WHERE id = v_demand.requester_store_id;

  IF v_src_location_id IS NULL OR v_dst_location_id IS NULL THEN
    RAISE EXCEPTION 'source or dest store has no location_id';
  END IF;

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, requested_by, created_by, updated_by)
  VALUES (v_demand.tenant_id,
          'DR-' || p_demand_id || '-' || EXTRACT(EPOCH FROM NOW())::bigint,
          v_src_location_id, v_dst_location_id, 'confirmed', 'store_to_store',
          p_operator, p_operator, p_operator)
  RETURNING id INTO v_new_xfer_id;

  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by, updated_by)
  VALUES (v_new_xfer_id, v_demand.sku_id, v_demand.qty, p_operator, p_operator);

  UPDATE demand_requests
     SET status = 'fulfilled_by_transfer',
         fulfilled_transfer_id = v_new_xfer_id,
         updated_by = p_operator
   WHERE id = p_demand_id;

  RETURN v_new_xfer_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- backorder 自動 roll-over 到下波 campaign
CREATE OR REPLACE FUNCTION rpc_rollover_backorders(
  p_new_campaign_id BIGINT,
  p_operator        UUID
) RETURNS INTEGER AS $$
DECLARE
  v_tenant_id       UUID;
  v_campaign_status TEXT;
  v_b               RECORD;
  v_new_order_id    BIGINT;
  v_new_item_id     BIGINT;
  v_campaign_item_id BIGINT;
  v_count           INTEGER := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('rollover:' || p_new_campaign_id::text));

  SELECT tenant_id, status INTO v_tenant_id, v_campaign_status
    FROM group_buy_campaigns WHERE id = p_new_campaign_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not found', p_new_campaign_id;
  END IF;
  IF v_campaign_status <> 'open' THEN
    RAISE EXCEPTION 'campaign % is not open (status=%)', p_new_campaign_id, v_campaign_status;
  END IF;

  FOR v_b IN
    SELECT b.* FROM backorders b
     WHERE b.tenant_id = v_tenant_id
       AND b.status = 'pending'
       AND b.sku_id IN (SELECT sku_id FROM campaign_items WHERE campaign_id = p_new_campaign_id)
  LOOP
    SELECT id INTO v_campaign_item_id
      FROM campaign_items
     WHERE campaign_id = p_new_campaign_id AND sku_id = v_b.sku_id;

    -- find or create customer_order
    SELECT id INTO v_new_order_id
      FROM customer_orders
     WHERE tenant_id = v_tenant_id
       AND campaign_id = p_new_campaign_id
       AND member_id = v_b.member_id
       AND pickup_store_id = v_b.store_id
     LIMIT 1;

    IF v_new_order_id IS NULL THEN
      -- 從原 backorder 對應的 customer_order 取 channel_id (避免店無 channel 時 NULL violation)
      INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id,
                                   member_id, pickup_store_id, status, notes,
                                   created_by, updated_by)
      SELECT v_tenant_id,
             'RO-' || p_new_campaign_id || '-' || v_b.id,
             p_new_campaign_id,
             COALESCE(orig_co.channel_id,
                      (SELECT lc.id FROM line_channels lc
                        WHERE lc.home_store_id = v_b.store_id LIMIT 1)),
             v_b.member_id, v_b.store_id, 'pending',
             '上期欠品 roll-over (backorder #' || v_b.id || ')',
             p_operator, p_operator
        FROM customer_order_items orig_coi
        JOIN customer_orders orig_co ON orig_co.id = orig_coi.order_id
       WHERE orig_coi.id = v_b.original_customer_order_item_id
      RETURNING id INTO v_new_order_id;

      IF v_new_order_id IS NULL THEN
        RAISE EXCEPTION 'failed to derive channel_id for backorder %', v_b.id;
      END IF;
    END IF;

    INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id,
                                      qty, unit_price, source, status, created_by, updated_by)
    SELECT v_tenant_id, v_new_order_id, v_campaign_item_id, v_b.sku_id,
           v_b.qty_pending,
           (SELECT unit_price FROM campaign_items WHERE id = v_campaign_item_id),
           'rollover', 'pending', p_operator, p_operator
    RETURNING id INTO v_new_item_id;

    UPDATE backorders
       SET status = 'rolled_over',
           rollover_to_campaign_id = p_new_campaign_id,
           rollover_customer_order_item_id = v_new_item_id,
           updated_by = p_operator
     WHERE id = v_b.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 認領互助板
CREATE OR REPLACE FUNCTION rpc_claim_aid(
  p_board_id          BIGINT,
  p_claiming_store_id BIGINT,
  p_qty               NUMERIC,
  p_operator          UUID
) RETURNS BIGINT AS $$
DECLARE
  v_board            RECORD;
  v_src_location_id  BIGINT;
  v_dst_location_id  BIGINT;
  v_new_xfer_id      BIGINT;
  v_claim_id         BIGINT;
BEGIN
  SELECT * INTO v_board FROM mutual_aid_board
   WHERE id = p_board_id AND status = 'active' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'board % not found or not active', p_board_id;
  END IF;
  IF v_board.qty_remaining < p_qty THEN
    RAISE EXCEPTION 'insufficient qty: remaining=%, requested=%', v_board.qty_remaining, p_qty;
  END IF;

  SELECT location_id INTO v_src_location_id FROM stores WHERE id = v_board.offering_store_id;
  SELECT location_id INTO v_dst_location_id FROM stores WHERE id = p_claiming_store_id;
  IF v_src_location_id IS NULL OR v_dst_location_id IS NULL THEN
    RAISE EXCEPTION 'store missing location_id mapping';
  END IF;

  UPDATE mutual_aid_board
     SET qty_remaining = qty_remaining - p_qty,
         status = CASE WHEN qty_remaining - p_qty = 0 THEN 'exhausted' ELSE status END,
         updated_by = p_operator
   WHERE id = p_board_id;

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, requested_by, created_by, updated_by)
  VALUES (v_board.tenant_id,
          'AID-' || p_board_id || '-' || EXTRACT(EPOCH FROM NOW())::bigint,
          v_src_location_id, v_dst_location_id, 'confirmed', 'store_to_store',
          p_operator, p_operator, p_operator)
  RETURNING id INTO v_new_xfer_id;

  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by, updated_by)
  VALUES (v_new_xfer_id, v_board.sku_id, p_qty, p_operator, p_operator);

  INSERT INTO mutual_aid_claims (tenant_id, board_id, claiming_store_id, qty,
                                 resulting_transfer_id, created_by)
  VALUES (v_board.tenant_id, p_board_id, p_claiming_store_id, p_qty, v_new_xfer_id, p_operator)
  RETURNING id INTO v_claim_id;

  RETURN v_new_xfer_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 認領 88 折出清
CREATE OR REPLACE FUNCTION rpc_claim_clearance(
  p_offer_id          BIGINT,
  p_claiming_store_id BIGINT,
  p_qty               NUMERIC,
  p_operator          UUID
) RETURNS BIGINT AS $$
DECLARE
  v_offer            RECORD;
  v_src_location_id  BIGINT;
  v_dst_location_id  BIGINT;
  v_new_xfer_id      BIGINT;
BEGIN
  SELECT * INTO v_offer FROM aid_clearance_offers
   WHERE id = p_offer_id AND status = 'offered' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer % not found or not offered', p_offer_id;
  END IF;
  IF v_offer.qty_remaining < p_qty THEN
    RAISE EXCEPTION 'insufficient qty: remaining=%, requested=%', v_offer.qty_remaining, p_qty;
  END IF;

  SELECT location_id INTO v_src_location_id FROM stores WHERE id = v_offer.offering_store_id;
  SELECT location_id INTO v_dst_location_id FROM stores WHERE id = p_claiming_store_id;

  UPDATE aid_clearance_offers
     SET qty_remaining = qty_remaining - p_qty,
         status = CASE WHEN qty_remaining - p_qty = 0 THEN 'claimed_by_store' ELSE status END,
         updated_by = p_operator
   WHERE id = p_offer_id;

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, requested_by, notes, created_by, updated_by)
  VALUES (v_offer.tenant_id,
          'CLR-' || p_offer_id || '-' || EXTRACT(EPOCH FROM NOW())::bigint,
          v_src_location_id, v_dst_location_id, 'confirmed', 'store_to_store',
          p_operator,
          'clearance @ ' || v_offer.discount_rate::text,
          p_operator, p_operator)
  RETURNING id INTO v_new_xfer_id;

  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by, updated_by)
  VALUES (v_new_xfer_id, v_offer.sku_id, p_qty, p_operator, p_operator);

  RETURN v_new_xfer_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- admin 把出清轉成 HQ 收貨需求
CREATE OR REPLACE FUNCTION rpc_convert_clearance_to_demand(
  p_offer_id   BIGINT,
  p_hq_store_id BIGINT,
  p_operator   UUID
) RETURNS BIGINT AS $$
DECLARE
  v_offer       RECORD;
  v_new_demand_id BIGINT;
BEGIN
  SELECT * INTO v_offer FROM aid_clearance_offers
   WHERE id = p_offer_id AND status = 'offered' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer % not found or not offered', p_offer_id;
  END IF;

  INSERT INTO demand_requests (tenant_id, requester_store_id, sku_id, qty,
                               urgency, reason, status, created_by, updated_by)
  VALUES (v_offer.tenant_id, p_hq_store_id, v_offer.sku_id, v_offer.qty_remaining,
          'normal',
          '88 折出清收回 (offer #' || p_offer_id || ', rate=' || v_offer.discount_rate::text || ')',
          'open', p_operator, p_operator)
  RETURNING id INTO v_new_demand_id;

  UPDATE aid_clearance_offers
     SET status = 'backfilled_by_hq',
         converted_demand_id = v_new_demand_id,
         updated_by = p_operator
   WHERE id = p_offer_id;

  RETURN v_new_demand_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 月結算 generate（draft）
CREATE OR REPLACE FUNCTION rpc_generate_transfer_settlement(
  p_tenant_id UUID,
  p_month     DATE,
  p_operator  UUID
) RETURNS INTEGER AS $$
DECLARE
  v_existing_confirmed INTEGER;
  v_pair               RECORD;
  v_settlement_id      BIGINT;
  v_a_to_b             NUMERIC(18,4);
  v_b_to_a             NUMERIC(18,4);
  v_count              INTEGER := 0;
  v_xfer_count         INTEGER;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('settlement:' || p_tenant_id::text || ':' || p_month::text));

  SELECT COUNT(*) INTO v_existing_confirmed
    FROM transfer_settlements
   WHERE tenant_id = p_tenant_id
     AND settlement_month = p_month
     AND status IN ('confirmed','settled');
  IF v_existing_confirmed > 0 THEN
    RAISE EXCEPTION 'settlement for month % already confirmed/settled', p_month;
  END IF;

  -- 砍掉 draft 重算
  DELETE FROM transfer_settlements
   WHERE tenant_id = p_tenant_id AND settlement_month = p_month AND status = 'draft';

  -- aggregate transfers by (store_a < store_b)
  FOR v_pair IN
    SELECT
      LEAST(src_store.id, dst_store.id)    AS store_a,
      GREATEST(src_store.id, dst_store.id) AS store_b
    FROM transfers t
    JOIN stores src_store ON src_store.location_id = t.source_location
    JOIN stores dst_store ON dst_store.location_id = t.dest_location
    WHERE t.tenant_id = p_tenant_id
      AND DATE_TRUNC('month', t.shipped_at) = p_month
      AND t.transfer_type IN ('store_to_store','return_to_hq')
      AND t.status IN ('received','closed')
    GROUP BY 1, 2
  LOOP
    SELECT
      COALESCE(SUM(CASE WHEN src_store.id = v_pair.store_a THEN line_amount END), 0),
      COALESCE(SUM(CASE WHEN src_store.id = v_pair.store_b THEN line_amount END), 0),
      COUNT(DISTINCT t.id)
    INTO v_a_to_b, v_b_to_a, v_xfer_count
    FROM transfers t
    JOIN stores src_store ON src_store.location_id = t.source_location
    JOIN stores dst_store ON dst_store.location_id = t.dest_location
    JOIN LATERAL (
      SELECT SUM(ti.qty_received * COALESCE(sb.avg_cost, 0)) AS line_amount
        FROM transfer_items ti
        LEFT JOIN stock_balances sb ON sb.location_id = t.source_location
                                   AND sb.sku_id = ti.sku_id
       WHERE ti.transfer_id = t.id
    ) amt ON TRUE
    WHERE t.tenant_id = p_tenant_id
      AND DATE_TRUNC('month', t.shipped_at) = p_month
      AND t.transfer_type IN ('store_to_store','return_to_hq')
      AND t.status IN ('received','closed')
      AND ((src_store.id = v_pair.store_a AND dst_store.id = v_pair.store_b)
        OR (src_store.id = v_pair.store_b AND dst_store.id = v_pair.store_a));

    INSERT INTO transfer_settlements (tenant_id, settlement_month, store_a_id, store_b_id,
                                      a_to_b_amount, b_to_a_amount, net_amount,
                                      transfer_count, status, created_by, updated_by)
    VALUES (p_tenant_id, p_month, v_pair.store_a, v_pair.store_b,
            v_a_to_b, v_b_to_a, v_a_to_b - v_b_to_a,
            v_xfer_count, 'draft', p_operator, p_operator)
    RETURNING id INTO v_settlement_id;

    -- 明細
    INSERT INTO transfer_settlement_items (tenant_id, settlement_id, transfer_id,
                                           direction, amount, transfer_date)
    SELECT p_tenant_id, v_settlement_id, t.id,
           CASE WHEN src_store.id = v_pair.store_a THEN 'a_to_b' ELSE 'b_to_a' END,
           amt.line_amount,
           t.shipped_at::date
    FROM transfers t
    JOIN stores src_store ON src_store.location_id = t.source_location
    JOIN stores dst_store ON dst_store.location_id = t.dest_location
    JOIN LATERAL (
      SELECT SUM(ti.qty_received * COALESCE(sb.avg_cost, 0)) AS line_amount
        FROM transfer_items ti
        LEFT JOIN stock_balances sb ON sb.location_id = t.source_location
                                   AND sb.sku_id = ti.sku_id
       WHERE ti.transfer_id = t.id
    ) amt ON TRUE
    WHERE t.tenant_id = p_tenant_id
      AND DATE_TRUNC('month', t.shipped_at) = p_month
      AND t.transfer_type IN ('store_to_store','return_to_hq')
      AND t.status IN ('received','closed')
      AND ((src_store.id = v_pair.store_a AND dst_store.id = v_pair.store_b)
        OR (src_store.id = v_pair.store_b AND dst_store.id = v_pair.store_a));

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 月結算 confirm（Flag 8: net>0 → vendor_bill 由 PRD #5 trigger 處理；本 RPC 只標 confirmed）
-- AP migration 後會 ALTER 此函數加入 vendor_bill insert 邏輯
CREATE OR REPLACE FUNCTION rpc_confirm_transfer_settlement(
  p_settlement_id BIGINT,
  p_operator      UUID
) RETURNS JSONB AS $$
DECLARE
  v_s RECORD;
BEGIN
  SELECT * INTO v_s FROM transfer_settlements
   WHERE id = p_settlement_id AND status = 'draft' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found or not draft', p_settlement_id;
  END IF;

  UPDATE transfer_settlements
     SET status = 'confirmed',
         settled_by = p_operator,
         settled_at = NOW(),
         updated_by = p_operator
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'net_amount', v_s.net_amount,
    'vendor_bill_id', NULL  -- PRD #5 migration 後會擴充此 RPC 自動建 bill
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 5. RLS
-- ============================================================

ALTER TABLE demand_requests             ENABLE ROW LEVEL SECURITY;
ALTER TABLE backorders                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE mutual_aid_board            ENABLE ROW LEVEL SECURITY;
ALTER TABLE mutual_aid_claims           ENABLE ROW LEVEL SECURITY;
ALTER TABLE aid_clearance_offers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfer_settlements        ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfer_settlement_items   ENABLE ROW LEVEL SECURITY;

-- demand_requests
CREATE POLICY dr_hq_all ON demand_requests
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY dr_store_own ON demand_requests
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND requester_store_id = (auth.jwt() ->> 'store_id')::bigint
  );

-- backorders
CREATE POLICY bo_hq_all ON backorders
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY bo_store_read ON backorders
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND store_id = (auth.jwt() ->> 'store_id')::bigint
  );

-- mutual_aid_board / aid_clearance_offers: 全店家可讀
CREATE POLICY aid_board_read_all ON mutual_aid_board
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY aid_board_owner_write ON mutual_aid_board
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (offering_store_id = (auth.jwt() ->> 'store_id')::bigint
         OR (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager'))
  );

CREATE POLICY clr_read_all ON aid_clearance_offers
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY clr_owner_write ON aid_clearance_offers
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (offering_store_id = (auth.jwt() ->> 'store_id')::bigint
         OR (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager'))
  );

-- mutual_aid_claims
CREATE POLICY aid_claims_hq_all ON mutual_aid_claims
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );
CREATE POLICY aid_claims_store_read ON mutual_aid_claims
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (claiming_store_id = (auth.jwt() ->> 'store_id')::bigint
         OR board_id IN (SELECT id FROM mutual_aid_board
                         WHERE offering_store_id = (auth.jwt() ->> 'store_id')::bigint))
  );

-- transfer_settlements / items
CREATE POLICY ts_hq_all ON transfer_settlements
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );
CREATE POLICY ts_store_read ON transfer_settlements
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND ((auth.jwt() ->> 'store_id')::bigint IN (store_a_id, store_b_id))
  );

CREATE POLICY tsi_hq_all ON transfer_settlement_items
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );
