-- ============================================================
-- 店長改訂單數量 — 限自店 + 限 pending
--
-- 背景：
--   ERP staff 帳號的 store 歸屬實際存放在 app_metadata.stores (TEXT[]，店名)。
--   既有 _check_order_edit_perm 讀的是 app_metadata.store_id (BIGINT)，店長一律失敗。
--
-- 本次：
--   1. 新增 qty 專屬權限 helper _check_order_edit_qty_perm，認 stores[] 比對店名。
--   2. rpc_update_order_item_qty 改呼叫新 helper；其餘 RPC (price/notes/discount) 不動。
--   3. 修 customer_order_audit_log 的 coa_store_read policy 同步改用 stores[] 比對，
--      讓店長能看到自己訂單的編輯歷史。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 新權限 helper：HQ 全通過 / 店長限 app_metadata.stores 內店名
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._check_order_edit_qty_perm(p_order_id BIGINT)
RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order      customer_orders%ROWTYPE;
  v_tenant     UUID    := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role       TEXT    := COALESCE(
                            NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                            NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                            ''
                          );
  v_stores     TEXT[];
  v_store_name TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found in tenant %', p_order_id, v_tenant;
  END IF;

  -- HQ tier（含 role NULL/空字串/'authenticated' 視為 admin tier）
  IF v_role IN ('owner','admin','hq_manager','hq_accountant','') THEN
    RETURN v_order;
  END IF;

  -- 讀 app_metadata.stores（JSON array of store names）→ TEXT[]
  SELECT COALESCE(
           ARRAY(SELECT jsonb_array_elements_text(auth.jwt() -> 'app_metadata' -> 'stores')),
           ARRAY[]::TEXT[]
         )
    INTO v_stores;

  -- 總倉 magic value：總倉成員可改任何店 pending 訂單
  IF '總倉' = ANY(v_stores) THEN
    RETURN v_order;
  END IF;

  -- 比對訂單 pickup_store 名稱是否在 stores[] 內
  SELECT name INTO v_store_name
    FROM stores
   WHERE id = v_order.pickup_store_id
     AND tenant_id = v_tenant;

  IF v_store_name IS NOT NULL AND v_store_name = ANY(v_stores) THEN
    RETURN v_order;
  END IF;

  RAISE EXCEPTION 'permission denied: role=% stores=% cannot edit qty of order %',
    v_role, v_stores::text, p_order_id;
END;
$$;

-- ----------------------------------------------------------------
-- 2. rpc_update_order_item_qty 改呼叫新 helper
--    其餘邏輯 (status gate / qty > 0 / FOR UPDATE / 稽核) 不變
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_update_order_item_qty(
  p_order_id BIGINT,
  p_item_id  BIGINT,
  p_new_qty  NUMERIC,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_order_items;
BEGIN
  -- 1. 權限檢查：HQ 全部 / 店長限 app_metadata.stores 內 pickup_store
  v_order := _check_order_edit_qty_perm(p_order_id);

  -- 2. 訂單狀態閘：僅 pending（被 PR 鎖定變 confirmed 後就擋下）
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION '訂單狀態為 %,僅 待確認 訂單可改數量', v_order.status;
  END IF;

  -- 3. 輸入驗證（配合 schema CHECK qty > 0，刪品項另走 RPC）
  IF p_new_qty IS NULL OR p_new_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be > 0';
  END IF;

  SELECT qty INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  -- 4. no-op 短路
  IF v_old = p_new_qty THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET qty        = p_new_qty,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  -- 5. 稽核
  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'qty',
     to_jsonb(v_old), to_jsonb(p_new_qty), p_reason, p_operator);

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_order_item_qty(BIGINT, BIGINT, NUMERIC, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_order_item_qty IS
  '店長可改自家 pending 訂單品項 qty。'
  'HQ tier 全部 / 店長限 app_metadata.stores 含訂單 pickup_store.name (或含 ''總倉'')；'
  '訂單狀態必須是 pending；qty 必須 > 0；寫 customer_order_audit_log，no-op 不寫。';

-- ----------------------------------------------------------------
-- 3. customer_order_audit_log 店家 SELECT policy 改用 stores[] 比對
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS coa_store_read ON customer_order_audit_log;

CREATE POLICY coa_store_read ON customer_order_audit_log
  FOR SELECT USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      -- 總倉 magic value：可看全部
      EXISTS (
        SELECT 1
          FROM jsonb_array_elements_text(
                 COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb)
               ) AS s(name)
         WHERE s.name = '總倉'
      )
      OR order_id IN (
        SELECT co.id
          FROM customer_orders co
          JOIN stores st ON st.id = co.pickup_store_id
         WHERE st.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
           AND st.name IN (
             SELECT jsonb_array_elements_text(
                      COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb)
                    )
           )
      )
    )
  );
