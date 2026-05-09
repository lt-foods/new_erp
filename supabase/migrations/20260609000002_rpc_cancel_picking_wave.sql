-- ============================================================
-- rpc_cancel_picking_wave — 軟取消撿貨單(status='cancelled' + 留 audit log)
--
-- 跟 rpc_delete_picking_wave 的差異:
--   - delete:整張 wave + items + audit_log 全砍,沒軌跡
--   - cancel:status 改 'cancelled' 留紀錄;v_picking_demand_by_po
--            的 wave_qty CTE 已經 WHERE pw.status <> 'cancelled' 過濾,
--            所以「可分配」會自動回血,效果跟 delete 一樣
--
-- 守衛:
--   - shipped 不可取消(已派貨,要走 reverse 流程)
--   - 已 cancelled 不可重複取消
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_cancel_picking_wave(
  p_wave_id  BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id   UUID;
  v_old_status  TEXT;
  v_wave_code   TEXT;
BEGIN
  -- 鎖 wave row 取狀態
  SELECT tenant_id, status, wave_code
    INTO v_tenant_id, v_old_status, v_wave_code
    FROM picking_waves
   WHERE id = p_wave_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到撿貨單 #%', p_wave_id;
  END IF;

  IF v_old_status = 'cancelled' THEN
    RAISE EXCEPTION '撿貨單 % 已經是取消狀態', v_wave_code;
  END IF;

  IF v_old_status = 'shipped' THEN
    RAISE EXCEPTION '撿貨單 % 已派貨,不可取消(請走 reverse 流程)', v_wave_code;
  END IF;

  -- 改狀態
  UPDATE picking_waves
     SET status = 'cancelled',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_wave_id;

  -- 寫 audit log
  INSERT INTO picking_wave_audit_log (
    tenant_id, wave_id, action, before_value, after_value, note, created_by
  ) VALUES (
    v_tenant_id,
    p_wave_id,
    'wave_cancelled',
    jsonb_build_object('status', v_old_status),
    jsonb_build_object('status', 'cancelled'),
    p_reason,
    p_operator
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_cancel_picking_wave(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_cancel_picking_wave IS
  '軟取消撿貨單:status=cancelled、留 audit log;不刪 items。可分配量自動回血(view 已過濾 cancelled)。';
