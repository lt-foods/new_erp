-- ============================================================
-- fixture: with-monthly-settlement
-- 店月結算：HQ 對加盟店每月計算貨款（賣斷制）
-- 依賴：with-transfers 已建 hq_to_store transfers + stock_movements
--
-- 建立 2 筆月結算（draft）：
--   SMS-S001  S001 平鎮店 — 來自 TF-0005 已收 8 件 SKU-006 × cost 230 = 1840
--   SMS-S002  S002 松山店 — 來自 TF-0006 已收 6 件 SKU-008 × cost 75  =  450
--
-- 都是當月、status='draft'。confirm + 產 vendor_bill 留給測試 RPC 觸發。
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- ── S001 月結算 ──────────────────────────────────────────
DO $$
DECLARE
  v_tenant     UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_month      DATE := DATE_TRUNC('month', NOW())::date;
  v_store      BIGINT;
  v_settlement BIGINT;
  v_operator   UUID;
  v_tf         BIGINT;
  v_ti         BIGINT;
  v_sku        BIGINT;
BEGIN
  SELECT id INTO v_store FROM stores
   WHERE tenant_id = v_tenant AND code = 'S001';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  SELECT id INTO v_tf FROM transfers
   WHERE tenant_id = v_tenant AND transfer_no = 'TF-0005';
  SELECT id, sku_id INTO v_ti, v_sku FROM transfer_items
   WHERE transfer_id = v_tf;

  INSERT INTO store_monthly_settlements (
    tenant_id, settlement_month, store_id,
    payable_amount, transfer_count, item_count,
    status, notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_month, v_store,
    1840, 1, 1,
    'draft',
    'E2E SMS-S001: TF-0005 partial 8/10（R6b 損壞 2）×230 = 1840',
    v_operator, v_operator
  ) RETURNING id INTO v_settlement;

  INSERT INTO store_monthly_settlement_items (
    tenant_id, settlement_id, transfer_id, transfer_item_id, sku_id,
    qty_received, unit_cost, line_amount, received_at
  ) VALUES (
    v_tenant, v_settlement, v_tf, v_ti, v_sku,
    8, 230, 1840, NOW() - INTERVAL '12 hours'
  );
END $$;

-- ── S002 月結算 ──────────────────────────────────────────
DO $$
DECLARE
  v_tenant     UUID := (SELECT (raw_app_meta_data->>'tenant_id')::uuid FROM auth.users WHERE raw_app_meta_data ? 'tenant_id' LIMIT 1);
  v_month      DATE := DATE_TRUNC('month', NOW())::date;
  v_store      BIGINT;
  v_settlement BIGINT;
  v_operator   UUID;
  v_tf         BIGINT;
  v_ti         BIGINT;
  v_sku        BIGINT;
BEGIN
  SELECT id INTO v_store FROM stores
   WHERE tenant_id = v_tenant AND code = 'S002';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;
  SELECT id INTO v_tf FROM transfers
   WHERE tenant_id = v_tenant AND transfer_no = 'TF-0006';
  SELECT id, sku_id INTO v_ti, v_sku FROM transfer_items
   WHERE transfer_id = v_tf;

  INSERT INTO store_monthly_settlements (
    tenant_id, settlement_month, store_id,
    payable_amount, transfer_count, item_count,
    status, notes, created_by, updated_by
  ) VALUES (
    v_tenant, v_month, v_store,
    450, 1, 1,
    'draft',
    'E2E SMS-S002: TF-0006 received 6 ×75 = 450',
    v_operator, v_operator
  ) RETURNING id INTO v_settlement;

  INSERT INTO store_monthly_settlement_items (
    tenant_id, settlement_id, transfer_id, transfer_item_id, sku_id,
    qty_received, unit_cost, line_amount, received_at
  ) VALUES (
    v_tenant, v_settlement, v_tf, v_ti, v_sku,
    6, 75, 450, NOW() - INTERVAL '12 hours'
  );
END $$;

COMMIT;

\echo 'fixture with-monthly-settlement seeded (2 draft settlements: S001=1840, S002=450).'
