-- rpc_confirm_picked 在轉 status='picked' 時，若仍有 picked_qty IS NULL 的行
-- 自動 backfill picked_qty := qty（語意：「沒手動改 = 全照計畫撿到」）。
--
-- 修補的 bug：使用者只看了 modal、沒動數字直接按「確認修正完成」，
-- DB 裡 picked_qty 仍是 NULL；接著「派貨出倉」時 generate_transfer_from_wave
-- 掃 picked_qty > 0 抓到 0 行，raise 'wave X has no picked items'。
--
-- 順便修補存量資料：把已是 picked / shipped / cancelled 狀態的 wave 中
-- 仍 NULL 的 picked_qty 補成 qty（給 wave 17 之類已卡住的單一條救援路）。

CREATE OR REPLACE FUNCTION public.rpc_confirm_picked(
  p_wave_id  BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id  UUID;
  v_old_status TEXT;
  v_backfilled INTEGER;
BEGIN
  SELECT tenant_id, status INTO v_tenant_id, v_old_status
    FROM picking_waves
   WHERE id = p_wave_id
     FOR UPDATE;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  IF v_old_status = 'picked' THEN
    -- idempotent，但仍把 NULL 的 picked_qty backfill 一次（救援已卡住的單）
    UPDATE picking_wave_items
       SET picked_qty = qty,
           updated_by = p_operator
     WHERE wave_id = p_wave_id
       AND picked_qty IS NULL;
    RETURN;
  END IF;

  IF v_old_status NOT IN ('draft', 'picking') THEN
    RAISE EXCEPTION 'wave % cannot be confirmed picked from status %', p_wave_id, v_old_status;
  END IF;

  UPDATE picking_wave_items
     SET picked_qty = qty,
         updated_by = p_operator
   WHERE wave_id = p_wave_id
     AND picked_qty IS NULL;
  GET DIAGNOSTICS v_backfilled = ROW_COUNT;

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
    jsonb_build_object('status', 'picked', 'picked_qty_backfilled', v_backfilled),
    p_operator
  );
END;
$$;

-- 一次性救援：所有非 draft / picking 狀態的 wave 中還是 NULL 的 picked_qty
-- 補成 qty（含 wave 17 等卡住的單）。
UPDATE picking_wave_items pwi
   SET picked_qty = qty
  FROM picking_waves pw
 WHERE pwi.wave_id = pw.id
   AND pwi.picked_qty IS NULL
   AND pw.status IN ('picked', 'shipped', 'cancelled');
