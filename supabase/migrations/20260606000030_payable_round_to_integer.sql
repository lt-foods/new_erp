-- ============================================================
-- 應收金額一律四捨五入到整數 NTD
--
-- 之前 payable = ROUND(items*(1-pct/100), 4) + shipping - discount
--   → 折扣 23% 會出現 $228.69 之類小數，不能實際收費
-- 改為 payable = ROUND(items*(1-pct/100) + shipping - discount, 0)
--   → 一律取整數 NTD（PostgreSQL ROUND(numeric, 0) 為 half-away-from-zero）
--
-- 同步：
--   1. v_customer_order_summary.payable_amount + balance_due
--   2. rpc_wallet_pay_order 內 v_payable 計算
-- 對應 frontend：OrderDetail.applyOrderDiscount + PickupDialog.payableAmount
-- ============================================================

-- 1) v_customer_order_summary
DROP VIEW IF EXISTS v_customer_order_summary;

CREATE VIEW v_customer_order_summary AS
SELECT
  co.id,
  co.tenant_id,
  co.order_no,
  co.member_id,
  co.pickup_store_id          AS store_id,
  co.campaign_id,
  co.channel_id,
  co.status,
  co.payment_status,
  co.payment_method,
  co.paid_at,
  co.shipping_method,
  co.shipping_address,
  co.shipping_phone,
  co.shipping_note,
  co.remit_amount,
  co.remit_at,
  co.remit_note,
  co.shipping_fee,
  co.discount_amount,
  co.discount_percent,
  co.wallet_paid_amount,
  co.pickup_deadline,
  co.notes,
  co.created_at,
  co.confirmed_at,
  co.shipping_at,
  co.ready_at,
  co.completed_at,
  co.cancelled_at,
  agg.items_total,
  GREATEST(
    0,
    ROUND(
      agg.items_total * (1 - co.discount_percent / 100)
        + co.shipping_fee
        - co.discount_amount,
      0
    )
  )                                                                            AS payable_amount,
  GREATEST(
    0,
    GREATEST(
      0,
      ROUND(
        agg.items_total * (1 - co.discount_percent / 100)
          + co.shipping_fee
          - co.discount_amount,
        0
      )
    ) - co.wallet_paid_amount
  )                                                                            AS balance_due,
  agg.items,
  (co.status IN ('reserved','ready','partially_ready',
                 'partially_completed','shipping','completed'))                AS arrived,
  (co.confirmed_at IS NOT NULL
    OR co.status IN ('reserved','ready','partially_ready',
                     'partially_completed','shipping','completed'))            AS settled,
  (co.payment_status = 'paid')                                                 AS paid,
  (co.status IN ('shipping','completed'))                                      AS shipped,
  ('S-' || lpad(co.id::text, 8, '0')
        || '-'
        || COALESCE(s.store_short_code, 'XX'))                                 AS settlement_no,
  s.name                                                                        AS store_name,
  s.code                                                                        AS store_code,
  gbc.name                                                                      AS campaign_name,
  gbc.cover_image_url                                                           AS campaign_cover_url,
  gbc.end_at                                                                    AS campaign_end_at,
  gbc.cutoff_date                                                               AS campaign_cutoff_date
FROM customer_orders co
LEFT JOIN stores               s   ON s.id = co.pickup_store_id
LEFT JOIN group_buy_campaigns  gbc ON gbc.id = co.campaign_id
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0)                                 AS items_total,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',               coi.id,
          'sku_id',           coi.sku_id,
          'sku_code',         sk.sku_code,
          'product_name',     sk.product_name,
          'variant_name',     sk.variant_name,
          'campaign_item_id', coi.campaign_item_id,
          'qty',              coi.qty,
          'unit_price',       coi.unit_price,
          'subtotal',         coi.qty * coi.unit_price,
          'status',           coi.status,
          'notes',            coi.notes,
          'image_url',        CASE
            WHEN jsonb_typeof(p.images) = 'array' AND jsonb_array_length(p.images) > 0 THEN
              COALESCE(p.images -> 0 ->> 'url', p.images ->> 0)
            ELSE NULL
          END
        ) ORDER BY coi.id
      ),
      '[]'::jsonb
    )                                                                           AS items
  FROM customer_order_items coi
  LEFT JOIN skus     sk ON sk.id = coi.sku_id
  LEFT JOIN products p  ON p.id  = sk.product_id
  WHERE coi.order_id = co.id
) agg ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合 + 品項詳細 + percent + amount 雙折扣 + 儲值金抵扣 + balance_due（應收已四捨五入到整數 NTD）';

-- 2) rpc_wallet_pay_order — payable 算式同步
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

  -- payable 四捨五入到整數 NTD（同 v_customer_order_summary）
  v_payable := GREATEST(
    0,
    ROUND(
      v_items_total * (1 - v_order.discount_percent / 100)
        + v_order.shipping_fee
        - v_order.discount_amount,
      0
    )
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
