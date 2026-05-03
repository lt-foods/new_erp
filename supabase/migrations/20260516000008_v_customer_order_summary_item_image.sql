-- ============================================================
-- v_customer_order_summary：items 加 image_url
--
-- LIFF 顧客端的「我的訂單」要在每個品項旁顯示商品圖。images 是 products
-- 的 JSONB array，可能是 ["path"] 或 [{url:"path"}]，取第一張當縮圖。
-- 注意：image_url 留下相對 path（liff-api 端會經 toPublicUrl 轉 storage URL）
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
          'notes',            coi.notes,
          'image_url',        CASE
            WHEN jsonb_typeof(p.images) = 'array' AND jsonb_array_length(p.images) > 0 THEN
              COALESCE(p.images -> 0 ->> 'url', p.images ->> 0)
            ELSE NULL
          END
        ) ORDER BY coi.id
      ),
      '[]'::jsonb
    )                                                                             AS items
  FROM customer_order_items coi
  LEFT JOIN skus     sk ON sk.id = coi.sku_id
  LEFT JOIN products p  ON p.id  = sk.product_id
  WHERE coi.order_id = co.id
) agg ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合 + 品項詳細（含 sku 名/規格/縮圖 path） + campaign 名 + 結單號';
