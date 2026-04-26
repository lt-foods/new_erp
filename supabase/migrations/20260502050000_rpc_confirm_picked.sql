-- rpc_confirm_picked：撿貨完成
-- 把「UPDATE status='picked' + 寫 picking_wave_audit_log」包裝成 RPC，
-- 避免前端只 UPDATE 而漏記 audit log。

CREATE OR REPLACE FUNCTION public.rpc_confirm_picked(
  p_wave_id  BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id UUID;
  v_old_status TEXT;
BEGIN
  SELECT tenant_id, status INTO v_tenant_id, v_old_status
    FROM picking_waves
   WHERE id = p_wave_id
     FOR UPDATE;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  IF v_old_status = 'picked' THEN
    RETURN; -- 已是 picked，idempotent
  END IF;

  IF v_old_status NOT IN ('draft', 'picking') THEN
    RAISE EXCEPTION 'wave % cannot be confirmed picked from status %', p_wave_id, v_old_status;
  END IF;

  UPDATE picking_waves
     SET status     = 'picked',
         updated_at = NOW(),
         updated_by = p_operator
   WHERE id = p_wave_id;

  INSERT INTO picking_wave_audit_log (
    tenant_id, wave_id, action, before_value, after_value, created_by
  ) VALUES (
    v_tenant_id,
    p_wave_id,
    'wave_status_changed',
    jsonb_build_object('status', v_old_status),
    jsonb_build_object('status', 'picked'),
    p_operator
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_confirm_picked(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_confirm_picked(BIGINT, UUID) IS
  '撿貨完成：把 wave status 從 draft/picking 改 picked，並寫 audit log。';
