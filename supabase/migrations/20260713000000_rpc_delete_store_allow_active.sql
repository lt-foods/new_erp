-- ============================================================
-- rpc_delete_store：放寬「必須先停用才能刪」，改成一鍵可刪（刪時兼停用）
--
-- 基底：20260620000080_rpc_delete_store.sql（唯一動過此函式的版本）
-- rollback：指回 20260620000080 版本（含 is_active 守門）即可
--
-- 動機：
--   原設計要求 is_active=false 才能刪，是兩段式（先停用→再刪）。實務上
--   後台門市多半是啟用中，導致刪除鈕（前端 !is_active 才顯示）根本按不到，
--   使用者以為「線上沒這功能」。刪除本就是軟刪 + 可還原，先停用只是儀式。
--
-- 變更：
--   1. 移除「門市還在啟用中，請先停用才能刪除」的 guard
--   2. UPDATE 時一併設 is_active=false（刪除本就代表下線）
--   3. 其餘守門全部保留：owner/admin、已刪防重複、進行中訂單、進行中補貨
--
-- 反悔：UPDATE stores SET deleted_at = NULL WHERE id = X（還原後仍為停用）
-- ============================================================

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

  -- （移除「必須先停用」的 guard；刪除時於下方一併停用）

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
         is_active  = FALSE,   -- 刪除即下線，取代原本「先手動停用」的要求
         updated_by = v_operator,
         updated_at = NOW()
   WHERE id = p_id AND tenant_id = v_tenant
   RETURNING * INTO v_store;

  RETURN v_store;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_delete_store(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_delete_store(BIGINT, UUID) IS
  '軟刪除門市（一鍵可刪，刪時兼停用）。守門：owner/admin、無進行中訂單與補貨申請。設定 deleted_at + is_active=false。';
