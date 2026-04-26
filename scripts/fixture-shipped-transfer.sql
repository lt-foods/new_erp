-- 建一筆 shipped transfer fixture 給 UI 手動測試用。回傳 transfer_id。
DO $do$
DECLARE
  v_tenant   UUID;
  v_op       UUID := '22222222-2222-2222-2222-222222222222';
  v_src      BIGINT;
  v_dst      BIGINT;
  v_sku_a    BIGINT;
  v_sku_b    BIGINT;
  v_xfer     BIGINT;
  v_out_a    BIGINT;
  v_out_b    BIGINT;
BEGIN
  SELECT tenant_id INTO v_tenant FROM locations LIMIT 1;
  SELECT id INTO v_src FROM locations WHERE type = 'central_warehouse' AND is_active LIMIT 1;
  SELECT id INTO v_dst FROM locations WHERE id <> v_src LIMIT 1;
  SELECT id INTO v_sku_a FROM skus ORDER BY id LIMIT 1;
  SELECT id INTO v_sku_b FROM skus WHERE id <> v_sku_a ORDER BY id LIMIT 1;

  INSERT INTO transfers (tenant_id, transfer_no, source_location, dest_location,
                         status, transfer_type, requested_by, shipped_by, shipped_at,
                         created_by, updated_by)
  VALUES (v_tenant, 'FIXTURE-' || EXTRACT(EPOCH FROM NOW())::BIGINT,
          v_src, v_dst, 'shipped', 'hq_to_store',
          v_op, v_op, NOW(), v_op, v_op)
  RETURNING id INTO v_xfer;

  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                movement_type, source_doc_type, source_doc_id, operator_id)
  VALUES (v_tenant, v_src, v_sku_a, -10, 25.5, 'transfer_out', 'transfer', v_xfer, v_op)
  RETURNING id INTO v_out_a;

  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                movement_type, source_doc_type, source_doc_id, operator_id)
  VALUES (v_tenant, v_src, v_sku_b, -5, 100, 'transfer_out', 'transfer', v_xfer, v_op)
  RETURNING id INTO v_out_b;

  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped,
                              out_movement_id, created_by, updated_by)
  VALUES (v_xfer, v_sku_a, 10, 10, v_out_a, v_op, v_op),
         (v_xfer, v_sku_b, 5, 5, v_out_b, v_op, v_op);

  RAISE NOTICE 'fixture transfer_id=%', v_xfer;
END
$do$;
