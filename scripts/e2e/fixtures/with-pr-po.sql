-- ============================================================
-- fixture: with-pr-po
-- 採購流：PR (請購) / PO (採購單) / GR (進貨) + 反向情境
--
-- 正常情境：
--   PR-0001  draft           平鎮店請購 P004 香米×10
--   PR-0002  fully_ordered   松山店請購 P003 醬油×6
--   PO-0001  sent            SUP-LOCAL → WH-HQ（剛發送、未驗收）
--   PO-0002  fully_received  SUP-LOCAL → WH-HQ → GR-0001 confirmed
--
-- 反向情境：
--   PR-0003  cancelled              R1: PR 直接取消
--   PR-0004  submitted              準備拆單到 PO-0003
--   PO-0003  cancelled (no GR)      R2a: PO 已 sent 後取消、未進貨
--   PO-0004  cancelled (partial)    R2b: 收 7 個後取消剩 3 個 → GR-0002 confirmed
--   PO-0005  partially_received     R3: 訂 8 個實收 5 個 → GR-0003 confirmed (3 件短少 → backorder)
--
-- AP / 退貨：
--   VB-0001  paid           PO-0002 應付帳款 + VP-0001 已付
--   VB-0002  pending        PO-0004 partial bill（only 7 received）
--   PRET-0001 confirmed     PO-0002 GR-0001 退貨 1 個 SKU-004 因瑕疵 → 走退供
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO purchase_requests (tenant_id, pr_no, source_location_id, status, created_by, submitted_at, notes)
SELECT :'tenant_id'::uuid,
       x.pr_no,
       (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = x.loc),
       x.status,
       (SELECT id FROM any_user),
       CASE WHEN x.status = 'draft' THEN NULL ELSE NOW() - INTERVAL '2 days' END,
       x.notes
FROM (VALUES
  ('PR-0001', 'WH-S001', 'draft',         NULL),
  ('PR-0002', 'WH-S002', 'fully_ordered', NULL),
  ('PR-0003', 'WH-S001', 'cancelled',     'R1: PR 取消（HQ 拒絕）'),
  ('PR-0004', 'WH-S003', 'submitted',     '北投店請購 → 準備拆 PO-0003 / PO-0005')
) AS x(pr_no, loc, status, notes);

INSERT INTO purchase_request_items (pr_id, sku_id, qty_requested)
SELECT pr.id,
       (SELECT id FROM skus WHERE tenant_id = :'tenant_id'::uuid AND sku_code = x.sku_code),
       x.qty
FROM purchase_requests pr
JOIN (VALUES
  ('PR-0001', 'SKU-004', 10),
  ('PR-0002', 'SKU-003',  6),
  ('PR-0003', 'SKU-005',  5),  -- R1 cancelled
  ('PR-0004', 'SKU-001', 10),  -- 對應 PO-0003 cancelled
  ('PR-0004', 'SKU-002',  8)   -- 對應 PO-0005 R3 短少
) AS x(pr_no, sku_code, qty) ON pr.pr_no = x.pr_no
WHERE pr.tenant_id = :'tenant_id'::uuid;

-- ── PO ─────────────────────────────────────────────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO purchase_orders (
  tenant_id, po_no, supplier_id, dest_location_id, status,
  order_date, expected_date, subtotal, tax, total, created_by, sent_at, sent_by, notes
)
SELECT :'tenant_id'::uuid,
       x.po_no,
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = x.sup_code),
       (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = x.dest_code),
       x.status,
       (CURRENT_DATE - INTERVAL '5 days')::date,
       (CURRENT_DATE + INTERVAL '7 days')::date,
       x.subtotal,
       ROUND(x.subtotal * 0.05, 2),
       ROUND(x.subtotal * 1.05, 2),
       (SELECT id FROM any_user),
       CASE WHEN x.status IN ('sent','partially_received','fully_received','cancelled')
            THEN NOW() - INTERVAL '4 days' ELSE NULL END,
       CASE WHEN x.status IN ('sent','partially_received','fully_received','cancelled')
            THEN (SELECT id FROM any_user) ELSE NULL END,
       x.notes
FROM (VALUES
  ('PO-0001', 'SUP-LOCAL', 'WH-HQ', 'sent',                900,  NULL),
  ('PO-0002', 'SUP-LOCAL', 'WH-HQ', 'fully_received',     1500,  NULL),
  ('PO-0003', 'SUP-JP',    'WH-HQ', 'cancelled',           850,  'R2a: 已 sent 後取消、未進貨'),
  ('PO-0004', 'SUP-LOCAL', 'WH-HQ', 'cancelled',          1300,  'R2b: 收 7/10 後取消剩 3'),
  ('PO-0005', 'SUP-LOCAL', 'WH-HQ', 'partially_received',  400,  'R3: 訂 8 個實收 5 個（短少 3）')
) AS x(po_no, sup_code, dest_code, status, subtotal, notes);

-- purchase_order_items：line_subtotal 為 GENERATED 欄位，不要塞值
INSERT INTO purchase_order_items (po_id, sku_id, qty_ordered, qty_received, unit_cost)
SELECT po.id,
       (SELECT id FROM skus WHERE tenant_id = :'tenant_id'::uuid AND sku_code = x.sku_code),
       x.qty,
       x.qty_recv,
       x.cost
FROM purchase_orders po
JOIN (VALUES
  ('PO-0001', 'SKU-003',  6,  0, 150),
  ('PO-0002', 'SKU-004', 10, 10, 130),
  ('PO-0002', 'SKU-007',  4,  4,  40),
  ('PO-0003', 'SKU-001', 10,  0,  85),  -- R2a 全 0 收
  ('PO-0004', 'SKU-006', 10,  7, 230),  -- R2b partial 7/10
  ('PO-0005', 'SKU-002',  8,  5,  50)   -- R3 short 5/8
) AS x(po_no, sku_code, qty, qty_recv, cost) ON po.po_no = x.po_no
WHERE po.tenant_id = :'tenant_id'::uuid;

-- 把 PR-0004 的 items po_item_id 連到 PO-0003 / PO-0005
UPDATE purchase_request_items pri
   SET po_item_id = poi.id
  FROM purchase_orders po, purchase_order_items poi, purchase_requests pr,
       skus s
 WHERE pr.tenant_id = :'tenant_id'::uuid
   AND pr.pr_no = 'PR-0004'
   AND pri.pr_id = pr.id
   AND po.tenant_id = :'tenant_id'::uuid
   AND po.po_no IN ('PO-0003','PO-0005')
   AND poi.po_id = po.id
   AND s.id = pri.sku_id
   AND s.id = poi.sku_id;

-- ── GR（3 張：GR-0001 PO-0002 fully + GR-0002 PO-0004 partial + GR-0003 PO-0005 short）──
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO goods_receipts (
  tenant_id, gr_no, po_id, supplier_id, dest_location_id, status, receive_date,
  received_by, confirmed_at, confirmed_by, created_by, notes
)
SELECT :'tenant_id'::uuid, x.gr_no, po.id, po.supplier_id, po.dest_location_id,
       'confirmed', (CURRENT_DATE - INTERVAL '1 day')::date,
       (SELECT id FROM any_user),
       NOW() - INTERVAL '1 day',
       (SELECT id FROM any_user),
       (SELECT id FROM any_user),
       x.notes
FROM purchase_orders po
JOIN (VALUES
  ('GR-0001', 'PO-0002', NULL),
  ('GR-0002', 'PO-0004', 'R2b: 收 7/10 後 PO 取消'),
  ('GR-0003', 'PO-0005', 'R3: 訂 8 實收 5 — 短少 3 件')
) AS x(gr_no, po_no, notes) ON po.po_no = x.po_no
WHERE po.tenant_id = :'tenant_id'::uuid;

-- GR-0001 全收（PO-0002 fully_received）
INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_expected, qty_received, unit_cost)
SELECT gr.id, poi.id, poi.sku_id, poi.qty_ordered, poi.qty_ordered, poi.unit_cost
FROM goods_receipts gr
JOIN purchase_orders po ON po.id = gr.po_id
JOIN purchase_order_items poi ON poi.po_id = po.id
WHERE gr.tenant_id = :'tenant_id'::uuid AND gr.gr_no = 'GR-0001';

-- GR-0002 partial（R2b）：PO-0004 SKU-006 訂 10、收 7
INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_expected, qty_received, unit_cost,
                                 variance_reason)
SELECT gr.id, poi.id, poi.sku_id, poi.qty_ordered, 7, poi.unit_cost,
       'R2b: 7/10 部分到貨後 PO 取消剩餘'
FROM goods_receipts gr
JOIN purchase_orders po ON po.id = gr.po_id
JOIN purchase_order_items poi ON poi.po_id = po.id
WHERE gr.tenant_id = :'tenant_id'::uuid AND gr.gr_no = 'GR-0002';

-- GR-0003 short（R3）：PO-0005 SKU-002 訂 8、收 5
INSERT INTO goods_receipt_items (gr_id, po_item_id, sku_id, qty_expected, qty_received, unit_cost,
                                 variance_reason)
SELECT gr.id, poi.id, poi.sku_id, poi.qty_ordered, 5, poi.unit_cost,
       'R3: 來貨不足 5/8 — 短少 3 件，預期成 backorder'
FROM goods_receipts gr
JOIN purchase_orders po ON po.id = gr.po_id
JOIN purchase_order_items poi ON poi.po_id = po.id
WHERE gr.tenant_id = :'tenant_id'::uuid AND gr.gr_no = 'GR-0003';

-- ── stock_movements: 已驗收的 GR 寫一筆 purchase_receipt 入 WH-HQ ──
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO stock_movements (
  tenant_id, location_id, sku_id, quantity, unit_cost,
  movement_type, source_doc_type, source_doc_id, source_doc_line_id,
  reason, operator_id
)
SELECT :'tenant_id'::uuid,
       gr.dest_location_id,
       gri.sku_id,
       gri.qty_received,
       gri.unit_cost,
       'purchase_receipt',
       'goods_receipt', gr.id, gri.id,
       'GR ' || gr.gr_no || ' 入庫',
       (SELECT id FROM any_user)
FROM goods_receipts gr
JOIN goods_receipt_items gri ON gri.gr_id = gr.id
WHERE gr.tenant_id = :'tenant_id'::uuid
  AND gr.gr_no IN ('GR-0001','GR-0002','GR-0003');

-- ── vendor_bills + payments + allocations ────────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO vendor_bills (
  tenant_id, bill_no, supplier_id, source_type, source_id,
  bill_date, due_date, amount, paid_amount, status, tax_amount,
  supplier_invoice_no, created_by, notes
)
SELECT :'tenant_id'::uuid,
       x.bill_no,
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = x.sup),
       x.src_type,
       (SELECT id FROM purchase_orders WHERE tenant_id = :'tenant_id'::uuid AND po_no = x.src_po),
       (CURRENT_DATE - INTERVAL '1 day')::date,
       (CURRENT_DATE + INTERVAL '29 days')::date,
       x.amount,
       x.paid,
       x.status,
       ROUND(x.amount * 0.05, 4),
       x.invoice_no,
       (SELECT id FROM any_user),
       x.notes
FROM (VALUES
  ('VB-0001', 'SUP-LOCAL', 'purchase_order', 'PO-0002', 1575, 1575, 'paid',     'INV-LOCAL-001', 'PO-0002 全收貨應付'),
  ('VB-0002', 'SUP-LOCAL', 'purchase_order', 'PO-0004', 1697,    0, 'pending',  'INV-LOCAL-002', 'R2b: PO-0004 partial 7×230×1.05+tax')
) AS x(bill_no, sup, src_type, src_po, amount, paid, status, invoice_no, notes);

-- vendor_bill_items（依 PO + GR 行展開）
INSERT INTO vendor_bill_items (
  tenant_id, bill_id, line_no, description, sku_id, qty, unit_cost, amount,
  po_item_id, gr_item_id
)
SELECT :'tenant_id'::uuid,
       vb.id,
       ROW_NUMBER() OVER (PARTITION BY vb.id ORDER BY gri.id),
       sk.product_name || ' - ' || sk.sku_code,
       gri.sku_id,
       gri.qty_received,
       gri.unit_cost,
       ROUND(gri.qty_received * gri.unit_cost * 1.05, 4),
       gri.po_item_id,
       gri.id
FROM vendor_bills vb
JOIN purchase_orders po ON po.id = vb.source_id
JOIN goods_receipts gr ON gr.po_id = po.id
JOIN goods_receipt_items gri ON gri.gr_id = gr.id
JOIN skus sk ON sk.id = gri.sku_id
WHERE vb.tenant_id = :'tenant_id'::uuid AND vb.bill_no IN ('VB-0001','VB-0002');

-- vendor_payments: VP-0001 付掉 VB-0001
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO vendor_payments (
  tenant_id, payment_no, supplier_id, amount, method, paid_at, status, created_by, notes
)
SELECT :'tenant_id'::uuid,
       'VP-0001',
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL'),
       1575, 'bank_transfer',
       NOW() - INTERVAL '12 hours',
       'completed',
       (SELECT id FROM any_user),
       '付 VB-0001';

INSERT INTO vendor_payment_allocations (tenant_id, payment_id, bill_id, allocated_amount)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM vendor_payments WHERE tenant_id = :'tenant_id'::uuid AND payment_no = 'VP-0001'),
       (SELECT id FROM vendor_bills    WHERE tenant_id = :'tenant_id'::uuid AND bill_no    = 'VB-0001'),
       1575;

-- ── purchase_returns: PRET-0001 退 1 個 SKU-004 因瑕疵 ──
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO purchase_returns (
  tenant_id, return_no, supplier_id, source_location_id, source_gr_id, status,
  return_date, reason, created_by, confirmed_at, confirmed_by, notes
)
SELECT :'tenant_id'::uuid,
       'PRET-0001',
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL'),
       (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-HQ'),
       (SELECT id FROM goods_receipts WHERE tenant_id = :'tenant_id'::uuid AND gr_no = 'GR-0001'),
       'confirmed',
       (CURRENT_DATE - INTERVAL '6 hours')::date,
       'GR-0001 SKU-004 瑕疵 1 個 退供應商',
       (SELECT id FROM any_user),
       NOW() - INTERVAL '6 hours',
       (SELECT id FROM any_user),
       'E2E: PO-0002 退供 1 件';

-- purchase_return_items 對應的 stock_movement type='return_to_supplier'
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     mv AS (
       INSERT INTO stock_movements (tenant_id, location_id, sku_id, quantity, unit_cost,
                                    movement_type, source_doc_type, source_doc_id,
                                    reason, operator_id)
       SELECT :'tenant_id'::uuid,
              (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-HQ'),
              s.id,
              -1, 130, 'return_to_supplier',
              'purchase_return',
              (SELECT id FROM purchase_returns WHERE tenant_id = :'tenant_id'::uuid AND return_no = 'PRET-0001'),
              'PRET-0001 退供 1 件 SKU-004',
              (SELECT id FROM any_user)
       FROM skus s WHERE s.tenant_id = :'tenant_id'::uuid AND s.sku_code = 'SKU-004'
       RETURNING id, sku_id
     )
INSERT INTO purchase_return_items (
  return_id, gr_item_id, sku_id, qty, unit_cost, reason, movement_id
)
SELECT (SELECT id FROM purchase_returns WHERE tenant_id = :'tenant_id'::uuid AND return_no = 'PRET-0001'),
       gri.id, mv.sku_id, 1, 130, '瑕疵', mv.id
FROM mv
JOIN goods_receipt_items gri ON gri.sku_id = mv.sku_id
JOIN goods_receipts gr ON gr.id = gri.gr_id AND gr.gr_no = 'GR-0001'
WHERE gr.tenant_id = :'tenant_id'::uuid;

COMMIT;

\echo 'fixture with-pr-po seeded (4 PRs + 5 POs + 3 GRs + 2 vendor_bills + 1 payment + 1 purchase_return).'
