-- ============================================================
-- rpc_wallet_pay_order: 放寬可結帳的訂單狀態
--   原版只允許 pending / confirmed，但實務上 confirmed 後很快會
--   跳到 reserved / ready（商品到齊待取），這些都應該還能用儲值金結帳。
--   只擋已完成 / 取消 / 轉出 / 逾期 / 已取貨 + 已 paid 的訂單。
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
  IF v_order.status IN ('completed','picked_up','cancelled','expired','transferred_out') THEN
    RAISE EXCEPTION 'order % is %, cannot be paid by wallet', p_order_id, v_order.status;
  END IF;
  IF v_order.payment_status = 'paid' THEN
    RAISE EXCEPTION 'order % already paid', p_order_id;
  END IF;
  IF v_order.member_id IS NULL THEN
    RAISE EXCEPTION 'order % has no member', p_order_id;
  END IF;

  SELECT status INTO v_member_status FROM members
   WHERE id = v_order.member_id AND tenant_id = v_order.tenant_id;
  IF v_member_status IS NULL THEN
    RAISE EXCEPTION 'member % not found', v_order.member_id;
  END IF;
  IF v_member_status <> 'active' THEN
    RAISE EXCEPTION 'member status=% cannot be charged', v_member_status;
  END IF;

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
