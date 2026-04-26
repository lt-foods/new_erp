-- 修 generate_transfer_from_wave：
-- 1. transfer 建立時 status='shipped' 而非 'confirmed'（讓 v_pr_progress 認得到）
-- 2. 加 rpc_outbound 從總倉扣庫存（之前漏掉，會造成庫存帳錯）
-- 3. 順手修補：existing 'confirmed' 狀態的 hq_to_store transfer 改成 shipped（已派但卡在錯狀態）
--    — 這部分庫存扣減**不會補做**（之前 RPC 沒做），需要手動 reconcile

CREATE OR REPLACE FUNCTION generate_transfer_from_wave(
  p_wave_id  BIGINT,
  p_hq_location_id BIGINT,
  p_operator UUID
) RETURNS JSONB AS $$
DECLARE
  v_tenant_id            UUID;
  v_wave_status          TEXT;
  v_expected_store_count INTEGER;
  v_expected_item_count  INTEGER;
  v_actual_xfer_count    INTEGER;
  v_actual_item_count    INTEGER;
  v_store_rec            RECORD;
  v_dest_location_id     BIGINT;
  v_new_xfer_id          BIGINT;
  v_inserted_items       INTEGER;
  v_xfer_ids             BIGINT[] := ARRAY[]::BIGINT[];
  v_pwi                  RECORD;
  v_out_mov_id           BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(p_wave_id);

  SELECT tenant_id, status INTO v_tenant_id, v_wave_status
    FROM picking_waves WHERE id = p_wave_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;
  IF v_wave_status <> 'picked' THEN
    RAISE EXCEPTION 'wave % is in status %, expected picked', p_wave_id, v_wave_status;
  END IF;

  SELECT COUNT(DISTINCT store_id), COUNT(*)
    INTO v_expected_store_count, v_expected_item_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0;

  IF v_expected_item_count = 0 THEN
    RAISE EXCEPTION 'wave % has no picked items, cannot generate transfer', p_wave_id;
  END IF;

  FOR v_store_rec IN
    SELECT DISTINCT pwi.store_id, s.location_id
      FROM picking_wave_items pwi
      JOIN stores s ON s.id = pwi.store_id
     WHERE pwi.wave_id = p_wave_id AND pwi.picked_qty > 0
  LOOP
    v_dest_location_id := v_store_rec.location_id;
    IF v_dest_location_id IS NULL THEN
      RAISE EXCEPTION 'store % has no location_id mapped', v_store_rec.store_id;
    END IF;

    INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                           status, transfer_type, requested_by, shipped_by, shipped_at,
                           created_by, updated_by)
    VALUES (v_tenant_id,
            'WAVE-' || p_wave_id || '-S' || v_store_rec.store_id,
            p_hq_location_id, v_dest_location_id,
            'shipped', 'hq_to_store', p_operator, p_operator, NOW(),
            p_operator, p_operator)
    RETURNING id INTO v_new_xfer_id;

    -- 建 transfer_items + 從總倉 outbound 扣庫存
    FOR v_pwi IN
      SELECT id, sku_id, picked_qty
        FROM picking_wave_items
       WHERE wave_id = p_wave_id
         AND store_id = v_store_rec.store_id
         AND picked_qty > 0
    LOOP
      v_out_mov_id := rpc_outbound(
        p_tenant_id       => v_tenant_id,
        p_location_id     => p_hq_location_id,
        p_sku_id          => v_pwi.sku_id,
        p_quantity        => v_pwi.picked_qty,
        p_movement_type   => 'transfer_out',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => v_new_xfer_id,
        p_operator        => p_operator,
        p_allow_negative  => FALSE
      );

      INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                                  out_movement_id, created_by, updated_by)
      VALUES (v_new_xfer_id, v_pwi.sku_id, v_pwi.picked_qty, v_pwi.picked_qty,
              v_out_mov_id, p_operator, p_operator);
    END LOOP;

    GET DIAGNOSTICS v_inserted_items = ROW_COUNT;

    UPDATE picking_wave_items
       SET generated_transfer_id = v_new_xfer_id, updated_by = p_operator
     WHERE wave_id = p_wave_id AND store_id = v_store_rec.store_id AND picked_qty > 0;

    INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, created_by)
    VALUES (v_tenant_id, p_wave_id, 'so_generated',
            jsonb_build_object('transfer_id', v_new_xfer_id,
                               'store_id', v_store_rec.store_id,
                               'items_count', v_inserted_items),
            p_operator);

    v_xfer_ids := v_xfer_ids || v_new_xfer_id;
  END LOOP;

  UPDATE picking_waves SET status = 'shipped', updated_by = p_operator WHERE id = p_wave_id;

  SELECT COUNT(DISTINCT generated_transfer_id)
    INTO v_actual_xfer_count
    FROM picking_wave_items
   WHERE wave_id = p_wave_id AND picked_qty > 0 AND generated_transfer_id IS NOT NULL;

  IF v_actual_xfer_count <> v_expected_store_count THEN
    RAISE EXCEPTION 'transfer count mismatch: expected %, got %', v_expected_store_count, v_actual_xfer_count;
  END IF;

  RETURN jsonb_build_object(
    'wave_id', p_wave_id,
    'transfer_ids', to_jsonb(v_xfer_ids),
    'store_count', v_expected_store_count,
    'item_count', v_expected_item_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 修補既有 confirmed 狀態的 hq_to_store transfer（已派貨但卡狀態不對）
-- 注意：這只改 status，不補 outbound（庫存帳本身已是錯的，需另外 reconcile）
UPDATE transfers
   SET status = 'shipped',
       shipped_at = COALESCE(shipped_at, updated_at)
 WHERE status = 'confirmed'
   AND transfer_type = 'hq_to_store';
