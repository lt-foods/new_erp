-- ============================================================
-- 2026-08-11 (2)：「到店了沒」改問取貨閘門，不要只看單頭 status
--
-- 承 20260811000000（arrived 拿掉 'shipping'）。那一版把「到店」定義成
-- 「單頭 status 已被推到 ready 之後」，方向對，但漏了一種單：
--
--   文山店 campaign 3090（GRP-20260715-028）6 張單 —— 該團該店開了**抵減單**
--   （order_kind='offset' 負數訂單，店內現貨吸收這組缺口），取貨閘門
--   is_order_pickup_ready() 走 Path D' 判定「可以交貨」，店員也真的能發貨；
--   但門市那張 hq_to_store transfer (10217) 還沒收，rpc_receive_transfer 沒跑過，
--   單頭就一直卡在 'shipping'。只看 status 的話這 6 張會顯示「待到貨」，
--   團友被擋在門外，貨其實就在店裡。
--
-- 修法：'shipping' 的列改問品項層級的取貨閘門 is_order_item_pickup_ready()，
--   **只要有任何一項到貨可取就算「待取貨」**（不要求整張全到齊）——
--   店員本來就是用同一道品項閘門逐項發貨（PickupDialog 只勾得到已到貨的行），
--   要求全到齊會把「已經有東西可以領」的單擋在「待到貨」，反向誤導。
--   閘門是 rpc_record_pickup 交貨時用的同一套（Path A/B/C/D、qty_received > 0、
--   backorder_at 擋板），所以會員看到「待取貨」＝店員確實按得下去「取貨」。
--   門市完全沒收貨的單，每一項都過不了閘門 → 一律「待到貨」，
--   本次回報的「貨在路上卻顯示待取貨」就此消失。
--
-- 為什麼 ready 之後的狀態不一起重判（刻意保留快路徑，只加不減）：
--   線上 14,454 張 status='ready' 裡有 63 張整單閘門回 false（52 張含待補貨
--   backorder_at 品項、8 張已無 active 品項、3 張該項未到），其他行多半仍可取。
--   ready 是收貨那一刻算過閘門才推上來的，維持「一旦可取就不會被畫面收回去」
--   對團友比較好懂。→ 這一版只會把單子從「待到貨」救回「待取貨」，不會降級。
--
--   效能：函式只對 status='shipping' 的列呼叫（線上 2,260 / 65,297 ≈ 3.5%），
--   其餘走原本的 status IN (...) 快路徑。實測單一會員 100 筆內 < 20ms；
--   本 view 只有 liff-api 在用，且一律帶 member_id + limit 100。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   v_customer_order_summary：20260811000000_member_arrived_excludes_shipping.sql
--   （逐字複製，只改 arrived 那一個運算式）
--
-- Rollback：v_customer_order_summary 還原為 20260811000000 版本
--
-- 對應程式（同一個 commit）：
--   apps/member/src/components/OrderCard.tsx —— 'shipping' 不再硬判「待到貨」，
--   改成尊重 arrived；只有 arrived=false 時才把標籤寫成「運送中」。
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
  -- 20260811000010：到店與否＝「現在有沒有東西可以交給客人」，直接問品項層級的
  -- 取貨閘門（店員發貨用的同一套），不要只看單頭 status —— 單頭只有
  -- rpc_receive_transfer 收到該店 transfer 時才會被推到 ready，靠店內現貨
  -- 吸收缺口的單永遠等不到那一刻。有任一項可取即算，不要求整張全到齊。
  -- 快路徑先擋掉 96%：已經是 ready 之後的狀態一律 true，函式只對 'shipping' 呼叫。
  (co.status IN ('reserved','ready','partially_ready',
                 'partially_completed','completed')
   OR (co.status = 'shipping' AND EXISTS (
         SELECT 1 FROM customer_order_items coi
          WHERE coi.order_id = co.id
            AND coi.status IN ('pending','reserved','ready')
            AND public.is_order_item_pickup_ready(coi.id)
       )))                                                                      AS arrived,
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
  '20260811000010：arrived 改問品項層級取貨閘門 is_order_item_pickup_ready() —— '
  '派貨中（門市未收貨）一律不算到店；有任一項可取即算，不要求全到齊。';

-- DROP + CREATE 會清掉 grant。public schema 的 default privileges 本來就會補回
-- anon/authenticated/service_role（20260731000000 沒寫 GRANT 也活著），這裡明寫一行
-- 當保險，不依賴 default privileges 的設定沒被動過。
GRANT SELECT ON v_customer_order_summary TO authenticated, anon;
