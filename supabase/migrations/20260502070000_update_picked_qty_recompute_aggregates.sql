-- rpc_update_picked_qty：每次更新 picked_qty 後，重算 picking_waves 上的
-- cached aggregates（item_count / store_count / total_qty），確保 list 顯示
-- 與 modal 內的數字同步。

CREATE OR REPLACE FUNCTION rpc_update_picked_qty(
  p_wave_item_id BIGINT,
  p_new_qty      NUMERIC,
  p_operator     UUID,
  p_note         TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_tenant_id   UUID;
  v_wave_id     BIGINT;
  v_wave_status TEXT;
  v_old_qty     NUMERIC(18,3);
BEGIN
  SELECT pwi.tenant_id, pwi.wave_id, pw.status, pwi.picked_qty
    INTO v_tenant_id, v_wave_id, v_wave_status, v_old_qty
    FROM picking_wave_items pwi
    JOIN picking_waves pw ON pw.id = pwi.wave_id
   WHERE pwi.id = p_wave_item_id
   FOR UPDATE OF pwi, pw;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'picking_wave_item % not found', p_wave_item_id;
  END IF;

  IF v_wave_status IN ('shipped', 'cancelled') THEN
    RAISE EXCEPTION 'wave % is in status %, cannot update picked_qty', v_wave_id, v_wave_status;
  END IF;

  UPDATE picking_wave_items
     SET picked_qty = p_new_qty,
         updated_by = p_operator
   WHERE id = p_wave_item_id;

  INSERT INTO picking_wave_audit_log (
    tenant_id, wave_id, wave_item_id, action, before_value, after_value, note, created_by
  ) VALUES (
    v_tenant_id, v_wave_id, p_wave_item_id, 'picked_qty_changed',
    jsonb_build_object('picked_qty', v_old_qty),
    jsonb_build_object('picked_qty', p_new_qty),
    p_note, p_operator
  );

  -- 重算 cached aggregates，total_qty 以 picked_qty 為準（撿到的實量）
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
       WHERE wave_id = v_wave_id
    ) agg
   WHERE pw.id = v_wave_id;

  IF v_wave_status = 'draft' THEN
    UPDATE picking_waves SET status = 'picking', updated_by = p_operator WHERE id = v_wave_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
