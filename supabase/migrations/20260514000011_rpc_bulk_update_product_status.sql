-- ============================================================
-- 2026-05-14: rpc_bulk_update_product_status
-- ------------------------------------------------------------
-- 批次切換商品狀態（上架 / 下架 / 草稿 / 停產）。
-- 走 SECURITY DEFINER：admin JWT 沒 role claim 也可改；同 tenant 才允許；
-- 每筆都進 product_audit_log（action = 'status_change'）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_bulk_update_product_status(
  p_ids    BIGINT[],
  p_status TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_user     UUID := auth.uid();
  v_id       BIGINT;
  v_before   JSONB;
  v_after    JSONB;
  v_count    INTEGER := 0;
BEGIN
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;
  IF p_status NOT IN ('draft','active','inactive','discontinued') THEN
    RAISE EXCEPTION 'invalid product status: %', p_status;
  END IF;

  FOREACH v_id IN ARRAY p_ids LOOP
    SELECT to_jsonb(p) INTO v_before FROM products p
      WHERE p.id = v_id AND p.tenant_id = v_tenant;
    IF v_before IS NULL THEN
      -- 跨 tenant 或不存在 → 跳過（不 raise，讓批次能完成其他項）
      CONTINUE;
    END IF;
    IF v_before->>'status' = p_status THEN
      -- 已是目標狀態 → 不寫 audit、不更新
      CONTINUE;
    END IF;

    UPDATE products
       SET status = p_status,
           updated_by = v_user,
           updated_at = NOW()
     WHERE id = v_id AND tenant_id = v_tenant;

    SELECT to_jsonb(p) INTO v_after FROM products p WHERE p.id = v_id;
    PERFORM public._log_product_audit(
      v_tenant, 'product', v_id, 'status_change',
      v_before, v_after, p_reason
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_bulk_update_product_status(BIGINT[], TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_update_product_status(BIGINT[], TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_bulk_update_product_status(BIGINT[], TEXT, TEXT) IS
  '批次切換 products.status；同 tenant 才生效；每筆寫 product_audit_log status_change。回傳實際變更筆數。';
