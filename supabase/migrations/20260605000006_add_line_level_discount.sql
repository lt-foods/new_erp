-- ============================================================
-- 單品項折扣（customer_order_items）：金額 + 百分比
--   line_subtotal = qty × unit_price × (1 − line_pct/100) − line_amt
-- 累計後再套用 order-level discount_percent / discount_amount
--
-- 也擴 audit log field、重建 v_customer_order_summary 套用線性折扣
-- ============================================================

ALTER TABLE customer_order_items
  ADD COLUMN discount_amount  NUMERIC(18,4) NOT NULL DEFAULT 0
    CHECK (discount_amount  >= 0),
  ADD COLUMN discount_percent NUMERIC(5,2)  NOT NULL DEFAULT 0
    CHECK (discount_percent >= 0 AND discount_percent <= 100);

COMMENT ON COLUMN customer_order_items.discount_amount  IS '單品項折扣金額 (line subtotal 直接扣除)';
COMMENT ON COLUMN customer_order_items.discount_percent IS '單品項折扣比例 0-100，例 20 = 80折';

-- 擴 audit log field
ALTER TABLE customer_order_audit_log DROP CONSTRAINT customer_order_audit_log_field_check;
ALTER TABLE customer_order_audit_log
  ADD CONSTRAINT customer_order_audit_log_field_check
    CHECK (field IN (
      'unit_price','item_notes','item_discount_amount','item_discount_percent',
      'discount_amount','discount_percent','order_notes'
    ));

-- 重建 view 套用 line-level discount → items_total → order discount
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
    ROUND(agg.items_total * (1 - co.discount_percent / 100), 4)
      + co.shipping_fee
      - co.discount_amount
  )                                                                            AS payable_amount,
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
    -- items_total 已套線性折扣
    COALESCE(SUM(
      GREATEST(
        0,
        ROUND(coi.qty * coi.unit_price * (1 - coi.discount_percent / 100), 4)
          - coi.discount_amount
      )
    ), 0) AS items_total,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',                    coi.id,
          'sku_id',                coi.sku_id,
          'sku_code',              sk.sku_code,
          'product_name',          sk.product_name,
          'variant_name',          sk.variant_name,
          'campaign_item_id',      coi.campaign_item_id,
          'qty',                   coi.qty,
          'unit_price',            coi.unit_price,
          'discount_amount',       coi.discount_amount,
          'discount_percent',      coi.discount_percent,
          'subtotal',              GREATEST(
            0,
            ROUND(coi.qty * coi.unit_price * (1 - coi.discount_percent / 100), 4)
              - coi.discount_amount
          ),
          'status',                coi.status,
          'notes',                 coi.notes,
          'image_url',             CASE
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
  'LIFF 顧客端共用：訂單聚合 + 品項詳細（含線性 + 整單兩層折扣 / amount + percent）';

-- 兩個新 RPC：item-level discount amount / percent
CREATE OR REPLACE FUNCTION rpc_update_order_item_discount_amount(
  p_order_id   BIGINT,
  p_item_id    BIGINT,
  p_new_amount NUMERIC,
  p_operator   UUID,
  p_reason     TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_order_items;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  IF p_new_amount IS NULL OR p_new_amount < 0 THEN
    RAISE EXCEPTION 'item discount_amount must be >= 0';
  END IF;

  SELECT discount_amount INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  IF v_old = p_new_amount THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET discount_amount = p_new_amount,
         updated_by      = p_operator,
         updated_at      = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'item_discount_amount',
     to_jsonb(v_old), to_jsonb(p_new_amount), p_reason, p_operator);

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION rpc_update_order_item_discount_percent(
  p_order_id    BIGINT,
  p_item_id     BIGINT,
  p_new_percent NUMERIC,
  p_operator    UUID,
  p_reason      TEXT DEFAULT NULL
) RETURNS customer_order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_order_items;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  IF p_new_percent IS NULL OR p_new_percent < 0 OR p_new_percent > 100 THEN
    RAISE EXCEPTION 'item discount_percent must be between 0 and 100';
  END IF;

  SELECT discount_percent INTO v_old
    FROM customer_order_items
   WHERE id = p_item_id AND order_id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item % not in order %', p_item_id, p_order_id;
  END IF;

  IF v_old = p_new_percent THEN
    SELECT * INTO v_row FROM customer_order_items WHERE id = p_item_id;
    RETURN v_row;
  END IF;

  UPDATE customer_order_items
     SET discount_percent = p_new_percent,
         updated_by       = p_operator,
         updated_at       = NOW()
   WHERE id = p_item_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'item', p_item_id, 'item_discount_percent',
     to_jsonb(v_old), to_jsonb(p_new_percent), p_reason, p_operator);

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_update_order_item_discount_amount(BIGINT, BIGINT, NUMERIC, UUID, TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_order_item_discount_percent(BIGINT, BIGINT, NUMERIC, UUID, TEXT) TO authenticated;
