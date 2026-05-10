-- ============================================================
-- fixture: with-transfers
-- 庫存調撥情境 + 反向情境：
--   TF-0001  draft           平鎮 → 松山                 （正常 draft）
--   TF-0002  shipped         WH-HQ → 北投（hq_to_store） （shipped、待收）
--   TF-0003  received        松山 → 內湖                 （正常完成、含 movements）
--   TF-0004  cancelled       WH-HQ → 信義（hq_to_store） R6a: 對方拒收、stock 反流 transfer_reject
--   TF-0005  received        WH-HQ → 平鎮（hq_to_store） R6b: 出 10 收 8、運送破損 2 件
--   TF-0006  received        WH-HQ → 松山（hq_to_store） 月結算用、近期 shipped + received
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO transfers (
  tenant_id, transfer_no, source_location, dest_location,
  status, transfer_type, requested_by, shipped_at, shipped_by,
  received_at, received_by, created_by, notes
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       x.no,
       (SELECT id FROM locations WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = x.src),
       (SELECT id FROM locations WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = x.dst),
       x.status,
       x.tf_type,
       (SELECT id FROM any_user),
       CASE WHEN x.status IN ('shipped','received','cancelled') THEN NOW() - INTERVAL '1 day' END,
       CASE WHEN x.status IN ('shipped','received','cancelled') THEN (SELECT id FROM any_user) END,
       CASE WHEN x.status = 'received' THEN NOW() - INTERVAL '12 hours' END,
       CASE WHEN x.status = 'received' THEN (SELECT id FROM any_user) END,
       (SELECT id FROM any_user),
       x.notes
FROM (VALUES
  ('TF-0001', 'WH-S001', 'WH-S002', 'draft',     'store_to_store', NULL),
  ('TF-0002', 'WH-HQ',   'WH-S003', 'shipped',   'hq_to_store',    NULL),
  ('TF-0003', 'WH-S002', 'WH-S004', 'received',  'store_to_store', NULL),
  ('TF-0004', 'WH-HQ',   'WH-S005', 'cancelled', 'hq_to_store',    'R6a: 對方拒收、stock 反流'),
  ('TF-0005', 'WH-HQ',   'WH-S001', 'received',  'hq_to_store',    'R6b: 出 10 收 8、損壞 2 件'),
  ('TF-0006', 'WH-HQ',   'WH-S002', 'received',  'hq_to_store',    '月結算用近期 hq_to_store')
) AS x(no, src, dst, status, tf_type, notes);

-- transfer_items
INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped, qty_received)
SELECT t.id,
       (SELECT id FROM skus WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND sku_code = x.sku_code),
       x.qty_req, x.qty_ship, x.qty_recv
FROM transfers t
JOIN (VALUES
  -- (no, sku, requested, shipped, received)
  ('TF-0001', 'SKU-001', 5,  0, 0),
  ('TF-0001', 'SKU-002', 3,  0, 0),
  ('TF-0002', 'SKU-001', 10, 10, 0),
  ('TF-0003', 'SKU-005', 4,  4, 4),
  ('TF-0004', 'SKU-007', 8,  8, 0),     -- R6a: shipped 8 後拒收
  ('TF-0005', 'SKU-006', 10, 10, 8),    -- R6b: shipped 10 received 8 (-2 damaged)
  ('TF-0006', 'SKU-008', 6,  6, 6)      -- 月結算用
) AS x(no, sku_code, qty_req, qty_ship, qty_recv) ON t.transfer_no = x.no
WHERE t.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);

-- ── stock_movements 鏈 ──────────────────────────────────
-- TF-0002 shipped (hq_to_store): 只有 transfer_out（dest 還沒 transfer_in）
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     t AS (SELECT * FROM transfers WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND transfer_no = 'TF-0002'),
     ti AS (SELECT ti.* FROM transfer_items ti JOIN t ON ti.transfer_id = t.id),
     mv AS (
       INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                    movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                                    reason, operator_id)
       SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
              (SELECT source_location FROM t),
              ti.sku_id,
              -ti.qty_shipped, 90,  -- SKU-001 cost
              'transfer_out', 'transfer', (SELECT id FROM t), ti.id,
              'TF-0002 shipped',
              (SELECT id FROM any_user)
       FROM ti
       RETURNING id, source_doc_line_id
     )
UPDATE transfer_items ti SET out_movement_id = mv.id
FROM mv WHERE ti.id = mv.source_doc_line_id;

-- TF-0003 received (store_to_store): transfer_out + transfer_in
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     t AS (SELECT * FROM transfers WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND transfer_no = 'TF-0003'),
     ti AS (SELECT ti.* FROM transfer_items ti JOIN t ON ti.transfer_id = t.id)
INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                             movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                             reason, operator_id)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), loc, ti.sku_id, qty, 60,  -- SKU-005 cost
       mtype, 'transfer', (SELECT id FROM t), ti.id, lbl, (SELECT id FROM any_user)
FROM ti
CROSS JOIN (VALUES
  ((SELECT source_location FROM t), -1, 'transfer_out', 'TF-0003 transfer_out'),
  ((SELECT dest_location   FROM t),  1, 'transfer_in',  'TF-0003 transfer_in')
) AS x(loc, sign, mtype, lbl)
CROSS JOIN LATERAL (SELECT (CASE WHEN x.sign = -1 THEN -ti.qty_received ELSE ti.qty_received END) AS qty) q;

-- TF-0004 cancelled (R6a): transfer_out shipped + transfer_reject 反流
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     t AS (SELECT * FROM transfers WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND transfer_no = 'TF-0004'),
     ti AS (SELECT ti.* FROM transfer_items ti JOIN t ON ti.transfer_id = t.id),
     out_mv AS (
       INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                    movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                                    reason, operator_id)
       SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
              (SELECT source_location FROM t),
              ti.sku_id, -ti.qty_shipped, 40,  -- SKU-007 cost
              'transfer_out', 'transfer', (SELECT id FROM t), ti.id,
              'TF-0004 shipped (將被拒收)',
              (SELECT id FROM any_user)
       FROM ti
       RETURNING id, source_doc_line_id
     )
INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                             movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                             reverses, reason, operator_id)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       (SELECT source_location FROM t),
       ti.sku_id, ti.qty_shipped, 40,
       'transfer_reject', 'transfer', (SELECT id FROM t), ti.id,
       om.id,
       'R6a: 對方拒收、回流',
       (SELECT id FROM auth.users LIMIT 1)
FROM ti, out_mv om WHERE om.source_doc_line_id = ti.id;

-- TF-0005 received with damage (R6b): transfer_out 10 / transfer_in 8 / damage 2
DO $$
DECLARE
  v_tenant   UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_operator UUID;
  v_t        BIGINT;
  v_ti       BIGINT;
  v_sku      BIGINT;
  v_src_loc  BIGINT;
  v_dst_loc  BIGINT;
BEGIN
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  SELECT id, source_location, dest_location INTO v_t, v_src_loc, v_dst_loc
    FROM transfers WHERE tenant_id = v_tenant AND transfer_no = 'TF-0005';
  SELECT id, sku_id INTO v_ti, v_sku FROM transfer_items WHERE transfer_id = v_t;

  -- transfer_out at HQ
  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                               movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                               reason, operator_id)
  VALUES (v_tenant, v_src_loc, v_sku, -10, 230,
          'transfer_out', 'transfer', v_t, v_ti, 'TF-0005 ship 10', v_operator);

  -- transfer_in at S001 (8 件)
  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                               movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                               reason, operator_id)
  VALUES (v_tenant, v_dst_loc, v_sku, 8, 230,
          'transfer_in', 'transfer', v_t, v_ti, 'TF-0005 receive 8', v_operator);

  -- damage 2 件記在 source（HQ）做 write-off
  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                               movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                               reason, operator_id)
  VALUES (v_tenant, v_src_loc, v_sku, -2, 230,
          'damage', 'transfer', v_t, v_ti, 'R6b: 運送破損 2 件', v_operator);
END $$;

-- TF-0006 normal hq_to_store received（月結算用）
DO $$
DECLARE
  v_tenant   UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_operator UUID;
  v_t        BIGINT;
  v_ti       BIGINT;
  v_sku      BIGINT;
  v_src_loc  BIGINT;
  v_dst_loc  BIGINT;
BEGIN
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  SELECT id, source_location, dest_location INTO v_t, v_src_loc, v_dst_loc
    FROM transfers WHERE tenant_id = v_tenant AND transfer_no = 'TF-0006';
  SELECT id, sku_id INTO v_ti, v_sku FROM transfer_items WHERE transfer_id = v_t;

  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                               movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                               reason, operator_id)
  VALUES (v_tenant, v_src_loc, v_sku, -6, 75,
          'transfer_out', 'transfer', v_t, v_ti, 'TF-0006 ship', v_operator);

  INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                               movement_type, source_doc_type, source_doc_id, source_doc_line_id,
                               reason, operator_id)
  VALUES (v_tenant, v_dst_loc, v_sku, 6, 75,
          'transfer_in', 'transfer', v_t, v_ti, 'TF-0006 receive', v_operator);
END $$;

-- ── transfer_settlements: 給 TF-0003（store↔store 已 received）建一筆 draft ──
-- store_a < store_b：TF-0003 src=S002 dst=S004，store_a=S002, store_b=S004
DO $$
DECLARE
  v_tenant     UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_month      DATE := DATE_TRUNC('month', NOW())::date;
  v_s2         BIGINT;
  v_s4         BIGINT;
  v_settlement BIGINT;
  v_tf3        BIGINT;
  v_amount     NUMERIC;
  v_operator   UUID;
BEGIN
  SELECT id INTO v_s2 FROM stores WHERE tenant_id = v_tenant AND code = 'S002';
  SELECT id INTO v_s4 FROM stores WHERE tenant_id = v_tenant AND code = 'S004';
  SELECT id INTO v_tf3 FROM transfers WHERE tenant_id = v_tenant AND transfer_no = 'TF-0003';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  v_amount := 4 * 60;  -- 4 件 × cost 60

  INSERT INTO transfer_settlements (
    tenant_id, settlement_month, store_a_id, store_b_id,
    a_to_b_amount, b_to_a_amount, net_amount, transfer_count,
    status, created_by, updated_by
  ) VALUES (
    v_tenant, v_month, LEAST(v_s2, v_s4), GREATEST(v_s2, v_s4),
    v_amount, 0, v_amount, 1,
    'draft', v_operator, v_operator
  ) RETURNING id INTO v_settlement;

  INSERT INTO transfer_settlement_items (
    tenant_id, settlement_id, transfer_id, direction, amount, transfer_date
  ) VALUES (
    v_tenant, v_settlement, v_tf3, 'a_to_b', v_amount, NOW()::date
  );
END $$;

COMMIT;

\echo 'fixture with-transfers seeded (6 TFs incl. R6a R6b + 1 settlement).'
