-- ============================================================
-- 2026-07-04: rpc_undo_pickup — 撤銷誤操作取貨（正式功能）
--
-- 場景：門市/管理員誤點「確認取貨」（客人其實沒來拿），需要把訂單還原成
-- 未取貨。先前兩例（GRP-20260609-025-0001 / GB20260522-C000333-0008）
-- 都是手動修資料，本 migration 把該流程包成 RPC + UI 按鈕。
--
-- 設計（全部沿用既有 append-only 慣例）：
--   1. 只撤「最近一次」取貨事件（picked_up / partial_pickup）。
--      多次取貨要逐次撤，每撤一次回復一個事件。
--   2. 庫存：每個品項的 sale movement 建 reversal 沖回門市
--      （movement_type='reversal', reverses=原 id；同 20260507000000 慣例。
--      原 row 不動 — stock_movements 禁 UPDATE，reversed_by 不回填）。
--   3. 品項：picked_up → pending、清 pickup_movement_id。
--      部分取貨拆出來的 split 行不合併回原行，直接變獨立的 pending 行
--      （金額/數量 line-level 都正確，後續可再取）。
--   4. 事件：order_pickup_events 禁改禁刪，插入補償事件
--      event_type='pickup_undone'（CHECK 白名單本檔加入）。
--   5. 訂單狀態：仍有 picked_up 行 → partially_completed；
--      否則 is_order_pickup_ready() → ready；否則 shipping。
--      completed_at 清空。
--   6. audit：customer_order_audit_log 逐品項 + 訂單 status 各寫一筆。
--   7. 金流不動：wallet_paid_amount / payment_status 保留（錢還在訂單上，
--      之後正常取貨不用再付；要退錢走取消/退款流程）。回傳值帶
--      wallet_paid_amount 讓 UI 提示。
--   8. 權限：owner / admin / hq_manager / ''（對齊
--      20260607000040 rpc_resolve_transfer_item_shortage 的 gate）。
--
-- 防呆：
--   - 品項不是 picked_up、movement 已被沖銷過（重複撤銷）、
--     movement 不是本單 sale → 全部 EXCEPTION（整筆 rollback）。
--
-- Rollback：DROP FUNCTION rpc_undo_pickup(bigint, uuid, text);
--   order_pickup_events CHECK 改回 5 值版（先確認無 pickup_undone rows）。
-- ============================================================

-- ----------------------------------------------------------------
-- 1. order_pickup_events.event_type 加 'pickup_undone'
-- ----------------------------------------------------------------
ALTER TABLE order_pickup_events DROP CONSTRAINT IF EXISTS order_pickup_events_event_type_check;
ALTER TABLE order_pickup_events
  ADD CONSTRAINT order_pickup_events_event_type_check
  CHECK (event_type IN ('picked_up','partial_pickup','no_show_expired','cancelled','refunded','pickup_undone'));

-- ----------------------------------------------------------------
-- 2. rpc_undo_pickup
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_undo_pickup(
  p_order_id bigint,
  p_operator uuid,
  p_reason   text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_order    customer_orders%ROWTYPE;
  v_event    order_pickup_events%ROWTYPE;
  v_item     customer_order_items%ROWTYPE;
  v_orig     stock_movements%ROWTYPE;
  v_item_id  BIGINT;
  v_rev_id   BIGINT;
  v_count    INT := 0;
  v_picked_remaining INT;
  v_new_status TEXT;
  v_undo_event_id BIGINT;
  v_now      TIMESTAMPTZ := NOW();
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'permission denied: role「%」無權撤銷取貨', v_role;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_pickup:' || p_order_id::text));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '找不到訂單 %', p_order_id;
  END IF;
  IF v_order.status IN ('cancelled','expired','transferred_out') THEN
    RAISE EXCEPTION '訂單 % 狀態為「%」，無法撤銷取貨', p_order_id, v_order.status;
  END IF;

  -- 最近一次取貨事件
  SELECT * INTO v_event
    FROM order_pickup_events
   WHERE order_id = p_order_id
     AND event_type IN ('picked_up','partial_pickup')
   ORDER BY id DESC
   LIMIT 1;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION '訂單 % 沒有取貨事件可撤銷', p_order_id;
  END IF;

  -- 逐品項：驗證 → reversal 沖庫存 → 還原 pending
  FOR v_item_id IN SELECT (jsonb_array_elements_text(v_event.item_ids))::bigint
  LOOP
    SELECT * INTO v_item FROM customer_order_items
     WHERE id = v_item_id AND order_id = p_order_id FOR UPDATE;
    IF v_item.id IS NULL THEN
      RAISE EXCEPTION '取貨事件 #% 的品項 % 不存在', v_event.id, v_item_id;
    END IF;
    IF v_item.status <> 'picked_up' OR v_item.pickup_movement_id IS NULL THEN
      RAISE EXCEPTION '品項 % 狀態「%」非已取貨，無法撤銷（事件 #% 可能已撤銷過）',
        v_item_id, v_item.status, v_event.id;
    END IF;

    SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.pickup_movement_id;
    IF v_orig.id IS NULL
       OR v_orig.movement_type <> 'sale'
       OR v_orig.source_doc_type <> 'customer_order'
       OR v_orig.source_doc_id <> p_order_id THEN
      RAISE EXCEPTION '品項 % 的 movement % 非本單取貨扣帳，無法撤銷', v_item_id, v_item.pickup_movement_id;
    END IF;
    IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
      RAISE EXCEPTION 'movement % 已被沖銷過，不可重複撤銷', v_orig.id;
    END IF;

    INSERT INTO stock_movements (
      tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
      source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
    ) VALUES (
      v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
      -v_orig.quantity, v_orig.unit_cost, 'reversal',
      'customer_order', p_order_id, v_item.id, v_orig.id,
      format('撤銷取貨 order=%s item=%s (沖銷 movement %s, 取貨事件 #%s)%s',
             p_order_id, v_item.id, v_orig.id, v_event.id,
             COALESCE('：' || NULLIF(TRIM(p_reason), ''), '')),
      p_operator
    ) RETURNING id INTO v_rev_id;

    UPDATE customer_order_items
       SET status = 'pending',
           pickup_movement_id = NULL,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = v_item.id;

    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    ) VALUES (
      v_order.tenant_id, p_order_id, 'item', v_item.id, 'status',
      to_jsonb('picked_up'::text), to_jsonb('pending'::text),
      format('撤銷取貨（事件 #%s），庫存以 reversal movement %s 沖回%s',
             v_event.id, v_rev_id, COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
      p_operator
    );

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION '取貨事件 #% 無品項可撤銷', v_event.id;
  END IF;

  -- 補償事件（order_pickup_events 為 append-only，不刪原事件）
  INSERT INTO order_pickup_events (
    tenant_id, order_id, pickup_store_id, event_type, item_ids, notes, created_by
  ) VALUES (
    v_order.tenant_id, p_order_id, v_order.pickup_store_id, 'pickup_undone',
    v_event.item_ids,
    format('撤銷取貨事件 #%s%s', v_event.id, COALESCE('：' || NULLIF(TRIM(p_reason), ''), '')),
    p_operator
  ) RETURNING id INTO v_undo_event_id;

  -- 重算訂單狀態。
  -- 先把訂單置為中性 active 狀態：is_order_pickup_ready 對 completed 等終態
  -- 一律回 false，必須先脫離 completed 再判定「是否全到貨」。
  UPDATE customer_orders
     SET status       = 'shipping',
         completed_at = NULL,
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_order_id;

  SELECT COUNT(*) INTO v_picked_remaining
    FROM customer_order_items
   WHERE order_id = p_order_id AND status = 'picked_up';

  IF v_picked_remaining > 0 THEN
    v_new_status := 'partially_completed';
  ELSIF public.is_order_pickup_ready(p_order_id) THEN
    v_new_status := 'ready';
  ELSE
    v_new_status := 'shipping';
  END IF;

  IF v_new_status <> 'shipping' THEN
    UPDATE customer_orders
       SET status     = v_new_status,
           updated_by = p_operator,
           updated_at = v_now
     WHERE id = p_order_id;
  END IF;

  INSERT INTO customer_order_audit_log (
    tenant_id, order_id, entity_type, entity_id, field,
    before_value, after_value, edit_reason, operator_id
  ) VALUES (
    v_order.tenant_id, p_order_id, 'order', p_order_id, 'status',
    to_jsonb(v_order.status), to_jsonb(v_new_status),
    format('撤銷取貨（事件 #%s → 補償事件 #%s）%s',
           v_event.id, v_undo_event_id, COALESCE('；原因：' || NULLIF(TRIM(p_reason), ''), '')),
    p_operator
  );

  RETURN jsonb_build_object(
    'undone_event_id',    v_event.id,
    'undo_event_id',      v_undo_event_id,
    'items_restored',     v_count,
    'new_status',         v_new_status,
    'wallet_paid_amount', v_order.wallet_paid_amount
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_undo_pickup(bigint, uuid, text) IS
  '撤銷最近一次取貨事件：reversal 沖回門市庫存、品項還原 pending、補償事件 pickup_undone、'
  '重算訂單狀態（picked 殘留→partially_completed / 全到→ready / 否則 shipping）。'
  '金流不動。權限 owner/admin/hq_manager。';

GRANT EXECUTE ON FUNCTION public.rpc_undo_pickup(bigint, uuid, text) TO authenticated;
