-- ============================================================
-- v_customer_order_summary：加品項詳細 + campaign 名
--
-- LIFF 顧客端「我的訂單」要顯示：
--   - 商品名 / 規格 / sku_code（避免顧客看到只有 sku_id）
--   - campaign 名（活動名 = 卡片頂部 title）
--   - campaign cover image
-- ============================================================

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
  co.pickup_deadline,
  co.notes,
  co.created_at,
  co.confirmed_at,
  co.shipping_at,
  co.ready_at,
  co.completed_at,
  co.cancelled_at,
  agg.items_total,
  agg.items_total + co.shipping_fee - co.discount_amount   AS payable_amount,
  agg.items,
  (co.status IN ('reserved','ready','partially_ready',
                 'partially_completed','shipping','completed'))                  AS arrived,
  (co.confirmed_at IS NOT NULL
    OR co.status IN ('reserved','ready','partially_ready',
                     'partially_completed','shipping','completed'))              AS settled,
  (co.payment_status = 'paid')                                                   AS paid,
  (co.status IN ('shipping','completed'))                                        AS shipped,
  ('S-' || lpad(co.id::text, 8, '0')
        || '-'
        || COALESCE(s.store_short_code, 'XX'))                                   AS settlement_no,
  s.name                                                                          AS store_name,
  s.code                                                                          AS store_code,
  -- campaign 顯示資訊
  gbc.name                                                                        AS campaign_name,
  gbc.cover_image_url                                                             AS campaign_cover_url,
  gbc.end_at                                                                      AS campaign_end_at,
  gbc.cutoff_date                                                                 AS campaign_cutoff_date
FROM customer_orders co
LEFT JOIN stores               s   ON s.id = co.pickup_store_id
LEFT JOIN group_buy_campaigns  gbc ON gbc.id = co.campaign_id
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0)                                   AS items_total,
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
          'notes',            coi.notes
        ) ORDER BY coi.id
      ),
      '[]'::jsonb
    )                                                                             AS items
  FROM customer_order_items coi
  LEFT JOIN skus sk ON sk.id = coi.sku_id
  WHERE coi.order_id = co.id
) agg ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合 + 品項詳細（含 sku 名/規格） + campaign 名 + 結單號';
