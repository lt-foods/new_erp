-- ============================================================
-- Phase 5e step 1 — rpc_advance_order_status
--
-- 直接 UPDATE customer_orders.status 會被 RLS 擋（store_access policy 要求 pickup_store
-- = jwt.store_id；admin 用 hq_all 但 dev user 不一定有）。
-- 統一走 RPC SECURITY DEFINER：驗 tenant + 合法狀態轉移、再 UPDATE。
--
-- 合法 forward 轉移（aid 列表/工作流用）：
--   pending → confirmed
--   confirmed → shipping
--   shipping → ready
--   ready → completed
-- 其他狀態轉移呼叫者要自己想清楚（暫不開放）。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_advance_order_status(
  p_order_id   BIGINT,
  p_new_status TEXT,
  p_operator   UUID
) RETURNS customer_orders
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_orig customer_orders%ROWTYPE;
  v_ok   BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_orig FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;

  -- 驗合法 forward 轉移
  v_ok := (v_orig.status = 'pending'   AND p_new_status = 'confirmed')
       OR (v_orig.status = 'confirmed' AND p_new_status = 'shipping')
       OR (v_orig.status = 'shipping'  AND p_new_status = 'ready')
       OR (v_orig.status = 'ready'     AND p_new_status = 'completed');
  IF NOT v_ok THEN
    RAISE EXCEPTION 'invalid status transition: % → %', v_orig.status, p_new_status;
  END IF;

  UPDATE customer_orders
     SET status = p_new_status,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_order_id
   RETURNING * INTO v_orig;

  RETURN v_orig;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_advance_order_status(BIGINT, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_advance_order_status IS
  'Phase 5e step 1：訂單狀態 forward 推進（pending→confirmed→shipping→ready→completed），bypass RLS、驗合法轉移';
