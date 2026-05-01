-- ============================================================
-- prices.scope CHECK 擴充 + RLS 依 role × scope 分層讀取
--
-- 背景：現行 prices.scope 只支援 retail / store / member_tier / promo，
-- 且 RLS 只擋 tenant 層、所有同 tenant role 都看得到全部 scope。
--
-- 需求 (BRIEF: docs/TEST-candidate-to-draft-and-pricing.md)：
--   1. 加 cost / branch 兩個 scope value
--      - cost   = 進貨成本價（限總部 role 看）
--      - branch = 全分店共用單一分店價（區別零售價；限 store_manager+/總部 看）
--   2. RLS 依 role 過濾：
--      - owner / admin / hq_manager / hq_accountant      → 看全部 scope
--      - store_manager                                    → retail + store + branch + member_tier + promo（不含 cost）
--      - store_staff                                      → retail + store + member_tier + promo（不含 cost / branch）
--      - 其他 role / 無 role                              → 同 store_staff 待遇
--
-- Scope: 只動 prices 表 CHECK + RLS policy；不動既有 RPC 行為（rpc_upsert_price 仍可寫所有 scope）
-- Rollback:
--   ALTER TABLE prices DROP CONSTRAINT prices_scope_check;
--   ALTER TABLE prices ADD CONSTRAINT prices_scope_check CHECK (scope IN ('retail','store','member_tier','promo'));
--   DROP POLICY IF EXISTS read_prices_role_scoped ON prices;
--   CREATE POLICY read_tenant_prices ON prices FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 擴充 prices.scope CHECK 接受 'cost' 和 'branch'
-- ----------------------------------------------------------------

ALTER TABLE prices DROP CONSTRAINT IF EXISTS prices_scope_check;

ALTER TABLE prices ADD CONSTRAINT prices_scope_check
  CHECK (scope IN ('retail','store','member_tier','promo','cost','branch'));

COMMENT ON COLUMN prices.scope IS
  'retail=零售價(scope_id NULL) / store=分店覆寫(scope_id=store_location_id) / branch=全分店共用分店價(scope_id NULL) / cost=進貨成本(scope_id NULL) / member_tier=會員等級(scope_id=tier_id) / promo=促銷(scope_id=promotion_id)';

-- ----------------------------------------------------------------
-- 2. 砍舊 read policy、改用依 role × scope 分層的新 policy
-- ----------------------------------------------------------------

DROP POLICY IF EXISTS read_tenant_prices ON prices;

-- 新 policy：tenant 比對 + 依 role 過濾 cost/branch
-- 寫法沿用 community_product_candidates ccp_hq_all 的 jwt path（app_metadata.role）
CREATE POLICY read_prices_role_scoped ON prices
  FOR SELECT
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      -- 公開 scope：任何同 tenant role 都看得到
      scope IN ('retail','store','member_tier','promo')
      OR
      -- cost：僅總部 role 看
      (scope = 'cost'
       AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           = ANY (ARRAY['owner','admin','hq_manager','hq_accountant']))
      OR
      -- branch：總部 role + store_manager 看（不給 store_staff）
      (scope = 'branch'
       AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
           = ANY (ARRAY['owner','admin','hq_manager','hq_accountant','store_manager']))
    )
  );

COMMENT ON POLICY read_prices_role_scoped ON prices IS
  '依 role × scope 分層：總部全看 / store_manager 不看 cost / store_staff 不看 cost+branch';
