-- 訂單派貨中：customer_orders.status 加 'shipping'，並在 wave 派貨完成時自動 update
--
-- 邏輯：當 picking_wave 進到 status='shipped' 時，找出該 wave 涉及的所有訂單
-- （依 store_id + close_date 對應），把 status 從 pending/confirmed/reserved
-- 改成 shipping。

-- 1. 放寬 CHECK 加入 shipping
ALTER TABLE customer_orders DROP CONSTRAINT customer_orders_status_check;
ALTER TABLE customer_orders ADD CONSTRAINT customer_orders_status_check
  CHECK (status IN ('pending','confirmed','reserved','shipping','ready',
                    'partially_ready','partially_completed','completed',
                    'expired','cancelled'));

-- 2. RPC：標示某 wave 涉及的訂單為派貨中
CREATE OR REPLACE FUNCTION rpc_mark_orders_shipping_for_wave(
  p_wave_id  BIGINT,
  p_operator UUID
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tenant_id UUID;
  v_wave_date DATE;
  v_updated   INTEGER;
BEGIN
  SELECT tenant_id, wave_date INTO v_tenant_id, v_wave_date
    FROM picking_waves WHERE id = p_wave_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'wave % not found', p_wave_id;
  END IF;

  WITH affected AS (
    UPDATE customer_orders co
       SET status = 'shipping',
           updated_at = NOW(),
           updated_by = p_operator
      FROM group_buy_campaigns gbc
     WHERE co.tenant_id = v_tenant_id
       AND co.campaign_id = gbc.id
       AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = v_wave_date
       AND co.pickup_store_id IN (
         SELECT DISTINCT store_id
           FROM picking_wave_items
          WHERE wave_id = p_wave_id
            AND picked_qty > 0
       )
       AND co.status IN ('pending','confirmed','reserved')
    RETURNING co.id
  )
  SELECT COUNT(*) INTO v_updated FROM affected;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_mark_orders_shipping_for_wave(BIGINT, UUID) TO authenticated;

-- 3. 修 generate_transfer_from_wave：派貨完成時呼叫上述 RPC
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

  -- 標記涉及訂單為派貨中
  PERFORM rpc_mark_orders_shipping_for_wave(p_wave_id, p_operator);

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

-- 4. 一次性：修 wave 12（已派但訂單還沒被標 shipping）
DO $$
DECLARE
  v_op UUID;
BEGIN
  SELECT created_by INTO v_op FROM picking_waves WHERE id = 12;
  IF v_op IS NOT NULL THEN
    PERFORM rpc_mark_orders_shipping_for_wave(12, v_op);
  END IF;
END $$;
