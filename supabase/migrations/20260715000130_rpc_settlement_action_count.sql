-- ============================================================
-- 2026-07-15: 月結對帳待辦數 rpc_settlement_action_count
--
-- 需求：電子對帳沒有推播，改在側欄「月結算」選單掛小數字當通知。
-- 口徑（依 caller 角色，讀 auth.jwt()）：
--   - 分店（store_manager / store_staff）：自己店（_jwt_store_ids()）
--     status IN ('sent','confirmed') —— 待核對 + 待匯款，都是店家要動作的。
--     （disputed 是等總部處理、remitted 是等總部收款，不算店家待辦）
--   - 總部（_settlement_caller_is_hq()，含 '' legacy admin）：全 tenant
--     status IN ('disputed','remitted') —— 待處理爭議 + 待確認收款。
--   - 其他 → 0。
--
-- 新函式，無歷史版本。
-- Rollback：DROP FUNCTION public.rpc_settlement_action_count();
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_settlement_action_count()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT CASE
    WHEN COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '')
         IN ('store_manager', 'store_staff') THEN (
      SELECT COUNT(*)::int
        FROM store_monthly_settlements s
       WHERE s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND s.store_id = ANY (public._jwt_store_ids())
         AND s.status IN ('sent', 'confirmed')
    )
    WHEN public._settlement_caller_is_hq() THEN (
      SELECT COUNT(*)::int
        FROM store_monthly_settlements s
       WHERE s.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND s.status IN ('disputed', 'remitted')
    )
    ELSE 0
  END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_settlement_action_count() TO authenticated;

COMMENT ON FUNCTION public.rpc_settlement_action_count IS
  '側欄月結算 badge 用：分店回自己店 sent+confirmed 筆數（待核對/待匯款）；'
  '總部回全 tenant disputed+remitted 筆數（待處理爭議/待確認收款）。';
