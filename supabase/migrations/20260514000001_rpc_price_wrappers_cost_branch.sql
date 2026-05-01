-- ============================================================
-- 成本價 / 分店共用價 wrapper RPC
--
-- 沿用 rpc_set_retail_price / rpc_set_store_price 的形狀（20260424120001_price_wrappers.sql）
-- 都從 JWT 讀 tenant_id、auth.uid() 讀 operator，呼叫既有 rpc_upsert_price。
--
-- Role 限制：
--   - rpc_set_cost_price   只給 owner/admin/hq_manager/hq_accountant
--   - rpc_set_branch_price 多給 store_manager
-- (RLS 雖也擋讀、但寫入要在 RPC body 內主動 check 才會擋住、因為 SECURITY DEFINER 會繞過 RLS)
--
-- Scope: 只加 RPC、不動 schema
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_set_cost_price(BIGINT, NUMERIC, TIMESTAMPTZ, TEXT);
--   DROP FUNCTION IF EXISTS public.rpc_set_branch_price(BIGINT, NUMERIC, TIMESTAMPTZ, TEXT);
-- ============================================================

-- ----------------------------------------------------------------
-- 設定成本價（cost）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_cost_price(
  p_sku_id         BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_reason         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  -- role check：成本價只給總部 role
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant') THEN
    RAISE EXCEPTION 'permission denied: role % cannot set cost price', v_role;
  END IF;

  -- tenant 比對
  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sku % not in tenant', p_sku_id;
  END IF;

  -- 寫入（scope='cost', scope_id=NULL）
  RETURN public.rpc_upsert_price(
    v_tenant, p_sku_id, 'cost', NULL, p_price, p_effective_from, p_reason, v_user
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_set_cost_price(BIGINT, NUMERIC, TIMESTAMPTZ, TEXT) IS
  'Set cost price (scope=cost, scope_id=NULL). HQ roles only (owner/admin/hq_manager/hq_accountant). Versioned append-only via rpc_upsert_price.';

GRANT EXECUTE ON FUNCTION public.rpc_set_cost_price(BIGINT, NUMERIC, TIMESTAMPTZ, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------
-- 設定全分店共用分店價（branch）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_set_branch_price(
  p_sku_id         BIGINT,
  p_price          NUMERIC,
  p_effective_from TIMESTAMPTZ DEFAULT NOW(),
  p_reason         TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := auth.uid();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  -- role check：分店共用價給總部 + store_manager
  IF v_role NOT IN ('owner','admin','hq_manager','hq_accountant','store_manager') THEN
    RAISE EXCEPTION 'permission denied: role % cannot set branch price', v_role;
  END IF;

  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sku % not in tenant', p_sku_id;
  END IF;

  -- 寫入（scope='branch', scope_id=NULL，全分店共用）
  RETURN public.rpc_upsert_price(
    v_tenant, p_sku_id, 'branch', NULL, p_price, p_effective_from, p_reason, v_user
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_set_branch_price(BIGINT, NUMERIC, TIMESTAMPTZ, TEXT) IS
  'Set branch-wide price (scope=branch, scope_id=NULL — single price for all stores, distinct from retail). HQ roles + store_manager. Versioned append-only via rpc_upsert_price.';

GRANT EXECUTE ON FUNCTION public.rpc_set_branch_price(BIGINT, NUMERIC, TIMESTAMPTZ, TEXT)
  TO authenticated;
