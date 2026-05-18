-- ============================================================
-- 2026-06-18: rpc_delete_product — 商品刪除（軟刪除）
-- ------------------------------------------------------------
-- products / skus 有 forbid_sku_delete trigger（BEFORE DELETE 一律 raise）
-- 且被 campaign_items / customer_order_items / prices / barcodes 等多表 FK
-- 參照，實體刪除不可行。沿用 rpc_delete_sku 慣例 → 軟刪除：
--   product + 其所有 sku 設 status='discontinued'。
-- SKU active→非active 會觸發 _cleanup_sku_from_draft_campaigns
-- （自動把該 SKU 從 draft 開團移除）；open/closed 開團與已下訂歷史不動。
-- 走 SECURITY DEFINER：admin JWT 無 role claim 也可改；限同 tenant。
--
-- 守門（2026-06-18 使用者要求）：
--   1. 商品「上架中」(status='active') 不可刪除 → 請先下架。
--   2. 商品只要有任何顧客訂單（customer_order_items 參照其 sku）不可刪除。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_product(
  p_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_status TEXT;
  v_before JSONB;
  v_after  JSONB;
BEGIN
  -- 上鎖（FOR UPDATE 只接純欄位，避免與 to_jsonb 併用的相容性疑慮）
  SELECT status INTO v_status
    FROM products
   WHERE id = p_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'product % not found', p_id;
  END IF;

  -- 守門 1：上架中不可刪
  IF v_status = 'active' THEN
    RAISE EXCEPTION 'product % is active, cannot delete', p_id;
  END IF;

  -- 守門 2：有任何顧客訂單不可刪
  IF EXISTS (
    SELECT 1
      FROM customer_order_items coi
      JOIN skus s ON s.id = coi.sku_id
     WHERE s.product_id = p_id
       AND s.tenant_id  = v_tenant
  ) THEN
    RAISE EXCEPTION 'product % has orders, cannot delete', p_id;
  END IF;

  SELECT to_jsonb(p) INTO v_before FROM products p WHERE p.id = p_id;

  UPDATE products
     SET status     = 'discontinued',
         updated_by = v_user,
         updated_at = NOW()
   WHERE id = p_id AND tenant_id = v_tenant;

  -- 連動規格軟刪除：觸發 _cleanup_sku_from_draft_campaigns + touch_updated_at
  UPDATE skus
     SET status     = 'discontinued',
         updated_by = v_user
   WHERE product_id = p_id
     AND tenant_id  = v_tenant
     AND status    <> 'discontinued';

  SELECT to_jsonb(p) INTO v_after FROM products p WHERE p.id = p_id;
  PERFORM public._log_product_audit(
    v_tenant, 'product', p_id, 'delete',
    v_before, v_after, '商品刪除（軟刪除：停產，連動規格停產）'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_product(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_product(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_product(BIGINT) IS
  '商品軟刪除：限非上架中且無任何顧客訂單；product + 其所有 sku 設 status=discontinued；同 tenant；寫 product_audit_log action=delete。';
