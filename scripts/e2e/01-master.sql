-- ============================================================
-- E2E reset · step 01 · master data
-- 灌主檔（locations / stores / brands / categories / member_tiers /
--          suppliers / products / skus / sku_packs / barcodes / prices /
--          expense_categories / petty_cash_accounts / line_channels /
--          post_templates / purchase_approval_thresholds）
--
-- 期望 psql 變數 :tenant_id（reset.sh 從 auth.users.app_metadata 取得後注入）
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- 把 :tenant_id 固定下來避免每行重複型別轉換

-- ── locations（1 倉 + 5 店各一個 location）────────────────────
INSERT INTO locations (tenant_id, code, name, type) VALUES
  (:'tenant_id'::uuid, 'WH-HQ',   '經總倉',   'central_warehouse'),
  (:'tenant_id'::uuid, 'WH-S001', '平鎮店倉', 'store'),
  (:'tenant_id'::uuid, 'WH-S002', '松山店倉', 'store'),
  (:'tenant_id'::uuid, 'WH-S003', '北投店倉', 'store'),
  (:'tenant_id'::uuid, 'WH-S004', '內湖店倉', 'store'),
  (:'tenant_id'::uuid, 'WH-S005', '信義店倉', 'store');

-- ── brands ────────────────────────────────────────────────
INSERT INTO brands (tenant_id, code, name) VALUES
  (:'tenant_id'::uuid, 'BR-LT',  '自有品牌'),
  (:'tenant_id'::uuid, 'BR-IMP', '進口品牌'),
  (:'tenant_id'::uuid, 'BR-OTH', '其他');

-- ── categories（3 層分類樹：level1 大類 → level2 中類 → level3 小類）──
-- level 1（3 大類）
INSERT INTO categories (tenant_id, code, name, level, sort_order) VALUES
  (:'tenant_id'::uuid, 'C-FRESH', '生鮮', 1, 1),
  (:'tenant_id'::uuid, 'C-DRY',   '乾貨', 1, 2),
  (:'tenant_id'::uuid, 'C-COND',  '調味', 1, 3);

-- level 2（9 中類）— 用 parent_id 串到 level 1
INSERT INTO categories (tenant_id, parent_id, code, name, level, sort_order)
SELECT :'tenant_id'::uuid, p.id, x.code, x.name, 2, x.sort
FROM (VALUES
  ('C-FRESH', 'C-FRESH-VEG',   '蔬菜',     1),
  ('C-FRESH', 'C-FRESH-FRUIT', '水果',     2),
  ('C-FRESH', 'C-FRESH-MEAT',  '肉品海鮮', 3),
  ('C-DRY',   'C-DRY-SNACK',   '餅乾零食', 1),
  ('C-DRY',   'C-DRY-RICE',    '米麵雜糧', 2),
  ('C-DRY',   'C-DRY-CAN',     '罐頭',     3),
  ('C-COND',  'C-COND-SAUCE',  '醬料',     1),
  ('C-COND',  'C-COND-VINEGAR','醋類',     2),
  ('C-COND',  'C-COND-SUGAR',  '糖蜜',     3)
) AS x(parent_code, code, name, sort)
JOIN categories p ON p.tenant_id = :'tenant_id'::uuid AND p.code = x.parent_code;

-- level 3（5 小類示範）— 用 parent_id 串到 level 2
INSERT INTO categories (tenant_id, parent_id, code, name, level, sort_order)
SELECT :'tenant_id'::uuid, p.id, x.code, x.name, 3, x.sort
FROM (VALUES
  ('C-DRY-SNACK', 'C-SNACK-CRACKER', '餅乾類',   1),
  ('C-DRY-SNACK', 'C-SNACK-CHIP',    '洋芋片',   2),
  ('C-DRY-RICE',  'C-RICE-BROWN',    '糙米',     1),
  ('C-DRY-RICE',  'C-RICE-WHITE',    '白米',     2),
  ('C-COND-SAUCE','C-SAUCE-SOY',     '醬油',     1)
) AS x(parent_code, code, name, sort)
JOIN categories p ON p.tenant_id = :'tenant_id'::uuid AND p.code = x.parent_code;

-- ── member_tiers ──────────────────────────────────────────
INSERT INTO member_tiers (tenant_id, code, name, sort_order, benefits) VALUES
  (:'tenant_id'::uuid, 'T-NORMAL', '一般會員', 1, '{"points_multiplier":1.0,"member_price_eligible":false}'::jsonb),
  (:'tenant_id'::uuid, 'T-SILVER', '銀卡會員', 2, '{"points_multiplier":1.2,"member_price_eligible":true}'::jsonb),
  (:'tenant_id'::uuid, 'T-GOLD',   '金卡會員', 3, '{"points_multiplier":1.5,"member_price_eligible":true}'::jsonb);

-- ── suppliers ─────────────────────────────────────────────
INSERT INTO suppliers (tenant_id, code, name, contact_name, phone, payment_terms, lead_time_days) VALUES
  (:'tenant_id'::uuid, 'SUP-LOCAL', '本地供應商', '王小明', '02-2345-6789', 'NET30', 3),
  (:'tenant_id'::uuid, 'SUP-JP',    '日本進口商', '田中太郎', '03-3456-7890', 'NET60', 21),
  (:'tenant_id'::uuid, 'SUP-XL',    '小蘭代購',   '小蘭',     '0911-222-333', 'COD',   7);

-- ── stores（5 家，必須在 suppliers 後因為 stores.supplier_id FK）────
INSERT INTO stores (tenant_id, code, name, location_id, notification_mode,
                    pickup_window_days, allowed_payment_methods, supplier_id) VALUES
  (:'tenant_id'::uuid, 'S001', '平鎮店',
   (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-S001'),
   'simple', 5, '["cash","wallet"]'::jsonb,
   (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL')),
  (:'tenant_id'::uuid, 'S002', '松山店',
   (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-S002'),
   'simple', 5, '["cash","wallet"]'::jsonb,
   (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL')),
  (:'tenant_id'::uuid, 'S003', '北投店',
   (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-S003'),
   'simple', 5, '["cash","wallet"]'::jsonb,
   (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL')),
  (:'tenant_id'::uuid, 'S004', '內湖店',
   (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-S004'),
   'simple', 5, '["cash","wallet"]'::jsonb,
   (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL')),
  (:'tenant_id'::uuid, 'S005', '信義店',
   (SELECT id FROM locations WHERE tenant_id = :'tenant_id'::uuid AND code = 'WH-S005'),
   'simple', 5, '["cash","wallet"]'::jsonb,
   (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL'));

-- ── products（10 個）── name / brand_code / category_code / product_code
INSERT INTO products (tenant_id, product_code, name, short_name, brand_id, category_id, status)
SELECT :'tenant_id'::uuid, x.code, x.name, x.short,
       (SELECT id FROM brands     WHERE tenant_id = :'tenant_id'::uuid AND code = x.brand_code),
       (SELECT id FROM categories WHERE tenant_id = :'tenant_id'::uuid AND code = x.cat_code),
       'active'
FROM (VALUES
  ('P001', '日本岡田屋綜合海老蝦餅185g', '海老蝦餅',   'BR-IMP', 'C-DRY'),
  ('P002', '台灣黑糖薑茶塊120g',         '黑糖薑茶',   'BR-LT',  'C-DRY'),
  ('P003', '日本醬油1L',                 '日本醬油',   'BR-IMP', 'C-COND'),
  ('P004', '台灣香米2kg',                '香米2kg',    'BR-LT',  'C-DRY'),
  ('P005', '冷凍魚丸500g',               '魚丸',       'BR-OTH', 'C-FRESH'),
  ('P006', '蜂蜜罐裝500g',               '蜂蜜500g',   'BR-IMP', 'C-COND'),
  ('P007', '中筋麵粉1kg',                '麵粉1kg',    'BR-LT',  'C-DRY'),
  ('P008', '土雞蛋10入',                 '雞蛋10入',   'BR-OTH', 'C-FRESH'),
  ('P009', '糯米醋500ml',                '糯米醋',     'BR-IMP', 'C-COND'),
  ('P010', '綜合餅乾禮盒800g',           '餅乾禮盒',   'BR-IMP', 'C-DRY')
) AS x(code, name, short, brand_code, cat_code);

-- ── skus（每商品一個 SKU，sku_code = SKU-001..010）────────
INSERT INTO skus (tenant_id, product_id, sku_code, base_unit, tax_rate,
                  product_name, category_id, brand_id, status)
SELECT p.tenant_id,
       p.id,
       'SKU-' || RIGHT(p.product_code, 3),
       '個',
       0.05,
       p.name,
       p.category_id,
       p.brand_id,
       'active'
FROM products p
WHERE p.tenant_id = :'tenant_id'::uuid;

-- ── sku_packs（每 SKU 至少一個 default pack；部分 SKU 加 multi-unit）──
-- 1. base unit pack（每 SKU 必有，is_default_sale=TRUE）
INSERT INTO sku_packs (sku_id, unit, qty_in_base, for_sale, for_purchase, for_transfer, is_default_sale)
SELECT id, '個', 1, TRUE, TRUE, TRUE, TRUE
FROM skus
WHERE tenant_id = :'tenant_id'::uuid;

-- 2. P004 香米：個 + 箱(qty=10)（採購用箱、銷售用個）
INSERT INTO sku_packs (sku_id, unit, qty_in_base, for_sale, for_purchase, for_transfer, is_default_sale)
SELECT s.id, '箱', 10, FALSE, TRUE, TRUE, FALSE
FROM skus s WHERE s.tenant_id = :'tenant_id'::uuid AND s.sku_code = 'SKU-004';

-- 3. P008 雞蛋：個 + 盒(qty=10)（銷售用盒）
INSERT INTO sku_packs (sku_id, unit, qty_in_base, for_sale, for_purchase, for_transfer, is_default_sale)
SELECT s.id, '盒', 10, TRUE, TRUE, TRUE, FALSE
FROM skus s WHERE s.tenant_id = :'tenant_id'::uuid AND s.sku_code = 'SKU-008';

-- 4. P010 餅乾：個 + 箱(qty=6)
INSERT INTO sku_packs (sku_id, unit, qty_in_base, for_sale, for_purchase, for_transfer, is_default_sale)
SELECT s.id, '箱', 6, FALSE, TRUE, TRUE, FALSE
FROM skus s WHERE s.tenant_id = :'tenant_id'::uuid AND s.sku_code = 'SKU-010';

-- ── barcodes（每 SKU 一個 internal 條碼）──────────────────
INSERT INTO barcodes (tenant_id, barcode_value, sku_id, unit, pack_qty, type, is_primary)
SELECT s.tenant_id,
       'INT' || LPAD((ROW_NUMBER() OVER (ORDER BY s.id))::text, 9, '0'),
       s.id,
       '個',
       1,
       'internal',
       TRUE
FROM skus s
WHERE s.tenant_id = :'tenant_id'::uuid;

-- ── internal_barcode_sequence（依目前條碼數量推進）────────
INSERT INTO internal_barcode_sequence (tenant_id, next_seq) VALUES
  (:'tenant_id'::uuid, 11);

-- ── prices（每 SKU × 3 tier = 30 筆，零售 retail 也加一筆）────
-- 用 first_user UUID 當 created_by 避免拿不到 NULL
WITH any_user AS (
  SELECT id FROM auth.users LIMIT 1
)
INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, effective_from, created_by)
SELECT s.tenant_id, s.id, 'retail', NULL,
       (CASE s.sku_code
          WHEN 'SKU-001' THEN 135
          WHEN 'SKU-002' THEN 80
          WHEN 'SKU-003' THEN 220
          WHEN 'SKU-004' THEN 180
          WHEN 'SKU-005' THEN 95
          WHEN 'SKU-006' THEN 350
          WHEN 'SKU-007' THEN 65
          WHEN 'SKU-008' THEN 110
          WHEN 'SKU-009' THEN 90
          WHEN 'SKU-010' THEN 480
        END)::numeric,
       NOW(), (SELECT id FROM any_user)
FROM skus s
WHERE s.tenant_id = :'tenant_id'::uuid;

-- 三個 tier 各折扣（金卡 0.85 / 銀卡 0.92 / 一般 1.0）
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     tiers AS (
       SELECT id, code FROM member_tiers WHERE tenant_id = :'tenant_id'::uuid
     ),
     base AS (
       SELECT s.id AS sku_id,
              (CASE s.sku_code
                 WHEN 'SKU-001' THEN 135 WHEN 'SKU-002' THEN 80
                 WHEN 'SKU-003' THEN 220 WHEN 'SKU-004' THEN 180
                 WHEN 'SKU-005' THEN 95  WHEN 'SKU-006' THEN 350
                 WHEN 'SKU-007' THEN 65  WHEN 'SKU-008' THEN 110
                 WHEN 'SKU-009' THEN 90  WHEN 'SKU-010' THEN 480
               END)::numeric AS retail
       FROM skus s
       WHERE s.tenant_id = :'tenant_id'::uuid
     )
INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, effective_from, created_by)
SELECT :'tenant_id'::uuid, b.sku_id, 'member_tier', t.id,
       ROUND(b.retail * (CASE t.code
                           WHEN 'T-GOLD'   THEN 0.85
                           WHEN 'T-SILVER' THEN 0.92
                           ELSE 1.00 END)::numeric, 2),
       NOW(),
       (SELECT id FROM any_user)
FROM base b CROSS JOIN tiers t;

-- ── cost / branch 價（出貨價格防呆 20260705000000：缺成本價/分店價不能出倉）──
-- cost = retail × 0.6、branch = retail × 0.8；少這兩種價黃金路徑派貨會被守衛擋下
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     base AS (
       SELECT s.id AS sku_id, s.tenant_id,
              (CASE s.sku_code
                 WHEN 'SKU-001' THEN 135 WHEN 'SKU-002' THEN 80
                 WHEN 'SKU-003' THEN 220 WHEN 'SKU-004' THEN 180
                 WHEN 'SKU-005' THEN 95  WHEN 'SKU-006' THEN 350
                 WHEN 'SKU-007' THEN 65  WHEN 'SKU-008' THEN 110
                 WHEN 'SKU-009' THEN 90  WHEN 'SKU-010' THEN 480
               END)::numeric AS retail
       FROM skus s
       WHERE s.tenant_id = :'tenant_id'::uuid
     )
INSERT INTO prices (tenant_id, sku_id, scope, scope_id, price, effective_from, created_by)
SELECT b.tenant_id, b.sku_id, x.scope, NULL,
       ROUND(b.retail * x.factor, 2), NOW(), (SELECT id FROM any_user)
FROM base b
CROSS JOIN (VALUES ('cost', 0.6::numeric), ('branch', 0.8::numeric)) AS x(scope, factor);

-- ── expense_categories（5 筆 P&L 科目）────────────────────
INSERT INTO expense_categories (tenant_id, code, name, default_pay_method) VALUES
  (:'tenant_id'::uuid, 'EC-RENT',    '租金',     'company_account'),
  (:'tenant_id'::uuid, 'EC-UTIL',    '水電',     'company_account'),
  (:'tenant_id'::uuid, 'EC-OFF',     '辦公耗材', 'either'),
  (:'tenant_id'::uuid, 'EC-FREIGHT', '運費',     'either'),
  (:'tenant_id'::uuid, 'EC-MISC',    '其他雜支', 'petty_cash');

-- ── petty_cash_accounts（每店一個零用金戶）────────────────
INSERT INTO petty_cash_accounts (tenant_id, store_id, account_name, balance, credit_limit)
SELECT :'tenant_id'::uuid, s.id, '主零用金', 5000, 20000
FROM stores s
WHERE s.tenant_id = :'tenant_id'::uuid;

-- ── line_channels（3 個 channel：主社群 + VIP + 日常）────────
INSERT INTO line_channels (tenant_id, code, name, channel_type, home_store_id, additional_pickup_store_ids)
SELECT :'tenant_id'::uuid, x.code, x.name, x.ctype,
       (SELECT id FROM stores WHERE tenant_id = :'tenant_id'::uuid AND code = x.home),
       x.additional::jsonb
FROM (VALUES
  ('LC-MAIN',  '主社群（測試）',   'open_chat', 'S001',
   '[' || (SELECT string_agg(id::text, ',') FROM stores
            WHERE tenant_id = :'tenant_id'::uuid AND code IN ('S002','S003','S004','S005')) || ']'),
  ('LC-VIP',   '金卡 VIP 群',      'open_chat', 'S002',
   '[' || (SELECT string_agg(id::text, ',') FROM stores
            WHERE tenant_id = :'tenant_id'::uuid AND code IN ('S001','S003')) || ']'),
  ('LC-DAILY', '日常用品群',       'open_chat', 'S003',
   '[]')
) AS x(code, name, ctype, home, additional);

-- ── post_templates（3 個：預設 / 促銷 / 結團）────────────
INSERT INTO post_templates (tenant_id, code, name, body) VALUES
  (:'tenant_id'::uuid, 'PT-DEFAULT', '預設模板',
   '【開團】{{name}}\n截止：{{end_at}}\n商品：{{items}}'),
  (:'tenant_id'::uuid, 'PT-PROMO',   '促銷模板',
   '🔥 限時促銷 🔥\n{{name}}\n優惠價：{{price}}\n截止：{{end_at}}'),
  (:'tenant_id'::uuid, 'PT-CLOSING', '結團模板',
   '【結團通知】{{name}}\n感謝大家的訂購！\n預計到貨：{{arrival_date}}');

-- ── purchase_approval_thresholds（3 級：全域 / 店 / 供應商）──
-- 一個 scope+scope_id 只能有 1 筆 active
INSERT INTO purchase_approval_thresholds (tenant_id, scope, scope_id, threshold_amount, approver_role) VALUES
  (:'tenant_id'::uuid, 'global', NULL, 5000, 'admin');

-- store 層門檻（每店 3000，HQ 角色為 hq_manager 才能 approve）
INSERT INTO purchase_approval_thresholds (tenant_id, scope, scope_id, threshold_amount, approver_role)
SELECT :'tenant_id'::uuid, 'store', s.id, 3000, 'hq_manager'
FROM stores s
WHERE s.tenant_id = :'tenant_id'::uuid AND s.code IN ('S001','S002');

-- supplier 層門檻：JP / XL 因金額大、走 owner 核准
INSERT INTO purchase_approval_thresholds (tenant_id, scope, scope_id, threshold_amount, approver_role)
SELECT :'tenant_id'::uuid, 'supplier', sup.id, 10000, 'owner'
FROM suppliers sup
WHERE sup.tenant_id = :'tenant_id'::uuid AND sup.code IN ('SUP-JP','SUP-XL');

-- ── supplier_skus（多供應商：JP 進口品由 SUP-JP / 雞蛋由 SUP-XL / 其餘 SUP-LOCAL）──
-- 預設由 SUP-LOCAL 提供（10 SKU 全覆蓋，作為 fallback）
INSERT INTO supplier_skus (tenant_id, supplier_id, sku_id, default_unit_cost, pack_qty, is_preferred)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-LOCAL'),
       s.id,
       (CASE s.sku_code
          WHEN 'SKU-001' THEN 90  WHEN 'SKU-002' THEN 50
          WHEN 'SKU-003' THEN 150 WHEN 'SKU-004' THEN 130
          WHEN 'SKU-005' THEN 60  WHEN 'SKU-006' THEN 250
          WHEN 'SKU-007' THEN 40  WHEN 'SKU-008' THEN 75
          WHEN 'SKU-009' THEN 60  WHEN 'SKU-010' THEN 320
        END)::numeric,
       1,
       (s.sku_code NOT IN ('SKU-001','SKU-003','SKU-006','SKU-008','SKU-010'))  -- JP/XL 主供應的設 FALSE
FROM skus s
WHERE s.tenant_id = :'tenant_id'::uuid;

-- SUP-JP 進口品（蝦餅 / 醬油 / 蜂蜜 / 餅乾）
INSERT INTO supplier_skus (tenant_id, supplier_id, sku_id, supplier_sku_code,
                           default_unit_cost, pack_qty, is_preferred)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-JP'),
       s.id,
       'JP-' || s.sku_code,
       (CASE s.sku_code
          WHEN 'SKU-001' THEN 85   -- 比 LOCAL 便宜 5
          WHEN 'SKU-003' THEN 140
          WHEN 'SKU-006' THEN 230
          WHEN 'SKU-010' THEN 300
        END)::numeric,
       1,
       TRUE
FROM skus s
WHERE s.tenant_id = :'tenant_id'::uuid AND s.sku_code IN ('SKU-001','SKU-003','SKU-006','SKU-010');

-- SUP-XL 小蘭（雞蛋）
INSERT INTO supplier_skus (tenant_id, supplier_id, sku_id, supplier_sku_code,
                           default_unit_cost, pack_qty, is_preferred)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM suppliers WHERE tenant_id = :'tenant_id'::uuid AND code = 'SUP-XL'),
       s.id,
       'XL-' || s.sku_code,
       70::numeric,  -- 比 LOCAL 便宜 5
       1,
       TRUE
FROM skus s
WHERE s.tenant_id = :'tenant_id'::uuid AND s.sku_code = 'SKU-008';

COMMIT;

\echo 'master seeded.'
