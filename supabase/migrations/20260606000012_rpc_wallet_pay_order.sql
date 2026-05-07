-- ============================================================
-- rpc_wallet_pay_order
--   Admin 後台「用儲值金結帳」單一原子操作
--
--   流程（單一 transaction）：
--   1. advisory lock + SELECT FOR UPDATE on customer_orders
--   2. 斷言 status IN (pending, confirmed)
--   3. 算 payable_amount（沿用 view 的公式：percent + amount 雙折扣）
--   4. 斷言 wallet_paid_amount + p_amount <= payable_amount
--   5. 呼叫 rpc_wallet_spend(...)（餘額不足會 RAISE）
--   6. UPDATE customer_orders SET wallet_paid_amount += p_amount
--      若 balance_due 歸 0 則 payment_status='paid' + paid_at=NOW
--   7. 回 JSONB 給前端 reload
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_wallet_pay_order(
  p_order_id  BIGINT,
  p_amount    NUMERIC,
  p_operator  UUID
) RETURNS JSONB AS $$
DECLARE
  v_order             customer_orders%ROWTYPE;
  v_member_status     TEXT;
  v_items_total       NUMERIC;
  v_payable           NUMERIC;
  v_new_wallet_paid   NUMERIC;
  v_new_balance_due   NUMERIC;
  v_ledger_id         BIGINT;
  v_paid              BOOLEAN := FALSE;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('aid_order:' || p_order_id));

  SELECT * INTO v_order FROM customer_orders
   WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found', p_order_id;
  END IF;
  IF v_order.status NOT IN ('pending','confirmed') THEN
    RAISE EXCEPTION 'order % is %, only pending/confirmed can be paid by wallet',
      p_order_id, v_order.status;
  END IF;
  IF v_order.member_id IS NULL THEN
    RAISE EXCEPTION 'order % has no member', p_order_id;
  END IF;

  -- 會員狀態擋（避免對 merged/deleted 扣款）
  SELECT status INTO v_member_status FROM members
   WHERE id = v_order.member_id AND tenant_id = v_order.tenant_id;
  IF v_member_status IS NULL THEN
    RAISE EXCEPTION 'member % not found', v_order.member_id;
  END IF;
  IF v_member_status <> 'active' THEN
    RAISE EXCEPTION 'member status=% cannot be charged', v_member_status;
  END IF;

  -- 算 payable（沿用 view 公式）
  SELECT COALESCE(SUM(qty * unit_price), 0)
    INTO v_items_total
    FROM customer_order_items
   WHERE order_id = p_order_id;

  v_payable := GREATEST(
    0,
    ROUND(v_items_total * (1 - v_order.discount_percent / 100), 4)
      + v_order.shipping_fee
      - v_order.discount_amount
  );

  v_new_wallet_paid := v_order.wallet_paid_amount + p_amount;
  IF v_new_wallet_paid > v_payable THEN
    RAISE EXCEPTION 'wallet pay exceeds balance_due: paying=%, already_paid=%, payable=%',
      p_amount, v_order.wallet_paid_amount, v_payable;
  END IF;

  -- 走 spend RPC（內部 FOR UPDATE 餘額、餘額不足 RAISE Insufficient wallet）
  v_ledger_id := rpc_wallet_spend(
    v_order.tenant_id,
    v_order.member_id,
    p_amount,
    'customer_order',
    p_order_id,
    p_operator
  );

  v_new_balance_due := v_payable - v_new_wallet_paid;
  v_paid := (v_new_balance_due = 0);

  UPDATE customer_orders
     SET wallet_paid_amount = v_new_wallet_paid,
         payment_status = CASE WHEN v_paid THEN 'paid' ELSE payment_status END,
         paid_at        = CASE WHEN v_paid AND paid_at IS NULL THEN NOW() ELSE paid_at END,
         updated_by     = p_operator,
         updated_at     = NOW()
   WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ledger_id',          v_ledger_id,
    'wallet_paid_amount', v_new_wallet_paid,
    'payable_amount',     v_payable,
    'balance_due',        v_new_balance_due,
    'payment_status',     CASE WHEN v_paid THEN 'paid' ELSE v_order.payment_status END,
    'paid_at',            CASE WHEN v_paid THEN COALESCE(v_order.paid_at, NOW()) ELSE v_order.paid_at END
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_wallet_pay_order(BIGINT, NUMERIC, UUID) TO authenticated;

COMMENT ON FUNCTION rpc_wallet_pay_order(BIGINT, NUMERIC, UUID) IS
  '用儲值金結帳；原子操作：lock 訂單 + 算 payable + 走 rpc_wallet_spend + UPDATE wallet_paid_amount + 全付清自動標 payment_status=paid';
