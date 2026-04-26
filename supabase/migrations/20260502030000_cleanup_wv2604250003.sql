-- 一次性清理 WV2604250003：空殼 shipped wave（auto-create 沒寫 items 留下的）
-- item_count=0、store_count=0、無對應 transfer，直接刪除即可。

DO $$
DECLARE
  v_id BIGINT;
BEGIN
  SELECT id INTO v_id FROM picking_waves WHERE wave_code = 'WV2604250003';
  IF v_id IS NULL THEN
    RAISE NOTICE 'WV2604250003 already deleted, skipping';
    RETURN;
  END IF;

  ALTER TABLE picking_wave_audit_log DISABLE TRIGGER trg_no_mut_wave_audit;
  BEGIN
    DELETE FROM picking_wave_audit_log WHERE wave_id = v_id;
    DELETE FROM picking_wave_items     WHERE wave_id = v_id;
    DELETE FROM picking_waves          WHERE id      = v_id;
  EXCEPTION WHEN OTHERS THEN
    ALTER TABLE picking_wave_audit_log ENABLE TRIGGER trg_no_mut_wave_audit;
    RAISE;
  END;
  ALTER TABLE picking_wave_audit_log ENABLE TRIGGER trg_no_mut_wave_audit;
END $$;
