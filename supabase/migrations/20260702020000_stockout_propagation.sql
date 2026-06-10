-- ============================================================
-- 斷貨連動：採購單斷貨 → 開團商品 / 顧客訂單 / 顧客通知
--
-- 需求：
--   1. 開團商品明細顯示「斷貨」
--   2. 受影響的顧客訂單品項 / 訂單顯示「斷貨」
--   3. 顧客在 LIFF 端看得到斷貨狀態（含通知中心留底）
--
-- 設計重點 — 為什麼「不」新增 status 值：
--   customer_order_items.status 被大量 view / RPC 用
--   `status NOT IN ('cancelled','expired')` 過濾（v_picking_demand_by_po、
--   rpc_create_wave_from_po、fix_pr_campaigns_sync、rpc_orders_pivot…）。
--   新增 'stockout' 值會讓斷貨品項繼續被算進撿貨需求，得改十幾支 view。
--   因此斷貨品項沿用 status='cancelled'（所有既有過濾自動正確），
--   另以 stockout_at 欄位區分「斷貨」與「一般取消」，顯示時優先顯示斷貨。
--
-- 基底版本：
--   - rpc_stockout_purchase_order：基於 20260702010000_po_delete_and_stockout.sql
--     （唯一前版）擴寫，保留原 PO 守衛與狀態轉換。
--   - v_customer_order_summary：基於 20260606000030_payable_round_to_integer.sql
--     （最新版）原樣重建，僅加 stockout 欄位；items_total / payable 計算不動。
--
-- 連動規則：
--   - 斷貨 SKU = PO 品項中 qty_received = 0 者（部分到貨的 SKU 不視為斷貨，
--     已到的貨會走正常撿貨 / 分貨流程）。
--   - 訂單品項只動 status='pending' 的（reserved/ready 表示已有庫存動作，
--     不該由斷貨自動取消）。
--   - 訂單單頭只在「全部品項都已取消/過期、且未付款、未用儲值金」時
--     自動轉 cancelled；有付款的單留給人工處理退款後再取消。
--
-- Rollback：
--   - rpc_stockout_purchase_order 還原為 20260702010000 版本
--   - v_customer_order_summary 還原為 20260606000030 版本
--   - ALTER TABLE campaign_items / customer_order_items / customer_orders
--       DROP COLUMN IF EXISTS stockout_at;
-- ============================================================

-- ------------------------------------------------------------
-- 1. 斷貨標記欄位
-- ------------------------------------------------------------

ALTER TABLE campaign_items
  ADD COLUMN IF NOT EXISTS stockout_at TIMESTAMPTZ;

ALTER TABLE customer_order_items
  ADD COLUMN IF NOT EXISTS stockout_at TIMESTAMPTZ;

ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS stockout_at TIMESTAMPTZ;

COMMENT ON COLUMN campaign_items.stockout_at IS
  '供應商斷貨時間；NULL = 正常。由 rpc_stockout_purchase_order 寫入';
COMMENT ON COLUMN customer_order_items.stockout_at IS
  '斷貨取消標記；非 NULL 時 status=cancelled 是因斷貨而非一般取消，UI 顯示「斷貨」';
COMMENT ON COLUMN customer_orders.stockout_at IS
  '整筆訂單因斷貨而結束的時間；部分斷貨（還有其他品項）不會設';

-- ------------------------------------------------------------
-- 2. RPC: rpc_stockout_purchase_order v2 — 加上連動
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_stockout_purchase_order(
  p_po_id    BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_po              purchase_orders%ROWTYPE;
  v_received        NUMERIC(18,3);
  v_new_status      TEXT;
  v_stockout_skus   BIGINT[];
  v_campaign_ids    BIGINT[];
  v_ci_count        INTEGER := 0;
  v_coi_count       INTEGER := 0;
  v_order_count     INTEGER := 0;
  v_notified        INTEGER := 0;
BEGIN
  SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到採購單 #%', p_po_id;
  END IF;

  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION '採購單 % 狀態為「%」、不可標記斷貨（需為「已發送」或「部分到貨」）',
      v_po.po_no, v_po.status;
  END IF;

  SELECT COALESCE(SUM(qty_received), 0) INTO v_received
    FROM purchase_order_items
   WHERE po_id = p_po_id;

  v_new_status := CASE WHEN v_received > 0 THEN 'closed' ELSE 'cancelled' END;

  UPDATE purchase_orders
     SET status          = v_new_status,
         stockout_at     = NOW(),
         stockout_by     = p_operator,
         stockout_reason = NULLIF(BTRIM(p_reason), ''),
         updated_by      = p_operator,
         updated_at      = NOW()
   WHERE id = p_po_id;

  -- ── 連動範圍 ─────────────────────────────────────────────
  -- 斷貨 SKU：此 PO 完全沒到貨的品項（部分到貨的 SKU 走正常分貨）
  SELECT ARRAY_AGG(sku_id) INTO v_stockout_skus
    FROM purchase_order_items
   WHERE po_id = p_po_id
     AND COALESCE(qty_received, 0) = 0;

  -- 受影響開團：PO → PR → purchase_request_campaigns
  SELECT ARRAY_AGG(DISTINCT prc.campaign_id) INTO v_campaign_ids
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_request_campaigns prc ON prc.pr_id = pri.pr_id
   WHERE poi.po_id = p_po_id;

  IF v_stockout_skus IS NOT NULL AND v_campaign_ids IS NOT NULL THEN

    -- (a) 開團商品標記斷貨
    UPDATE campaign_items
       SET stockout_at = NOW(),
           updated_by  = p_operator,
           updated_at  = NOW()
     WHERE campaign_id = ANY(v_campaign_ids)
       AND sku_id = ANY(v_stockout_skus)
       AND stockout_at IS NULL;
    GET DIAGNOSTICS v_ci_count = ROW_COUNT;

    -- (b) 顧客訂單品項：pending → cancelled + 斷貨標記
    UPDATE customer_order_items coi
       SET status      = 'cancelled',
           stockout_at = NOW(),
           updated_by  = p_operator,
           updated_at  = NOW()
      FROM customer_orders co
     WHERE co.id = coi.order_id
       AND co.campaign_id = ANY(v_campaign_ids)
       AND coi.sku_id = ANY(v_stockout_skus)
       AND coi.status = 'pending'
       AND coi.stockout_at IS NULL;
    GET DIAGNOSTICS v_coi_count = ROW_COUNT;

    -- (c) 訂單單頭：全部品項都已取消/過期 + 沒收過錢 → 整單取消（斷貨標記）
    --     有付款 / 用過儲值金的單不自動取消，留給人工退款流程
    UPDATE customer_orders co
       SET status       = 'cancelled',
           cancelled_at = NOW(),
           stockout_at  = NOW(),
           updated_by   = p_operator,
           updated_at   = NOW()
     WHERE co.campaign_id = ANY(v_campaign_ids)
       AND co.status IN ('pending','confirmed')
       AND COALESCE(co.payment_status, 'unpaid') <> 'paid'
       AND COALESCE(co.wallet_paid_amount, 0) = 0
       AND EXISTS (
             SELECT 1 FROM customer_order_items x
              WHERE x.order_id = co.id
                AND x.stockout_at IS NOT NULL
           )
       AND NOT EXISTS (
             SELECT 1 FROM customer_order_items x
              WHERE x.order_id = co.id
                AND x.status NOT IN ('cancelled','expired')
           );
    GET DIAGNOSTICS v_order_count = ROW_COUNT;

    -- (d) 顧客通知（in-app 通知中心留底；綁定會員的訂單才發得了）
    INSERT INTO notifications (tenant_id, member_id, category, title, body, url)
    SELECT
      co.tenant_id,
      co.member_id,
      'stockout',
      '商品斷貨通知',
      '您訂購的「' || string_agg(DISTINCT COALESCE(sk.product_name, sk.sku_code)
                                  || COALESCE('-' || sk.variant_name, ''), '、')
        || '」因供應商斷貨無法供貨，相關品項已取消，造成不便敬請見諒。',
      '/orders'
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    JOIN skus sk ON sk.id = coi.sku_id
    WHERE co.campaign_id = ANY(v_campaign_ids)
      AND coi.sku_id = ANY(v_stockout_skus)
      AND coi.stockout_at IS NOT NULL
      AND co.member_id IS NOT NULL
    GROUP BY co.tenant_id, co.member_id;
    GET DIAGNOSTICS v_notified = ROW_COUNT;

  END IF;

  RETURN jsonb_build_object(
    'po_no',            v_po.po_no,
    'new_status',       v_new_status,
    'stockout_skus',    COALESCE(array_length(v_stockout_skus, 1), 0),
    'campaign_items',   v_ci_count,
    'order_items',      v_coi_count,
    'orders_cancelled', v_order_count,
    'members_notified', v_notified
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stockout_purchase_order TO authenticated;

COMMENT ON FUNCTION public.rpc_stockout_purchase_order IS
  '供應商斷貨：PO 結掉（有到貨→closed、無到貨→cancelled）＋連動標記開團商品 / '
  '顧客訂單品項（pending→cancelled+stockout_at）／未付款全斷訂單整單取消／寫入顧客通知';

-- ------------------------------------------------------------
-- 3. v_customer_order_summary v2 — 加 stockout 欄位
--    （基於 20260606000030 原樣重建；僅多 co.stockout_at 與
--      items[].stockout，金額計算完全不動）
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
  GREATEST(
    0,
    ROUND(
      agg.items_total * (1 - co.discount_percent / 100)
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
        agg.items_total * (1 - co.discount_percent / 100)
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
) agg ON TRUE;

COMMENT ON VIEW v_customer_order_summary IS
  'LIFF 顧客端共用：訂單聚合 + 品項詳細 + percent + amount 雙折扣 + 儲值金抵扣 + balance_due'
  '（應收已四捨五入到整數 NTD）+ 斷貨標記（stockout_at / items[].stockout）';
