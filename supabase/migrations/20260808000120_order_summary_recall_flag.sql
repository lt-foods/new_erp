-- ============================================================
-- 2026-08-08: v_customer_order_summary 加召回標記
--
-- 召回的品項沿用 status='cancelled' + recalled_at（與斷貨同型，見
-- 20260808000100_recall_schema.sql 檔頭），所以 items_total 已經自動
-- 不含它們（20260808000010）。但會員端 OrderCard 是靠 items[].stockout
-- 決定要不要畫刪除線 + 標籤 —— 召回的行 stockout 是 false，結果那一列
-- 看起來完全正常卻不計入件數/金額，「商品（N 件）$X」對不起來。
--
-- 所以只加兩個欄位、其他逐字保留：
--   co.recalled_at        整單因召回結束
--   items[].recalled      該品項行是因召回被取消
--
-- 基底版本（逐字複製後只插入上述兩行）：
--   20260808000010_payable_exclude_cancelled_items.sql（線上最新）
-- Rollback：重跑 20260808000010 的 DROP VIEW + CREATE VIEW 段落。
-- TEST: docs/TEST-warehouse-recall.md §F
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
  co.stockout_at,
  co.recalled_at,
  agg.items_total,
  ret.returned_qty,
  ret.returned_deduction,
  GREATEST(
    0,
    ROUND(
      GREATEST(0, agg.items_total - ret.returned_deduction)
        * (1 - co.discount_percent / 100)
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
        GREATEST(0, agg.items_total - ret.returned_deduction)
          * (1 - co.discount_percent / 100)
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
    COALESCE(SUM(coi.qty * coi.unit_price)
               FILTER (WHERE coi.status NOT IN ('cancelled','expired')), 0)  AS items_total,
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
          'stockout',         (coi.stockout_at IS NOT NULL),
          'recalled',         (coi.recalled_at IS NOT NULL),
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
) agg ON TRUE
LEFT JOIN LATERAL (
  -- 未取退貨扣減：return_to_hq（shipped/received、notes header 不含
  -- |取貨後退回）依 SKU 聚合退貨量，按品項行序 (id) 分攤到未取消品項行、
  -- 以該行 unit_price 折算金額
  SELECT
    COALESCE(SUM(a.alloc_qty), 0)                AS returned_qty,
    COALESCE(SUM(a.alloc_qty * a.unit_price), 0) AS returned_deduction
  FROM (
    SELECT
      i.unit_price,
      LEAST(i.qty, GREATEST(r.ret_qty - i.prior_qty, 0)) AS alloc_qty
    FROM (
      SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
        FROM transfers t
        JOIN transfer_items ti ON ti.transfer_id = t.id
       WHERE t.customer_order_id = co.id
         AND t.tenant_id     = co.tenant_id
         AND t.transfer_type = 'return_to_hq'
         AND t.status IN ('shipped','received')
         AND COALESCE(substring(t.notes FROM '^\[order return([^\]:]*)'), '')
             NOT LIKE '%取貨後退回%'
       GROUP BY ti.sku_id
    ) r
    JOIN (
      SELECT coi.sku_id, coi.qty, coi.unit_price,
             COALESCE(SUM(coi.qty) OVER (
               PARTITION BY coi.sku_id ORDER BY coi.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS prior_qty
        FROM customer_order_items coi
       WHERE coi.order_id = co.id
         AND coi.status NOT IN ('cancelled','expired')
    ) i ON i.sku_id = r.sku_id
  ) a
) ret ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合 + 品項詳細 + percent + amount 雙折扣 + 儲值金抵扣 + balance_due'
  '（應收已四捨五入到整數 NTD）+ 斷貨標記（stockout_at / items[].stockout）'
  '+ 召回標記（recalled_at / items[].recalled，20260808000120）'
  '+ 未取退貨扣減（returned_qty / returned_deduction；取貨後退回不扣、退款走 rpc_wallet_partial_refund）'
  '。items_total 不含 cancelled/expired 品項（斷貨 / 召回 / 人工刪除的品項不收錢）；'
  'items[] 仍保留這些行供前端顯示「斷貨」「召回」。';

-- DROP + CREATE 會清掉 grant，明寫補回（同 20260808000010）
GRANT SELECT ON v_customer_order_summary TO anon, authenticated, service_role;
