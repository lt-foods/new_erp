-- ============================================================
-- 2026-08-08: 訂單「應收」不再含已取消 / 斷貨的品項
--
-- 回報案例（訂單 GRP-20260712-004-0046, id=49469）：
--   4 個品項取走 3 個（$218）、第 4 項斷貨取消（$65），訂單明細頁
--   仍顯示「原價 $283 · 小計 $283 · 應收 $283」，「用儲值金結帳」也
--   按 $283 開。客人拿不到的貨不該收錢。
--
-- 根因：items_total = SUM(qty * unit_price) 完全不濾 coi.status，
--   斷貨取消（status='cancelled' + stockout_at，見 20260702020000）
--   與人工刪除品項（rpc_delete_order_item 軟刪成 cancelled）都還留在
--   加總裡。同一條算式散在四處，全都沒濾：
--     v_customer_order_summary.items_total（admin 明細 + LIFF 會員端）
--     rpc_wallet_pay_order.v_items_total（儲值金可扣上限）
--     v_admin_orders_list.total_amount（/orders 列表「總金額」欄，可排序）
--     admin OrderDetail / orders 列表 / member OrderCard 的前端加總
--
--   線上影響：241 張未結訂單合計多算 NT$24,630；其中
--   payment_status='paid' 0 張、wallet_paid_amount > 0 也 0 張
--   → 沒有任何已收款訂單會因為應收下修而出現負的 balance_due。
--
-- 修法：加總一律加 `status NOT IN ('cancelled','expired')`。
--   - 這與同一支 view 的 returned_deduction 分攤子查詢（20260731000000）
--     早就在用的過濾條件一致 —— 之前是「扣減只認 active 行、母數卻含
--     全部行」，本次把母數對齊。
--   - items[] jsonb **不濾**：前端要繼續顯示「⛔ 斷貨」那一列
--     （會員端 OrderCard 會把它畫成刪除線）。
--   - 'expired' 一併排除：與 cancelled 同屬「這行不算數」的終態，
--     既有過濾慣例都是兩個一起寫。
--
-- 基底版本（append-only，逐字保留所有 prior fix）：
--   - v_customer_order_summary：20260731000000_return_deduct_payable_and_pickup_guard.sql
--     （逐字保留，僅 items_total 加 FILTER + COMMENT 補一句）
--   - rpc_wallet_pay_order：20260731000000_return_deduct_payable_and_pickup_guard.sql
--     （逐字保留，僅 v_items_total 的 SELECT 加 WHERE）
--   - v_admin_orders_list：20260807000000_v_admin_orders_list_sortable.sql
--     （逐字保留，僅 LATERAL 彙總加 WHERE；line_count / total_qty 一併排除，
--      不然會出現「5 件 $218」這種列不起來的組合）
--
-- 對應前端（同一個 commit）：
--   - apps/admin/src/components/OrderDetail.tsx（原價 / 小計 / 件數）
--   - apps/admin/src/app/(protected)/orders/page.tsx（列表品項彙總）
--   - apps/member/src/components/OrderCard.tsx（商品件數）
--   PickupDialog 不動：它本來就只加總本次勾選的品項。
--
-- Rollback：
--   - v_customer_order_summary / rpc_wallet_pay_order 還原為 20260731000000 版本
--   - v_admin_orders_list 還原為 20260807000000 版本
--
-- TEST: docs/TEST-stockout-closes-picked-order.md §D
-- ============================================================

-- ------------------------------------------------------------
-- 1. v_customer_order_summary v4 — items_total 排除 cancelled/expired
-- ------------------------------------------------------------

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
  'items[] 仍保留這些行供前端顯示「斷貨」。';

-- DROP + CREATE 會清掉 grant。public schema 的 default privileges 本來就會補回
-- anon/authenticated/service_role（20260731000000 沒寫 GRANT 也活著），這裡明寫一行
-- 當保險，不依賴 default privileges 的設定沒被動過。
GRANT SELECT ON v_customer_order_summary TO authenticated, anon;

-- ------------------------------------------------------------
-- 2. rpc_wallet_pay_order — v_items_total 同步排除 cancelled/expired
--    基底 20260731000000 逐字保留，僅 v_items_total 的 SELECT 加 WHERE
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION rpc_wallet_pay_order(
  p_order_id  BIGINT,
  p_amount    NUMERIC,
  p_operator  UUID
) RETURNS JSONB AS $$
DECLARE
  v_order              customer_orders%ROWTYPE;
  v_member_status      TEXT;
  v_items_total        NUMERIC;
  v_returned_deduction NUMERIC;
  v_payable            NUMERIC;
  v_new_wallet_paid    NUMERIC;
  v_new_balance_due    NUMERIC;
  v_ledger_id          BIGINT;
  v_paid               BOOLEAN := FALSE;
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

  -- 20260808000010：已取消 / 斷貨的品項不收錢（同 v_customer_order_summary.items_total）
  SELECT COALESCE(SUM(qty * unit_price), 0)
    INTO v_items_total
    FROM customer_order_items
   WHERE order_id = p_order_id
     AND status NOT IN ('cancelled','expired');

  -- 未取退貨扣減（同 v_customer_order_summary 的 ret LATERAL）
  SELECT COALESCE(SUM(a.alloc_qty * a.unit_price), 0)
    INTO v_returned_deduction
    FROM (
      SELECT
        i.unit_price,
        LEAST(i.qty, GREATEST(r.ret_qty - i.prior_qty, 0)) AS alloc_qty
      FROM (
        SELECT ti.sku_id, SUM(ti.qty_shipped) AS ret_qty
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.customer_order_id = p_order_id
           AND t.tenant_id     = v_order.tenant_id
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
         WHERE coi.order_id = p_order_id
           AND coi.status NOT IN ('cancelled','expired')
      ) i ON i.sku_id = r.sku_id
    ) a;

  -- payable 四捨五入到整數 NTD（同 v_customer_order_summary）
  v_payable := GREATEST(
    0,
    ROUND(
      GREATEST(0, v_items_total - v_returned_deduction)
        * (1 - v_order.discount_percent / 100)
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

COMMENT ON FUNCTION rpc_wallet_pay_order(BIGINT, NUMERIC, UUID) IS
  '儲值金結帳：可扣上限 = 應收 − 已扣。應收算式與 v_customer_order_summary.payable_amount 同步 '
  '（未取退貨扣減 @20260731000000；20260808000010 起不含 cancelled/expired 品項）。';

-- ------------------------------------------------------------
-- 3. v_admin_orders_list — /orders 列表彙總排除 cancelled/expired
--    基底 20260807000000 逐字保留，僅 LATERAL 加 WHERE
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_admin_orders_list;

CREATE VIEW v_admin_orders_list
WITH (security_invoker = true) AS
SELECT
  o.*,
  c.name AS campaign_name,
  COALESCE(m.name, o.nickname_snapshot) AS member_name,
  s.name AS store_name,
  agg.line_count,
  agg.total_qty,
  agg.total_amount,
  agg.source_summary
FROM v_admin_orders o
LEFT JOIN group_buy_campaigns c ON c.id = o.campaign_id
LEFT JOIN members m ON m.id = o.member_id
LEFT JOIN stores s ON s.id = o.pickup_store_id
LEFT JOIN LATERAL (
  SELECT
    count(*)::int                          AS line_count,
    COALESCE(sum(i.qty), 0)                AS total_qty,
    COALESCE(sum(i.qty * i.unit_price), 0) AS total_amount,
    CASE WHEN count(DISTINCT i.source) > 1 THEN 'mixed'
         ELSE min(i.source) END            AS source_summary
  FROM customer_order_items i
  WHERE i.order_id = o.id
    -- 20260808000010：已取消 / 斷貨的品項不算進項數 / 件數 / 金額
    AND i.status NOT IN ('cancelled','expired')
) agg ON true;

COMMENT ON VIEW v_admin_orders_list IS
  '/orders 列表查詢用：v_admin_orders + 可排序欄位（campaign_name / member_name / '
  'store_name / line_count / total_qty / total_amount / source_summary）。'
  '只給列表 + 選取全部用；tab 數量與趨勢的 rpc_order_overview 維持查 v_admin_orders，'
  '避免整表聚合時多揹 per-row 品項彙總。'
  '20260808000010：彙總排除 cancelled/expired 品項，與訂單明細的應收同一套語意。';

GRANT SELECT ON v_admin_orders_list TO authenticated;
