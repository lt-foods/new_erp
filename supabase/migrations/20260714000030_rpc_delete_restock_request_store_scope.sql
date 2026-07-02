-- ============================================================================
-- 2026-07-14: rpc_delete_restock_request — 放行門市角色刪「自己店」的 pending 申請
-- ----------------------------------------------------------------------------
-- 問題：20260714000020 版只放行 owner/admin/hq_manager，但補貨申請是分店建的，
--   店長（store_manager）在前台刪自己店的待處理申請會被
--   'permission denied: role store_manager ...' 擋下。
--   原 schema（20260515000001）本來就定義 pending → cancelled（建單者取消），
--   建單者要能收回自己的 pending 申請。
--
-- 難點：store_manager 的 JWT 沒有 store_id claim，只有 app_metadata.stores
--   （店名陣列）。店別綁定用既有 helper _jwt_store_ids()（20260707000070，
--   店名 → store id 陣列、tenant 綁定、SECURITY DEFINER），
--   與 stock_balances RLS / 退貨 RPC（20260707000080）同一套做法。
--
-- 改動（相對 20260714000020 基底版，其餘守門與連帶刪除邏輯全數保留）：
--   - role 守門加入 store_manager / store_staff
--   - 門市角色多一道店別守門：requesting_store_id 必須在 _jwt_store_ids() 內
--
-- 基底：20260714000020_rpc_delete_restock_request.sql（唯一前版）。
-- Rollback：重跑 20260714000020 的 CREATE OR REPLACE FUNCTION 區塊。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_restock_request(
  p_request_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_req    RECORD;
  v_waves  INTEGER;
BEGIN
  -- role 守門：HQ 職能 + 門市職能（空字串放行 — 對齊既有 restock RPC）
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot delete restock request', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'restock request % not found', p_request_id;
  END IF;

  -- 門市角色只能刪自己店的申請（店名 claim → store id，見 20260707000070）
  IF v_role IN ('store_manager','store_staff')
     AND NOT (v_req.requesting_store_id = ANY (public._jwt_store_ids())) THEN
    RAISE EXCEPTION 'store role can only delete request for own store';
  END IF;

  -- 守門 1：只有 pending 可刪 — 已派貨/已轉採購的單有下游單據，走各自流程
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'restock request % is %, only pending can be deleted',
      p_request_id, v_req.status;
  END IF;

  -- 守門 2：雙重保險 — 已有撿貨波引用（正常 pending 不會有；建波會把狀態
  -- 推到 approved_transfer，這裡防的是資料不一致）
  SELECT COUNT(*) INTO v_waves
    FROM picking_waves
   WHERE source_restock_request_id = p_request_id;
  IF v_waves > 0 THEN
    RAISE EXCEPTION 'restock request % already has picking waves, cannot delete', p_request_id;
  END IF;

  -- 連帶刪內部 sentinel 訂單 RR-{id}（items 為 ON DELETE CASCADE）。
  -- 舊資料（20260612000020 之前建的申請）沒有 RR- 訂單，刪 0 筆是正常的。
  BEGIN
    DELETE FROM customer_orders
     WHERE tenant_id = v_tenant
       AND order_kind = 'restock'
       AND external_order_no = 'RR-' || p_request_id::TEXT;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'restock request % internal order still referenced, cannot delete', p_request_id;
  END;

  -- 實體硬刪：restock_request_lines 為 ON DELETE CASCADE
  BEGIN
    DELETE FROM restock_requests
     WHERE id = p_request_id AND tenant_id = v_tenant;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'restock request % still referenced by other records, cannot delete', p_request_id;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_restock_request(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_restock_request(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_restock_request(BIGINT) IS
  '補貨申請刪除（硬刪）：限 pending 且無撿貨波引用；'
  '連帶刪建單時自動掛的內部 RR-{id} customer_order（items 為 CASCADE）；'
  'lines 由 ON DELETE CASCADE 連帶刪；同 tenant；'
  'HQ 職能全刪、門市職能限自己店（_jwt_store_ids）。';
