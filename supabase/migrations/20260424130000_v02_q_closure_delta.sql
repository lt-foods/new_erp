-- ============================================================
-- v0.2 Q-closure delta
-- Session: 2026-04-23
-- 合併 8 段 delta：各 v0.2 addendum 的 Open Questions + Q17 per-store 發票模式
-- 參照：docs/decisions/2026-04-23-系統立場-混合型.md
-- ============================================================

-- ------------------------------------------------------------
-- 1. 訂單 Q1 / Q4 / 庫存 Q2: customer_orders 欄位 (+ 樂樂 CSV 對應)
-- ------------------------------------------------------------
ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS rollover_opt_out BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS called_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS external_order_no TEXT,
  ADD COLUMN IF NOT EXISTS external_source   TEXT
      CHECK (external_source IS NULL OR external_source IN ('lele','pinduoduo','1688','line_community','manual')),
  ADD COLUMN IF NOT EXISTS ordered_at        TIMESTAMPTZ;

COMMENT ON COLUMN customer_orders.rollover_opt_out IS '(庫存 Q2 2026-04-23) 顧客選擇缺貨不要 rollover、直接退款';
COMMENT ON COLUMN customer_orders.called_at         IS '(訂單 Q4 2026-04-23) 已電聯時間戳；NULL = 尚未電聯';
COMMENT ON COLUMN customer_orders.external_order_no IS '(訂單 Q1 2026-04-23) 樂樂/PDD 等外部通路的訂單代號';
COMMENT ON COLUMN customer_orders.external_source   IS '(訂單 Q1 2026-04-23) 外部通路來源';
COMMENT ON COLUMN customer_orders.ordered_at        IS '(訂單 Q1 2026-04-23) 外部通路下單時間（區隔於 created_at 的系統寫入時間）';

CREATE UNIQUE INDEX IF NOT EXISTS idx_corders_external
  ON customer_orders (tenant_id, external_source, external_order_no)
  WHERE external_order_no IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_corders_called_at
  ON customer_orders (pickup_store_id, called_at)
  WHERE called_at IS NOT NULL;

-- ------------------------------------------------------------
-- 2. 訂單 Q1: members / skus 欄位 (樂樂 CSV 對應)
-- ------------------------------------------------------------
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS external_id            TEXT,
  ADD COLUMN IF NOT EXISTS takeout_store_name_hint TEXT;

COMMENT ON COLUMN members.external_id IS '(訂單 Q1 2026-04-23) 樂樂/PDD 等外部會員編號';
COMMENT ON COLUMN members.takeout_store_name_hint IS
  '(訂單 Q1 2026-04-23) 外部通路帶回的取貨店名稱（raw，待 Apps Script 模糊比對成 store_id）';

ALTER TABLE skus
  ADD COLUMN IF NOT EXISTS external_code TEXT;

COMMENT ON COLUMN skus.external_code IS '(訂單 Q1 2026-04-23) 樂樂「品號」；與 SKU 內部 code 分離';

-- ------------------------------------------------------------
-- 3. 訂單 Q1: 樂樂 CSV staging 表
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lele_order_imports (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID NOT NULL,
  batch_id       UUID NOT NULL DEFAULT gen_random_uuid(),
  source_file    TEXT,
  row_no         INTEGER NOT NULL,
  raw            JSONB NOT NULL,
  parsed         JSONB,
  status         TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','parsed','applied','error','skipped')),
  error_message  TEXT,
  applied_at     TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, batch_id, row_no)
);

CREATE INDEX IF NOT EXISTS idx_lele_imports_batch  ON lele_order_imports (tenant_id, batch_id, status);
CREATE INDEX IF NOT EXISTS idx_lele_imports_status ON lele_order_imports (tenant_id, status);

COMMENT ON TABLE lele_order_imports IS
  '(訂單 Q1 2026-04-23) 樂樂訂單 CSV 的 staging 層 (append-only)；RPC rpc_ingest_lele_csv 寫入、rpc_apply_lele_batch 處理到 customer_orders';

-- ------------------------------------------------------------
-- 4. AP Q6: vendor_payments HQ clearing house 三欄
-- ------------------------------------------------------------
ALTER TABLE vendor_payments
  ADD COLUMN IF NOT EXISTS cleared_via_hq     BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS hq_clearing_leg    TEXT
      CHECK (hq_clearing_leg IS NULL OR hq_clearing_leg IN ('store_to_hq','hq_to_store')),
  ADD COLUMN IF NOT EXISTS linked_payment_id  BIGINT REFERENCES vendor_payments(id);

COMMENT ON COLUMN vendor_payments.cleared_via_hq    IS '(AP Q6 2026-04-23) 加盟店間對付款走總部 clearing';
COMMENT ON COLUMN vendor_payments.hq_clearing_leg   IS '(AP Q6 2026-04-23) clearing 雙腿哪一腿';
COMMENT ON COLUMN vendor_payments.linked_payment_id IS '(AP Q6 2026-04-23) 另一腿 payment 的對照';

CREATE INDEX IF NOT EXISTS idx_vpay_hq_clearing
  ON vendor_payments (tenant_id, cleared_via_hq, hq_clearing_leg)
  WHERE cleared_via_hq = TRUE;

-- ------------------------------------------------------------
-- 5. AP Q2: expense_categories per-store 預算
-- ------------------------------------------------------------
ALTER TABLE expense_categories
  ADD COLUMN IF NOT EXISTS store_id             BIGINT REFERENCES stores(id),
  ADD COLUMN IF NOT EXISTS monthly_budget_cents BIGINT
      CHECK (monthly_budget_cents IS NULL OR monthly_budget_cents > 0);

COMMENT ON COLUMN expense_categories.store_id             IS '(AP Q2 2026-04-23) NULL = 總部/共用；有值 = 該店專屬預算';
COMMENT ON COLUMN expense_categories.monthly_budget_cents IS '(AP Q2 2026-04-23) NULL = 不啟用預算；有值 = 警示但不擋';

-- 原本 UNIQUE(tenant_id, code) 在 per-store 下需放寬：
--  (a) 總部/共用（store_id IS NULL）：同 tenant + code 唯一
--  (b) 店專屬（store_id IS NOT NULL）：同 tenant + store + code 唯一
-- 用兩個 partial unique index 比 COALESCE(store_id, 0) workaround 乾淨（無特殊值 0 假設）
ALTER TABLE expense_categories DROP CONSTRAINT IF EXISTS expense_categories_tenant_id_code_key;
CREATE UNIQUE INDEX IF NOT EXISTS expense_categories_tenant_code_hq_uq
  ON expense_categories (tenant_id, code) WHERE store_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS expense_categories_tenant_store_code_uq
  ON expense_categories (tenant_id, store_id, code) WHERE store_id IS NOT NULL;

-- ------------------------------------------------------------
-- 6. AP Q5: supplier 從 trigger auto-create 改為 on-demand helper
-- ------------------------------------------------------------
-- 刪掉 2026-04-23 之前的 BEFORE INSERT trigger
DROP TRIGGER  IF EXISTS trg_store_as_supplier ON stores;
DROP FUNCTION IF EXISTS sync_store_as_supplier();

CREATE OR REPLACE FUNCTION ensure_store_supplier(p_store_id BIGINT)
RETURNS BIGINT AS $$
DECLARE
  v_supplier_id BIGINT;
  v_store       stores%ROWTYPE;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM stores WHERE id = p_store_id;
  IF v_supplier_id IS NOT NULL THEN
    RETURN v_supplier_id;
  END IF;

  SELECT * INTO v_store FROM stores WHERE id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ensure_store_supplier: store_id % not found', p_store_id;
  END IF;

  INSERT INTO suppliers (tenant_id, code, name, is_active, created_by, updated_by)
  VALUES (v_store.tenant_id, 'STORE-' || v_store.code, v_store.name, TRUE,
          v_store.created_by, COALESCE(v_store.updated_by, v_store.created_by))
  RETURNING id INTO v_supplier_id;

  UPDATE stores SET supplier_id = v_supplier_id, updated_at = NOW()
   WHERE id = p_store_id;

  RETURN v_supplier_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ensure_store_supplier(BIGINT) IS
  '(AP Q5 2026-04-23) On-demand 建立加盟店的 supplier row；第一次 transfer settlement 或 clearing 呼叫';

-- ------------------------------------------------------------
-- 7. Q17: stores per-store 發票模式 (ezPay 老客戶擴容 2026-04-23 decision)
-- ------------------------------------------------------------
ALTER TABLE stores
  ADD COLUMN IF NOT EXISTS tax_id                           TEXT,
  ADD COLUMN IF NOT EXISTS invoice_mode                     TEXT NOT NULL DEFAULT 'none'
      CHECK (invoice_mode IN ('enabled','manual','none')),
  ADD COLUMN IF NOT EXISTS ezpay_sub_merchant_id            TEXT,
  ADD COLUMN IF NOT EXISTS monthly_revenue_threshold_cents  BIGINT NOT NULL DEFAULT 20000000;

COMMENT ON COLUMN stores.tax_id IS '(Q17 2026-04-23) 加盟店的統一編號（每家獨立）';
COMMENT ON COLUMN stores.invoice_mode IS
  '(Q17 2026-04-23) 發票模式：enabled=電子發票(ezPay 子商店) / manual=紙本發票機 / none=合法免開(<20萬)';
COMMENT ON COLUMN stores.ezpay_sub_merchant_id IS
  '(Q17 2026-04-23) ezPay 子商店 ID；on-demand 開通後回填';
COMMENT ON COLUMN stores.monthly_revenue_threshold_cents IS
  '(Q17 2026-04-23) 強制開立發票的月營業額門檻（預設 NT$200,000 = 20,000,000 cents）；超過時通知模組發提醒';

CREATE INDEX IF NOT EXISTS idx_stores_invoice_mode
  ON stores (tenant_id, invoice_mode)
  WHERE is_active;

-- ------------------------------------------------------------
-- 8. 商品 Q14 bonus: products.lele_meta (樂樂通路匯出 JSON)
-- ------------------------------------------------------------
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS lele_meta JSONB;

COMMENT ON COLUMN products.lele_meta IS
  '(商品 Q14 2026-04-23) 樂樂通路專屬旗標 (allow_vip_purchase / is_instock_only / max_per_person 等)；避免污染 products 主檔';

-- ------------------------------------------------------------
-- 9. RLS: 新表 lele_order_imports 啟用 row-level security
-- ------------------------------------------------------------
ALTER TABLE lele_order_imports ENABLE ROW LEVEL SECURITY;

-- 對齊既有 convention（auth.jwt claim + custom_access_token_hook 注入）
-- 不用 current_setting('app.tenant_id')、那需要 SET LOCAL、PostgREST 不會自動設
CREATE POLICY p_lele_imports_tenant_read
  ON lele_order_imports
  FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

CREATE POLICY p_lele_imports_tenant_write
  ON lele_order_imports
  FOR INSERT
  WITH CHECK (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

-- ============================================================
-- 變更歷史
-- ============================================================
-- 2026-04-23 初版：合併 8 段 delta
--   §1 訂單 Q1/Q4 + 庫存 Q2 customer_orders 欄位
--   §2 訂單 Q1 members / skus 樂樂對應欄位
--   §3 訂單 Q1 lele_order_imports staging 表
--   §4 AP Q6 vendor_payments HQ clearing 三欄
--   §5 AP Q2 expense_categories per-store 預算
--   §6 AP Q5 supplier on-demand helper (ensure_store_supplier)
--   §7 Q17 stores per-store 發票模式 (ezPay 擴展架構)
--   §8 商品 Q14 products.lele_meta
--   §9 RLS 啟用新表
