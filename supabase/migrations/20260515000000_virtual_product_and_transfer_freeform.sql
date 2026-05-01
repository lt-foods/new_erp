-- ============================================================
-- Case 1 (free transfer) schema：虛擬商品 + transfer_items 擴欄
--
-- 變更：
--   1. products.is_virtual BOOLEAN — 標記虛擬商品（用於沒 catalog 的店間轉貨）
--   2. transfer_items.description / estimated_amount — 虛擬轉貨用
--   3. CHECK：有 description 必有 estimated_amount（防忘記填估價）
--   4. Seed：每 tenant 一筆 MISC product + MISC-01 SKU（is_virtual=TRUE / status=active）
--
-- TEST: docs/TEST-store-self-service.md §1.1, §1.2
-- Rollback:
--   ALTER TABLE products DROP COLUMN is_virtual;
--   ALTER TABLE transfer_items DROP COLUMN description, DROP COLUMN estimated_amount;
--   DELETE FROM skus WHERE sku_code = 'MISC-01';
--   DELETE FROM products WHERE product_code = 'MISC';
-- ============================================================

-- ----------------------------------------------------------------
-- 1. products.is_virtual
-- ----------------------------------------------------------------
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS is_virtual BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN products.is_virtual IS
  '虛擬商品：系統管、不進銷售流程、用於 transfer freeform 轉貨（沒 catalog 的東西用 description 描述）';

CREATE INDEX IF NOT EXISTS idx_products_virtual
  ON products (tenant_id) WHERE is_virtual = TRUE;

-- ----------------------------------------------------------------
-- 2. transfer_items 擴欄
-- ----------------------------------------------------------------
ALTER TABLE transfer_items
  ADD COLUMN IF NOT EXISTS description       TEXT,
  ADD COLUMN IF NOT EXISTS estimated_amount  NUMERIC(18,4);

COMMENT ON COLUMN transfer_items.description IS
  '虛擬轉貨：實際品名 / 規格描述（真實 SKU 留 NULL）';
COMMENT ON COLUMN transfer_items.estimated_amount IS
  '虛擬轉貨：估價（單筆總額；真實 SKU 留 NULL，金額由 unit_price * qty 算）';

-- description 與 estimated_amount 同生死
ALTER TABLE transfer_items
  ADD CONSTRAINT transfer_items_description_estimate_paired
    CHECK (
      (description IS NULL AND estimated_amount IS NULL)
      OR
      (description IS NOT NULL AND estimated_amount IS NOT NULL AND estimated_amount >= 0)
    );

-- ----------------------------------------------------------------
-- 3. Seed MISC virtual product + MISC-01 SKU per tenant
-- ----------------------------------------------------------------
DO $$
DECLARE
  t        RECORD;
  v_pid    BIGINT;
  cnt_p    INT := 0;
  cnt_s    INT := 0;
BEGIN
  FOR t IN
    SELECT DISTINCT tenant_id FROM products
  LOOP
    -- 找或建 MISC product
    SELECT id INTO v_pid
      FROM products
     WHERE tenant_id = t.tenant_id AND product_code = 'MISC';

    IF v_pid IS NULL THEN
      INSERT INTO products (
        tenant_id, product_code, name, short_name, status, is_virtual
      ) VALUES (
        t.tenant_id, 'MISC', '虛擬轉貨商品', '虛擬轉貨', 'active', TRUE
      ) RETURNING id INTO v_pid;
      cnt_p := cnt_p + 1;
    ELSE
      -- 已有但可能 is_virtual=FALSE，補上
      UPDATE products SET is_virtual = TRUE
       WHERE id = v_pid AND is_virtual = FALSE;
    END IF;

    -- 找或建 MISC-01 SKU
    IF NOT EXISTS (
      SELECT 1 FROM skus
       WHERE tenant_id = t.tenant_id AND product_id = v_pid AND sku_code = 'MISC-01'
    ) THEN
      INSERT INTO skus (
        tenant_id, product_id, sku_code, variant_name, spec, base_unit, tax_rate, status,
        product_name
      ) VALUES (
        t.tenant_id, v_pid, 'MISC-01', NULL, '{}'::jsonb, '件', 0.0500, 'active',
        '虛擬轉貨商品'
      );
      -- base sku_pack
      INSERT INTO sku_packs (sku_id, unit, qty_in_base, is_default_sale)
      SELECT id, '件', 1, TRUE FROM skus
       WHERE tenant_id = t.tenant_id AND product_id = v_pid AND sku_code = 'MISC-01';
      cnt_s := cnt_s + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Seeded MISC: % products, % skus across tenants', cnt_p, cnt_s;
END $$;
