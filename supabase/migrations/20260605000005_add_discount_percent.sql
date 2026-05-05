-- ============================================================
-- customer_orders.discount_percent
--   整單折扣的「比例版」（與 discount_amount 並存可同時使用）
--   值範圍 0-100，例：10 = 9折
--   payable = subtotal × (1 - percent/100) − discount_amount
--
-- 也擴充 customer_order_audit_log.field 允許 'discount_percent'
-- 並重建 v_customer_order_summary.payable_amount 公式
-- ============================================================

ALTER TABLE customer_orders
  ADD COLUMN discount_percent NUMERIC(5,2) NOT NULL DEFAULT 0
    CHECK (discount_percent >= 0 AND discount_percent <= 100);

COMMENT ON COLUMN customer_orders.discount_percent IS
  '整單折扣比例（0-100，例 10 = 9折）；與 discount_amount 並存：payable = subtotal × (1 − percent/100) − discount_amount';

-- 擴充 audit log field CHECK
ALTER TABLE customer_order_audit_log DROP CONSTRAINT customer_order_audit_log_field_check;
ALTER TABLE customer_order_audit_log
  ADD CONSTRAINT customer_order_audit_log_field_check
    CHECK (field IN ('unit_price','item_notes','discount_amount','discount_percent','order_notes'));

-- 重建 v_customer_order_summary 套用 percent
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
  'LIFF 顧客端共用：訂單聚合 + 品項詳細 + percent + amount 雙折扣';

-- 新 RPC：rpc_update_order_discount_percent
CREATE OR REPLACE FUNCTION rpc_update_order_discount_percent(
  p_order_id    BIGINT,
  p_new_percent NUMERIC,
  p_operator    UUID,
  p_reason      TEXT DEFAULT NULL
) RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order customer_orders%ROWTYPE;
  v_old   NUMERIC;
  v_row   customer_orders;
BEGIN
  v_order := _check_order_edit_perm(p_order_id);

  IF p_new_percent IS NULL OR p_new_percent < 0 OR p_new_percent > 100 THEN
    RAISE EXCEPTION 'discount_percent must be between 0 and 100';
  END IF;

  v_old := v_order.discount_percent;

  IF v_old = p_new_percent THEN
    RETURN v_order;
  END IF;

  UPDATE customer_orders
     SET discount_percent = p_new_percent,
         updated_by       = p_operator,
         updated_at       = NOW()
   WHERE id = p_order_id
   RETURNING * INTO v_row;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  VALUES
    (v_order.tenant_id, p_order_id, 'order', NULL, 'discount_percent',
     to_jsonb(v_old), to_jsonb(p_new_percent), p_reason, p_operator);

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_update_order_discount_percent(BIGINT, NUMERIC, UUID, TEXT) TO authenticated;
