-- ============================================================
-- fixture: with-orders
-- 依賴 with-campaign 已建立活動。直接 \i 串入 with-campaign 確保獨立可跑。
--
-- 8 筆顧客訂單覆蓋正常 + 反向情境：
--   ORD-0001  pending              （CAMP-001、M-TEST-001、平鎮取貨）
--   ORD-0002  reserved             （CAMP-002、M-TEST-002、松山取貨、wallet pay）
--   ORD-0003  ready                （CAMP-009、M-TEST-001）
--   ORD-0004  completed            （CAMP-010、M-TEST-002、含 pickup_event）
--   ORD-0005  cancelled            （CAMP-003、M-TEST-001、soft-cancel 負數情境）
--   ORD-0006  completed → returned （CAMP-005、M-TEST-001、R8 顧客退貨情境 + wallet refund）
--   ORD-0007  partially_completed  （CAMP-006、M-TEST-002、R4 缺貨情境 + shortage_events）
--   ORD-0008  pending              （CAMP-008、M-TEST-003、銀卡 0.92 + 88 折促銷雙折扣）
-- ============================================================
\set ON_ERROR_STOP on

\ir with-campaign.sql

BEGIN;

-- ── 8 筆訂單單頭 ────────────────────────────────────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO customer_orders (
  tenant_id, order_no, campaign_id, channel_id, member_id,
  nickname_snapshot, pickup_store_id, pickup_deadline, status, created_by, notes
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       x.order_no,
       (SELECT id FROM group_buy_campaigns WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND campaign_no = x.camp),
       (SELECT id FROM line_channels WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = x.channel_code),
       (SELECT id FROM members WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND member_no = x.member_no),
       x.nickname,
       (SELECT id FROM stores  WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = x.store),
       (CURRENT_DATE + 14)::date,
       x.status,
       (SELECT id FROM any_user),
       x.notes
FROM (VALUES
  ('ORD-0001', 'CAMP-001', 'LC-MAIN', 'M-TEST-001', '小明',  'S001', 'pending',              NULL),
  ('ORD-0002', 'CAMP-002', 'LC-MAIN', 'M-TEST-002', '小華',  'S002', 'confirmed',            'wallet 付款（confirmed = 預扣已鎖）'),
  ('ORD-0003', 'CAMP-009', 'LC-MAIN', 'M-TEST-001', '小明',  'S001', 'ready',                NULL),
  ('ORD-0004', 'CAMP-010', 'LC-MAIN', 'M-TEST-002', '小華',  'S002', 'completed',            '已取貨'),
  ('ORD-0005', 'CAMP-003', 'LC-MAIN', 'M-TEST-001', '小明',  'S001', 'cancelled',            'R4: soft-cancel 負數情境'),
  ('ORD-0006', 'CAMP-005', 'LC-MAIN', 'M-TEST-001', '小明',  'S001', 'completed',            'R8: 取貨後反悔退貨'),
  ('ORD-0007', 'CAMP-006', 'LC-MAIN', 'M-TEST-002', '小華',  'S002', 'partially_completed',  'R4: 部分缺貨'),
  ('ORD-0008', 'CAMP-008', 'LC-MAIN', 'M-TEST-003', '小芳',  'S003', 'pending',              '88折促銷 + 銀卡 0.92')
) AS x(order_no, camp, channel_code, member_no, nickname, store, status, notes);

-- ── 訂單明細：依各訂單情境分別灌 ────────────────────────
-- ORD-0001 ~ ORD-0004 沿用原 mapping（依 campaign_items sort_order）
INSERT INTO customer_order_items (
  tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
)
SELECT
  (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.id, ci.id, ci.sku_id,
  CASE WHEN ci.sort_order = 1 THEN 2 ELSE 1 END,
  ci.unit_price,
  CASE o.status
    WHEN 'pending'   THEN 'pending'
    WHEN 'confirmed' THEN 'reserved'
    WHEN 'ready'     THEN 'ready'
    WHEN 'completed' THEN 'picked_up'
  END,
  'manual'
FROM customer_orders o
JOIN campaign_items ci ON ci.campaign_id = o.campaign_id AND ci.tenant_id = o.tenant_id
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no IN ('ORD-0001','ORD-0002','ORD-0003','ORD-0004');

-- ORD-0005 cancelled：原訂 SKU-006 蜂蜜 ×3 → cancelled（負數情境用）
INSERT INTO customer_order_items (
  tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.id, ci.id, ci.sku_id, 3, ci.unit_price, 'cancelled', 'manual'
FROM customer_orders o
JOIN campaign_items ci ON ci.campaign_id = o.campaign_id AND ci.sort_order = 1
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no = 'ORD-0005';

-- ORD-0006 completed → returned（R8 退貨情境）
-- 訂 SKU-002 黑糖薑茶 ×2 + SKU-007 麵粉 ×1，已 picked_up（之後 R8 用 movement+wallet 反映退貨）
INSERT INTO customer_order_items (
  tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
)
SELECT
  (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.id, ci.id, ci.sku_id,
  CASE WHEN ci.sort_order = 1 THEN 2 ELSE 1 END,
  ci.unit_price, 'picked_up', 'manual'
FROM customer_orders o
JOIN campaign_items ci ON ci.campaign_id = o.campaign_id AND ci.tenant_id = o.tenant_id
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no = 'ORD-0006';

-- ORD-0007 partially_completed（R4 缺貨）
-- 訂 SKU-009 糯米醋 ×3，但只供應 2 個 → 1 個 shortage
INSERT INTO customer_order_items (
  tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.id, ci.id, ci.sku_id, 3, ci.unit_price, 'partially_picked_up', 'manual'
FROM customer_orders o
JOIN campaign_items ci ON ci.campaign_id = o.campaign_id AND ci.sort_order = 1
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no = 'ORD-0007';

-- ORD-0008 pending：銀卡 + 88 折促銷雙折扣 (CAMP-008 SKU-007 麵粉 65 → 65*0.92*0.88 = 52.62)
INSERT INTO customer_order_items (
  tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status, source, notes
)
SELECT
  (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.id, ci.id, ci.sku_id,
  2,
  ROUND(ci.unit_price * 0.92 * 0.88, 4),  -- 銀卡 0.92 × 88折 = 0.8096
  'pending', 'manual',
  '88折 + 銀卡雙折扣'
FROM customer_orders o
JOIN campaign_items ci ON ci.campaign_id = o.campaign_id AND ci.sort_order = 1
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no = 'ORD-0008';

-- ── customer_order_sources（訂單來源 audit 4 種）─────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1)
INSERT INTO customer_order_sources (
  tenant_id, campaign_id, order_id, source_type, screenshot_url, created_by
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       o.campaign_id,
       o.id,
       x.stype,
       x.url,
       (SELECT id FROM any_user)
FROM customer_orders o
JOIN (VALUES
  ('ORD-0001', 'screenshot',   'https://example.com/screenshot/ord-0001.jpg'),
  ('ORD-0002', 'manual_paste', NULL),
  ('ORD-0008', 'csv',          NULL)
) AS x(order_no, stype, url) ON o.order_no = x.order_no
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);

-- ── R4 缺貨事件（ORD-0007）──────────────────────────────
INSERT INTO order_shortage_events (
  tenant_id, campaign_id, order_id, sku_id, requested_qty, fulfilled_qty, reason
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.campaign_id, o.id, coi.sku_id,
       coi.qty, 2, 'R4: 確認時發現庫存只有 2 個（請求 3 個）'
FROM customer_orders o
JOIN customer_order_items coi ON coi.order_id = o.id
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no = 'ORD-0007';

-- ── ORD-0004 取貨事件（completed）+ ORD-0006 取貨事件（後 R8）──
INSERT INTO order_pickup_events (
  tenant_id, order_id, pickup_store_id, event_type, item_ids, created_by
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1), o.id, o.pickup_store_id, 'picked_up',
       (SELECT jsonb_agg(coi.id) FROM customer_order_items coi WHERE coi.order_id = o.id),
       o.created_by
FROM customer_orders o
WHERE o.tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND o.order_no IN ('ORD-0004','ORD-0006');

-- ── R8: ORD-0006 SKU-002 黑糖薑茶 ×1 取貨後退回 ────────────
-- step 1: stock_movement type='customer_return' 把 1 個還回 S001 平鎮店
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     o AS (SELECT * FROM customer_orders WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND order_no = 'ORD-0006'),
     coi AS (SELECT coi.* FROM customer_order_items coi
              JOIN o ON coi.order_id = o.id
              JOIN skus s ON s.id = coi.sku_id
             WHERE s.sku_code = 'SKU-002')
INSERT INTO stock_movements (
  tenant_id, location_id, sku_id, quantity, unit_cost,
  movement_type, source_doc_type, source_doc_id, source_doc_line_id,
  reason, operator_id
)
SELECT (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1),
       (SELECT location_id FROM stores WHERE tenant_id = (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1) AND code = 'S001'),
       (SELECT sku_id FROM coi),
       1, 50,  -- 用 SUP-LOCAL 黑糖薑茶 cost
       'customer_return',
       'customer_order', (SELECT id FROM o), (SELECT id FROM coi),
       'R8: ORD-0006 顧客取貨後反悔退回 SKU-002 ×1',
       (SELECT id FROM any_user);

-- step 2: wallet refund（M-TEST-001 退 80 = SKU-002 unit_price）
DO $$
DECLARE
  v_tenant   UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_member   BIGINT;
  v_balance  NUMERIC;
  v_operator UUID;
  v_order_id BIGINT;
BEGIN
  SELECT id INTO v_member FROM members
   WHERE tenant_id = v_tenant AND member_no = 'M-TEST-001';
  SELECT id INTO v_order_id FROM customer_orders
   WHERE tenant_id = v_tenant AND order_no = 'ORD-0006';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  SELECT balance INTO v_balance FROM wallet_balances
   WHERE tenant_id = v_tenant AND member_id = v_member;

  -- M-TEST-001 base+wallet-history 後 balance = 750；退款 +80 → 830
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, source_id, reason, operator_id)
  VALUES (v_tenant, v_member, 80, v_balance + 80, 'refund',
          'customer_order', v_order_id, 'R8: ORD-0006 取貨後退貨補回 wallet',
          v_operator);

  UPDATE wallet_balances
     SET balance = v_balance + 80, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = v_tenant AND member_id = v_member;
END $$;

COMMIT;

\echo 'fixture with-orders seeded (8 orders incl. R4 shortage + R8 customer return + 88折).'
