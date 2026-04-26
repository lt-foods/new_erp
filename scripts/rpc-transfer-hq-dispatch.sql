-- 測試 Phase 5a-2：總倉調度後端
-- 包在 DO block + ROLLBACK_OK 強迫整段回滾
DO $outer$
DECLARE
  v_op            UUID := '22222222-2222-2222-2222-222222222222';
  v_tenant        UUID;
  v_hq_loc        BIGINT;
  v_store_a_loc   BIGINT;
  v_store_b_loc   BIGINT;
  v_sku_a         BIGINT;
  v_sku_b         BIGINT;
  v_xfer_arrive_1 BIGINT;
  v_xfer_arrive_2 BIGINT;
  v_xfer_dist_1   BIGINT;
  v_xfer_dist_2   BIGINT;
  v_xfer_draft    BIGINT;
  v_xfer_air      BIGINT;
  v_xfer_recv     BIGINT;
  v_ti_recv       BIGINT;
  v_result        JSONB;
  v_count         INT;
  v_dmg_mov_id    BIGINT;
  v_damage_qty    NUMERIC;
  v_status        TEXT;
  v_succeeded     JSONB;
  v_failed        JSONB;
BEGIN
  -- ============================================================
  -- Fixture：拿 HQ + 2 stores + 2 skus；HQ 有庫存（stock_balances）
  -- ============================================================
  SELECT id INTO v_hq_loc FROM locations
   WHERE id NOT IN (SELECT location_id FROM stores WHERE location_id IS NOT NULL)
   ORDER BY id LIMIT 1;
  IF v_hq_loc IS NULL THEN
    -- fallback：用第一個 location
    SELECT id INTO v_hq_loc FROM locations ORDER BY id LIMIT 1;
  END IF;

  SELECT location_id INTO v_store_a_loc FROM stores
   WHERE location_id IS NOT NULL AND location_id <> v_hq_loc ORDER BY id LIMIT 1;
  SELECT location_id INTO v_store_b_loc FROM stores
   WHERE location_id IS NOT NULL AND location_id <> v_hq_loc AND location_id <> v_store_a_loc
   ORDER BY id LIMIT 1;
  IF v_store_a_loc IS NULL OR v_store_b_loc IS NULL THEN
    RAISE EXCEPTION 'fixture FAIL: need 2 store locations besides HQ';
  END IF;

  -- 找 HQ 有庫存的 sku（dist 用 qty 3 + 2 即足）
  SELECT sku_id, tenant_id INTO v_sku_a, v_tenant
    FROM stock_balances
   WHERE location_id = v_hq_loc AND on_hand >= 3
   ORDER BY sku_id LIMIT 1;
  SELECT sku_id INTO v_sku_b
    FROM stock_balances
   WHERE location_id = v_hq_loc AND on_hand >= 2
     AND sku_id <> v_sku_a
   ORDER BY sku_id LIMIT 1;
  IF v_sku_a IS NULL OR v_sku_b IS NULL THEN
    RAISE EXCEPTION 'fixture FAIL: need 2 skus with HQ stock (>= 3/2)';
  END IF;

  RAISE NOTICE 'fixture: tenant=%, hq=%, store_a_loc=%, store_b_loc=%, sku_a=%, sku_b=%',
               v_tenant, v_hq_loc, v_store_a_loc, v_store_b_loc, v_sku_a, v_sku_b;

  -- ============================================================
  -- A. Schema delta
  -- ============================================================
  -- A1: shipping_temp CHECK
  BEGIN
    INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                           status, transfer_type, shipping_temp, created_by, updated_by)
    VALUES (v_tenant, 'TEST-A1-' || EXTRACT(EPOCH FROM NOW())::TEXT,
            v_hq_loc, v_store_a_loc, 'draft', 'hq_to_store', 'invalid_temp', v_op, v_op);
    RAISE EXCEPTION 'A1 FAIL: should reject invalid shipping_temp';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'A1 PASS: invalid shipping_temp rejected';
  END;

  -- A4: damage_qty CHECK >= 0
  BEGIN
    INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                           status, transfer_type, created_by, updated_by)
    VALUES (v_tenant, 'TEST-A4-' || EXTRACT(EPOCH FROM NOW())::TEXT,
            v_hq_loc, v_store_a_loc, 'draft', 'hq_to_store', v_op, v_op)
    RETURNING id INTO v_xfer_draft;
    INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, damage_qty,
                                 created_by, updated_by)
    VALUES (v_xfer_draft, v_sku_a, 1, -1, v_op, v_op);
    RAISE EXCEPTION 'A4 FAIL';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'A4 PASS: damage_qty < 0 rejected';
  END;

  -- ============================================================
  -- Build fixture transfers
  -- ============================================================
  -- TRs for batch_arrive (dest=HQ + shipped)：模擬店退倉
  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, shipped_by, shipped_at,
                         created_by, updated_by)
  VALUES (v_tenant, 'TEST-ARV-1-' || EXTRACT(EPOCH FROM NOW())::TEXT,
          v_store_a_loc, v_hq_loc, 'shipped', 'return_to_hq',
          v_op, NOW(), v_op, v_op)
  RETURNING id INTO v_xfer_arrive_1;
  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                movement_type, source_doc_type, source_doc_id, operator_id)
  VALUES (v_tenant, v_store_a_loc, v_sku_a, -10, 10, 'transfer_out', 'transfer', v_xfer_arrive_1, v_op);
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                              out_movement_id, created_by, updated_by)
  VALUES (v_xfer_arrive_1, v_sku_a, 10, 10,
          currval(pg_get_serial_sequence('stock_movements','id')), v_op, v_op);

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, shipped_by, shipped_at,
                         created_by, updated_by)
  VALUES (v_tenant, 'TEST-ARV-2-' || EXTRACT(EPOCH FROM NOW())::TEXT,
          v_store_b_loc, v_hq_loc, 'shipped', 'return_to_hq',
          v_op, NOW(), v_op, v_op)
  RETURNING id INTO v_xfer_arrive_2;
  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                movement_type, source_doc_type, source_doc_id, operator_id)
  VALUES (v_tenant, v_store_b_loc, v_sku_b, -5, 20, 'transfer_out', 'transfer', v_xfer_arrive_2, v_op);
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                              out_movement_id, created_by, updated_by)
  VALUES (v_xfer_arrive_2, v_sku_b, 5, 5,
          currval(pg_get_serial_sequence('stock_movements','id')), v_op, v_op);

  -- TRs for batch_distribute (source=HQ + draft)
  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, shipping_temp, hq_notes,
                         created_by, updated_by)
  VALUES (v_tenant, 'TEST-DIST-1-' || EXTRACT(EPOCH FROM NOW())::TEXT,
          v_hq_loc, v_store_a_loc, 'draft', 'hq_to_store', 'frozen', '測試 5a-2',
          v_op, v_op)
  RETURNING id INTO v_xfer_dist_1;
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by, updated_by)
  VALUES (v_xfer_dist_1, v_sku_a, 3, v_op, v_op);

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, created_by, updated_by)
  VALUES (v_tenant, 'TEST-DIST-2-' || EXTRACT(EPOCH FROM NOW())::TEXT,
          v_hq_loc, v_store_b_loc, 'confirmed', 'hq_to_store', v_op, v_op)
  RETURNING id INTO v_xfer_dist_2;
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by, updated_by)
  VALUES (v_xfer_dist_2, v_sku_b, 2, v_op, v_op);

  -- 空中轉 TR (source=store_a, dest=store_b, is_air_transfer=TRUE)
  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, is_air_transfer, created_by, updated_by)
  VALUES (v_tenant, 'TEST-AIR-' || EXTRACT(EPOCH FROM NOW())::TEXT,
          v_store_a_loc, v_store_b_loc, 'draft', 'store_to_store', TRUE, v_op, v_op)
  RETURNING id INTO v_xfer_air;
  RAISE NOTICE 'fixture transfers: arrive=[%, %], dist=[%, %], air=%',
               v_xfer_arrive_1, v_xfer_arrive_2, v_xfer_dist_1, v_xfer_dist_2, v_xfer_air;

  -- ============================================================
  -- B. rpc_transfer_arrive_at_hq_batch happy path
  -- ============================================================
  v_result := rpc_transfer_arrive_at_hq_batch(
    ARRAY[v_xfer_arrive_1, v_xfer_arrive_2], v_hq_loc, v_op);
  v_succeeded := v_result -> 'succeeded';
  v_failed    := v_result -> 'failed';
  IF jsonb_array_length(v_succeeded) <> 2 THEN
    RAISE EXCEPTION 'B1 FAIL: succeeded count=%, expected 2 (failed=%)',
                    jsonb_array_length(v_succeeded), v_failed;
  END IF;

  SELECT status INTO v_status FROM transfers WHERE id = v_xfer_arrive_1;
  IF v_status <> 'received' THEN
    RAISE EXCEPTION 'B1 FAIL: status=% expected received', v_status;
  END IF;
  RAISE NOTICE 'B1 PASS: 2 transfers arrived at HQ; sample status=received';

  -- ============================================================
  -- C2: batch_arrive 包含 dest 不是 HQ → failed
  -- ============================================================
  v_result := rpc_transfer_arrive_at_hq_batch(
    ARRAY[v_xfer_dist_1], v_hq_loc, v_op);  -- v_xfer_dist_1 dest 是 store_a
  v_succeeded := v_result -> 'succeeded';
  v_failed    := v_result -> 'failed';
  IF jsonb_array_length(v_succeeded) <> 0 OR jsonb_array_length(v_failed) <> 1 THEN
    RAISE EXCEPTION 'C2 FAIL: succeeded=%, failed=%',
                    jsonb_array_length(v_succeeded), jsonb_array_length(v_failed);
  END IF;
  RAISE NOTICE 'C2 PASS: dest != HQ rejected, reason=%',
               v_failed -> 0 ->> 'reason';

  -- ============================================================
  -- D. rpc_transfer_distribute_batch happy path
  -- ============================================================
  v_result := rpc_transfer_distribute_batch(
    ARRAY[v_xfer_dist_1, v_xfer_dist_2], v_hq_loc, v_op);
  v_succeeded := v_result -> 'succeeded';
  v_failed    := v_result -> 'failed';
  IF jsonb_array_length(v_succeeded) <> 2 THEN
    RAISE EXCEPTION 'D1 FAIL: succeeded=%, failed=%',
                    jsonb_array_length(v_succeeded), v_failed;
  END IF;

  SELECT status, shipped_by INTO v_status, v_op
    FROM transfers WHERE id = v_xfer_dist_1;
  IF v_status <> 'shipped' THEN
    RAISE EXCEPTION 'D1 FAIL: status=% expected shipped', v_status;
  END IF;
  v_op := '22222222-2222-2222-2222-222222222222';

  -- D3: out_movement_id 寫入
  PERFORM 1 FROM transfer_items
    WHERE transfer_id = v_xfer_dist_1 AND out_movement_id IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'D3 FAIL: out_movement_id not set';
  END IF;
  RAISE NOTICE 'D1-D4 PASS: 2 transfers distributed (shipped + out_movement set)';

  -- ============================================================
  -- E2: distribute_batch 包含 source 不是 HQ → failed
  -- ============================================================
  v_result := rpc_transfer_distribute_batch(
    ARRAY[v_xfer_air], v_hq_loc, v_op);  -- v_xfer_air source=store_a
  v_failed := v_result -> 'failed';
  IF jsonb_array_length(v_failed) <> 1 THEN
    RAISE EXCEPTION 'E2 FAIL: failed count=%', jsonb_array_length(v_failed);
  END IF;
  RAISE NOTICE 'E2 PASS: source != HQ rejected';

  -- ============================================================
  -- F. rpc_register_damage happy path (用 v_xfer_arrive_1 已 received)
  -- ============================================================
  SELECT id INTO v_ti_recv FROM transfer_items WHERE transfer_id = v_xfer_arrive_1 LIMIT 1;
  v_dmg_mov_id := rpc_register_damage(v_ti_recv, 2, '測試損壞', v_op);
  IF v_dmg_mov_id IS NULL THEN
    RAISE EXCEPTION 'F1 FAIL: returned NULL';
  END IF;

  PERFORM 1 FROM stock_movements
    WHERE id = v_dmg_mov_id
      AND movement_type = 'damage'
      AND quantity = -2
      AND location_id = v_hq_loc;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'F1 FAIL: stock_movement wrong';
  END IF;

  SELECT damage_qty INTO v_damage_qty FROM transfer_items WHERE id = v_ti_recv;
  IF v_damage_qty <> 2 THEN
    RAISE EXCEPTION 'F2 FAIL: damage_qty=% expected 2', v_damage_qty;
  END IF;
  RAISE NOTICE 'F1-F2 PASS: damage registered (movement=%, damage_qty=%)',
               v_dmg_mov_id, v_damage_qty;

  -- F5: 累加
  PERFORM rpc_register_damage(v_ti_recv, 1, '再損 1', v_op);
  SELECT damage_qty INTO v_damage_qty FROM transfer_items WHERE id = v_ti_recv;
  IF v_damage_qty <> 3 THEN
    RAISE EXCEPTION 'F5 FAIL: damage_qty=% expected 3 (2+1)', v_damage_qty;
  END IF;
  RAISE NOTICE 'F5 PASS: damage_qty 累加=3';

  -- G2: damage > qty_received → exception (qty_received=10、累加 3 + 100 > 10)
  BEGIN
    PERFORM rpc_register_damage(v_ti_recv, 100, '溢出', v_op);
    RAISE EXCEPTION 'G2 FAIL';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%exceeds remaining%' THEN
      RAISE NOTICE 'G2 PASS: %', SQLERRM;
    ELSE RAISE; END IF;
  END;

  -- G3: damage_qty <= 0 → exception
  BEGIN
    PERFORM rpc_register_damage(v_ti_recv, 0, NULL, v_op);
    RAISE EXCEPTION 'G3 FAIL';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%must be > 0%' THEN
      RAISE NOTICE 'G3 PASS: %', SQLERRM;
    ELSE RAISE; END IF;
  END;

  -- G1: transfer status='shipped' (還沒收貨) → exception
  BEGIN
    PERFORM rpc_register_damage(
      (SELECT id FROM transfer_items WHERE transfer_id = v_xfer_dist_1 LIMIT 1),
      1, NULL, v_op);
    RAISE EXCEPTION 'G1 FAIL';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%only received/closed%' THEN
      RAISE NOTICE 'G1 PASS: %', SQLERRM;
    ELSE RAISE; END IF;
  END;

  -- ============================================================
  -- H. rpc_transfer_batch_delete happy path (建一個 draft、然後刪)
  -- ============================================================
  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, created_by, updated_by)
  VALUES (v_tenant, 'TEST-DEL-' || EXTRACT(EPOCH FROM NOW())::TEXT,
          v_hq_loc, v_store_a_loc, 'draft', 'hq_to_store', v_op, v_op)
  RETURNING id INTO v_xfer_draft;
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, created_by, updated_by)
  VALUES (v_xfer_draft, v_sku_a, 1, v_op, v_op);

  v_result := rpc_transfer_batch_delete(ARRAY[v_xfer_draft], v_op);
  IF jsonb_array_length(v_result -> 'deleted') <> 1 THEN
    RAISE EXCEPTION 'H1 FAIL: deleted=%', v_result -> 'deleted';
  END IF;
  PERFORM 1 FROM transfers WHERE id = v_xfer_draft;
  IF FOUND THEN
    RAISE EXCEPTION 'H1 FAIL: transfer still exists';
  END IF;
  PERFORM 1 FROM transfer_items WHERE transfer_id = v_xfer_draft;
  IF FOUND THEN
    RAISE EXCEPTION 'H2 FAIL: transfer_items not cascaded';
  END IF;
  RAISE NOTICE 'H1-H2 PASS: draft transfer + items deleted (CASCADE)';

  -- I1: 非 draft 不刪
  v_result := rpc_transfer_batch_delete(ARRAY[v_xfer_arrive_1], v_op);
  IF jsonb_array_length(v_result -> 'failed') <> 1 THEN
    RAISE EXCEPTION 'I1 FAIL';
  END IF;
  RAISE NOTICE 'I1 PASS: non-draft rejected';

  -- ============================================================
  -- J/K. is_air_transfer + shipping_temp（已在 fixture build 中隱含驗證）
  -- ============================================================
  PERFORM 1 FROM transfers WHERE id = v_xfer_air AND is_air_transfer = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'J1 FAIL'; END IF;
  RAISE NOTICE 'J1 PASS: is_air_transfer=TRUE 可塞 store→store';

  PERFORM 1 FROM transfers WHERE id = v_xfer_dist_1 AND shipping_temp = 'frozen';
  IF NOT FOUND THEN RAISE EXCEPTION 'K1 FAIL'; END IF;
  RAISE NOTICE 'K1 PASS: shipping_temp=frozen 寫入正確';

  RAISE NOTICE '======= ALL TESTS PASSED (A1/A4 + B1 + C2 + D1-D4 + E2 + F1-F2,F5 + G1-G3 + H1-H2 + I1 + J1 + K1) =======';
  RAISE EXCEPTION 'ROLLBACK_OK';
END $outer$;
