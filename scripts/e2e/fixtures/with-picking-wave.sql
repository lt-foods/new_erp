-- ============================================================
-- fixture: with-picking-wave
-- 撿貨波次情境（依賴 with-orders 的 customer_orders + with-campaign）：
--
--   WAVE-0001  picked      正常 wave + R5 撿貨不足量
--                          - SKU-001 ORD-0001 申請 2、實撿 2
--                          - SKU-007 ORD-0001 申請 1、實撿 1
--                          - SKU-003 ORD-0002 申請 2、實撿 1（R5 短少 1 件 → 應產 backorder）
--   WAVE-0002  cancelled   R9: wave 整單取消（picking 中）
--                          - SKU-008 ORD-0003 申請 1、picked_qty 還沒填
--
-- 不模擬 generate_transfer_from_wave（generated_transfer_id 留空）。
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- ── WAVE-0001 picked（含 R5 撿貨不足）───────────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO picking_waves (
  tenant_id, wave_code, wave_date, status, store_count, item_count, total_qty,
  note, created_by, updated_by
)
SELECT :'tenant_id'::uuid,
       'WAVE-0001',
       CURRENT_DATE,
       'picked',
       2, 3, 4,  -- 2 stores (S001+S002), 3 items, total picked 4
       'CAMP-001 + CAMP-002 撿貨波次（含 R5 短少）',
       (SELECT id FROM any_user),
       (SELECT id FROM any_user);

-- WAVE-0001 items
INSERT INTO picking_wave_items (
  tenant_id, wave_id, sku_id, store_id, qty, picked_qty, campaign_id,
  note, created_by, updated_by
)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM picking_waves WHERE tenant_id = :'tenant_id'::uuid AND wave_code = 'WAVE-0001'),
       (SELECT id FROM skus WHERE tenant_id = :'tenant_id'::uuid AND sku_code = x.sku),
       (SELECT id FROM stores WHERE tenant_id = :'tenant_id'::uuid AND code = x.store),
       x.qty, x.picked,
       (SELECT id FROM group_buy_campaigns WHERE tenant_id = :'tenant_id'::uuid AND campaign_no = x.camp),
       x.note,
       (SELECT id FROM auth.users LIMIT 1),
       (SELECT id FROM auth.users LIMIT 1)
FROM (VALUES
  ('SKU-001', 'S001', 'CAMP-001', 2, 2, NULL),
  ('SKU-007', 'S001', 'CAMP-001', 1, 1, NULL),
  ('SKU-003', 'S002', 'CAMP-002', 2, 1, 'R5: 申請 2 實撿 1（短少 1 件 → backorder）')
) AS x(sku, store, camp, qty, picked, note);

-- WAVE-0001 audit log
INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, note, created_by)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM picking_waves WHERE tenant_id = :'tenant_id'::uuid AND wave_code = 'WAVE-0001'),
       a.action, a.after_value::jsonb, a.note,
       (SELECT id FROM auth.users LIMIT 1)
FROM (VALUES
  ('wave_created',         '{"wave_code":"WAVE-0001","item_count":3}',         NULL),
  ('picked_qty_changed',   '{"sku":"SKU-001","picked_qty":2}',                  NULL),
  ('picked_qty_changed',   '{"sku":"SKU-007","picked_qty":1}',                  NULL),
  ('picked_qty_changed',   '{"sku":"SKU-003","picked_qty":1,"shortage":1}',     'R5 短少'),
  ('wave_status_changed',  '{"from":"picking","to":"picked"}',                  NULL)
) AS a(action, after_value, note);

-- ── R5: backorders 為短少件數開單 ─────────────────────────
-- ORD-0002 SKU-003 申請 2 實得 1 → 1 件 backorder
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     o AS (SELECT * FROM customer_orders WHERE tenant_id = :'tenant_id'::uuid AND order_no = 'ORD-0002'),
     coi AS (SELECT coi.* FROM customer_order_items coi
              JOIN o ON coi.order_id = o.id
              JOIN skus s ON s.id = coi.sku_id
             WHERE s.sku_code = 'SKU-003')
INSERT INTO backorders (
  tenant_id, original_customer_order_item_id, sku_id, store_id, member_id,
  qty_pending, status, notes, created_by, updated_by
)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM coi),
       (SELECT sku_id FROM coi),
       (SELECT pickup_store_id FROM o),
       (SELECT member_id FROM o),
       1,
       'pending',
       'R5: WAVE-0001 撿貨不足、ORD-0002 SKU-003 短少 1 件',
       (SELECT id FROM any_user),
       (SELECT id FROM any_user);

-- ── WAVE-0002 cancelled（R9 wave 整單取消）──────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO picking_waves (
  tenant_id, wave_code, wave_date, status, store_count, item_count, total_qty,
  note, created_by, updated_by
)
SELECT :'tenant_id'::uuid,
       'WAVE-0002',
       CURRENT_DATE,
       'cancelled',
       1, 1, 0,
       'R9: 撿貨中發現拼錯波次、整單取消',
       (SELECT id FROM any_user),
       (SELECT id FROM any_user);

INSERT INTO picking_wave_items (
  tenant_id, wave_id, sku_id, store_id, qty, picked_qty, campaign_id,
  note, created_by, updated_by
)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM picking_waves WHERE tenant_id = :'tenant_id'::uuid AND wave_code = 'WAVE-0002'),
       (SELECT id FROM skus WHERE tenant_id = :'tenant_id'::uuid AND sku_code = 'SKU-008'),
       (SELECT id FROM stores WHERE tenant_id = :'tenant_id'::uuid AND code = 'S001'),
       1, NULL,  -- 還沒撿就取消
       (SELECT id FROM group_buy_campaigns WHERE tenant_id = :'tenant_id'::uuid AND campaign_no = 'CAMP-009'),
       NULL,
       (SELECT id FROM auth.users LIMIT 1),
       (SELECT id FROM auth.users LIMIT 1);

-- WAVE-0002 audit log
INSERT INTO picking_wave_audit_log (tenant_id, wave_id, action, after_value, note, created_by)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM picking_waves WHERE tenant_id = :'tenant_id'::uuid AND wave_code = 'WAVE-0002'),
       a.action, a.after_value::jsonb, a.note,
       (SELECT id FROM auth.users LIMIT 1)
FROM (VALUES
  ('wave_created',     '{"wave_code":"WAVE-0002","item_count":1}',  NULL),
  ('wave_cancelled',   '{"reason":"R9: 拼錯波次"}',                  'R9 整單取消')
) AS a(action, after_value, note);

COMMIT;

\echo 'fixture with-picking-wave seeded (1 picked wave with R5 shortage + 1 cancelled wave R9 + 1 backorder).'
