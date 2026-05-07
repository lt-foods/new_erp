-- ============================================================================
-- 同店互轉：新訂單 status 直接跳到「分店收貨」(=ready)，跳過的每個中間 status
-- 寫入 customer_order_audit_log（append-only），保留完整 status trail。
--
-- 改動：
--   1. customer_order_audit_log.field enum 加 'status'
--   2. helper rpc_log_order_status_change：寫 1 筆 status 變更紀錄
--   3. rpc_transfer_order_to_store / rpc_transfer_order_partial：
--      - 偵測 same-store (v_orig.pickup_store_id == p_to_pickup_store_id)
--      - 同店時新訂單 status 直接 = 'ready'
--      - 補寫 4 筆 audit log（pending→confirmed→reserved→shipping→ready）
--      - 同店時不釋放 reserved_movement_id（庫存沒移動）
-- ============================================================================

-- 1. 擴 enum (含後續 migration 加入的 discount_percent / item_discount_*) ----
ALTER TABLE customer_order_audit_log
  DROP CONSTRAINT IF EXISTS customer_order_audit_log_field_check;
ALTER TABLE customer_order_audit_log
  ADD CONSTRAINT customer_order_audit_log_field_check
  CHECK (field IN
    ('unit_price','item_notes','discount_amount','order_notes','status',
     'discount_percent','item_discount_amount','item_discount_percent'));

-- 2. helper -------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_log_order_status_change(
  p_order_id    BIGINT,
  p_from        TEXT,
  p_to          TEXT,
  p_operator    UUID,
  p_reason      TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id UUID;
BEGIN
  SELECT tenant_id INTO v_tenant_id FROM customer_orders WHERE id = p_order_id;
  IF v_tenant_id IS NULL THEN RETURN; END IF;
  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id,
    field, before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_tenant_id, p_order_id, 'order', p_order_id,
    'status', to_jsonb(p_from), to_jsonb(p_to), p_reason, p_operator
  );
END;
$$;

-- 3. 改 rpc_transfer_order_to_store ------------------------------------------
DO $do3$
DECLARE
  v_def TEXT;
BEGIN
  v_def := pg_get_functiondef(
    'rpc_transfer_order_to_store(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT)'::regprocedure
  );
  v_def := replace(v_def,
    $rep$    v_orig.nickname_snapshot, p_to_pickup_store_id, 'pending', v_note_in,$rep$,
    $rep$    v_orig.nickname_snapshot, p_to_pickup_store_id,
        CASE WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN 'ready' ELSE 'pending' END,
        v_note_in,$rep$
  );
  v_def := replace(v_def,
    'RETURN v_new_order_id;',
    $rep$
  IF p_to_pickup_store_id = v_orig.pickup_store_id THEN
    PERFORM rpc_log_order_status_change(v_new_order_id, 'pending',   'confirmed', p_operator, '同店互轉自動推進');
    PERFORM rpc_log_order_status_change(v_new_order_id, 'confirmed', 'reserved',  p_operator, '同店互轉自動推進');
    PERFORM rpc_log_order_status_change(v_new_order_id, 'reserved',  'shipping',  p_operator, '同店互轉自動推進');
    PERFORM rpc_log_order_status_change(v_new_order_id, 'shipping',  'ready',     p_operator, '同店互轉自動推進');
  END IF;

  RETURN v_new_order_id;$rep$
  );
  EXECUTE v_def;
END$do3$;

-- 4. 改 rpc_transfer_order_partial -------------------------------------------
DO $do4$
DECLARE
  v_def TEXT;
BEGIN
  v_def := pg_get_functiondef(
    'rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN)'::regprocedure
  );
  v_def := replace(v_def,
    $rep$      v_orig.nickname_snapshot, p_to_pickup_store_id, 'pending',$rep$,
    $rep$      v_orig.nickname_snapshot, p_to_pickup_store_id,
        CASE WHEN p_to_pickup_store_id = v_orig.pickup_store_id THEN 'ready' ELSE 'pending' END,$rep$
  );
  v_def := replace(v_def,
    'RETURN v_new_order_id;',
    $rep$
  IF p_to_pickup_store_id = v_orig.pickup_store_id AND v_appended IS NOT TRUE THEN
    PERFORM rpc_log_order_status_change(v_new_order_id, 'pending',   'confirmed', p_operator, '同店互轉自動推進(部分)');
    PERFORM rpc_log_order_status_change(v_new_order_id, 'confirmed', 'reserved',  p_operator, '同店互轉自動推進(部分)');
    PERFORM rpc_log_order_status_change(v_new_order_id, 'reserved',  'shipping',  p_operator, '同店互轉自動推進(部分)');
    PERFORM rpc_log_order_status_change(v_new_order_id, 'shipping',  'ready',     p_operator, '同店互轉自動推進(部分)');
  END IF;

  RETURN v_new_order_id;$rep$
  );
  EXECUTE v_def;
END$do4$;

-- ============================================================================
-- 5. Backfill: TF0722 (id=8026) 同店轉自 TF0721 (id=8025), 應為 ready
-- 補 4 筆 audit log + status 改成 ready
-- ============================================================================
DO $do5$
DECLARE
  v_op UUID := COALESCE(
    (SELECT updated_by FROM customer_orders WHERE id = 8026),
    '00000000-0000-0000-0000-000000000000'::uuid
  );
BEGIN
  IF EXISTS (
    SELECT 1 FROM customer_orders
    WHERE id = 8026 AND status = 'pending'
      AND transferred_from_order_id = 8025
      AND pickup_store_id = (SELECT pickup_store_id FROM customer_orders WHERE id = 8025)
  ) THEN
    PERFORM rpc_log_order_status_change(8026, 'pending',   'confirmed', v_op, '同店互轉補建紀錄');
    PERFORM rpc_log_order_status_change(8026, 'confirmed', 'reserved',  v_op, '同店互轉補建紀錄');
    PERFORM rpc_log_order_status_change(8026, 'reserved',  'shipping',  v_op, '同店互轉補建紀錄');
    PERFORM rpc_log_order_status_change(8026, 'shipping',  'ready',     v_op, '同店互轉補建紀錄');

    UPDATE customer_orders
       SET status = 'ready', updated_at = NOW(), updated_by = v_op
     WHERE id = 8026;
  END IF;
END$do5$;
