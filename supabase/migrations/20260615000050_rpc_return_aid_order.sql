-- ============================================================
-- rpc_return_aid_order：已收貨互助單退單（修 #234 / R12 gap）
--
-- 確認過的缺口：互助單 received 後
--   - rpc_cancel_aid_order 限 pending/confirmed/shipping（received 即 RAISE）
--   - rpc_reject_transfer 限 transfer=shipped（received 即 RAISE）
-- → 無正規退單路徑，只能手動 free transfer（不還原單狀態/來源連結/wallet）。
--
-- 本 RPC 處理「received 未取貨」(status='ready') 的退單：
--   反向 dest 店庫存 → 退回原 source 店、aid 單 cancelled、
--   來源單 transferred_out→confirmed、wallet 有付則 refund。
--
-- 範圍刻意對齊 sibling（rpc_cancel_aid_order / rpc_reject_transfer）：
--   不動 mutual_aid_board qty、不顯式反向 store_monthly_settlement
--   （cancel/reject 也都沒動，保持一致；transfer cancelled 自然不入結算）。
--
-- completed（已取貨、貨已不在店）= 客退+解互助糾纏案，明確 RAISE 引導，
-- 不在本 RPC 範圍（避免硬扣產生負庫存）。
--
-- TEST: docs/TEST-rpc-return-aid-order.md
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_return_aid_order(
  p_order_id BIGINT,
  p_reason   TEXT,
  p_operator UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_src_order        customer_orders%ROWTYPE;
  v_src_store_id     BIGINT;
  v_src_location     BIGINT;
  v_recv_xfer        transfers%ROWTYPE;
  v_dest_location    BIGINT;
  v_ret_id           BIGINT;
  v_ret_no           TEXT;
  v_ti               RECORD;
  v_out_mov          BIGINT;
  v_in_mov           BIGINT;
  v_epoch            BIGINT;
  v_reason_note      TEXT;
  v_items            INTEGER := 0;
  v_total_qty        NUMERIC := 0;
  v_refund_ledger_id BIGINT;
  v_refunded_amount  NUMERIC := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;

  -- 必須是互助單
  IF v_order.transferred_from_order_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM customer_order_items
        WHERE order_id = p_order_id AND source = 'aid_transfer'
     ) THEN
    RAISE EXCEPTION 'order % is not an aid order', p_order_id;
  END IF;

  -- 狀態閘
  IF v_order.status IN ('pending','confirmed','shipping') THEN
    RAISE EXCEPTION 'aid order % is % (not yet received) — use rpc_cancel_aid_order to cancel before receipt',
      p_order_id, v_order.status;
  ELSIF v_order.status = 'completed' THEN
    RAISE EXCEPTION 'aid order % already completed (picked up) — goods no longer at store; handle customer return first. rpc_return_aid_order only supports received-not-picked (status=ready)',
      p_order_id;
  ELSIF v_order.status <> 'ready' THEN
    RAISE EXCEPTION 'aid order % status=% cannot be returned (expected ready)', p_order_id, v_order.status;
  END IF;

  -- dest-facing 已收貨 transfer（air = 唯一 store_to_store；經總倉 = Leg-2 hq_to_store）
  SELECT * INTO v_recv_xfer
    FROM transfers
   WHERE customer_order_id = p_order_id
     AND tenant_id = v_order.tenant_id
     AND status = 'received'
   ORDER BY id DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no received transfer found for aid order %', p_order_id;
  END IF;
  v_dest_location := v_recv_xfer.dest_location;

  -- 原 source 店 location（同 rpc_ship_aid_order 的推導）
  SELECT * INTO v_src_order
    FROM customer_orders WHERE id = v_order.transferred_from_order_id;
  IF NOT FOUND OR v_src_order.pickup_store_id IS NULL THEN
    RAISE EXCEPTION 'source order % has no pickup_store', v_order.transferred_from_order_id;
  END IF;
  v_src_store_id := v_src_order.pickup_store_id;
  SELECT location_id INTO v_src_location FROM stores WHERE id = v_src_store_id;
  IF v_src_location IS NULL THEN
    RAISE EXCEPTION 'source store % has no location_id', v_src_store_id;
  END IF;
  IF v_src_location = v_dest_location THEN
    RAISE EXCEPTION 'source and dest share location_id %, cannot return', v_src_location;
  END IF;

  v_epoch := EXTRACT(EPOCH FROM NOW())::BIGINT;
  v_ret_no := 'AT-RET-O' || p_order_id || '-' || v_epoch;
  v_reason_note := '[aid return: ' || COALESCE(p_reason, '') || ']';

  -- 退貨 transfer：dest 店 → 原 source 店，一次反向（status=received 紙上即完成）
  INSERT INTO transfers (
    tenant_id, transfer_no, source_location, dest_location,
    status, transfer_type, customer_order_id, next_transfer_id,
    requested_by, shipped_by, shipped_at, received_by, received_at,
    notes, created_by, updated_by
  ) VALUES (
    v_order.tenant_id, v_ret_no, v_dest_location, v_src_location,
    'received', 'store_to_store', NULL, NULL,
    p_operator, p_operator, NOW(), p_operator, NOW(),
    v_reason_note, p_operator, p_operator
  ) RETURNING id INTO v_ret_id;

  -- 依實收量反向：dest outbound → source inbound
  FOR v_ti IN
    SELECT sku_id, COALESCE(qty_received, qty_shipped) AS qty
      FROM transfer_items
     WHERE transfer_id = v_recv_xfer.id
       AND COALESCE(qty_received, qty_shipped) > 0
  LOOP
    v_out_mov := rpc_outbound(
      p_tenant_id       => v_order.tenant_id,
      p_location_id     => v_dest_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty,
      p_movement_type   => 'transfer_out',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_ret_id,
      p_operator        => p_operator
    );
    v_in_mov := rpc_inbound(
      p_tenant_id       => v_order.tenant_id,
      p_location_id     => v_src_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty,
      p_unit_cost       => 0,
      p_movement_type   => 'transfer_in',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => v_ret_id,
      p_operator        => p_operator
    );
    INSERT INTO transfer_items (
      transfer_id, sku_id, qty_requested, qty_shipped, qty_received,
      out_movement_id, in_movement_id, created_by, updated_by
    ) VALUES (
      v_ret_id, v_ti.sku_id, v_ti.qty, v_ti.qty, v_ti.qty,
      v_out_mov, v_in_mov, p_operator, p_operator
    );
    v_items := v_items + 1;
    v_total_qty := v_total_qty + v_ti.qty;
  END LOOP;

  IF v_items = 0 THEN
    RAISE EXCEPTION 'received transfer % has no items to return', v_recv_xfer.id;
  END IF;

  -- 串接 timeline（received aid leg 是終端、next 應為 NULL）
  UPDATE transfers
     SET next_transfer_id = v_ret_id, updated_by = p_operator
   WHERE id = v_recv_xfer.id AND next_transfer_id IS NULL;

  -- aid 單 → cancelled
  UPDATE customer_orders
     SET status       = 'cancelled',
         cancelled_at = NOW(),
         updated_by   = p_operator,
         updated_at   = NOW()
   WHERE id = p_order_id;

  -- 來源單回 confirmed（mirror rpc_cancel_aid_order）
  IF v_order.transferred_from_order_id IS NOT NULL THEN
    UPDATE customer_orders
       SET status                  = 'confirmed',
           transferred_to_order_id = NULL,
           updated_by              = p_operator,
           updated_at              = NOW()
     WHERE id = v_order.transferred_from_order_id
       AND status = 'transferred_out';
  END IF;

  -- wallet 有付則 refund（mirror rpc_cancel_aid_order）
  IF v_order.wallet_paid_amount > 0 AND v_order.member_id IS NOT NULL THEN
    v_refund_ledger_id := rpc_wallet_refund(
      v_order.tenant_id,
      v_order.member_id,
      v_order.wallet_paid_amount,
      'customer_order',
      p_order_id,
      'aid_order_returned: ' || COALESCE(p_reason, '(no reason)'),
      p_operator
    );
    v_refunded_amount := v_order.wallet_paid_amount;
  END IF;

  RETURN jsonb_build_object(
    'order_id',                p_order_id,
    'return_transfer_id',      v_ret_id,
    'reversed_items',          v_items,
    'reversed_qty',            v_total_qty,
    'source_order_reverted',   v_order.transferred_from_order_id IS NOT NULL,
    'wallet_refunded',         v_refunded_amount,
    'wallet_refund_ledger_id', v_refund_ledger_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_return_aid_order(BIGINT, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_return_aid_order IS
  '已收貨互助單退單（#234 / R12）：status=ready（received 未取貨）才可。反向 dest 庫存→退回原 source 店、aid 單 cancelled、來源單 transferred_out→confirmed、wallet 有付自動 refund。completed（已取貨）/未收貨 明確 RAISE 引導改走客退 / rpc_cancel_aid_order。不動 mutual_aid_board / settlement（對齊 cancel/reject）。';
