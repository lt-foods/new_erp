-- ============================================================
-- 補 stock_balances / stock_movements 的 SELECT policy
--
-- 既有狀況：
--   - stock_balances：只有 owner/purchaser/warehouse/reporter (hq_full_read)
--     + store_manager/clerk own location (store_read_own)
--     → admin role 看不到（policy 沒包含）→ 後台庫存頁面讀回 0 rows
--   - stock_movements：RLS enabled 但完全沒 policy → deny all SELECT
--     → admin 後台所有庫存異動報表都壞
--
-- 對照：20260430160000_picking_auth_read_rls 已把 transfers/transfer_items/
-- picking_waves/picking_wave_items/goods_receipts/goods_receipt_items 開給
-- authenticated read。stock_balances 和 stock_movements 是這層補丁的遺漏。
--
-- 策略：
--   1. stock_balances：新增 admin role policy（看本 tenant 全部）；既有
--      hq_full_read / store_read_own 保留
--   2. stock_movements：新增與 stock_balances 對等的 3 條 policy
--      (hq_full_read 包含 admin / store_read_own / 預留)
-- ============================================================

-- ----------------------------------------------------------------
-- 1. stock_balances admin policy（不動既有 policy，避免影響其他角色）
-- ----------------------------------------------------------------
CREATE POLICY hq_admin_read ON stock_balances
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('admin','hq_manager')
  );

-- ----------------------------------------------------------------
-- 2. stock_movements policy (HQ-side + admin + store own)
-- ----------------------------------------------------------------
CREATE POLICY hq_full_read ON stock_movements
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('owner','admin','hq_manager','purchaser','warehouse','reporter')
  );

CREATE POLICY store_read_own ON stock_movements
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('store_manager','store_staff','clerk')
    AND location_id = NULLIF(auth.jwt() ->> 'location_id', '')::bigint
  );

COMMENT ON POLICY hq_admin_read ON stock_balances IS
  'admin / hq_manager 角色讀本 tenant 全部庫存結存。';
COMMENT ON POLICY hq_full_read ON stock_movements IS
  'HQ-side (owner/admin/hq_manager/purchaser/warehouse/reporter) 讀本 tenant 全部庫存異動。';
COMMENT ON POLICY store_read_own ON stock_movements IS
  '門市角色只讀自己 location 的庫存異動。';
