-- rpc_set_picked_qty：以 (wave_id, sku_id, store_id) 為 key 設定 picked_qty
-- 沒有對應 row 就 INSERT (qty=0, picked_qty=N)，有就 UPDATE picked_qty。
-- 用途：撿貨修正時新增「原本沒分配到」的店家，或調整既有 cell 的數量。

CREATE OR REPLACE FUNCTION rpc_set_picked_qty(
  p_wave_id   BIGINT,
  p_sku_id    BIGINT,
  p_store_id  BIGINT,
  p_picked_qty NUMERIC,
  p_operator  UUID,
  p_note      TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_tenant_id   UUID;
  v_wave_status TEXT;
  v_existing_id BIGINT;
  v_old_picked  NUMERIC(18,3);
BEGIN
  SELECT tenant_id, status INTO v_tenant_id, v_wave_status
    FROM picking_waves
   WHERE id = p_wave_id
     FOR UPDATE;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  IF v_wave_status IN ('shipped', 'cancelled') THEN
    RAISE EXCEPTION 'wave % is in status %, cannot set picked_qty', p_wave_id, v_wave_status;
  END IF;

  SELECT id, picked_qty INTO v_existing_id, v_old_picked
    FROM picking_wave_items
   WHERE wave_id = p_wave_id
     AND sku_id = p_sku_id
     AND store_id = p_store_id
     FOR UPDATE;

  IF v_existing_id IS NULL THEN
    -- 新增 cell：應發 0、實分 = 輸入值
    IF p_picked_qty <= 0 THEN
      RETURN; -- 0 或負數不寫入 (qty CHECK > 0 會擋)
    END IF;
    INSERT INTO picking_wave_items (
      tenant_id, wave_id, sku_id, store_id, qty, picked_qty, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_wave_id, p_sku_id, p_store_id, p_picked_qty, p_picked_qty, p_operator, p_operator
    );
    INSERT INTO picking_wave_audit_log (
      tenant_id, wave_id, wave_item_id, action, after_value, note, created_by
    ) VALUES (
      v_tenant_id, p_wave_id,
      (SELECT id FROM picking_wave_items WHERE wave_id = p_wave_id AND sku_id = p_sku_id AND store_id = p_store_id),
      'item_added',
      jsonb_build_object('sku_id', p_sku_id, 'store_id', p_store_id, 'picked_qty', p_picked_qty),
      p_note, p_operator
    );
  ELSE
    UPDATE picking_wave_items
       SET picked_qty = p_picked_qty,
           updated_by = p_operator
     WHERE id = v_existing_id;
    INSERT INTO picking_wave_audit_log (
      tenant_id, wave_id, wave_item_id, action, before_value, after_value, note, created_by
    ) VALUES (
      v_tenant_id, p_wave_id, v_existing_id, 'picked_qty_changed',
      jsonb_build_object('picked_qty', v_old_picked),
      jsonb_build_object('picked_qty', p_picked_qty),
      p_note, p_operator
    );
  END IF;

  -- 重算 cached aggregates
  UPDATE picking_waves pw
     SET item_count  = agg.item_count,
         store_count = agg.store_count,
         total_qty   = agg.total_qty,
         updated_by  = p_operator
    FROM (
      SELECT COUNT(*)                                       AS item_count,
             COUNT(DISTINCT store_id)                       AS store_count,
             COALESCE(SUM(COALESCE(picked_qty, qty)), 0)    AS total_qty
        FROM picking_wave_items
       WHERE wave_id = p_wave_id
    ) agg
   WHERE pw.id = p_wave_id;

  IF v_wave_status = 'draft' THEN
    UPDATE picking_waves SET status = 'picking', updated_by = p_operator WHERE id = p_wave_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_set_picked_qty(BIGINT, BIGINT, BIGINT, NUMERIC, UUID, TEXT) TO authenticated;
