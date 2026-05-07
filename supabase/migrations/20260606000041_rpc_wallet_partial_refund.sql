-- ============================================================
-- rpc_wallet_partial_refund: 訂單部分退儲值金（手動）
--
-- 場景：訂單未取消、但客人想退一部分（item-level partial cancel
-- 等更精細場景的 v1 替代）。
--
-- 流程（單一 transaction）：
--   1. advisory lock + SELECT FOR UPDATE on customer_orders
--   2. 斷言 p_amount <= wallet_paid_amount
--   3. 呼叫 rpc_wallet_refund(... type='refund')
--   4. UPDATE customer_orders SET wallet_paid_amount -= p_amount
--   5. 回 JSONB
--
-- reason 必填 ≥ 4 chars，沿用 rpc_wallet_refund 既有檢查。
-- 訂單狀態不擋（completed / partially_completed 都允許部分退）；
-- cancelled 不該再 partial — 因為 cancel 時已全退。
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_wallet_partial_refund(
  p_order_id  BIGINT,
  p_amount    NUMERIC,
  p_reason    TEXT,
  p_operator  UUID
) RETURNS JSONB AS $$
DECLARE
  v_order            customer_orders%ROWTYPE;
  v_member_status    TEXT;
  v_new_wallet_paid  NUMERIC;
  v_ledger_id        BIGINT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;
  IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) < 4 THEN
    RAISE EXCEPTION 'reason required (>=4 chars)';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders
   WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  IF v_order.status = 'cancelled' THEN
    RAISE EXCEPTION 'order % already cancelled (use cancel flow which auto-refunds)', p_order_id;
  END IF;
  IF v_order.member_id IS NULL THEN
    RAISE EXCEPTION 'order % has no member', p_order_id;
  END IF;
  IF v_order.wallet_paid_amount <= 0 THEN
    RAISE EXCEPTION 'order % has no wallet payment to refund', p_order_id;
  END IF;
  IF p_amount > v_order.wallet_paid_amount THEN
    RAISE EXCEPTION 'partial refund exceeds wallet_paid_amount: requesting=%, paid=%',
      p_amount, v_order.wallet_paid_amount;
  END IF;

  -- 會員狀態（merged / deleted 仍允許 refund — 錢應該還）
  SELECT status INTO v_member_status FROM members
   WHERE id = v_order.member_id AND tenant_id = v_order.tenant_id;
  IF v_member_status IS NULL THEN
    RAISE EXCEPTION 'member % not found', v_order.member_id;
  END IF;

  v_ledger_id := rpc_wallet_refund(
    v_order.tenant_id,
    v_order.member_id,
    p_amount,
    'customer_order',
    p_order_id,
    p_reason,
    p_operator
  );

  v_new_wallet_paid := v_order.wallet_paid_amount - p_amount;

  UPDATE customer_orders
     SET wallet_paid_amount = v_new_wallet_paid,
         -- 全退完且原本是 paid → 改回 unpaid（balance_due 又 > 0 了）
         payment_status = CASE
           WHEN v_new_wallet_paid = 0 AND payment_status = 'paid' THEN 'unpaid'
           ELSE payment_status
         END,
         paid_at = CASE
           WHEN v_new_wallet_paid = 0 AND payment_status = 'paid' THEN NULL
           ELSE paid_at
         END,
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ledger_id',          v_ledger_id,
    'wallet_paid_amount', v_new_wallet_paid,
    'refunded_amount',    p_amount
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_wallet_partial_refund(BIGINT, NUMERIC, TEXT, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_wallet_partial_refund(BIGINT, NUMERIC, TEXT, UUID) IS
  '訂單部分退儲值金；不取消訂單、只還錢。reason 必填。cancelled 訂單拒絕（用 cancel flow 自動退）';
