-- ============================================================
-- E2E reset · step 02 · base fixtures
-- 所有 scenario 都會跑這支：
--   - 4 個測試會員：full × 3 (normal / silver / gold) + store_internal × 1
--   - customer_line_aliases（舊版暱稱表）+ member_line_bindings（新版 LINE Login 表）並存
--   - member_cards 一張（每會員）
--   - member_points_balance / wallet_balances 初始化
--   - M-TEST-002 wallet 預灌 $5000（master 黃金路徑用、wallet_ledger 有 topup row）
--
-- 不動 auth.users（員工帳號 / 員工→店家的綁定一律手動透過 Supabase
-- Dashboard 維護 raw_app_meta_data.location_id）
-- ============================================================
\set ON_ERROR_STOP on

BEGIN;

-- ── 4 個測試會員 ──────────────────────────────────────────
-- M-TEST-001 普通會員、家店 S001
INSERT INTO members (
  tenant_id, member_no, phone_hash, name, member_type,
  tier_id, home_store_id, status, joined_at
) VALUES (
  :'tenant_id'::uuid, 'M-TEST-001',
  encode(digest('0900000001', 'sha256'), 'hex'), '測試小明', 'full',
  (SELECT id FROM member_tiers WHERE tenant_id = :'tenant_id'::uuid AND code = 'T-NORMAL'),
  (SELECT id FROM stores       WHERE tenant_id = :'tenant_id'::uuid AND code = 'S001'),
  'active', NOW()
);

-- M-TEST-002 金卡、家店 S002（master 黃金路徑要用、wallet 預灌 5000）
INSERT INTO members (
  tenant_id, member_no, phone_hash, name, member_type,
  tier_id, home_store_id, status, joined_at
) VALUES (
  :'tenant_id'::uuid, 'M-TEST-002',
  encode(digest('0900000002', 'sha256'), 'hex'), '測試小華', 'full',
  (SELECT id FROM member_tiers WHERE tenant_id = :'tenant_id'::uuid AND code = 'T-GOLD'),
  (SELECT id FROM stores       WHERE tenant_id = :'tenant_id'::uuid AND code = 'S002'),
  'active', NOW()
);

-- M-TEST-003 銀卡、家店 S003
INSERT INTO members (
  tenant_id, member_no, phone_hash, name, member_type,
  tier_id, home_store_id, status, joined_at
) VALUES (
  :'tenant_id'::uuid, 'M-TEST-003',
  encode(digest('0900000003', 'sha256'), 'hex'), '測試小芳', 'full',
  (SELECT id FROM member_tiers WHERE tenant_id = :'tenant_id'::uuid AND code = 'T-SILVER'),
  (SELECT id FROM stores       WHERE tenant_id = :'tenant_id'::uuid AND code = 'S003'),
  'active', NOW()
);

-- M-TEST-INT-001 店內購買（store_internal、S001 平鎮店店長代叫貨用）
INSERT INTO members (
  tenant_id, member_no, phone_hash, name, member_type,
  tier_id, home_store_id, status, joined_at
) VALUES (
  :'tenant_id'::uuid, 'M-TEST-INT-001',
  encode(digest('0900000099', 'sha256'), 'hex'), 'S001 內購', 'store_internal',
  (SELECT id FROM member_tiers WHERE tenant_id = :'tenant_id'::uuid AND code = 'T-NORMAL'),
  (SELECT id FROM stores       WHERE tenant_id = :'tenant_id'::uuid AND code = 'S001'),
  'active', NOW()
);

-- ── customer_line_aliases（舊版暱稱表）─────────────────────
INSERT INTO customer_line_aliases (tenant_id, channel_id, nickname, member_id)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM line_channels WHERE tenant_id = :'tenant_id'::uuid AND code = 'LC-MAIN'),
       n.nickname,
       (SELECT id FROM members WHERE tenant_id = :'tenant_id'::uuid AND member_no = n.member_no)
FROM (VALUES
  ('小明', 'M-TEST-001'),
  ('小華', 'M-TEST-002'),
  ('小芳', 'M-TEST-003')
) AS n(nickname, member_no);

-- 小華也在 LC-VIP 群（同會員跨頻道可有不同暱稱）
INSERT INTO customer_line_aliases (tenant_id, channel_id, nickname, member_id)
SELECT :'tenant_id'::uuid,
       (SELECT id FROM line_channels WHERE tenant_id = :'tenant_id'::uuid AND code = 'LC-VIP'),
       'VIP小華',
       (SELECT id FROM members WHERE tenant_id = :'tenant_id'::uuid AND member_no = 'M-TEST-002');

-- ── member_line_bindings（新版 LINE Login 綁定表）────────────
-- 一會員可在多店綁定；line_user_id 用 fixture 固定值（前綴 U + 31 chars）
INSERT INTO member_line_bindings (tenant_id, store_id, member_id, line_user_id, bound_at)
SELECT :'tenant_id'::uuid,
       m.home_store_id,
       m.id,
       'U' || lpad(replace(m.member_no, '-', ''), 31, '0'),
       NOW()
FROM members m
WHERE m.tenant_id = :'tenant_id'::uuid
  AND m.member_no IN ('M-TEST-001','M-TEST-002','M-TEST-003');

-- ── member_cards（每會員一張 virtual）─────────────────────
INSERT INTO member_cards (tenant_id, member_id, card_no, type, is_primary, status)
SELECT :'tenant_id'::uuid, m.id,
       'CARD-' || REPLACE(m.member_no, '-', ''),
       'virtual', TRUE, 'active'
FROM members m
WHERE m.tenant_id = :'tenant_id'::uuid;

-- ── points + wallet 餘額初始化（4 會員都 0）───────────────
INSERT INTO member_points_balance (tenant_id, member_id, balance)
SELECT tenant_id, id, 0 FROM members WHERE tenant_id = :'tenant_id'::uuid;

INSERT INTO wallet_balances (tenant_id, member_id, balance)
SELECT tenant_id, id, 0 FROM members WHERE tenant_id = :'tenant_id'::uuid;

-- ── M-TEST-002 wallet 預灌 5000（黃金路徑要用）──────────
WITH any_user AS (SELECT id FROM auth.users LIMIT 1),
     m2       AS (SELECT id FROM members WHERE tenant_id = :'tenant_id'::uuid AND member_no = 'M-TEST-002')
INSERT INTO wallet_ledger (
  tenant_id, member_id, change, balance_after, type,
  source_type, source_id, payment_method, reason, operator_id
)
SELECT :'tenant_id'::uuid, (SELECT id FROM m2),
       5000, 5000, 'topup',
       'seed', NULL, 'cash', 'E2E base seed: M-TEST-002 預灌 5000',
       (SELECT id FROM any_user);

UPDATE wallet_balances
   SET balance = 5000, version = 1, last_movement_at = NOW(), updated_at = NOW()
 WHERE tenant_id = :'tenant_id'::uuid
   AND member_id = (SELECT id FROM members WHERE tenant_id = :'tenant_id'::uuid AND member_no = 'M-TEST-002');

COMMIT;

\echo 'base fixtures seeded (4 members; M-TEST-002 wallet=5000).'
