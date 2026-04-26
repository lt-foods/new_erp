-- 一次性：完整刪除 wave 12 (WV260425184716) — 派貨後的全鏈路逆轉
--
-- 影響面：
-- 1. transfers (hq_to_store, transfer_no='WAVE-12-S*') + transfer_items
-- 2. stock_movements 對應的 transfer_out（補一筆 reversal 把總倉庫存補回）
-- 3. customer_orders 4 張：3 cancelled (auto-cancelled by WV260425184716) + 1 shipping
--    → 統一還原為 'confirmed'（無 status history 表，只能取最常見的 pre-state）
--    cancelled 訂單同時清掉自動帶上的 notes 標記
-- 4. picking_wave_audit_log + picking_wave_items + picking_waves
--
-- 注意：stock_movements 是 append-only，逆轉是「再 INSERT 一筆 reversal」
--       不是 DELETE，原 outbound 紀錄保留以維持稽核軌跡。

DO $$
DECLARE
  v_wave_id    BIGINT := 12;
  v_wave_code  TEXT;
  v_wave_date  DATE;
  v_tenant_id  UUID;
  v_op         UUID;
  v_xfer       RECORD;
  v_ti         RECORD;
  v_orig       RECORD;
  v_rev_id     BIGINT;
  v_n_xfer     INT := 0;
  v_n_rev      INT := 0;
  v_n_orders   INT := 0;
BEGIN
  SELECT tenant_id, wave_code, wave_date, created_by
    INTO v_tenant_id, v_wave_code, v_wave_date, v_op
    FROM picking_waves WHERE id = v_wave_id;

  IF v_tenant_id IS NULL THEN
    RAISE NOTICE 'wave % not found, skip', v_wave_id;
    RETURN;
  END IF;

  -- ============================================================
  -- 1. 還原訂單（在刪 picking_wave_items 之前做，因為 join 用得到）
  -- ============================================================

  -- 1a. shipping → confirmed
  UPDATE customer_orders co
     SET status     = 'confirmed',
         updated_at = NOW(),
         updated_by = v_op
    FROM group_buy_campaigns gbc
   WHERE co.tenant_id = v_tenant_id
     AND co.campaign_id = gbc.id
     AND DATE(gbc.end_at AT TIME ZONE 'Asia/Taipei') = v_wave_date
     AND co.pickup_store_id IN (
       SELECT DISTINCT store_id FROM picking_wave_items WHERE wave_id = v_wave_id
     )
     AND co.status = 'shipping';
  GET DIAGNOSTICS v_n_orders = ROW_COUNT;

  -- 1b. cancelled (auto-cancelled by this wave) → confirmed + 清掉 notes 標記
  WITH affected AS (
    UPDATE customer_orders
       SET status = 'confirmed',
           notes  = NULLIF(
                      regexp_replace(
                        COALESCE(notes, ''),
                        E'(?:^|\\n)\\[auto-cancelled by ' || v_wave_code || '：沒撿到貨\\]',
                        '', 'g'
                      ),
                      ''
                    ),
           updated_at = NOW(),
           updated_by = v_op
     WHERE tenant_id = v_tenant_id
       AND status = 'cancelled'
       AND notes LIKE '%[auto-cancelled by ' || v_wave_code || '%'
    RETURNING id
  )
  SELECT v_n_orders + COUNT(*) INTO v_n_orders FROM affected;

  -- ============================================================
  -- 2. 逆轉 transfers + transfer_items + stock_movements
  -- ============================================================
  FOR v_xfer IN
    SELECT id
      FROM transfers
     WHERE tenant_id = v_tenant_id
       AND transfer_type = 'hq_to_store'
       AND transfer_no LIKE 'WAVE-' || v_wave_id || '-S%'
  LOOP
    FOR v_ti IN
      SELECT id, sku_id, qty_shipped, out_movement_id
        FROM transfer_items
       WHERE transfer_id = v_xfer.id
    LOOP
      IF v_ti.out_movement_id IS NOT NULL THEN
        -- 取原 outbound row
        SELECT * INTO v_orig FROM stock_movements WHERE id = v_ti.out_movement_id;

        IF FOUND THEN
          -- 補一筆反向 movement：原 quantity 是負的，這裡放正的（-v_orig.quantity）
          INSERT INTO stock_movements
            (tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
             source_doc_type, source_doc_id, reverses, reason, operator_id)
          VALUES
            (v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
             -v_orig.quantity, v_orig.unit_cost, 'reversal',
             'transfer', v_xfer.id, v_orig.id,
             'cleanup wave ' || v_wave_code, v_op)
          RETURNING id INTO v_rev_id;

          UPDATE stock_movements SET reversed_by = v_rev_id WHERE id = v_orig.id;
          v_n_rev := v_n_rev + 1;
        END IF;
      END IF;
    END LOOP;

    -- 解 FK：picking_wave_items.generated_transfer_id 指著這張 transfer
    UPDATE picking_wave_items
       SET generated_transfer_id = NULL
     WHERE wave_id = v_wave_id AND generated_transfer_id = v_xfer.id;

    DELETE FROM transfer_items WHERE transfer_id = v_xfer.id;
    DELETE FROM transfers WHERE id = v_xfer.id;
    v_n_xfer := v_n_xfer + 1;
  END LOOP;

  -- ============================================================
  -- 3. 刪 wave + items + audit log
  -- ============================================================
  ALTER TABLE picking_wave_audit_log DISABLE TRIGGER trg_no_mut_wave_audit;
  BEGIN
    DELETE FROM picking_wave_audit_log WHERE wave_id = v_wave_id;
    DELETE FROM picking_wave_items     WHERE wave_id = v_wave_id;
    DELETE FROM picking_waves          WHERE id      = v_wave_id;
  EXCEPTION WHEN OTHERS THEN
    ALTER TABLE picking_wave_audit_log ENABLE TRIGGER trg_no_mut_wave_audit;
    RAISE;
  END;
  ALTER TABLE picking_wave_audit_log ENABLE TRIGGER trg_no_mut_wave_audit;

  RAISE NOTICE 'wave % (%) cleaned up: % transfers reversed, % stock_movement reversals, % orders restored',
    v_wave_id, v_wave_code, v_n_xfer, v_n_rev, v_n_orders;
END $$;
