-- ============================================================
-- 2026-08-10: 會員端「未結單金額」只算「已訂未領貨」，不再把取過的貨一直掛帳
--
-- 回報案例（多位團友，會員 528590 / 581086 / 160806 / 091207）：
--   528590 的會員中心顯示「未結單金額 $3,072」，但同一頁點進「進行中訂單
--   7 筆」逐張加總只有 $1,110。581086 顯示 6,336 / 實際 1,421，
--   160806 顯示 5,280 / 實際 1,808，091207 顯示 9,700 / 實際 4,171。
--
-- 根因：liff-api getOverview 的「未結」定義是
--     payment_status = 'unpaid' AND status NOT IN ('cancelled','expired')
--   但 payment_status 這個欄位在這套系統裡**從來沒有被寫成 'paid' 過**
--   （現金在門市取貨當下收，rpc_record_pickup 不碰 payment_status；
--    唯一會寫 'paid' 的 rpc_wallet_pay_order 目前線上 0 筆使用）：
--
--     SELECT payment_status, count(*) FROM customer_orders GROUP BY 1;
--       unpaid | 65297      ← 全部，一筆 'paid' 都沒有
--
--   所以那個條件等於沒有條件，「未結單金額」實際上是
--   **這位會員從開站到現在所有沒被取消的訂單總和** —— 早就取貨付現的
--   23,731 張 completed 訂單全都還掛在上面，而且只會愈積愈多。
--   全站被多算的金額 = NT$4,822,464（1,745 位會員）。
--
-- 修法：不要再用 payment_status 當「有沒有收到錢」的依據，改用**品項有沒有
--   被取走**。取貨 = 付款（現金當場收），所以
--     未結 = 尚未取貨的品項金額
--   品項層級才算得準：partially_completed（取一半）那 69 張，用訂單層級
--   算會把已取走的那半也算進去。
--
--   新增兩個欄位到 v_customer_order_summary：
--     unpicked_total      尚未取貨的品項小計（排除 picked_up / cancelled / expired）
--     outstanding_amount  這張單真正還沒收的錢（unpicked_total 套用退貨扣減 /
--                         折扣 / 運費 / 已扣儲值金；終態訂單一律 0）
--
--   終態訂單（cancelled / expired / transferred_out）一律回 0：
--   transferred_out 的品項在轉手後**仍留在原單且維持 pending**
--   （見 20260507000000），貨已經在新單上，不歸零會整批重複計算
--   （線上 115 張、$29,560）。
--
--   items_total / payable_amount **語意不變** —— 那是「這張單本身多少錢」，
--   訂單明細、結單、admin 都在用；本次只是另外給「還沒收的部分」一個欄位。
--
-- 驗證（member 67982 = 528590）：
--   SUM(outstanding_amount) = 1110  ← 與「進行中訂單 7 筆」逐張加總一致
--   舊算法                  = 3072  ← 團友截圖那個數字
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   v_customer_order_summary：20260808000010_payable_exclude_cancelled_items.sql
--   （逐字保留，僅 agg LATERAL 加 unpicked_total、SELECT 清單加兩欄）
--
-- Rollback：v_customer_order_summary 還原為 20260808000010 版本
--   （前端 / liff-api 需一併回退，它們會 select outstanding_amount）
--
-- 對應程式（同一個 commit）：
--   supabase/functions/liff-api/index.ts
--     - getOverview：receivable 改加總 outstanding_amount，
--       active_orders_count 一併排除 transferred_out
--     - listMySettlements（tab=unpaid）：改用 outstanding_amount > 0
--   apps/member/src/components/SettlementCard.tsx（已付款判定）
--   apps/member/src/app/me/page.tsx、overview/page.tsx（加一行文案說明口徑）
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
  '不可以拿來當「有沒有收到錢」的依據。';

-- DROP + CREATE 會清掉 grant。public schema 的 default privileges 本來就會補回
-- anon/authenticated/service_role（20260731000000 沒寫 GRANT 也活著），這裡明寫一行
-- 當保險，不依賴 default privileges 的設定沒被動過。
GRANT SELECT ON v_customer_order_summary TO authenticated, anon;
