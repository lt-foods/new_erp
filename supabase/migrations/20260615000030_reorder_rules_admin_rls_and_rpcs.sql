-- ============================================================
-- reorder_rules：admin 讀取 RLS + 維護 RPC
--
-- 缺口：reorder_rules 在 20260422120003 ENABLE ROW LEVEL SECURITY
-- 但從未加任何 policy → admin 連 SELECT 都被靜默拒（0 rows）。
-- 後果：/inventory「只看低於補貨點」filter 一直回空（不是沒資料、是讀不到）。
--
-- 本 migration：
--   1. 補 admin/HQ SELECT policy（對齊 20260614000042 stock_admin_read 模式）
--      → 順帶修復 /inventory 低庫存 filter
--   2. rpc_upsert_reorder_rule / rpc_delete_reorder_rule（SECURITY DEFINER）
--      寫入只走 RPC，不開 broad PATCH policy（避 PostgREST 直寫副作用）
--
-- TEST: docs/TEST-reorder-rules-maintenance.md
-- ============================================================

-- ----------------------------------------------------------------
-- 1. admin / HQ 讀取 policy
-- ----------------------------------------------------------------
CREATE POLICY hq_admin_read ON reorder_rules
  FOR SELECT TO authenticated USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '')
        IN ('owner','admin','hq_manager','purchaser','warehouse','reporter')
  );

COMMENT ON POLICY hq_admin_read ON reorder_rules IS
  'HQ-side (owner/admin/hq_manager/purchaser/warehouse/reporter) 讀本 tenant 補貨規則。寫入走 SECURITY DEFINER RPC。';

-- ----------------------------------------------------------------
-- 2. upsert 補貨規則
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_upsert_reorder_rule(
  p_location_id    BIGINT,
  p_sku_id         BIGINT,
  p_safety_stock   NUMERIC DEFAULT 0,
  p_reorder_point  NUMERIC DEFAULT 0,
  p_max_stock      NUMERIC DEFAULT NULL,
  p_lead_time_days INT     DEFAULT NULL,
  p_operator       UUID    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_user   UUID := COALESCE(p_operator, auth.uid());
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_ss     NUMERIC := COALESCE(p_safety_stock, 0);
  v_rp     NUMERIC := COALESCE(p_reorder_point, 0);
  v_existed BOOLEAN;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    RAISE EXCEPTION 'permission denied: role % cannot maintain reorder rules', v_role;
  END IF;

  IF v_ss < 0 OR v_rp < 0 OR (p_max_stock IS NOT NULL AND p_max_stock < 0)
     OR (p_lead_time_days IS NOT NULL AND p_lead_time_days < 0) THEN
    RAISE EXCEPTION 'reorder rule values must be non-negative';
  END IF;
  IF v_rp < v_ss THEN
    RAISE EXCEPTION 'reorder_point (%) must be >= safety_stock (%)', v_rp, v_ss;
  END IF;
  IF p_max_stock IS NOT NULL AND p_max_stock < v_rp THEN
    RAISE EXCEPTION 'max_stock (%) must be >= reorder_point (%)', p_max_stock, v_rp;
  END IF;

  PERFORM 1 FROM locations WHERE id = p_location_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'location % not in tenant', p_location_id;
  END IF;
  PERFORM 1 FROM skus WHERE id = p_sku_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sku % not in tenant', p_sku_id;
  END IF;

  SELECT TRUE INTO v_existed
    FROM reorder_rules
   WHERE tenant_id = v_tenant AND location_id = p_location_id AND sku_id = p_sku_id;

  INSERT INTO reorder_rules (
    tenant_id, location_id, sku_id,
    safety_stock, reorder_point, max_stock, lead_time_days,
    created_by, updated_by
  ) VALUES (
    v_tenant, p_location_id, p_sku_id,
    v_ss, v_rp, p_max_stock, p_lead_time_days,
    v_user, v_user
  )
  ON CONFLICT (tenant_id, location_id, sku_id) DO UPDATE SET
    safety_stock   = EXCLUDED.safety_stock,
    reorder_point  = EXCLUDED.reorder_point,
    max_stock      = EXCLUDED.max_stock,
    lead_time_days = EXCLUDED.lead_time_days,
    updated_by     = v_user;

  RETURN jsonb_build_object(
    'location_id', p_location_id,
    'sku_id', p_sku_id,
    'safety_stock', v_ss,
    'reorder_point', v_rp,
    'max_stock', p_max_stock,
    'lead_time_days', p_lead_time_days,
    'action', CASE WHEN v_existed THEN 'updated' ELSE 'created' END
  );
END;
$$;

-- ----------------------------------------------------------------
-- 3. delete 補貨規則
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_delete_reorder_rule(
  p_location_id BIGINT,
  p_sku_id      BIGINT,
  p_operator    UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant  UUID := public._current_tenant_id();
  v_role    TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth.jwt() ->> 'role', '');
  v_deleted INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager') THEN
    RAISE EXCEPTION 'permission denied: role % cannot maintain reorder rules', v_role;
  END IF;

  DELETE FROM reorder_rules
   WHERE tenant_id = v_tenant
     AND location_id = p_location_id
     AND sku_id = p_sku_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object('deleted', v_deleted);
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_upsert_reorder_rule(BIGINT, BIGINT, NUMERIC, NUMERIC, NUMERIC, INT, UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.rpc_delete_reorder_rule(BIGINT, BIGINT, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_upsert_reorder_rule IS
  '維護補貨規則（upsert on tenant+location+sku）。HQ-only。驗 reorder_point>=safety_stock、max_stock>=reorder_point、location/sku 屬本 tenant。';
COMMENT ON FUNCTION public.rpc_delete_reorder_rule IS
  '刪除補貨規則（tenant-scoped）。HQ-only。回傳 deleted 筆數。';
