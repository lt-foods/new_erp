-- ============================================================
-- 新增刪除門市功能：deleted_at 欄位 + rpc_delete_store(p_id)
--
-- 設計：軟刪除（不真的 DELETE row）
--   - 18+ 張 table FK 指向 stores.id，hard delete 風險太高
--   - 既有 is_active=false 是「暫時停用」，可隨時恢復
--   - deleted_at=NOW() 是「正式下線」，從列表預設藏起來
--
-- 守門：
--   - role 必須 owner / admin
--   - is_active 必須 false（要先停用才能刪）
--   - 沒有「進行中」的 customer_orders 引用該店為 pickup_store_id
--     (狀態不在 cancelled / expired / completed)
--   - 沒有「進行中」的 restock_requests（狀態不在 cancelled / completed / rejected）
--   - 通過後 UPDATE stores SET deleted_at = NOW()
--
-- 反悔：UPDATE stores SET deleted_at = NULL WHERE id = X 即可
-- ============================================================

ALTER TABLE stores
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

COMMENT ON COLUMN stores.deleted_at IS
'軟刪除標記。NULL = 活著、非 NULL = 已刪。前端預設過濾掉非 NULL。';

CREATE OR REPLACE FUNCTION rpc_delete_store(
  p_id       BIGINT,
  p_operator UUID DEFAULT NULL
) RETURNS stores
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role     TEXT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                       NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                       ''
                     );
  v_operator UUID := COALESCE(p_operator, auth.uid());
  v_store    stores;
  v_open_orders   INT;
  v_open_restocks INT;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'permission denied: only owner/admin can delete stores';
  END IF;

  SELECT * INTO v_store FROM stores
   WHERE id = p_id AND tenant_id = v_tenant FOR UPDATE;
  IF v_store.id IS NULL THEN
    RAISE EXCEPTION 'store % not found', p_id;
  END IF;

  IF v_store.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION '門市 % 已被刪除（deleted_at=%）', v_store.code, v_store.deleted_at;
  END IF;

  IF v_store.is_active THEN
    RAISE EXCEPTION '門市 % 還在啟用中，請先停用才能刪除', v_store.code;
  END IF;

  -- 守門：進行中的訂單
  SELECT COUNT(*) INTO v_open_orders
    FROM customer_orders
   WHERE tenant_id = v_tenant
     AND pickup_store_id = p_id
     AND status NOT IN ('cancelled','expired','completed');
  IF v_open_orders > 0 THEN
    RAISE EXCEPTION '門市 % 仍有 % 筆進行中訂單（非 cancelled/expired/completed），不能刪除',
      v_store.code, v_open_orders;
  END IF;

  -- 守門：進行中的補貨申請
  SELECT COUNT(*) INTO v_open_restocks
    FROM restock_requests
   WHERE tenant_id = v_tenant
     AND requesting_store_id = p_id
     AND status NOT IN ('cancelled','received','rejected');
  IF v_open_restocks > 0 THEN
    RAISE EXCEPTION '門市 % 仍有 % 筆進行中補貨申請，不能刪除',
      v_store.code, v_open_restocks;
  END IF;

  UPDATE stores
     SET deleted_at = NOW(),
         updated_by = v_operator,
         updated_at = NOW()
   WHERE id = p_id AND tenant_id = v_tenant
   RETURNING * INTO v_store;

  RETURN v_store;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_delete_store(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_delete_store(BIGINT, UUID) IS
  '軟刪除門市。守門：owner/admin、必須先停用、無進行中訂單與補貨申請。設定 deleted_at。';
