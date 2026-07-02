-- ============================================================================
-- 2026-07-14: rpc_delete_restock_request — 補貨申請刪除（限 pending、實體硬刪）
-- ----------------------------------------------------------------------------
-- 需求：補貨申請在「待處理」（pending）狀態要可以刪除（建錯單想直接清掉，
--       不想留一筆 cancelled / rejected 佔列表）。
--
-- 難點：rpc_create_restock_request（20260612000020 版）建單時有副作用 ——
--   同時建一張內部 sentinel customer_order（order_kind='restock'、
--   external_order_no='RR-{id}'）+ customer_order_items，供派貨工作台當需求來源。
--   只刪 restock_requests 本體會留下孤兒 RR- 訂單，繼續出現在
--   v_picking_demand 等需求彙總裡。故刪除時必須連帶刪掉該內部訂單。
--
-- 設計（守門順序）：
--   role 守門（owner/admin/hq_manager；空字串放行，對齊 rpc_reject_restock）→
--   not found / 跨 tenant → 非 pending 擋（已進派貨/採購流程的單走各自流程）→
--   已有 picking_wave 引用擋（pending 理論上不會有，防資料不一致的雙重保險）→
--   刪內部 RR- 訂單（customer_order_items 為 ON DELETE CASCADE 自動連帶）→
--   實體刪 restock_requests（restock_request_lines 為 ON DELETE CASCADE）。
--
-- 基底慣例：rpc_delete_pr（20260706000000）— 守門 + 硬刪 + 殘參照丟可讀訊息。
-- 本 function 為新建（無歷史版本）；狀態守門對齊 rpc_reject_restock
-- （20260515000002，僅 pending 可操作）。
-- 依賴：restock_request_lines.request_id / customer_order_items.order_id
--       均為 ON DELETE CASCADE；picking_waves.source_restock_request_id 無 CASCADE。
-- Rollback：DROP FUNCTION public.rpc_delete_restock_request(BIGINT);
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
  -- role 守門：HQ 職能（空字串放行 — 對齊既有 restock RPC）
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot delete restock request', v_role;
  END IF;

  SELECT * INTO v_req FROM restock_requests
   WHERE id = p_request_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'restock request % not found', p_request_id;
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
  'lines 由 ON DELETE CASCADE 連帶刪；同 tenant；owner/admin/hq_manager。';
