-- ============================================================
-- 2026-07-11: rpc_unreceive_transfer — 店家已收貨可再退回取消收貨
--
-- 場景：分店在「收貨待辦」(wms/inbound) 誤點「收貨」/「批次收貨」，或收錯數量，
--   需要把已收貨(received)的調撥單退回「待收(shipped)」重收。目前只能收、不能退。
--
-- 本 RPC 是 rpc_receive_transfer（20260703000000 線上現行版）的反向操作，逐一沖銷：
--   1. 入庫庫存：每個 qty_received>0 的 transfer_item 的 transfer_in movement，
--      以 movement_type='reversal'、reverses=原 id、負數量 建沖銷分錄
--      （沿用 20260704000010 rpc_undo_pickup 的 append-only 沖銷慣例；
--       原 movement 不動，stock_movements 禁 UPDATE/DELETE）。
--      transfer_items.qty_received 歸零、in_movement_id 清空。
--   2. 調撥單：status received → shipped、received_by/received_at 清空、notes 追加退回註記。
--   3. 反向邏輯 B（aid 單 FK）/ 邏輯 C（hq_to_store）：把因本次收貨被推到
--      ready、但沖銷後已不再 is_order_pickup_ready() 的訂單退回 shipping、清 ready_at，
--      並寫 order status audit log。因其他已收波次而仍到貨的訂單維持 ready。
--
-- 防呆守衛（整筆 rollback）：
--   - 調撥單非 received → 擋。
--   - 多段接力(next_transfer_id)且後段已離開 draft（收貨時自動出貨過）→ 擋，
--     請先處理後段，避免下游未沖銷造成不一致。
--   - transfer_item 的 in_movement 非本調撥入庫、或已被沖銷過 → 擋（防重複退回）。
--   - 物理守衛：入庫的貨若已被取貨/售出使該店 on_hand 不足以沖銷 → 擋，
--     避免庫存變負數（貨實際已離店，不該退回收貨）。
--
-- 權限：對齊 rpc_receive_transfer（無 role gate，authenticated 即可），
--   讓收貨的分店帳號可以自行退回自己的誤操作。
--
-- 基底版本：rpc_receive_transfer = 20260703000000（本檔為其反向，不改動它）。
-- Rollback：DROP FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT);
--   （已寫入的 reversal movement 為 append-only，不隨 DROP 消失；如需完全回復，
--    須人工再收貨一次。）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_unreceive_transfer(
  p_transfer_id bigint,
  p_operator    uuid,
  p_notes       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- 邏輯 C 需重掃該店所有 ready 訂單並逐張跑 is_order_pickup_ready，覆寫 PostgREST
-- 預設 statement_timeout，避免大店退回時中途被砍。
SET statement_timeout TO '60000'
AS $function$
DECLARE
  v_tenant_id         UUID;
  v_status            TEXT;
  v_transfer_type     TEXT;
  v_dest_location     BIGINT;
  v_existing_notes    TEXT;
  v_customer_order_id BIGINT;
  v_next_transfer_id  BIGINT;
  v_leg2_status       TEXT;
  v_item              RECORD;
  v_orig              stock_movements%ROWTYPE;
  v_on_hand           NUMERIC;
  v_rev_id            BIGINT;
  v_items_reversed    INTEGER := 0;
  v_total_qty         NUMERIC := 0;
  v_dest_store_id     BIGINT;
  v_orders_reverted   INTEGER := 0;
  v_ord               RECORD;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT tenant_id, status, transfer_type, dest_location, notes,
         customer_order_id, next_transfer_id
    INTO v_tenant_id, v_status, v_transfer_type, v_dest_location, v_existing_notes,
         v_customer_order_id, v_next_transfer_id
    FROM transfers
   WHERE id = p_transfer_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  IF v_status <> 'received' THEN
    RAISE EXCEPTION '調撥單 % 目前狀態為「%」，僅「已收貨(received)」可退回取消收貨', p_transfer_id, v_status;
  END IF;

  -- 守衛：多段接力且後段已自動出貨（收貨時 ship 過），不允許直接退回本段
  IF v_next_transfer_id IS NOT NULL THEN
    SELECT status INTO v_leg2_status FROM transfers WHERE id = v_next_transfer_id FOR UPDATE;
    IF v_leg2_status IS NOT NULL AND v_leg2_status <> 'draft' THEN
      RAISE EXCEPTION '此調撥為多段接力，後段調撥 %（狀態 %）已出貨，請先處理後段後再退回本段收貨',
        v_next_transfer_id, v_leg2_status;
    END IF;
  END IF;

  -- 逐項沖銷 transfer_in 入庫、並把 qty_received 歸零
  FOR v_item IN
    SELECT id, sku_id, qty_received, in_movement_id
      FROM transfer_items
     WHERE transfer_id = p_transfer_id
     ORDER BY id
     FOR UPDATE
  LOOP
    IF v_item.qty_received > 0 AND v_item.in_movement_id IS NOT NULL THEN
      SELECT * INTO v_orig FROM stock_movements WHERE id = v_item.in_movement_id;

      IF v_orig.id IS NULL
         OR v_orig.movement_type <> 'transfer_in'
         OR v_orig.source_doc_type <> 'transfer'
         OR v_orig.source_doc_id <> p_transfer_id THEN
        RAISE EXCEPTION 'transfer_item % 的 movement % 非本調撥入庫，無法退回收貨',
          v_item.id, v_item.in_movement_id;
      END IF;
      IF EXISTS (SELECT 1 FROM stock_movements sm WHERE sm.reverses = v_orig.id) THEN
        RAISE EXCEPTION 'movement % 已被沖銷過，不可重複退回收貨', v_orig.id;
      END IF;

      -- 物理守衛：入庫貨若已被取貨/售出使 on_hand 不足以沖銷 → 擋（避免庫存變負）
      SELECT on_hand INTO v_on_hand
        FROM stock_balances
       WHERE tenant_id   = v_orig.tenant_id
         AND location_id = v_orig.location_id
         AND sku_id      = v_orig.sku_id
       FOR UPDATE;
      IF COALESCE(v_on_hand, 0) < v_orig.quantity THEN
        RAISE EXCEPTION '分店庫存不足以退回收貨（SKU %：現有 %、需沖銷 %）：該批貨可能已被取貨/售出，無法退回',
          v_orig.sku_id, COALESCE(v_on_hand, 0), v_orig.quantity;
      END IF;

      INSERT INTO stock_movements (
        tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
        source_doc_type, source_doc_id, source_doc_line_id, reverses, reason, operator_id
      ) VALUES (
        v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
        -v_orig.quantity, v_orig.unit_cost, 'reversal',
        'transfer', p_transfer_id, v_item.id, v_orig.id,
        format('退回收貨 transfer=%s item=%s（沖銷 movement %s）%s',
               p_transfer_id, v_item.id, v_orig.id,
               COALESCE('：' || NULLIF(TRIM(p_notes), ''), '')),
        p_operator
      ) RETURNING id INTO v_rev_id;

      v_total_qty      := v_total_qty + v_orig.quantity;
      v_items_reversed := v_items_reversed + 1;
    END IF;

    UPDATE transfer_items
       SET qty_received   = 0,
           in_movement_id = NULL,
           updated_by     = p_operator,
           updated_at     = NOW()
     WHERE id = v_item.id;
  END LOOP;

  -- 調撥單退回 shipped
  UPDATE transfers
     SET status      = 'shipped',
         received_by = NULL,
         received_at = NULL,
         notes       = CASE
                         WHEN p_notes IS NULL OR TRIM(p_notes) = '' THEN v_existing_notes
                         WHEN v_existing_notes IS NULL OR v_existing_notes = '' THEN '退回收貨：' || p_notes
                         ELSE v_existing_notes || E'\n退回收貨：' || p_notes
                       END,
         updated_by  = p_operator
   WHERE id = p_transfer_id;

  -- 反向邏輯 B（aid 單 FK）/ 邏輯 C（hq_to_store）：
  -- 把因本次收貨被推到 ready、沖銷後已不再 pickup_ready 的訂單退回 shipping。
  -- 因其他已收波次而仍到貨的訂單維持 ready。已取貨(partially_completed/completed)不動。
  IF v_customer_order_id IS NOT NULL THEN
    FOR v_ord IN
      SELECT id FROM customer_orders
       WHERE id = v_customer_order_id AND status = 'ready'
       FOR UPDATE
    LOOP
      IF NOT public.is_order_pickup_ready(v_ord.id) THEN
        UPDATE customer_orders
           SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
         WHERE id = v_ord.id;
        PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
          format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
        v_orders_reverted := v_orders_reverted + 1;
      END IF;
    END LOOP;

  ELSIF v_transfer_type = 'hq_to_store' THEN
    SELECT id INTO v_dest_store_id
      FROM stores
     WHERE tenant_id = v_tenant_id AND location_id = v_dest_location
     LIMIT 1;

    IF v_dest_store_id IS NOT NULL THEN
      FOR v_ord IN
        SELECT id FROM customer_orders
         WHERE tenant_id       = v_tenant_id
           AND pickup_store_id = v_dest_store_id
           AND status          = 'ready'
         FOR UPDATE
      LOOP
        IF NOT public.is_order_pickup_ready(v_ord.id) THEN
          UPDATE customer_orders
             SET status = 'shipping', ready_at = NULL, updated_by = p_operator, updated_at = NOW()
           WHERE id = v_ord.id;
          PERFORM rpc_log_order_status_change(v_ord.id, 'ready', 'shipping', p_operator,
            format('退回收貨（調撥 %s）：該訂單的貨已退回在途，恢復未到貨', p_transfer_id));
          v_orders_reverted := v_orders_reverted + 1;
        END IF;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'transfer_id',        p_transfer_id,
    'items_reversed',     v_items_reversed,
    'total_qty_reversed', v_total_qty,
    'orders_reverted',    v_orders_reverted
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_unreceive_transfer(BIGINT, UUID, TEXT) IS
  '退回收貨：rpc_receive_transfer 的反向。沖銷 transfer_in 入庫(reversal movement)、'
  'qty_received 歸零、調撥單 received→shipped；沖銷後不再 pickup_ready 的訂單退回 shipping。'
  '守衛：非 received / 後段已出貨 / movement 已沖銷 / on_hand 不足(貨已取用) 皆擋下。';
