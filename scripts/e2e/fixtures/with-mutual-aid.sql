-- ============================================================
-- fixture: with-mutual-aid
-- 互助板情境（依賴 with-orders 已建 customer_orders）：
--
--   request 類型（純求助）:
--     AID-REQ-001  active  S001 SKU-002 ×12
--     AID-REQ-002  active  S002 SKU-006 ×6（剩 3）
--     AID-REQ-003  active  S003 SKU-008 ×20
--
--   offer 類型（從 customer_order 釋出）:
--     AID-OFR-001  active     S002 SKU-003 ×2 src=ORD-0002（黃金路徑用）+ 3 replies
--     AID-OFR-002  cancelled  S001 SKU-008 ×3 src=ORD-0001  R11a: 取消、無 claim
--     AID-OFR-003  cancelled  S002 SKU-010 ×1 src=ORD-0004  R11b: 取消、claim 也取消
--     AID-OFR-004  cancelled  S001 SKU-009 ×1 src=ORD-0003  R11c: 已 ship 後取消、stock 反流
--
--   R12: aid received 後對方退單（既有 RPC gap、走 free transfer 反向 workaround）
--     用 AID-OFR-001 chain 但這份 fixture 不灌 received 終態，留給未來 with-cancellations 補
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- ── 1. request 類型（原 3 則）────────────────────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO mutual_aid_board (
  tenant_id, offering_store_id, sku_id,
  qty_available, qty_remaining, expires_at, note, status,
  post_type, source_customer_order_id, created_by
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       (SELECT id FROM stores WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = x.store_code),
       (SELECT id FROM skus   WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND sku_code = x.sku_code),
       x.qty, x.qty_remain,
       NOW() + (x.expires_in_days || ' days')::interval,
       x.note, 'active', 'request', NULL,
       (SELECT id FROM any_user)
FROM (VALUES
  ('S001', 'SKU-002', 12, 12, '需求：請其他店支援',     7),
  ('S002', 'SKU-006',  6,  3, '需求：缺貨急徵',         5),
  ('S003', 'SKU-008', 20, 20, '需求：要辦活動，求支援', 3)
) AS x(store_code, sku_code, qty, qty_remain, note, expires_in_days);

-- ── 2. offer 類型（依賴 customer_orders）─────────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     orders AS (
       SELECT * FROM customer_orders WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1)
     )
INSERT INTO mutual_aid_board (
  tenant_id, offering_store_id, sku_id,
  qty_available, qty_remaining, expires_at, note, status,
  post_type, source_customer_order_id, created_by, updated_by
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       (SELECT id FROM stores WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = x.store_code),
       (SELECT id FROM skus   WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND sku_code = x.sku_code),
       x.qty, x.qty_remain,
       NOW() + (x.expires_days || ' days')::interval,
       x.note, x.status, 'offer',
       (SELECT id FROM orders WHERE order_no = x.src_order),
       (SELECT id FROM any_user),
       (SELECT id FROM any_user)
FROM (VALUES
  ('S002', 'SKU-003', 2, 2, 'active',    'AID-OFR-001: 黃金路徑用、可被認領',     7, 'ORD-0002'),
  ('S001', 'SKU-008', 3, 3, 'cancelled', 'R11a: offer 取消、無 claim',            3, 'ORD-0001'),
  ('S002', 'SKU-010', 1, 1, 'cancelled', 'R11b: offer + claim 都取消',            3, 'ORD-0004'),
  ('S001', 'SKU-009', 1, 1, 'cancelled', 'R11c: offer 已 ship 後取消、stock 反流', 3, 'ORD-0003')
) AS x(store_code, sku_code, qty, qty_remain, status, note, expires_days, src_order);

-- ── 3. mutual_aid_replies（active offer 上 3 則對話）──────
INSERT INTO mutual_aid_replies (tenant_id, board_id, author_id, author_label, body)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), b.id,
       (SELECT id FROM auth.users LIMIT 1),
       x.author,
       x.body
FROM mutual_aid_board b
JOIN (VALUES
  ('S002', '小華',     '我想認領 1 件，可以嗎？'),
  ('S002', 'S002 店長', '請補一下品項細節 + 預期到貨'),
  ('S002', '小芳',     '我也想要 1 件')
) AS x(store_code, author, body) ON x.store_code = 'S002'
WHERE b.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1)
  AND b.note LIKE 'AID-OFR-001%';

-- ── 4. mutual_aid_claims ────────────────────────────────
-- AID-OFR-001 active：S001 認領 1 件（resulting transfer = TF-AID-001 shipped）
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     b AS (SELECT id, offering_store_id, sku_id FROM mutual_aid_board
           WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND note LIKE 'AID-OFR-001%'),
     s_target AS (SELECT id, location_id FROM stores
                  WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = 'S001'),
     s_source AS (SELECT location_id FROM stores
                  WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = 'S002'),
     new_transfer AS (
       INSERT INTO transfers (
         tenant_id, transfer_no, source_location, dest_location,
         status, transfer_type, requested_by, shipped_at, shipped_by, created_by, notes
       ) VALUES (
         (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), 'TF-AID-001',
         (SELECT location_id FROM s_source),
         (SELECT location_id FROM s_target),
         'shipped', 'store_to_store',
         (SELECT id FROM any_user),
         NOW() - INTERVAL '6 hours', (SELECT id FROM any_user),
         (SELECT id FROM any_user),
         '互助 AID-OFR-001 認領出貨'
       ) RETURNING id
     ),
     new_item AS (
       INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped, qty_received)
       SELECT (SELECT id FROM new_transfer), (SELECT sku_id FROM b), 1, 1, 0
       RETURNING id
     ),
     -- transfer_out movement (S002 倉)
     out_mv AS (
       INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                    movement_type, source_doc_type, source_doc_id,
                                    reason, operator_id)
       SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
              (SELECT location_id FROM s_source),
              (SELECT sku_id FROM b),
              -1, 150,  -- SKU-003 cost
              'transfer_out', 'transfer', (SELECT id FROM new_transfer),
              'AID-OFR-001 → TF-AID-001 ship',
              (SELECT id FROM any_user)
       RETURNING id
     )
INSERT INTO mutual_aid_claims (tenant_id, board_id, claiming_store_id, qty,
                                resulting_transfer_id, created_by)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), (SELECT id FROM b),
       (SELECT id FROM s_target),
       1,
       (SELECT id FROM new_transfer),
       (SELECT id FROM any_user);

-- AID-OFR-001 qty_remaining 從 2 扣到 1
UPDATE mutual_aid_board
   SET qty_remaining = 1
 WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1)
   AND note LIKE 'AID-OFR-001%';

-- ── 5. R11b: 已取消的 offer + 已取消的 claim ───────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     b AS (SELECT id, offering_store_id, sku_id FROM mutual_aid_board
           WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND note LIKE 'R11b:%')
INSERT INTO mutual_aid_claims (tenant_id, board_id, claiming_store_id, qty,
                                resulting_transfer_id, created_by)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), (SELECT id FROM b),
       (SELECT id FROM stores WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = 'S004'),
       1, NULL,  -- 沒有 transfer 因為 claim 在 cancel 前就被取消了
       (SELECT id FROM any_user);
-- 註：claim 表是 append-only、無 status 欄位。實務上「取消 claim」靠
-- mutual_aid_board.status='cancelled' 標示；claims 行保留供 audit。

-- ── 6. R11c: 已 ship 後 offer 取消、stock 反流 ──────────────
-- S001 的 SKU-009 從 customer_order ORD-0003 釋出 1 件、給 S004
-- 已 shipped + 對應 stock_movements.transfer_out + 取消後 transfer_reject 反流
DO $$
DECLARE
  v_tenant     UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_operator   UUID;
  v_sku        BIGINT;
  v_src_loc    BIGINT;
  v_dst_loc    BIGINT;
  v_dst_store  BIGINT;
  v_board      BIGINT;
  v_transfer   BIGINT;
  v_item       BIGINT;
  v_out_mv     BIGINT;
BEGIN
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  SELECT id, offering_store_id, sku_id, NULL::int INTO v_board, v_dst_store, v_sku, v_dst_store
    FROM mutual_aid_board
   WHERE tenant_id = v_tenant AND note LIKE 'R11c:%';
  SELECT id, sku_id INTO v_board, v_sku FROM mutual_aid_board
   WHERE tenant_id = v_tenant AND note LIKE 'R11c:%';
  SELECT location_id INTO v_src_loc FROM stores WHERE tenant_id = v_tenant AND code = 'S001';
  SELECT id, location_id INTO v_dst_store, v_dst_loc FROM stores
   WHERE tenant_id = v_tenant AND code = 'S004';

  -- transfers
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, requested_by, shipped_at, shipped_by, created_by, notes
  ) VALUES (
    v_tenant, 'TF-AID-002', v_src_loc, v_dst_loc,
    'cancelled', 'store_to_store',
    v_operator, NOW() - INTERVAL '8 hours', v_operator,
    v_operator, 'R11c: 互助已 ship 後取消'
  ) RETURNING id INTO v_transfer;

  -- transfer_items
  INSERT INTO transfer_items (transfer_id, sku_id, qty_requested, qty_shipped, qty_received)
  VALUES (v_transfer, v_sku, 1, 1, 0)
  RETURNING id INTO v_item;

  -- transfer_out
  INSERT INTO stock_movements (
    tenant_id, location_id, sku_id, quantity, unit_cost,
    movement_type, source_doc_type, source_doc_id, source_doc_line_id,
    reason, operator_id
  ) VALUES (
    v_tenant, v_src_loc, v_sku, -1, 60,
    'transfer_out', 'transfer', v_transfer, v_item,
    'TF-AID-002 ship', v_operator
  ) RETURNING id INTO v_out_mv;

  -- transfer_reject reversal
  INSERT INTO stock_movements (
    tenant_id, location_id, sku_id, quantity, unit_cost,
    movement_type, source_doc_type, source_doc_id, source_doc_line_id,
    reverses, reason, operator_id
  ) VALUES (
    v_tenant, v_src_loc, v_sku, 1, 60,
    'transfer_reject', 'transfer', v_transfer, v_item,
    v_out_mv, 'R11c: 取消、stock 反流', v_operator
  );

  -- claim
  INSERT INTO mutual_aid_claims (
    tenant_id, board_id, claiming_store_id, qty, resulting_transfer_id, created_by
  ) VALUES (
    v_tenant, v_board, v_dst_store, 1, v_transfer, v_operator
  );
END $$;

COMMIT;

\echo 'fixture with-mutual-aid seeded (3 req + 4 offers incl. R11a/b/c + 1 active claim + 3 replies).'

