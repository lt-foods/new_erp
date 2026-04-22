-- ============================================================
-- Sales Module Schema v0.1
-- PostgreSQL 15+ / Supabase
-- 依賴：inventory_schema.sql（locations, stock_movements, rpc_outbound, rpc_inbound）
-- See docs/DB-銷售模組.md for full design rationale.
-- ============================================================

-- ============================================================
-- TABLES
-- ============================================================

-- 1. 客戶主檔
CREATE TABLE customers (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  code              TEXT NOT NULL,
  name              TEXT NOT NULL,
  type              TEXT NOT NULL CHECK (type IN ('b2b','walk_in','employee')),
  tax_id            TEXT,
  tier              TEXT,
  contact_name      TEXT,
  phone             TEXT,
  email             TEXT,
  address           TEXT,
  payment_terms     TEXT,
  credit_limit      NUMERIC(18,2),
  employee_ref_id   BIGINT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  notes             TEXT,
  created_by        UUID,
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);

-- 2. 客戶階級價
CREATE TABLE customer_tier_prices (
  tenant_id      UUID NOT NULL,
  tier           TEXT NOT NULL,
  sku_id         BIGINT NOT NULL,
  price          NUMERIC(18,4) NOT NULL,
  effective_from DATE NOT NULL DEFAULT DATE '1900-01-01',
  effective_to   DATE,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, tier, sku_id, effective_from)
);

-- 3. B2B 銷售訂單
CREATE TABLE sales_orders (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL,
  so_no              TEXT NOT NULL,
  customer_id        BIGINT NOT NULL REFERENCES customers(id),
  source_location_id BIGINT NOT NULL REFERENCES locations(id),
  status             TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                       'draft','confirmed','partially_shipped','shipped','invoiced','closed','cancelled'
                     )),
  order_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  required_date      DATE,
  subtotal           NUMERIC(18,2) NOT NULL DEFAULT 0,
  discount           NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax                NUMERIC(18,2) NOT NULL DEFAULT 0,
  total              NUMERIC(18,2) NOT NULL DEFAULT 0,
  payment_terms      TEXT,
  created_by         UUID NOT NULL,
  updated_by         UUID,
  confirmed_at       TIMESTAMPTZ,
  notes              TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, so_no)
);

CREATE TABLE sales_order_items (
  id             BIGSERIAL PRIMARY KEY,
  so_id          BIGINT NOT NULL REFERENCES sales_orders(id) ON DELETE CASCADE,
  sku_id         BIGINT NOT NULL,
  qty_ordered    NUMERIC(18,3) NOT NULL CHECK (qty_ordered > 0),
  qty_shipped    NUMERIC(18,3) NOT NULL DEFAULT 0,
  qty_returned   NUMERIC(18,3) NOT NULL DEFAULT 0,
  unit_price     NUMERIC(18,4) NOT NULL,
  discount_amt   NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax_rate       NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  line_subtotal  NUMERIC(18,2) GENERATED ALWAYS AS (qty_ordered * unit_price - discount_amt) STORED,
  notes          TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. 出貨單
CREATE TABLE sales_deliveries (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  delivery_no         TEXT NOT NULL,
  so_id               BIGINT NOT NULL REFERENCES sales_orders(id),
  source_location_id  BIGINT NOT NULL REFERENCES locations(id),
  status              TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed','cancelled')),
  delivery_date       DATE NOT NULL DEFAULT CURRENT_DATE,
  shipped_by          UUID,
  confirmed_at        TIMESTAMPTZ,
  notes               TEXT,
  created_by          UUID,
  updated_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, delivery_no)
);

CREATE TABLE sales_delivery_items (
  id             BIGSERIAL PRIMARY KEY,
  delivery_id    BIGINT NOT NULL REFERENCES sales_deliveries(id) ON DELETE CASCADE,
  so_item_id     BIGINT REFERENCES sales_order_items(id),
  sku_id         BIGINT NOT NULL,
  qty_shipped    NUMERIC(18,3) NOT NULL CHECK (qty_shipped > 0),
  unit_price     NUMERIC(18,4) NOT NULL,
  movement_id    BIGINT REFERENCES stock_movements(id),
  notes          TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. POS 交易
CREATE TABLE pos_sales (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  sale_no           TEXT NOT NULL,
  location_id       BIGINT NOT NULL REFERENCES locations(id),
  terminal_id       TEXT,
  customer_id       BIGINT REFERENCES customers(id),
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
                      'pending','completed','voided','refunded'
                    )),
  subtotal          NUMERIC(18,2) NOT NULL DEFAULT 0,
  discount          NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax               NUMERIC(18,2) NOT NULL DEFAULT 0,
  total             NUMERIC(18,2) NOT NULL DEFAULT 0,
  paid_amount       NUMERIC(18,2) NOT NULL DEFAULT 0,
  change_amount     NUMERIC(18,2) NOT NULL DEFAULT 0,
  buyer_tax_id      TEXT,
  carrier_type      TEXT,
  carrier_id        TEXT,
  donated_to        TEXT,
  invoice_id        BIGINT,
  completed_at      TIMESTAMPTZ,
  operator_id       UUID NOT NULL,
  updated_by        UUID,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, sale_no)
);
COMMENT ON COLUMN pos_sales.operator_id IS '結帳店員（等同 created_by）';

CREATE TABLE pos_sale_items (
  id             BIGSERIAL PRIMARY KEY,
  sale_id        BIGINT NOT NULL REFERENCES pos_sales(id) ON DELETE CASCADE,
  sku_id         BIGINT NOT NULL,
  qty            NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  unit_price     NUMERIC(18,4) NOT NULL,
  discount_amt   NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax_rate       NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  line_subtotal  NUMERIC(18,2) GENERATED ALWAYS AS (qty * unit_price - discount_amt) STORED,
  movement_id    BIGINT REFERENCES stock_movements(id),
  notes          TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. 退貨單
CREATE TABLE sales_returns (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  return_no       TEXT NOT NULL,
  source_type     TEXT NOT NULL CHECK (source_type IN ('sales_order','pos_sale')),
  source_id       BIGINT NOT NULL,
  customer_id     BIGINT REFERENCES customers(id),
  dest_location_id BIGINT NOT NULL REFERENCES locations(id),
  status          TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                    'draft','confirmed','refunded','cancelled'
                  )),
  return_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  reason          TEXT,
  subtotal        NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax             NUMERIC(18,2) NOT NULL DEFAULT 0,
  total           NUMERIC(18,2) NOT NULL DEFAULT 0,
  refund_amount   NUMERIC(18,2) NOT NULL DEFAULT 0,
  created_by      UUID NOT NULL,
  updated_by      UUID,
  confirmed_at    TIMESTAMPTZ,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, return_no)
);

CREATE TABLE sales_return_items (
  id             BIGSERIAL PRIMARY KEY,
  return_id      BIGINT NOT NULL REFERENCES sales_returns(id) ON DELETE CASCADE,
  source_item_id BIGINT,
  sku_id         BIGINT NOT NULL,
  qty            NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  unit_price     NUMERIC(18,4) NOT NULL,
  line_subtotal  NUMERIC(18,2) GENERATED ALWAYS AS (qty * unit_price) STORED,
  movement_id    BIGINT REFERENCES stock_movements(id),
  notes          TEXT,
  created_by     UUID,
  updated_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. 付款
CREATE TABLE payments (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL,
  payment_no        TEXT NOT NULL,
  method            TEXT NOT NULL CHECK (method IN (
                      'cash','credit_card','line_pay','jko_pay','credit_sale','other'
                    )),
  amount            NUMERIC(18,2) NOT NULL CHECK (amount <> 0),
  direction         TEXT NOT NULL CHECK (direction IN ('in','out')),
  sales_order_id    BIGINT REFERENCES sales_orders(id),
  pos_sale_id       BIGINT REFERENCES pos_sales(id),
  sales_return_id   BIGINT REFERENCES sales_returns(id),
  receivable_id     BIGINT,
  card_type         TEXT,
  auth_code         TEXT,
  tx_ref            TEXT,
  status            TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('pending','completed','failed','refunded')),
  paid_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  operator_id       UUID,
  updated_by        UUID,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, payment_no),
  CHECK (
    (sales_order_id IS NOT NULL)::int
    + (pos_sale_id IS NOT NULL)::int
    + (sales_return_id IS NOT NULL)::int
    + (receivable_id IS NOT NULL)::int
    >= 1
  )
);

-- 8. 發票（沿用舊系統）
CREATE TABLE invoices (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  invoice_no      TEXT,
  invoice_type    TEXT NOT NULL CHECK (invoice_type IN ('b2b_triplicate','b2c_duplicate','allowance','voided')),
  issue_date      DATE,
  buyer_tax_id    TEXT,
  carrier_type    TEXT,
  carrier_id      TEXT,
  subtotal        NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax             NUMERIC(18,2) NOT NULL DEFAULT 0,
  total           NUMERIC(18,2) NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','issued','voided','allowance')),
  source_type     TEXT NOT NULL CHECK (source_type IN ('sales_order','pos_sale','sales_return')),
  source_id       BIGINT NOT NULL,
  external_ref    TEXT,
  issued_at       TIMESTAMPTZ,
  voided_at       TIMESTAMPTZ,
  notes           TEXT,
  created_by      UUID,
  updated_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, invoice_no)
);

ALTER TABLE pos_sales
  ADD CONSTRAINT fk_pos_invoice FOREIGN KEY (invoice_id) REFERENCES invoices(id);

-- 9. 應收帳款明細帳
CREATE TABLE receivables (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  customer_id     BIGINT NOT NULL REFERENCES customers(id),
  source_type     TEXT NOT NULL CHECK (source_type IN ('sales_order','sales_return','manual')),
  source_id       BIGINT,
  direction       TEXT NOT NULL CHECK (direction IN ('debit','credit')),
  amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  balance_after   NUMERIC(18,2),
  due_date        DATE,
  settled_by_payment_id BIGINT REFERENCES payments(id),
  status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','partially_settled','settled','written_off')),
  notes           TEXT,
  created_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE receivables IS 'AR ledger 性質：append-only；沖帳靠新增 credit 列，不改原 row';

ALTER TABLE payments
  ADD CONSTRAINT fk_payment_receivable FOREIGN KEY (receivable_id) REFERENCES receivables(id);

-- 10. 員工餐
CREATE TABLE employee_meals (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL,
  employee_id     BIGINT NOT NULL,
  location_id     BIGINT NOT NULL REFERENCES locations(id),
  meal_date       DATE NOT NULL DEFAULT CURRENT_DATE,
  sku_id          BIGINT NOT NULL,
  qty             NUMERIC(18,3) NOT NULL CHECK (qty > 0),
  unit_price      NUMERIC(18,4) NOT NULL DEFAULT 0,
  total           NUMERIC(18,2) GENERATED ALWAYS AS (qty * unit_price) STORED,
  movement_id     BIGINT REFERENCES stock_movements(id),
  payroll_batch   TEXT,
  notes           TEXT,
  created_by      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE employee_meals IS 'Log 性質：append-only；不修改已產生紀錄';

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_so_customer_date  ON sales_orders (tenant_id, customer_id, order_date DESC);
CREATE INDEX idx_so_status         ON sales_orders (tenant_id, status);
CREATE INDEX idx_soi_so            ON sales_order_items (so_id);
CREATE INDEX idx_dlv_so            ON sales_deliveries (so_id, status);

CREATE INDEX idx_pos_location_time ON pos_sales (tenant_id, location_id, created_at DESC);
CREATE INDEX idx_pos_status        ON pos_sales (tenant_id, status);

CREATE INDEX idx_sr_source         ON sales_returns (source_type, source_id);
CREATE INDEX idx_sr_date           ON sales_returns (tenant_id, return_date DESC);

CREATE INDEX idx_pay_method_date   ON payments (tenant_id, method, paid_at DESC);
CREATE INDEX idx_pay_pos           ON payments (pos_sale_id) WHERE pos_sale_id IS NOT NULL;
CREATE INDEX idx_pay_so            ON payments (sales_order_id) WHERE sales_order_id IS NOT NULL;

CREATE INDEX idx_inv_source        ON invoices (source_type, source_id);

CREATE INDEX idx_ar_customer_open  ON receivables (tenant_id, customer_id, status)
  WHERE status IN ('open','partially_settled');

CREATE INDEX idx_meal_emp_month    ON employee_meals (tenant_id, employee_id, payroll_batch);

-- ============================================================
-- TRIGGERS (touch updated_at)
-- ============================================================
-- 註：touch_updated_at 函式由 inventory_schema.sql 定義

CREATE TRIGGER trg_touch_customers             BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_customer_tier_prices  BEFORE UPDATE ON customer_tier_prices
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sales_orders          BEFORE UPDATE ON sales_orders
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sales_order_items     BEFORE UPDATE ON sales_order_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sales_deliveries      BEFORE UPDATE ON sales_deliveries
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sales_delivery_items  BEFORE UPDATE ON sales_delivery_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_pos_sales             BEFORE UPDATE ON pos_sales
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_pos_sale_items        BEFORE UPDATE ON pos_sale_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sales_returns         BEFORE UPDATE ON sales_returns
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_sales_return_items    BEFORE UPDATE ON sales_return_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_payments              BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_invoices              BEFORE UPDATE ON invoices
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- RPC FUNCTIONS
-- ============================================================

-- POS 結帳
CREATE OR REPLACE FUNCTION rpc_complete_pos_sale(p_sale_id BIGINT, p_operator UUID)
RETURNS VOID AS $$
DECLARE v_sale RECORD; v_item RECORD; v_mov_id BIGINT;
BEGIN
  SELECT * INTO v_sale FROM pos_sales WHERE id = p_sale_id FOR UPDATE;
  IF v_sale.status <> 'pending' THEN
    RAISE EXCEPTION 'POS sale % is not pending', p_sale_id;
  END IF;

  FOR v_item IN SELECT * FROM pos_sale_items WHERE sale_id = p_sale_id LOOP
    v_mov_id := rpc_outbound(
      p_tenant_id       => v_sale.tenant_id,
      p_location_id     => v_sale.location_id,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_item.qty,
      p_movement_type   => 'sale',
      p_source_doc_type => 'pos_sale',
      p_source_doc_id   => p_sale_id,
      p_operator        => p_operator
    );
    UPDATE pos_sale_items SET movement_id = v_mov_id WHERE id = v_item.id;
  END LOOP;

  UPDATE pos_sales SET status = 'completed', completed_at = NOW(), updated_at = NOW()
   WHERE id = p_sale_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 出貨單確認
CREATE OR REPLACE FUNCTION rpc_confirm_delivery(p_delivery_id BIGINT, p_operator UUID)
RETURNS VOID AS $$
DECLARE v_dlv RECORD; v_item RECORD; v_mov_id BIGINT; v_so_id BIGINT; v_fully BOOLEAN;
BEGIN
  SELECT * INTO v_dlv FROM sales_deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF v_dlv.status <> 'draft' THEN
    RAISE EXCEPTION 'Delivery % is not draft', p_delivery_id;
  END IF;

  FOR v_item IN SELECT * FROM sales_delivery_items WHERE delivery_id = p_delivery_id LOOP
    v_mov_id := rpc_outbound(
      p_tenant_id       => v_dlv.tenant_id,
      p_location_id     => v_dlv.source_location_id,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_item.qty_shipped,
      p_movement_type   => 'sale',
      p_source_doc_type => 'sales_delivery',
      p_source_doc_id   => p_delivery_id,
      p_operator        => p_operator
    );
    UPDATE sales_delivery_items SET movement_id = v_mov_id WHERE id = v_item.id;

    IF v_item.so_item_id IS NOT NULL THEN
      UPDATE sales_order_items
         SET qty_shipped = qty_shipped + v_item.qty_shipped
       WHERE id = v_item.so_item_id;
    END IF;
  END LOOP;

  UPDATE sales_deliveries SET status='confirmed', confirmed_at=NOW(), updated_at=NOW()
    WHERE id = p_delivery_id;

  v_so_id := v_dlv.so_id;
  SELECT BOOL_AND(qty_shipped >= qty_ordered) INTO v_fully
    FROM sales_order_items WHERE so_id = v_so_id;

  UPDATE sales_orders
     SET status = CASE WHEN v_fully THEN 'shipped' ELSE 'partially_shipped' END,
         updated_at = NOW()
   WHERE id = v_so_id AND status IN ('confirmed','partially_shipped');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 銷售退貨確認
CREATE OR REPLACE FUNCTION rpc_confirm_sales_return(p_return_id BIGINT, p_operator UUID)
RETURNS VOID AS $$
DECLARE v_r RECORD; v_item RECORD; v_mov_id BIGINT;
BEGIN
  SELECT * INTO v_r FROM sales_returns WHERE id = p_return_id FOR UPDATE;
  IF v_r.status <> 'draft' THEN
    RAISE EXCEPTION 'Return % is not draft', p_return_id;
  END IF;

  FOR v_item IN SELECT * FROM sales_return_items WHERE return_id = p_return_id LOOP
    v_mov_id := rpc_inbound(
      p_tenant_id       => v_r.tenant_id,
      p_location_id     => v_r.dest_location_id,
      p_sku_id          => v_item.sku_id,
      p_quantity        => v_item.qty,
      p_unit_cost       => v_item.unit_price,
      p_movement_type   => 'customer_return',
      p_source_doc_type => 'sales_return',
      p_source_doc_id   => p_return_id,
      p_operator        => p_operator
    );
    UPDATE sales_return_items SET movement_id = v_mov_id WHERE id = v_item.id;
  END LOOP;

  UPDATE sales_returns SET status='confirmed', confirmed_at=NOW(), updated_at=NOW()
    WHERE id = p_return_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 掛帳
CREATE OR REPLACE FUNCTION rpc_book_receivable(
  p_tenant_id UUID, p_customer_id BIGINT,
  p_source_type TEXT, p_source_id BIGINT,
  p_amount NUMERIC, p_due_date DATE
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO receivables
    (tenant_id, customer_id, source_type, source_id, direction, amount, due_date, status)
  VALUES
    (p_tenant_id, p_customer_id, p_source_type, p_source_id, 'debit', p_amount, p_due_date, 'open')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 收款沖帳
CREATE OR REPLACE FUNCTION rpc_settle_receivable(
  p_receivable_id BIGINT, p_payment_id BIGINT, p_amount NUMERIC
) RETURNS VOID AS $$
DECLARE v_r RECORD; v_settled NUMERIC;
BEGIN
  SELECT * INTO v_r FROM receivables WHERE id = p_receivable_id FOR UPDATE;
  IF v_r.status = 'settled' THEN
    RAISE EXCEPTION 'Receivable already settled';
  END IF;

  INSERT INTO receivables
    (tenant_id, customer_id, source_type, source_id, direction, amount,
     settled_by_payment_id, status)
  VALUES
    (v_r.tenant_id, v_r.customer_id, 'sales_order', v_r.source_id, 'credit', p_amount,
     p_payment_id, 'open');

  SELECT COALESCE(SUM(amount),0) INTO v_settled
    FROM receivables
   WHERE customer_id = v_r.customer_id
     AND source_type = v_r.source_type
     AND source_id = v_r.source_id
     AND direction = 'credit';

  UPDATE receivables
     SET status = CASE WHEN v_settled >= v_r.amount THEN 'settled' ELSE 'partially_settled' END
   WHERE id = p_receivable_id;

  UPDATE payments SET receivable_id = p_receivable_id WHERE id = p_payment_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 員工取餐
CREATE OR REPLACE FUNCTION rpc_log_employee_meal(
  p_tenant_id UUID, p_employee_id BIGINT, p_location_id BIGINT,
  p_sku_id BIGINT, p_qty NUMERIC, p_unit_price NUMERIC, p_operator UUID
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT; v_mov_id BIGINT;
BEGIN
  v_mov_id := rpc_outbound(
    p_tenant_id => p_tenant_id,
    p_location_id => p_location_id,
    p_sku_id => p_sku_id,
    p_quantity => p_qty,
    p_movement_type => 'sale',
    p_source_doc_type => 'employee_meal',
    p_source_doc_id => NULL,
    p_operator => p_operator
  );

  INSERT INTO employee_meals
    (tenant_id, employee_id, location_id, sku_id, qty, unit_price, movement_id,
     payroll_batch)
  VALUES
    (p_tenant_id, p_employee_id, p_location_id, p_sku_id, p_qty, p_unit_price, v_mov_id,
     to_char(NOW(),'YYYY-MM'))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RLS
-- ============================================================

ALTER TABLE customers              ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_tier_prices   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_orders           ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_order_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_deliveries       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_delivery_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_sales              ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_sale_items         ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_returns          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_return_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments               ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices               ENABLE ROW LEVEL SECURITY;
ALTER TABLE receivables            ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_meals         ENABLE ROW LEVEL SECURITY;

-- 店員：只看本店 POS
CREATE POLICY pos_store_scope ON pos_sales
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND location_id = (auth.jwt() ->> 'location_id')::bigint
  );

-- 老闆/會計：tenant 全讀
CREATE POLICY hq_full_read_so ON sales_orders
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','accountant','purchaser')
  );

CREATE POLICY hq_full_read_pos ON pos_sales
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','accountant')
  );

CREATE POLICY hq_full_read_ar ON receivables
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','accountant')
  );
