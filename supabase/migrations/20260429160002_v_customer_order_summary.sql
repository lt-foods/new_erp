-- ============================================================
-- v_customer_order_summary
--   LIFF 顧客端「我的訂單 / 我的結單」共用 view
--
-- 提供：
--   - 聚合金額（items_total / payable_amount）
--   - items JSONB 陣列（避免 N+1 query）
--   - 4 個狀態 chips boolean：arrived / settled / paid / shipped
--   - 結單衍生欄位 settlement_no（S-xxxxxxxx-XX）
--   - store_name / store_code（顯示用）
--
-- 由 service_role（Edge Function liff-api）讀，view 不需獨立 RLS；
-- 呼叫端負責 member_id + store_id filter。
-- ============================================================

CREATE OR REPLACE VIEW v_customer_order_summary AS
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
  -- 聚合金額 + items
  agg.items_total,
  agg.items_total + co.shipping_fee - co.discount_amount   AS payable_amount,
  agg.items,
  -- 狀態 chips（4 個 boolean）
  (co.status IN ('reserved','ready','partially_ready',
                 'partially_completed','shipping','completed'))                  AS arrived,
  (co.confirmed_at IS NOT NULL
    OR co.status IN ('reserved','ready','partially_ready',
                     'partially_completed','shipping','completed'))              AS settled,
  (co.payment_status = 'paid')                                                   AS paid,
  (co.status IN ('shipping','completed'))                                        AS shipped,
  -- 結單衍生
  ('S-' || lpad(co.id::text, 8, '0')
        || '-'
        || COALESCE(s.store_short_code, 'XX'))                                   AS settlement_no,
  s.name                                                                          AS store_name,
  s.code                                                                          AS store_code
FROM customer_orders co
LEFT JOIN stores s ON s.id = co.pickup_store_id
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0)                                   AS items_total,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',               coi.id,
          'sku_id',           coi.sku_id,
          'campaign_item_id', coi.campaign_item_id,
          'qty',              coi.qty,
          'unit_price',       coi.unit_price,
          'status',           coi.status
        ) ORDER BY coi.id
      ),
      '[]'::jsonb
    )                                                                             AS items
  FROM customer_order_items coi
  WHERE coi.order_id = co.id
) agg ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合金額 + items + 4 chip booleans + 結單號（S-xxxxxxxx-XX）';
