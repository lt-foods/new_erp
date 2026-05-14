-- ============================================================
-- 2026-06-14: 補種 MISC 虛擬商品 / MISC-01 SKU
--
-- 原本 20260515000000 的 seed DO block 在某些 tenant 漏跑（migration apply 順序 + RLS
-- 在 DO block 內的行為造成 SELECT DISTINCT 拿不到 tenant_id）。
-- 結果 rpc_create_free_transfer 報「MISC virtual SKU not found for tenant」。
--
-- 這條 migration 直接對每個既有 tenant 重跑同樣的 seed（idempotent）。
-- ============================================================

DO $$
DECLARE
  t        RECORD;
  v_pid    BIGINT;
  cnt_p    INT := 0;
  cnt_s    INT := 0;
BEGIN
  -- 同時涵蓋有 product 的 tenant 和有 location 的 tenant（避免 RLS 影響）
  FOR t IN
    SELECT DISTINCT tenant_id FROM (
      SELECT tenant_id FROM products
      UNION
      SELECT tenant_id FROM locations
    ) x
    WHERE tenant_id IS NOT NULL
  LOOP
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
      UPDATE products SET is_virtual = TRUE
       WHERE id = v_pid AND is_virtual = FALSE;
    END IF;

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
      INSERT INTO sku_packs (sku_id, unit, qty_in_base, is_default_sale)
      SELECT id, '件', 1, TRUE FROM skus
       WHERE tenant_id = t.tenant_id AND product_id = v_pid AND sku_code = 'MISC-01';
      cnt_s := cnt_s + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Reseed MISC: % products, % skus added', cnt_p, cnt_s;
END $$;
