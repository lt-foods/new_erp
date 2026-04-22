-- ============================================================
-- 應付帳款 (AP) + 零用金 (Petty Cash) + 費用 (Expense) v0.2
-- PRD: docs/PRD-應付帳款零用金-v0.2.md
-- ============================================================

-- ============================================================
-- 1. expense_categories (master, 先建以供 expenses FK)
-- ============================================================

CREATE TABLE expense_categories (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  code                  TEXT NOT NULL,
  name                  TEXT NOT NULL,
  parent_id             BIGINT REFERENCES expense_categories(id),
  approval_threshold    NUMERIC(18,4),
  default_pay_method    TEXT
                          CHECK (default_pay_method IN ('petty_cash','company_account','either')),
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  created_by            UUID,
  updated_by            UUID,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);

CREATE TRIGGER trg_touch_expense_cat BEFORE UPDATE ON expense_categories
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================================================
-- 2. vendor_bills
-- ============================================================

CREATE TABLE vendor_bills (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL,
  bill_no               TEXT NOT NULL,
  supplier_id           BIGINT NOT NULL REFERENCES suppliers(id),
  source_type           TEXT NOT NULL
                          CHECK (source_type IN ('purchase_order','goods_receipt',
                                                 'transfer_settlement','xiaolan_import','manual')),
  source_id             BIGINT,
  bill_date             DATE NOT NULL,
  due_date              DATE NOT NULL,
  amount                NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  paid_amount           NUMERIC(18,4) NOT NULL DEFAULT 0
                          CHECK (paid_amount >= 0 AND paid_amount <= amount),
  status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','partially_paid','paid','cancelled','disputed')),
  currency              TEXT NOT NULL DEFAULT 'TWD',
  tax_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
  supplier_invoice_no   TEXT,
  notes                 TEXT,
  created_by            UUID,
  updated_by            UUID,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, bill_no)
);

CREATE INDEX idx_bills_supplier ON vendor_bills (tenant_id, supplier_id, status);
CREATE INDEX idx_bills_due ON vendor_bills (tenant_id, due_date)
  WHERE status IN ('pending','partially_paid');
CREATE INDEX idx_bills_source ON vendor_bills (tenant_id, source_type, source_id);

-- vendor_bill_items (append-only)
CREATE TABLE vendor_bill_items (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL,
  bill_id       BIGINT NOT NULL REFERENCES vendor_bills(id) ON DELETE CASCADE,
  line_no       INTEGER NOT NULL,
  description   TEXT NOT NULL,
  sku_id        BIGINT REFERENCES skus(id),
  qty           NUMERIC(18,3),
  unit_cost     NUMERIC(18,4),
  amount        NUMERIC(18,4) NOT NULL,
  po_item_id    BIGINT REFERENCES purchase_order_items(id),
  gr_item_id    BIGINT REFERENCES goods_receipt_items(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_bill_items_bill ON vendor_bill_items (bill_id, line_no);

-- ============================================================
-- 3. vendor_payments
-- ============================================================

CREATE TABLE vendor_payments (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL,
  payment_no               TEXT NOT NULL,
  supplier_id              BIGINT NOT NULL REFERENCES suppliers(id),
  amount                   NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  method                   TEXT NOT NULL
                             CHECK (method IN ('cash','bank_transfer','check','offset','petty_cash','other')),
  bank_account             TEXT,
  check_no                 TEXT,
  paid_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  paid_from_petty_cash_id  BIGINT,  -- FK 加在 petty_cash_transactions 建表後
  status                   TEXT NOT NULL DEFAULT 'completed'
                             CHECK (status IN ('pending','completed','voided')),
  notes                    TEXT,
  created_by               UUID,
  updated_by               UUID,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, payment_no)
);

CREATE INDEX idx_vpay_supplier ON vendor_payments (tenant_id, supplier_id, paid_at DESC);

-- vendor_payment_allocations (append-only)
CREATE TABLE vendor_payment_allocations (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  payment_id          BIGINT NOT NULL REFERENCES vendor_payments(id) ON DELETE CASCADE,
  bill_id             BIGINT NOT NULL REFERENCES vendor_bills(id),
  allocated_amount    NUMERIC(18,4) NOT NULL CHECK (allocated_amount > 0),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_vpay_alloc_bill ON vendor_payment_allocations (bill_id);
CREATE INDEX idx_vpay_alloc_pay ON vendor_payment_allocations (payment_id);

-- ============================================================
-- 4. petty_cash_accounts + transactions
-- ============================================================

CREATE TABLE petty_cash_accounts (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  store_id            BIGINT NOT NULL REFERENCES stores(id),
  account_name        TEXT NOT NULL,
  balance             NUMERIC(18,4) NOT NULL DEFAULT 0,
  credit_limit        NUMERIC(18,4) NOT NULL DEFAULT 0,
  custodian_user_id   UUID,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_by          UUID,
  updated_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, store_id, account_name)
);

CREATE INDEX idx_pca_store ON petty_cash_accounts (tenant_id, store_id) WHERE is_active;

CREATE TABLE petty_cash_transactions (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL,
  account_id          BIGINT NOT NULL REFERENCES petty_cash_accounts(id),
  txn_date            DATE NOT NULL DEFAULT CURRENT_DATE,
  direction           TEXT NOT NULL CHECK (direction IN ('in','out')),
  amount              NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  purpose             TEXT NOT NULL,
  category_id         BIGINT REFERENCES expense_categories(id),
  expense_id          BIGINT,  -- FK 加在 expenses 建表後
  vendor_payment_id   BIGINT REFERENCES vendor_payments(id),
  receipt_photo_url   TEXT,
  notes               TEXT,
  created_by          UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_pct_account_date ON petty_cash_transactions (account_id, txn_date DESC);
CREATE INDEX idx_pct_category ON petty_cash_transactions (category_id) WHERE category_id IS NOT NULL;

-- 補建 vendor_payments → petty_cash_transactions FK
ALTER TABLE vendor_payments
  ADD CONSTRAINT fk_vpay_petty_cash
  FOREIGN KEY (paid_from_petty_cash_id) REFERENCES petty_cash_transactions(id);

-- ============================================================
-- 5. expenses
-- ============================================================

CREATE TABLE expenses (
  id                            BIGSERIAL PRIMARY KEY,
  tenant_id                     UUID NOT NULL,
  expense_no                    TEXT NOT NULL,
  applicant_id                  UUID NOT NULL,
  store_id                      BIGINT REFERENCES stores(id),
  category_id                   BIGINT NOT NULL REFERENCES expense_categories(id),
  amount                        NUMERIC(18,4) NOT NULL CHECK (amount > 0),
  currency                      TEXT NOT NULL DEFAULT 'TWD',
  expense_date                  DATE NOT NULL,
  description                   TEXT NOT NULL,
  receipt_photo_url             TEXT,
  approval_status               TEXT NOT NULL DEFAULT 'pending'
                                  CHECK (approval_status IN ('pending','approved','rejected','paid')),
  approved_by                   UUID,
  approved_at                   TIMESTAMPTZ,
  rejection_reason              TEXT,
  paid_by_vendor_payment_id     BIGINT REFERENCES vendor_payments(id),
  paid_by_petty_cash_txn_id     BIGINT REFERENCES petty_cash_transactions(id),
  settled_by_hq                 BOOLEAN NOT NULL DEFAULT FALSE,
  created_by                    UUID,
  updated_by                    UUID,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, expense_no),
  CHECK (
    (paid_by_vendor_payment_id IS NULL)::int
    + (paid_by_petty_cash_txn_id IS NULL)::int >= 1
  )
);

CREATE INDEX idx_expenses_status ON expenses (tenant_id, approval_status);
CREATE INDEX idx_expenses_store ON expenses (tenant_id, store_id, expense_date DESC);
CREATE INDEX idx_expenses_applicant ON expenses (applicant_id, approval_status);

-- 補建 petty_cash_transactions → expenses FK
ALTER TABLE petty_cash_transactions
  ADD CONSTRAINT fk_pct_expense
  FOREIGN KEY (expense_id) REFERENCES expenses(id);

-- 補建 transfer_settlements → vendor_bills FK (Flag 8)
ALTER TABLE transfer_settlements
  ADD CONSTRAINT fk_settlement_vendor_bill
  FOREIGN KEY (generated_vendor_bill_id) REFERENCES vendor_bills(id);

-- ============================================================
-- 6. TRIGGERS
-- ============================================================

CREATE TRIGGER trg_touch_vendor_bills      BEFORE UPDATE ON vendor_bills
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_vendor_payments   BEFORE UPDATE ON vendor_payments
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_petty_acct        BEFORE UPDATE ON petty_cash_accounts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_expenses          BEFORE UPDATE ON expenses
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- append-only 防 mutation
CREATE TRIGGER trg_no_mut_bill_items   BEFORE UPDATE OR DELETE ON vendor_bill_items
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
CREATE TRIGGER trg_no_mut_alloc        BEFORE UPDATE OR DELETE ON vendor_payment_allocations
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();
CREATE TRIGGER trg_no_mut_pct          BEFORE UPDATE OR DELETE ON petty_cash_transactions
  FOR EACH ROW EXECUTE FUNCTION forbid_append_only_mutation();

-- petty_cash_accounts.balance 自動由 transactions 維護
CREATE OR REPLACE FUNCTION apply_petty_cash_txn()
RETURNS TRIGGER AS $$
DECLARE
  v_acct RECORD;
  v_new_balance NUMERIC(18,4);
BEGIN
  SELECT * INTO v_acct FROM petty_cash_accounts
   WHERE id = NEW.account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'petty cash account % not found', NEW.account_id;
  END IF;

  v_new_balance := v_acct.balance + CASE WHEN NEW.direction = 'in' THEN NEW.amount ELSE -NEW.amount END;

  IF v_new_balance + v_acct.credit_limit < 0 THEN
    RAISE EXCEPTION 'petty cash overdraw: balance=%, credit_limit=%, change=%',
      v_acct.balance, v_acct.credit_limit,
      CASE WHEN NEW.direction = 'in' THEN NEW.amount ELSE -NEW.amount END;
  END IF;

  UPDATE petty_cash_accounts
     SET balance = v_new_balance,
         updated_at = NOW()
   WHERE id = NEW.account_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_petty_cash AFTER INSERT ON petty_cash_transactions
  FOR EACH ROW EXECUTE FUNCTION apply_petty_cash_txn();

-- 加盟店 supplier 同步 (Flag 8)
CREATE OR REPLACE FUNCTION sync_store_as_supplier()
RETURNS TRIGGER AS $$
DECLARE
  v_supplier_id BIGINT;
BEGIN
  IF NEW.supplier_id IS NULL THEN
    INSERT INTO suppliers (tenant_id, code, name, is_active, created_by, updated_by)
    VALUES (NEW.tenant_id, 'STORE-' || NEW.code, NEW.name, TRUE,
            NEW.created_by, COALESCE(NEW.updated_by, NEW.created_by))
    RETURNING id INTO v_supplier_id;
    NEW.supplier_id := v_supplier_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_store_as_supplier BEFORE INSERT ON stores
  FOR EACH ROW EXECUTE FUNCTION sync_store_as_supplier();

-- ============================================================
-- 7. VIEW: AP aging
-- ============================================================

CREATE OR REPLACE VIEW v_ap_aging AS
SELECT
  supplier_id,
  supplier_name,
  SUM(CASE WHEN due_date >= CURRENT_DATE THEN unpaid END) AS current_due,
  SUM(CASE WHEN due_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1 THEN unpaid END) AS overdue_1_30,
  SUM(CASE WHEN due_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE - 31 THEN unpaid END) AS overdue_31_60,
  SUM(CASE WHEN due_date < CURRENT_DATE - 60 THEN unpaid END) AS overdue_60_plus,
  SUM(unpaid) AS total_unpaid
FROM (
  SELECT b.supplier_id, s.name AS supplier_name, b.due_date,
         b.amount - b.paid_amount AS unpaid
    FROM vendor_bills b
    JOIN suppliers s ON s.id = b.supplier_id
   WHERE b.status IN ('pending','partially_paid')
) sub
GROUP BY supplier_id, supplier_name;

-- ============================================================
-- 8. RPC FUNCTIONS
-- ============================================================

-- 手動建 bill
CREATE OR REPLACE FUNCTION rpc_create_manual_bill(
  p_tenant_id   UUID,
  p_supplier_id BIGINT,
  p_bill_no     TEXT,
  p_bill_date   DATE,
  p_due_date    DATE,
  p_amount      NUMERIC,
  p_notes       TEXT,
  p_operator    UUID
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO vendor_bills (tenant_id, bill_no, supplier_id, source_type,
                            bill_date, due_date, amount, status, notes,
                            created_by, updated_by)
  VALUES (p_tenant_id, p_bill_no, p_supplier_id, 'manual',
          p_bill_date, p_due_date, p_amount, 'pending', p_notes,
          p_operator, p_operator)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 付款 + 分配多張 bill
CREATE OR REPLACE FUNCTION rpc_make_payment(
  p_tenant_id   UUID,
  p_supplier_id BIGINT,
  p_payment_no  TEXT,
  p_amount      NUMERIC,
  p_method      TEXT,
  p_paid_at     TIMESTAMPTZ,
  p_allocations JSONB,  -- [{bill_id, allocated_amount}]
  p_operator    UUID
) RETURNS BIGINT AS $$
DECLARE
  v_pay_id     BIGINT;
  v_alloc      JSONB;
  v_bill_id    BIGINT;
  v_alloc_amt  NUMERIC(18,4);
  v_total      NUMERIC(18,4) := 0;
  v_bill       RECORD;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('vpay:' || p_supplier_id::text));

  -- 驗 allocations 總和 = amount
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
  LOOP
    v_total := v_total + (v_alloc->>'allocated_amount')::numeric;
  END LOOP;
  IF v_total <> p_amount THEN
    RAISE EXCEPTION 'allocations sum (%) does not match payment amount (%)', v_total, p_amount;
  END IF;

  INSERT INTO vendor_payments (tenant_id, payment_no, supplier_id, amount, method,
                               paid_at, status, created_by, updated_by)
  VALUES (p_tenant_id, p_payment_no, p_supplier_id, p_amount, p_method,
          p_paid_at, 'completed', p_operator, p_operator)
  RETURNING id INTO v_pay_id;

  -- 分配
  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
  LOOP
    v_bill_id := (v_alloc->>'bill_id')::bigint;
    v_alloc_amt := (v_alloc->>'allocated_amount')::numeric;

    SELECT * INTO v_bill FROM vendor_bills
     WHERE id = v_bill_id AND tenant_id = p_tenant_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'bill % not found', v_bill_id;
    END IF;
    IF v_bill.paid_amount + v_alloc_amt > v_bill.amount THEN
      RAISE EXCEPTION 'over-allocation on bill %: paid=%, alloc=%, total=%',
        v_bill_id, v_bill.paid_amount, v_alloc_amt, v_bill.amount;
    END IF;

    INSERT INTO vendor_payment_allocations (tenant_id, payment_id, bill_id, allocated_amount)
    VALUES (p_tenant_id, v_pay_id, v_bill_id, v_alloc_amt);

    UPDATE vendor_bills
       SET paid_amount = paid_amount + v_alloc_amt,
           status = CASE WHEN paid_amount + v_alloc_amt = amount THEN 'paid' ELSE 'partially_paid' END,
           updated_by = p_operator
     WHERE id = v_bill_id;
  END LOOP;

  RETURN v_pay_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 員工申請費用
CREATE OR REPLACE FUNCTION rpc_add_expense(
  p_tenant_id    UUID,
  p_expense_no   TEXT,
  p_applicant    UUID,
  p_store_id     BIGINT,
  p_category_id  BIGINT,
  p_amount       NUMERIC,
  p_expense_date DATE,
  p_description  TEXT,
  p_receipt_url  TEXT
) RETURNS BIGINT AS $$
DECLARE
  v_id        BIGINT;
  v_threshold NUMERIC(18,4);
  v_status    TEXT;
BEGIN
  SELECT approval_threshold INTO v_threshold
    FROM expense_categories WHERE id = p_category_id;

  v_status := CASE
                WHEN v_threshold IS NULL OR p_amount < v_threshold THEN 'approved'
                ELSE 'pending'
              END;

  INSERT INTO expenses (tenant_id, expense_no, applicant_id, store_id, category_id,
                        amount, expense_date, description, receipt_photo_url,
                        approval_status, approved_at, approved_by,
                        created_by, updated_by)
  VALUES (p_tenant_id, p_expense_no, p_applicant, p_store_id, p_category_id,
          p_amount, p_expense_date, p_description, p_receipt_url,
          v_status,
          CASE WHEN v_status = 'approved' THEN NOW() END,
          CASE WHEN v_status = 'approved' THEN p_applicant END,
          p_applicant, p_applicant)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 審核通過
CREATE OR REPLACE FUNCTION rpc_approve_expense(
  p_expense_id BIGINT,
  p_note       TEXT,
  p_operator   UUID
) RETURNS VOID AS $$
DECLARE
  v_applicant UUID;
BEGIN
  SELECT applicant_id INTO v_applicant FROM expenses
   WHERE id = p_expense_id AND approval_status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense % not found or not pending', p_expense_id;
  END IF;

  IF v_applicant = p_operator THEN
    RAISE EXCEPTION 'cannot approve own expense';
  END IF;

  UPDATE expenses
     SET approval_status = 'approved',
         approved_by = p_operator,
         approved_at = NOW(),
         rejection_reason = NULL,
         updated_by = p_operator
   WHERE id = p_expense_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 審核退回
CREATE OR REPLACE FUNCTION rpc_reject_expense(
  p_expense_id BIGINT,
  p_reason     TEXT,
  p_operator   UUID
) RETURNS VOID AS $$
BEGIN
  IF p_reason IS NULL OR length(p_reason) = 0 THEN
    RAISE EXCEPTION 'rejection reason is required';
  END IF;

  UPDATE expenses
     SET approval_status = 'rejected',
         rejection_reason = p_reason,
         approved_by = p_operator,
         approved_at = NOW(),
         updated_by = p_operator
   WHERE id = p_expense_id AND approval_status = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense % not found or not pending', p_expense_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 零用金流水
CREATE OR REPLACE FUNCTION rpc_post_petty_cash_txn(
  p_tenant_id  UUID,
  p_account_id BIGINT,
  p_direction  TEXT,
  p_amount     NUMERIC,
  p_purpose    TEXT,
  p_category_id BIGINT,
  p_operator   UUID,
  p_notes      TEXT DEFAULT NULL,
  p_receipt_url TEXT DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO petty_cash_transactions (tenant_id, account_id, direction, amount,
                                       purpose, category_id, notes, receipt_photo_url,
                                       created_by)
  VALUES (p_tenant_id, p_account_id, p_direction, p_amount,
          p_purpose, p_category_id, p_notes, p_receipt_url, p_operator)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 重新定義 rpc_confirm_transfer_settlement (擴充: net>0 自動建 vendor_bill, Flag 8)
CREATE OR REPLACE FUNCTION rpc_confirm_transfer_settlement(
  p_settlement_id BIGINT,
  p_operator      UUID
) RETURNS JSONB AS $$
DECLARE
  v_s            RECORD;
  v_debtor_id    BIGINT;
  v_creditor_id  BIGINT;
  v_supplier_id  BIGINT;
  v_bill_id      BIGINT;
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

  IF v_s.net_amount > 0 THEN
    -- A 欠 B (a_to_b > b_to_a, 故 store_a 欠 store_b)
    v_debtor_id := v_s.store_a_id;
    v_creditor_id := v_s.store_b_id;
  ELSIF v_s.net_amount < 0 THEN
    -- B 欠 A
    v_debtor_id := v_s.store_b_id;
    v_creditor_id := v_s.store_a_id;
  END IF;

  IF v_s.net_amount <> 0 THEN
    SELECT supplier_id INTO v_supplier_id FROM stores WHERE id = v_creditor_id;
    IF v_supplier_id IS NULL THEN
      RAISE EXCEPTION 'creditor store % has no supplier_id mapping', v_creditor_id;
    END IF;

    INSERT INTO vendor_bills (tenant_id, bill_no, supplier_id, source_type, source_id,
                              bill_date, due_date, amount, status, notes,
                              created_by, updated_by)
    VALUES (v_s.tenant_id,
            'SETTLE-' || p_settlement_id,
            v_supplier_id, 'transfer_settlement', p_settlement_id,
            CURRENT_DATE, CURRENT_DATE + INTERVAL '30 days',
            ABS(v_s.net_amount), 'pending',
            'auto-generated from transfer_settlement #' || p_settlement_id,
            p_operator, p_operator)
    RETURNING id INTO v_bill_id;

    UPDATE transfer_settlements
       SET generated_vendor_bill_id = v_bill_id, updated_by = p_operator
     WHERE id = p_settlement_id;
  END IF;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'net_amount', v_s.net_amount,
    'vendor_bill_id', v_bill_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 9. RLS
-- ============================================================

ALTER TABLE vendor_bills                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_bill_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_payments              ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_payment_allocations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE petty_cash_accounts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE petty_cash_transactions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_categories           ENABLE ROW LEVEL SECURITY;

CREATE POLICY vb_admin_all ON vendor_bills
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );
CREATE POLICY vb_store_read ON vendor_bills
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND supplier_id = (SELECT supplier_id FROM stores WHERE id = (auth.jwt() ->> 'store_id')::bigint)
  );

CREATE POLICY vbi_admin_all ON vendor_bill_items
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );

CREATE POLICY vp_admin_all ON vendor_payments
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );

CREATE POLICY vpa_admin_all ON vendor_payment_allocations
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );

CREATE POLICY pca_admin_all ON petty_cash_accounts
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );
CREATE POLICY pca_store_own ON petty_cash_accounts
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND store_id = (auth.jwt() ->> 'store_id')::bigint
  );

CREATE POLICY pct_admin_all ON petty_cash_transactions
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );
CREATE POLICY pct_store_access ON petty_cash_transactions
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND account_id IN (SELECT id FROM petty_cash_accounts
                        WHERE store_id = (auth.jwt() ->> 'store_id')::bigint)
  );

CREATE POLICY exp_applicant ON expenses
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND applicant_id = (auth.jwt() ->> 'sub')::uuid
  );
CREATE POLICY exp_admin_all ON expenses
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager','hq_accountant')
  );

CREATE POLICY ec_read_all ON expense_categories
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
CREATE POLICY ec_admin_write ON expense_categories
  FOR ALL USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (auth.jwt() ->> 'role') IN ('owner','admin','hq_manager')
  );

-- ============================================================
-- 10. SEED expense_categories (placeholder tenant_id 須由 admin 後續 update)
-- ============================================================

-- 預留：實際 seed 須在租戶建立後手動執行 (依 tenant_id)
-- 樣板:
-- INSERT INTO expense_categories (tenant_id, code, name, default_pay_method) VALUES
--   ('<tenant_id>', 'TRANSPORT',  '交通',     'either'),
--   ('<tenant_id>', 'STATIONERY', '文具',     'petty_cash'),
--   ('<tenant_id>', 'MEAL',       '餐飲',     'petty_cash'),
--   ('<tenant_id>', 'COMMS',      '通訊',     'company_account'),
--   ('<tenant_id>', 'UTILITY',    '水電',     'company_account'),
--   ('<tenant_id>', 'MISC',       '雜支',     'either'),
--   ('<tenant_id>', 'REPAIR',     '修繕',     'company_account'),
--   ('<tenant_id>', 'PURCHASE_MISC', '採購雜項', 'either');
