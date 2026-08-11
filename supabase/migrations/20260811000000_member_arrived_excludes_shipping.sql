-- ============================================================
-- 2026-08-11: 會員端「待取貨」不可以在貨還沒進店時就亮起來
--
-- 回報案例（古華店 / 冠顗油飯9香麻油雞肉油飯（一斤重）$155）：
--   團友的「我的訂單」把該筆放進「待取貨 1」，卡片右上角寫「待取貨」；
--   但同一時間 WMS /wms/receive 顯示該波次 WV26081100135 還在「未收 (16)」
--   —— 總倉 2026-08-11 11:05 才派出，門市根本還沒收貨。
--   團友跑一趟店裡會領不到東西。
--
-- 根因：v_customer_order_summary.arrived 把 'shipping' 算成「已到店」：
--
--     (co.status IN ('reserved','ready','partially_ready',
--                    'partially_completed','shipping','completed')) AS arrived
--
--   但 customer_orders.status 的語意是（apps/admin/src/lib/orderStatus.ts）：
--     shipping = 派貨中  ← 總倉波次已出貨，**門市尚未收貨**
--     ready    = 可取貨  ← rpc_receive_transfer 收貨後、且
--                          is_order_pickup_ready() 逐項確認該團該 SKU 實收
--                          qty_received > 0 才會推上來（20260703000000）
--   會員端 OrderCard.orderPhase() 只看 arrived 分「待到貨 / 待取貨」，
--   於是「總倉一派出」= 團友看到「待取貨」，中間整段運送時間全是假的。
--
--   線上規模（修之前）：
--     status='shipping' 共 2,260 張，其中 is_order_pickup_ready() = true 只有 6 張
--     → 約 2,254 張訂單正對著團友顯示「待取貨」，貨其實還在路上。
--
--   同一支 liff-api 的「取貨提醒條」(getOverview) 用的是 status='ready'，
--   兩邊口徑本來就對不上；這次以 'ready' 為準。
--
-- 修法：arrived 拿掉 'shipping'。到店與否一律以訂單狀態被推到 ready 為準
--   （= 門市確實收到貨 + 該單每一項都實收 > 0）。
--     shipping             → 待到貨（運送中，正確）
--     reserved/ready       → 待取貨（已在店裡）
--     partially_ready      → 待取貨（同上；兩者線上皆 0 筆，語意保留）
--     partially_completed  → OrderCard 直接判「部分已取」，不看 arrived
--     completed            → 已完成，同樣不看 arrived
--
--   settled（是否已結單）**不動**：'shipping' 對「這團結單了沒」而言是對的，
--   而且線上沒有畫面在用它。shipped (status IN ('shipping','completed')) 也不動。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   v_customer_order_summary：20260810000000_receivable_exclude_picked_up.sql
--   （逐字複製，只改 arrived 那一個運算式）
--
-- Rollback：v_customer_order_summary 還原為 20260810000000 版本
--
-- 驗證：
--   SELECT status, arrived, count(*) FROM v_customer_order_summary
--    WHERE status IN ('shipping','ready') GROUP BY 1,2;
--   -- shipping 應該全是 arrived=false，ready 全是 true
--
-- 對應程式（同一個 commit）：
--   apps/member/src/components/OrderCard.tsx —— orderPhase() 明寫
--   case 'shipping' → waiting，view 萬一被 rollback 前端也不會再誤報。
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
  agg.items_total,
  agg.unpicked_total,
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
  -- 20260810000000：還沒收的錢 = 尚未取貨品項套同一條應收算式，再扣掉已付的儲值金。
  -- 終態訂單（cancelled / expired / transferred_out）與「已全部取走」一律 0；
  -- 全取走時直接回 0，不讓運費 / 折扣在沒有貨的情況下自己長出金額。
  CASE
    WHEN co.status IN ('cancelled','expired','transferred_out') THEN 0
    WHEN agg.unpicked_total <= 0                                THEN 0
    ELSE GREATEST(
      0,
      GREATEST(
        0,
        ROUND(
          GREATEST(0, agg.unpicked_total - ret.returned_deduction)
            * (1 - co.discount_percent / 100)
            + co.shipping_fee
            - co.discount_amount,
          0
        )
      ) - co.wallet_paid_amount
    )
  END                                                                          AS outstanding_amount,
  agg.items,
  -- 20260811000000：'shipping' = 派貨中（總倉已出貨、門市未收貨），不是「到店可取」。
  -- 到店與否只認 status 被推到 ready 之後的狀態（rpc_receive_transfer 收貨 +
  -- is_order_pickup_ready 逐項確認實收 > 0 才會推）。
  (co.status IN ('reserved','ready','partially_ready',
                 'partially_completed','completed'))                           AS arrived,
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
    -- 20260810000000：尚未取貨的部分（picked_up 也排掉）。取貨當下收現金，
    -- 所以「取走了」＝「收到錢了」，不該再算在未結裡。
    COALESCE(SUM(coi.qty * coi.unit_price)
               FILTER (WHERE coi.status NOT IN ('cancelled','expired','picked_up')), 0)
                                                                              AS unpicked_total,
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
  '+ 未取退貨扣減（returned_qty / returned_deduction；取貨後退回不扣、退款走 rpc_wallet_partial_refund）'
  '。20260808000010：items_total 不含 cancelled/expired 品項（斷貨 / 人工刪除的品項不收錢）；'
  'items[] 仍保留這些行供前端顯示「斷貨」。'
  '20260810000000：新增 unpicked_total / outstanding_amount —— 會員端「未結單金額」'
  '（已訂未領貨）專用，取貨即收現金，所以 picked_up 品項不算；'
  'cancelled/expired/transferred_out 訂單一律 0。payment_status 全站從未寫過 ''paid''，'
  '不可以拿來當「有沒有收到錢」的依據。'
  '20260811000000：arrived 不再含 ''shipping'' —— 派貨中＝貨還在路上，會員端只有門市收貨（status→ready）後才顯示「待取貨」。';

-- DROP + CREATE 會清掉 grant。public schema 的 default privileges 本來就會補回
-- anon/authenticated/service_role（20260731000000 沒寫 GRANT 也活著），這裡明寫一行
-- 當保險，不依賴 default privileges 的設定沒被動過。
GRANT SELECT ON v_customer_order_summary TO authenticated, anon;
