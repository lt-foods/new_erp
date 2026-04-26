-- rpc_update_wave_date：修改撿貨單配送日
-- 派貨後（shipped）或已取消的不允許改。

CREATE OR REPLACE FUNCTION rpc_update_wave_date(
  p_wave_id  BIGINT,
  p_new_date DATE,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_status   TEXT;
  v_old_date DATE;
  v_tenant   UUID;
BEGIN
  SELECT tenant_id, status, wave_date INTO v_tenant, v_status, v_old_date
    FROM picking_waves WHERE id = p_wave_id FOR UPDATE;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  IF v_status IN ('shipped', 'cancelled') THEN
    RAISE EXCEPTION 'wave % is in status %, cannot change wave_date', p_wave_id, v_status;
  END IF;

  IF v_old_date = p_new_date THEN
    RETURN;
  END IF;

  UPDATE picking_waves
     SET wave_date = p_new_date,
         updated_at = NOW(),
         updated_by = p_operator
   WHERE id = p_wave_id;

  INSERT INTO picking_wave_audit_log (
    tenant_id, wave_id, action, before_value, after_value, created_by
  ) VALUES (
    v_tenant, p_wave_id, 'wave_status_changed',
    jsonb_build_object('wave_date', v_old_date),
    jsonb_build_object('wave_date', p_new_date),
    p_operator
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_update_wave_date(BIGINT, DATE, UUID) TO authenticated;
