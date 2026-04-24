-- ============================================================
-- SKU 規格編號自動產生：{product_code}-{NN}
-- 例：F00001-01、F00001-02
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_next_sku_code(
  p_product_id BIGINT
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_product_code TEXT;
  v_next         INT;
BEGIN
  SELECT product_code INTO v_product_code
    FROM products
   WHERE id = p_product_id AND tenant_id = v_tenant;
  IF v_product_code IS NULL THEN
    RAISE EXCEPTION 'product % not in tenant', p_product_id;
  END IF;

  SELECT COALESCE(MAX((SUBSTRING(sku_code FROM '^' || v_product_code || '-(\d+)$'))::INT), 0) + 1
    INTO v_next
    FROM skus
   WHERE tenant_id = v_tenant
     AND product_id = p_product_id
     AND sku_code ~ ('^' || v_product_code || '-\d+$');

  RETURN v_product_code || '-' || lpad(v_next::text, 2, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_next_sku_code TO authenticated;

COMMENT ON FUNCTION public.rpc_next_sku_code IS
  '依商品產生下一個 SKU 編號：{product_code}-{NN}';
