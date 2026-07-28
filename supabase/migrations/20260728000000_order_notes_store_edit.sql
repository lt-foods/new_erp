-- ============================================================
-- 店長/店員可編輯訂單備註（單頭 notes + 品項 notes）— 限自店
--
-- 背景：
--   ERP staff 帳號的 store 歸屬存在 app_metadata.stores (TEXT[]，店名)，
--   沒有 store_id。rpc_update_order_notes / rpc_update_order_item_notes
--   沿用 _check_order_edit_perm（認 app_metadata.store_id BIGINT），
--   店長/店員一律 permission denied；前端 OrderDetail 也以 canEdit
--   (HQ/總倉) 把備註欄鎖成唯讀。
--
-- 本次：
--   1. 新增 _check_order_edit_notes_perm：判斷邏輯同 20260629000010 的
--      _check_order_edit_qty_perm（HQ tier 全過 / stores[] 含 '總倉' 全過 /
--      其他比對 stores[] 是否含訂單 pickup_store 店名），僅錯誤訊息不同。
--   2. rpc_update_order_notes / rpc_update_order_item_notes 改呼叫新 helper，
--      其餘（no-op 短路 / audit log / updated_by）不動。
--      基底版本：20260605000002_rpc_edit_order_price_and_notes.sql
--      （兩支 RPC 至今唯一版本，grep migrations 確認無後續修改）。
--   3. price / discount RPC 維持 _check_order_edit_perm，權限不變。
--   （店家可讀自店訂單 audit log 的 coa_store_read policy 已在
--    20260629000010 改用 stores[] 比對，本次不需再動。）
--
-- Rollback：把兩支 RPC 還原成 20260605000002 版（呼叫 _check_order_edit_perm），
--   再 DROP FUNCTION _check_order_edit_notes_perm(BIGINT)。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. 備註權限 helper：HQ 全過 / 總倉全過 / 店家限 stores[] 內店名
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._check_order_edit_notes_perm(p_order_id BIGINT)
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

  -- 總倉 magic value：總倉成員可編任何店訂單備註
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

  RAISE EXCEPTION 'permission denied: role=% stores=% cannot edit notes of order %',
    v_role, v_stores::text, p_order_id;
END;
$$;

-- ----------------------------------------------------------------
-- 2a. order header notes（基底 20260605000002；僅換權限 helper）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_update_order_notes(
  p_order_id  BIGINT,
  p_new_notes TEXT,
  p_operator  UUID,
  p_reason    TEXT DEFAULT NULL
) RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   TEXT;
  v_row   customer_orders;
BEGIN
  v_order := _check_order_edit_notes_perm(p_order_id);

  v_old := v_order.notes;

  IF v_old IS NOT DISTINCT FROM p_new_notes THEN
    RETURN v_order;
  END IF;

  UPDATE customer_orders
     SET notes      = p_new_notes,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_order_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'order', NULL, 'order_notes',
     to_jsonb(v_old), to_jsonb(p_new_notes), p_reason, p_operator);

  RETURN v_row;
END;
$$;

-- ----------------------------------------------------------------
-- 2b. line item notes（基底 20260605000002；僅換權限 helper）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_update_order_item_notes(
  p_order_id  BIGINT,
  p_item_id   BIGINT,
  p_new_notes TEXT,
  p_operator  UUID,
  p_reason    TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   TEXT;
  v_row   customer_order_items;
BEGIN
  v_order := _check_order_edit_notes_perm(p_order_id);

  SELECT notes INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  IF v_old IS NOT DISTINCT FROM p_new_notes THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET notes      = p_new_notes,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'item_notes',
     to_jsonb(v_old), to_jsonb(p_new_notes), p_reason, p_operator);

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.rpc_update_order_notes IS
  '編輯訂單單頭備註。HQ tier 全部 / 店長店員限 app_metadata.stores 含訂單 '
  'pickup_store.name（或含 ''總倉''）；寫 customer_order_audit_log，no-op 不寫。';

COMMENT ON FUNCTION public.rpc_update_order_item_notes IS
  '編輯訂單品項備註。HQ tier 全部 / 店長店員限 app_metadata.stores 含訂單 '
  'pickup_store.name（或含 ''總倉''）；寫 customer_order_audit_log，no-op 不寫。';
