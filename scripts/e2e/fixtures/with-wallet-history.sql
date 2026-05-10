-- ============================================================
-- fixture: with-wallet-history
-- 灌 wallet_ledger 歷史，覆蓋 5 種 type：topup / spend / refund / adjust / reversal
-- 含 R10：wallet topup 反向（reverse）情境
--
-- 灌完餘額：
--   M-TEST-001  →  750  (topup 1000 - spend 300 + refund 50)
--   M-TEST-002  → 4500  (前 base 5000 - spend 500)
--   M-TEST-003  →  200  (topup 200 + topup 100 + reversal -100)
--   M-TEST-INT-001 → 0  (內購不灌)
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- M-TEST-001：topup 1000 → spend 300 → refund 50（balance 1000 → 700 → 750）
DO $$
DECLARE
  v_tenant   UUID := :'tenant_id'::uuid;
  v_member   BIGINT;
  v_operator UUID;
  v_topup_id BIGINT;
  v_spend_id BIGINT;
BEGIN
  SELECT id INTO v_member FROM members
   WHERE tenant_id = v_tenant AND member_no = 'M-TEST-001';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;

  -- 1. topup 1000
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, payment_method, reason, operator_id)
  VALUES (v_tenant, v_member, 1000, 1000, 'topup',
          'seed', 'cash', 'E2E: 加值 1000', v_operator)
  RETURNING id INTO v_topup_id;

  -- 2. spend 300
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, reason, operator_id)
  VALUES (v_tenant, v_member, -300, 700, 'spend',
          'seed', 'E2E: 訂單付款 300', v_operator)
  RETURNING id INTO v_spend_id;

  -- 3. refund 50（補貼）
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, reason, operator_id)
  VALUES (v_tenant, v_member, 50, 750, 'refund',
          'seed', 'E2E: 客訴補償 50', v_operator);

  -- 同步 wallet_balances
  UPDATE wallet_balances
     SET balance = 750, version = 3, last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = v_tenant AND member_id = v_member;
END $$;

-- M-TEST-002：base 已給 5000；加 spend 500（balance 5000 → 4500）
DO $$
DECLARE
  v_tenant   UUID := :'tenant_id'::uuid;
  v_member   BIGINT;
  v_operator UUID;
BEGIN
  SELECT id INTO v_member FROM members
   WHERE tenant_id = v_tenant AND member_no = 'M-TEST-002';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;

  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, reason, operator_id)
  VALUES (v_tenant, v_member, -500, 4500, 'spend',
          'seed', 'E2E: 黃金路徑 預扣 500', v_operator);

  UPDATE wallet_balances
     SET balance = 4500, version = version + 1,
         last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = v_tenant AND member_id = v_member;
END $$;

-- M-TEST-003：topup 200 → topup 100 → reverse 100（R10 反向情境）
-- balance: 0 → 200 → 300 → 200
DO $$
DECLARE
  v_tenant      UUID := :'tenant_id'::uuid;
  v_member      BIGINT;
  v_operator    UUID;
  v_topup1_id   BIGINT;
  v_topup2_id   BIGINT;  -- 待反向的 topup
  v_reversal_id BIGINT;
BEGIN
  SELECT id INTO v_member FROM members
   WHERE tenant_id = v_tenant AND member_no = 'M-TEST-003';
  SELECT id INTO v_operator FROM auth.users LIMIT 1;

  -- topup +200
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, payment_method, reason, operator_id)
  VALUES (v_tenant, v_member, 200, 200, 'topup',
          'seed', 'cash', 'E2E: 加值 200', v_operator)
  RETURNING id INTO v_topup1_id;

  -- topup +100（誤刷、稍後反向）
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             source_type, payment_method, reason, operator_id)
  VALUES (v_tenant, v_member, 100, 300, 'topup',
          'seed', 'credit_card', 'E2E: 誤刷 100（將反向）', v_operator)
  RETURNING id INTO v_topup2_id;

  -- reversal -100 → 反向 v_topup2
  INSERT INTO wallet_ledger (tenant_id, member_id, change, balance_after, type,
                             reverses, reason, operator_id)
  VALUES (v_tenant, v_member, -100, 200, 'reversal',
          v_topup2_id, 'E2E: 取消誤刷', v_operator)
  RETURNING id INTO v_reversal_id;

  -- 互填 reversed_by（讓查詢能反查）
  -- wallet_ledger 是 append-only trigger 會擋；要先暫關再開
  ALTER TABLE wallet_ledger DISABLE TRIGGER trg_no_update_wallet;
  UPDATE wallet_ledger SET reversed_by = v_reversal_id WHERE id = v_topup2_id;
  ALTER TABLE wallet_ledger ENABLE TRIGGER trg_no_update_wallet;

  -- 同步 wallet_balances
  UPDATE wallet_balances
     SET balance = 200, version = 3, last_movement_at = NOW(), updated_at = NOW()
   WHERE tenant_id = v_tenant AND member_id = v_member;
END $$;

COMMIT;

\echo 'fixture with-wallet-history seeded (M001=750, M002=4500, M003=200 with R10 reversal).'
