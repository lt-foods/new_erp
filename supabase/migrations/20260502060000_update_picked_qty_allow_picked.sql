-- rpc_update_picked_qty：picked 狀態也允許改數量（沒派貨前都該可修正）
-- 原版只允許 draft/picking，導致使用者按完「✅ 確認修正完成」後反而不能再修正。
-- 真正應該擋的是 shipped/cancelled。

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

  -- draft → picking（picked 不變）
  IF v_wave_status = 'draft' THEN
    UPDATE picking_waves SET status = 'picking', updated_by = p_operator WHERE id = v_wave_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
