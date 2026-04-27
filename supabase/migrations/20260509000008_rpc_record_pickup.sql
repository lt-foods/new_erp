-- ============================================================
-- Phase 6 — rpc_record_pickup：顧客取貨
--
-- 寫 order_pickup_events (append-only) + 改 customer_order_items.status='picked_up'
-- + 重算 customer_orders.status (completed / partially_completed)
--
-- v1 範疇（簡化）：
--   - 全 item 取貨（每個 item 整筆取走、不支援 partial qty）；要 partial 先 cancel 再分單
--   - 不寫 stock_movements（既有 reservation/allocate 流程未完整、之後再補）
--   - allowed source status: pending / reserved / ready (active items)
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_record_pickup(
  p_order_id  BIGINT,
  p_item_ids  BIGINT[],
  p_operator  UUID,
  p_notes     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_item_id          BIGINT;
  v_picked_count     INT := 0;
  v_active_remaining INT;
  v_new_status       TEXT;
  v_event_type       TEXT;
  v_event_id         BIGINT;
  v_now              TIMESTAMPTZ := NOW();
BEGIN
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_item_ids is empty';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  IF v_order.status IN ('completed','expired','cancelled','transferred_out') THEN
    RAISE EXCEPTION 'order % status=% cannot pickup', p_order_id, v_order.status;
  END IF;

  -- 驗每個 item 屬本訂單、且 status 可取
  FOR v_item_id IN SELECT unnest(p_item_ids) LOOP
    PERFORM 1 FROM customer_order_items
      WHERE id = v_item_id
        AND order_id = p_order_id
        AND status IN ('pending','reserved','ready')
      FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'item % not in order % or status not pickable', v_item_id, p_order_id;
    END IF;
  END LOOP;

  -- 標記 picked_up
  UPDATE customer_order_items
     SET status = 'picked_up',
         updated_by = p_operator,
         updated_at = v_now
   WHERE id = ANY(p_item_ids);
  GET DIAGNOSTICS v_picked_count = ROW_COUNT;

  -- 重算 order status
  SELECT COUNT(*) INTO v_active_remaining
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status IN ('pending','reserved','ready');

  IF v_active_remaining = 0 THEN
    v_new_status := 'completed';
    v_event_type := 'picked_up';
  ELSE
    v_new_status := 'partially_completed';
    v_event_type := 'partial_pickup';
  END IF;

  UPDATE customer_orders
     SET status = v_new_status,
         updated_by = p_operator,
         updated_at = v_now
   WHERE id = p_order_id;

  -- 寫 event (append-only)
  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, v_event_type,
    to_jsonb(p_item_ids), p_notes, p_operator
  ) RETURNING id INTO v_event_id;

  RETURN jsonb_build_object(
    'event_id', v_event_id,
    'event_type', v_event_type,
    'picked_count', v_picked_count,
    'active_remaining', v_active_remaining,
    'new_order_status', v_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_record_pickup(BIGINT, BIGINT[], UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION rpc_record_pickup IS
  'Phase 6：顧客取貨；items 改 picked_up、order 改 completed/partially_completed、寫 order_pickup_events';
